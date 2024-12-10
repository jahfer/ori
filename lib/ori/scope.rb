# typed: true
# frozen_string_literal: true

require "nio"
require "random/formatter"

module Ori
  class Scope
    class CancellationError < StandardError
      attr_reader :scope

      def initialize(scope, message = "Scope cancelled")
        @scope = scope
        super(message)
      end
    end

    class << self
      def boundary(name: nil, cancel_after: nil, raise_after: nil, &block)
        prev_scheduler = Fiber.current_scheduler
        nested_scope = prev_scheduler.is_a?(Scope)
        scope = if nested_scope
          Scope.new(prev_scheduler, name: name)
        else
          Scope.new(name: name)
        end

        # Set timeout if specified
        deadline = cancel_after || raise_after
        scope.deadline(deadline) if deadline

        Fiber.set_scheduler(scope)

        begin
          if Fiber.current.blocking?
            scope.fork { block.call(scope) }
          else
            yield(scope)
          end

          scope.await
          scope
        rescue CancellationError => error
          # Re-raise if:
          # 1. The error is from a different scope, or
          # 2. This is our error but it's from raise_after
          raise if error.scope != scope || !raise_after.nil?

          scope # Return the scope even when cancelled
        ensure
          Fiber.set_scheduler(prev_scheduler)
        end
      end
    end

    attr_reader :scope_id,
      :parent_scope,
      :fiber_ids,
      :readable,
      :writable,
      :waiting,
      :tracer,
      :child_scopes,
      :deadline_owner

    def initialize(parent_scope = nil, name: nil)
      @scope_id = Random.uuid_v7(extra_timestamp_bits: 12)
      @name = name
      @parent_scope = parent_scope
      @tracer = parent_scope&.tracer || Tracer.new
      @cancelled = false
      @cancel_reason = nil

      # Inherit parent's deadline if it exists
      if parent_scope&.remaining_deadline
        @deadline_at = current_time + parent_scope.remaining_deadline
        @deadline_owner = parent_scope.deadline_owner
      end

      # Get the creating fiber's ID from the parent scope if we're in a fiber
      creating_fiber_id = if parent_scope
        parent_scope.fiber_ids[Fiber.current]
      end

      @tracer.register_scope(@scope_id, parent_scope&.scope_id, creating_fiber_id, name: @name)

      @pending = []
      @ready = {}
      @fiber_ids = {}
      @closed = false

      @readable = Hash.new { |h, k| h[k] = Set.new }
      @writable = Hash.new { |h, k| h[k] = Set.new }
      @waiting = {}
      @sleeping = {}

      @tracer.record_scope(@scope_id, :opened)

      @child_scopes = Set.new

      @parent_scope&.register_child_scope(self)
    end

    def tag(name)
      @tracer.record_scope(@scope_id, :tag, name)
    end

    def print_ascii_trace
      @tracer.visualize
    end

    def write_html_trace(directory)
      @tracer.write_timeline_data(directory)
    end

    def await
      while pending_work?
        process_available_work
        Fiber.yield if parent_scope && pending_work?
      end
    ensure
      close_scope
      @parent_scope&.deregister_child_scope(self)
    end

    def fiber(&block)
      create_and_run_fiber(&block)
    end
    alias_method :fork, :fiber

    def fork_each(enumerable)
      return enum_for(:fork_each, enumerable) unless block_given?

      enumerable.each { |item| fork { yield(item) } }
    end

    def next_id
      Random.uuid_v7(extra_timestamp_bits: 12)
    end

    def io_wait(io, events, timeout = nil)
      return @parent_scope.io_wait(io, events, timeout) unless @fiber_ids.key?(Fiber.current)

      fiber = Fiber.current
      id = @fiber_ids[fiber]
      @tracer.record(id, :waiting_io, "#{io.inspect}:#{events}")

      added = register_io_wait(fiber, io, events)
      register_timeout(fiber, timeout)

      Fiber.yield

      if added[:readable] && added[:writable]
        IO::READABLE | IO::WRITABLE
      elsif added[:readable]
        IO::READABLE
      elsif added[:writable]
        IO::WRITABLE
      else
        0
      end
    ensure
      cleanup_io_wait(fiber, io, added)
      @waiting.delete(fiber) if timeout
    end

    def io_select(readables, writables, exceptables, timeout)
      unless @fiber_ids.key?(Fiber.current)
        return @parent_scope.io_select(readables, writables, exceptables, timeout)
      end

      selector = NIO::Selector.new

      readables&.each do |io|
        selector.register(io, :r)
      end

      writables&.each do |io|
        selector.register(io, :w)
      end

      begin
        ready = selector.select(timeout)
        return [], [], [] if ready.nil?

        readable = []
        writable = []
        exceptional = []

        ready.each do |monitor|
          if monitor.readable?
            readable << monitor.io
          end
          if monitor.writable?
            writable << monitor.io
          end
        end

        [readable, writable, exceptional]
      ensure
        selector.close
      end
    end

    # def io_write(...) = ()
    # def io_pread(...) = ()
    # def io_pwrite(...) = ()

    # def process_wait(...) = ()
    # def timeout_after(...) = ()
    # def address_resolve(...) = ()

    def kernel_sleep(duration)
      return @parent_scope.kernel_sleep(duration) unless @fiber_ids.key?(Fiber.current)

      fiber = Fiber.current
      id = @fiber_ids[fiber]
      @tracer.record(id, :sleeping, duration)

      if duration > 0
        register_timeout(fiber, duration)
        @sleeping[fiber] = current_time + duration
        Fiber.yield
      end
    ensure
      @sleeping.delete(fiber)
    end

    def block(...)
      unless @fiber_ids.key?(Fiber.current)
        return @parent_scope.block(...) if @parent_scope
      end

      Fiber.yield
    end

    def unblock(blocker, fiber)
      unless @fiber_ids.key?(Fiber.current)
        return @parent_scope.unblock(blocker, fiber) if @parent_scope
      end

      resume_fiber(fiber)
    end

    def closed? = @closed

    def deadline(duration)
      @parent_scope&.remaining_deadline

      # If we already have a deadline (inherited or set), use the shorter one
      current_remaining = remaining_deadline
      return if current_remaining && current_remaining < duration

      @deadline_at = current_time + duration
      @deadline_owner = self
    end

    def cancel!(cause = nil)
      return if @cancelled

      @cancelled = true
      @cancel_reason = cause
      cancellation_error = cause.is_a?(CancellationError) ? cause : CancellationError.new(self, cause)

      @tracer.record_scope(@scope_id, :cancelling, cancellation_error.message)

      @child_scopes.each do |scope|
        scope.cancel!(cause)
      end

      @pending.each do |fiber|
        cancel_fiber(fiber, cancellation_error)
      end

      @waiting.each do |fiber, _|
        cancel_fiber(fiber, cancellation_error)
      end

      @sleeping.each do |fiber, _|
        cancel_fiber(fiber, cancellation_error)
      end

      cleanup_io_resources

      @tracer.record_scope(@scope_id, :cancelled)
    end

    protected

    def remaining_deadline
      return unless @deadline_at

      remaining = @deadline_at - current_time
      remaining.positive? ? remaining : 0
    end

    def pending_work?
      return false if closed?

      @readable.values.any? { |fibers| fibers.any?(&:alive?) } ||
        @writable.values.any? { |fibers| fibers.any?(&:alive?) } ||
        @waiting.any? { |fiber, _| fiber.alive? } ||
        @sleeping.any? { |fiber, _| fiber.alive? } ||
        @pending.any?(&:alive?) ||
        @child_scopes.any? { |scope| scope.pending_work? } # rubocop:disable Style/SymbolProc
    end

    def register_child_scope(scope)
      @child_scopes.add(scope)
    end

    def deregister_child_scope(scope)
      @child_scopes.delete(scope)
    end

    private

    def close_scope
      @closed = true
      @tracer.record_scope(@scope_id, :closed)
    end

    def process_available_work
      check_deadline
      cleanup_dead_fibers

      process_pending_fibers
      process_io_operations
      handle_timeouts(current_time)
    end

    def process_pending_fibers
      fibers = @pending
      @pending = []

      fibers.each do |fiber|
        next if @sleeping.key?(fiber)

        resume_fiber(fiber)
      end
    end

    def process_io_operations
      return if @readable.none? && @writable.none?

      readable, writable = IO.select(@readable.keys, @writable.keys, [], next_timeout)

      process_ready_io(readable, @readable)
      process_ready_io(writable, @writable)
    end

    def process_ready_io(ready_ios, io_map)
      return unless ready_ios

      ready_ios.each do |io|
        io_map[io].each { |fiber| resume_fiber(fiber) }
      end
    end

    def check_deadline
      return unless @deadline_at

      if current_time >= @deadline_at
        error = CancellationError.new(@deadline_owner)
        cancel!(error)
        raise error
      end
    end

    def cancel_fiber(fiber, error)
      return unless fiber.alive?

      id = @fiber_ids[fiber]
      @tracer.record(id, :cancelling, error.message)

      begin
        fiber.raise(error)
      rescue CancellationError => e
        @tracer.record(id, :cancelled, e.message)
        fiber.kill
      end
    end

    def cleanup_dead_fibers
      dead_fibers = @fiber_ids.keys.reject(&:alive?).to_set
      return if dead_fibers.empty?

      # Clean up dead fibers from all collections
      @readable.each_value { |fibers| fibers.subtract(dead_fibers) }
      @readable.delete_if { |_, fibers| fibers.empty? }

      @writable.each_value { |fibers| fibers.subtract(dead_fibers) }
      @writable.delete_if { |_, fibers| fibers.empty? }

      @waiting.delete_if { |fiber, _| !fiber.alive? }
      @sleeping.delete_if { |fiber, _| !fiber.alive? }

      dead_fibers.each { |fiber| @fiber_ids.delete(fiber) }
    end

    def handle_timeouts(now = current_time)
      check_deadline

      fibers_to_resume = []
      @waiting.each_key do |fiber|
        if @waiting[fiber] <= now
          fibers_to_resume << fiber
        end
      end

      fibers_to_resume.each do |fiber|
        @waiting.delete(fiber)
        resume_fiber(fiber)
      end

      fibers_to_resume = []
      @sleeping.each_key do |fiber|
        deadline = @sleeping[fiber]
        next if deadline.nil?

        if deadline <= now
          fibers_to_resume << fiber
        end
      end

      fibers_to_resume.each do |fiber|
        @sleeping.delete(fiber)
        resume_fiber(fiber)
      end
    end

    def next_timeout
      timeouts = T.let([], T::Array[Numeric])

      # Add IO wait timeouts
      timeouts.concat(@waiting.values) unless @waiting.empty?

      # Add sleep timeouts (excluding nil values for indefinite sleeps)
      timeouts.concat(@sleeping.values.compact) unless @sleeping.empty?

      # Add deadline timeout if one exists
      timeouts << @deadline_at if @deadline_at

      return 0 if timeouts.empty?

      # Calculate the nearest timeout
      nearest = T.must(timeouts.min)
      delay = nearest - current_time

      # Return 0 if the timeout is in the past, otherwise return the delay
      [0, delay].max
    end

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def cleanup_io_resources
      @readable.keys.each do |io|
        io.close unless io.closed?
      rescue => e
        @tracer.record_scope(@scope_id, :error, "Failed to close readable: #{e.message}")
      end

      @writable.keys.each do |io|
        io.close unless io.closed?
      rescue => e
        @tracer.record_scope(@scope_id, :error, "Failed to close writable: #{e.message}")
      end
    end

    def resume_fiber(fiber)
      return unless fiber.alive?

      id = @fiber_ids[fiber]
      # @tracer.record(id, :resuming)

      begin
        # TODO: Unnecessary?
        raise CancellationError.new(self, @cancel_reason) if @cancelled

        fiber.resume
        if fiber.alive?
          @pending << fiber
          # @tracer.record(id, :yielded)
        end
      rescue CancellationError => error
        @tracer.record(id, :cancelled, error.message)
        fiber.kill
      rescue => error
        @tracer.record(id, :error, error.message)
        cancel!(error)
        raise error
      end
      @tracer.record(id, :completed) unless fiber.alive?
    end

    def create_and_run_fiber(&block)
      raise CancellationError.new(self, @cancel_reason) if @cancelled
      raise "Scope is closed" if closed?

      id = next_id
      fiber = Fiber.new(&block)
      @fiber_ids[fiber] = id
      @tracer.register_fiber(id, @scope_id)
      @tracer.record(id, :created)

      resume_fiber(fiber)
      fiber
    end

    def register_timeout(fiber, deadline)
      return unless deadline

      @waiting[fiber] = current_time + deadline
    end

    def register_io_wait(fiber, io, events)
      added = {
        readable: T.let(false, T::Boolean),
        writable: T.let(false, T::Boolean),
      }

      if (events & IO::READABLE).nonzero?
        @readable[io].add(fiber)
        added[:readable] = true
      end

      if (events & IO::WRITABLE).nonzero?
        @writable[io].add(fiber)
        added[:writable] = true
      end

      added
    end

    def cleanup_io_wait(fiber, io, added)
      @readable[io].delete(fiber) if added[:readable]
      @writable[io].delete(fiber) if added[:writable]

      @readable.delete(io) if @readable[io]&.empty?
      @writable.delete(io) if @writable[io]&.empty?
    end
  end
end
