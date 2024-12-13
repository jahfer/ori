# typed: true
# frozen_string_literal: true

require "nio"
require "random/formatter"
require "ori/channel"

module Ori
  class Scope
    attr_reader :tracer

    def initialize(parent_scope = nil, deadline: nil, name: nil, trace: false)
      @scope_id = Random.uuid_v7(extra_timestamp_bits: 12)
      @name = name
      @parent_scope = parent_scope
      @tracer = if trace || parent_scope&.tracing?
        parent_scope&.tracer || Tracer.new
      end
      @cancelled = false
      @cancel_reason = nil

      @pending = []
      @ready = {}
      @fiber_ids = {}
      @closed = false

      @readable = Hash.new { |h, k| h[k] = Set.new }
      @writable = Hash.new { |h, k| h[k] = Set.new }
      @waiting = {}
      @blocked = {}
      @child_scopes = Set.new

      inherit_or_set_deadline(deadline)

      if @tracer
        creating_fiber_id = parent_scope.fiber_ids[Fiber.current] if parent_scope
        @tracer.register_scope(@scope_id, parent_scope&.scope_id, creating_fiber_id, name: @name)
        @parent_scope&.register_child_scope(self)
        @tracer.record_scope(@scope_id, :opened)
      end
    end

    # Users are not expected to call this method directly
    # This is the event loop for an Ori::Scope instance
    def await
      while pending_work?
        process_available_work
        Fiber.yield if parent_scope && pending_work?
      end
    ensure
      close_scope
      @parent_scope&.deregister_child_scope(self)
    end

    # Public API

    def async(&block)
      fiber(&block)
    end

    def each_async(enumerable)
      return enum_for(:each_async, enumerable) unless block_given?

      enumerable.each { |item| async { yield(item) } }
    end

    def closed? = @closed

    def tracing? = !@tracer.nil?

    def cancel!(cause = nil)
      return if @cancelled

      @cancelled = true
      @cancel_reason = cause
      cancellation_error = cause.is_a?(CancellationError) ? cause : CancellationError.new(self)

      @tracer&.record_scope(@scope_id, :cancelling, cancellation_error.message)

      @child_scopes.each do |scope|
        scope.cancel!(cause)
      end

      (@pending + @waiting.keys + @blocked.keys).each do |fiber|
        cancel_fiber!(fiber, cancellation_error)
      end

      cleanup_io_resources

      @tracer&.record_scope(@scope_id, :cancelled)
    end

    def tag(name)
      @tracer&.record_scope(@scope_id, :tag, name)
    end

    def print_ascii_trace
      @tracer&.visualize
    end

    def write_html_trace(directory)
      @tracer&.write_timeline_data(directory)
    end

    # Ruby FiberScheduler interface implementation

    def fiber(&block)
      create_and_run_fiber(&block)
    end

    def io_wait(io, events, timeout = nil)
      return @parent_scope.io_wait(io, events, timeout) unless @fiber_ids.key?(Fiber.current)

      fiber = Fiber.current
      id = @fiber_ids[fiber]
      @tracer&.record(id, :waiting_io, "#{io.inspect}:#{events}")

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
      cleanup_timeout(fiber) if timeout
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
          readable << monitor.io if monitor.readable?
          writable << monitor.io if monitor.writable?
        end

        [readable, writable, exceptional]
      ensure
        selector.close
      end
    end

    def kernel_sleep(duration)
      return @parent_scope.kernel_sleep(duration) unless @fiber_ids.key?(Fiber.current)

      fiber = Fiber.current
      id = @fiber_ids[fiber]
      @tracer&.record(id, :sleeping, duration)

      if duration > 0
        register_timeout(fiber, duration)
        Fiber.yield
      end
    ensure
      cleanup_timeout(fiber)
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

    # def io_write(...) = ()
    # def io_pread(...) = ()
    # def io_pwrite(...) = ()

    # TODO: Implement these
    # def process_wait(...) = ()
    # def timeout_after(...) = ()
    # def address_resolve(...) = ()

    protected

    attr_reader :fiber_ids
    attr_reader :scope_id
    attr_reader :deadline_owner

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
        @blocked.any? { |fiber, _| fiber.alive? } ||
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

    attr_reader :parent_scope
    attr_reader :readable
    attr_reader :writable
    attr_reader :waiting
    attr_reader :child_scopes

    # Scope lifecycle

    def inherit_or_set_deadline(duration)
      parent_deadline = parent_scope&.remaining_deadline

      if parent_deadline && (duration.nil? || parent_deadline < duration)
        # Inherit parent's deadline
        @deadline_at = current_time + parent_deadline
        @deadline_owner = parent_scope.deadline_owner
      elsif duration
        @deadline_at = current_time + duration
        @deadline_owner = self
      end
    end

    def process_available_work
      check_deadline!
      cleanup_dead_fibers

      process_pending_fibers
      process_blocked_fibers
      process_io_operations
      process_timeouts(current_time)
    end

    def process_pending_fibers
      fibers = @pending
      @pending = []

      fibers.each do |fiber|
        next if @waiting.key?(fiber)

        resume_fiber(fiber)
      end
    end

    def process_blocked_fibers
      fibers_to_resume = []

      @blocked.each do |fiber, resource|
        case resource
        when Ori::Channel
          fibers_to_resume << fiber if resource.value?
        when Ori::Promise
          fibers_to_resume << fiber if resource.resolved?
        when Ori::Semaphore
          fibers_to_resume << fiber if resource.available?
        end
      end

      fibers_to_resume.each do |fiber|
        @blocked.delete(fiber)
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

    def close_scope
      @closed = true
      @tracer&.record_scope(@scope_id, :closed)
    end

    # Timeouts and deadlines

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def process_timeouts(now = current_time)
      check_deadline!

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
    end

    def check_deadline!
      return unless @deadline_at

      if current_time >= @deadline_at
        error = CancellationError.new(@deadline_owner)
        cancel!(error)
        raise error
      end
    end

    def next_timeout
      timeouts = T.let([], T::Array[Numeric])
      timeouts.concat(@waiting.values.compact) unless @waiting.empty?
      timeouts << @deadline_at if @deadline_at

      return 0 if timeouts.empty?

      nearest = T.must(timeouts.min)
      delay = nearest - current_time

      # Return 0 if the timeout is in the past, otherwise return the delay
      [0, delay].max
    end

    # Fiber management

    def create_and_run_fiber(&block)
      raise CancellationError.new(self, @cancel_reason) if @cancelled
      raise "Scope is closed" if closed?

      fiber = Fiber.new(&block)
      id = @tracer ? generate_fiber_id : fiber.object_id
      @fiber_ids[fiber] = id
      if @tracer
        @tracer.register_fiber(id, @scope_id)
        @tracer.record(id, :created)
      end

      resume_fiber(fiber)
      fiber
    end

    def generate_fiber_id
      Random.uuid_v7(extra_timestamp_bits: 12)
    end

    def resume_fiber(fiber)
      return unless fiber.alive?

      id = @fiber_ids[fiber]

      begin
        raise CancellationError.new(self, @cancel_reason) if @cancelled

        case maybe_blocked_resource = fiber.resume
        when Ori::Channel, Ori::Promise, Ori::Semaphore
          # Special case for channels, promises, and semaphores
          # as we can detect when they are ready without naïvely
          # resuming the fiber.
          @blocked[fiber] = maybe_blocked_resource
        else
          @pending << fiber if fiber.alive?
        end
      rescue CancellationError => error
        @tracer&.record(id, :cancelled, error.message)
        fiber.kill
      rescue => error
        @tracer&.record(id, :error, error.message)
        cancel!(error)
        raise error
      end
      @tracer&.record(id, :completed) unless fiber.alive?
    end

    def cancel_fiber!(fiber, error)
      return unless fiber.alive?

      id = @fiber_ids[fiber]
      @tracer&.record(id, :cancelling, error.message)

      begin
        fiber.raise(error)
      rescue CancellationError => e
        @tracer&.record(id, :cancelled, e.message)
        fiber.kill
      end
    end

    # Registration

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

    # Cleanup

    def cleanup_dead_fibers
      dead_fibers = @fiber_ids.keys.reject(&:alive?).to_set
      return if dead_fibers.empty?

      @readable.each_value { |fibers| fibers.subtract(dead_fibers) }
      @readable.delete_if { |_, fibers| fibers.empty? }

      @writable.each_value { |fibers| fibers.subtract(dead_fibers) }
      @writable.delete_if { |_, fibers| fibers.empty? }

      @waiting.delete_if { |fiber, _| !fiber.alive? }

      dead_fibers.each { |fiber| @fiber_ids.delete(fiber) }
    end

    def cleanup_io_resources
      @readable.keys.each do |io|
        io.close unless io.closed?
      rescue => e
        @tracer&.record_scope(@scope_id, :error, "Failed to close readable: #{e.message}")
      end

      @writable.keys.each do |io|
        io.close unless io.closed?
      rescue => e
        @tracer&.record_scope(@scope_id, :error, "Failed to close writable: #{e.message}")
      end
    end

    def cleanup_io_wait(fiber, io, added)
      @readable[io].delete(fiber) if added[:readable]
      @writable[io].delete(fiber) if added[:writable]

      @readable.delete(io) if @readable[io]&.empty?
      @writable.delete(io) if @writable[io]&.empty?
    end

    def cleanup_timeout(fiber)
      @waiting.delete(fiber)
    end
  end
end
