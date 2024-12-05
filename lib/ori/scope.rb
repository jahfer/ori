# typed: true
# frozen_string_literal: true

require "nio"
require "random/formatter"

module Ori
  class Scope
    class CancellationError < StandardError; end

    class << self
      def boundary(name: nil, &block)
        old_scheduler = Fiber.current_scheduler
        nested_scope = old_scheduler.is_a?(Scope)
        scope = if nested_scope
          Scope.new(old_scheduler, name: name)
        else
          Scope.new(name: name)
        end

        Fiber.set_scheduler(scope)

        # Ensure the block runs in a non-blocking fiber,
        # particularly because the root fiber is blocking
        if Fiber.current.blocking?
          scope.fork { block.call(scope) }
        else
          yield(scope)
        end

        scope.await
      ensure
        Fiber.set_scheduler(old_scheduler)
      end
    end

    attr_reader :scope_id, :parent_scope, :fiber_ids, :readable, :writable, :waiting, :tracer, :child_scopes

    def initialize(parent_scope = nil, name: nil)
      @scope_id = Random.uuid_v7(extra_timestamp_bits: 12)
      @name = name
      @parent_scope = parent_scope
      @tracer = parent_scope&.tracer || Tracer.new
      @cancelled = false
      @cancel_reason = nil

      # Get the creating fiber's ID from the parent scope if we're in a fiber
      creating_fiber_id = if parent_scope
        parent_scope.fiber_ids[Fiber.current]
      end

      # Register this scope with the tracer, now passing the name
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

      # If we have a parent scope, register ourselves with it
      @parent_scope&.register_child_scope(self)
    end

    def tag(name)
      @tracer.record_scope(@scope_id, :tag, name)
    end

    def trace_visualization
      @tracer.visualize
    end

    def await
      # RubyLogger.debug("await: starting event loop")
      while pending_work?
        process_available_work
        Fiber.yield if parent_scope && pending_work?
      end
    ensure
      close_scope
      # Deregister from parent when done
      @parent_scope&.deregister_child_scope(self)

      # Only output visualization and write timeline data if we're the root scope
      if @parent_scope.nil?
        puts trace_visualization
        @tracer.write_timeline_data(File.join(__dir__, "out", "script.js"))
      end
    end

    def fiber(&block)
      raise CancellationError, @cancel_reason if @cancelled
      raise "Scope is closed" if closed?

      id = next_id
      f = Fiber.new(&block)
      @fiber_ids[f] = id
      @tracer.register_fiber(id, @scope_id)
      @tracer.record(id, :created)

      resume_fiber(f)

      f
    end
    alias_method :fork, :fiber

    def next_id
      Random.uuid_v7(extra_timestamp_bits: 12)
    end

    # Fiber::Scheduler hooks

    # This hook is invoked by `IO#read` and `IO#write` in the case that `io_read`
    # and `io_write` hooks are not available. This implementation is not
    # completely general, in the sense that calling `io_wait` multiple times with
    # the same `io` and `events` will not work, which is okay for tests but not
    # for real code. Correct fiber schedulers should not have this limitation.
    def io_wait(io, events, timeout = nil)
      unless @fiber_ids.key?(Fiber.current)
        return @parent_scope.io_wait(io, events, timeout)
      end

      # RubyLogger.debug("io_wait: #{io}, #{events}, #{timeout}")
      fiber = Fiber.current
      id = @fiber_ids[fiber]

      @tracer.record(id, :waiting_io, "#{io.inspect}:#{events}")

      # Track if we added to readable/writable for cleanup
      added_readable = false
      added_writable = false

      # Check for readable events
      if (events & IO::READABLE).nonzero?
        @readable[io].add(fiber)
        added_readable = true
      end

      # Check for writable events
      if (events & IO::WRITABLE).nonzero?
        @writable[io].add(fiber)
        added_writable = true
      end

      # Handle timeout
      if timeout
        @waiting[fiber] = current_time + timeout
      end

      Fiber.yield

      # RubyLogger.debug("io_wait: #{io}, #{events}, #{timeout} - resuming")

      if added_readable && added_writable
        IO::READABLE | IO::WRITABLE
      elsif added_readable
        IO::READABLE
      elsif added_writable
        IO::WRITABLE
      else
        0
      end
    ensure
      @waiting.delete(fiber) if timeout
      @readable[io].delete(fiber) if added_readable
      @writable[io].delete(fiber) if added_writable

      @readable.delete(io) if @readable[io].empty?
      @writable.delete(io) if @writable[io].empty?
    end

    def io_select(readables, writables, exceptables, timeout)
      unless @fiber_ids.key?(Fiber.current)
        return @parent_scope.io_select(readables, writables, exceptables, timeout)
      end

      # RubyLogger.debug("io_select: #{readables}, #{writables}, #{exceptables}, #{timeout}")

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

    def kernel_sleep(duration)
      unless @fiber_ids.key?(Fiber.current)
        return @parent_scope.kernel_sleep(duration)
      end

      # RubyLogger.debug("kernel_sleep: #{duration}")
      fiber = Fiber.current
      id = @fiber_ids[fiber]

      @tracer.record(id, :sleeping, duration)

      if duration > 0
        @sleeping[fiber] = current_time + duration
        Fiber.yield
      end

      # RubyLogger.debug("kernel_sleep: #{duration} - resuming")
    end

    # def process_wait(...) = ()
    # def timeout_after(...) = ()
    # def address_resolve(...) = ()

    def block(...)
      unless @fiber_ids.key?(Fiber.current)
        return @parent_scope.block(...)
      end

      Fiber.yield
    end

    def unblock(blocker, fiber)
      unless @fiber_ids.key?(Fiber.current)
        return @parent_scope.unblock(blocker, fiber)
      end

      resume_fiber(fiber)
    end

    def closed? = @closed

    protected

    def close_scope
      @closed = true
      @tracer.record_scope(@scope_id, :closed)
    end

    def pending_work?
      return false if closed?

      @readable.values.any? { |fibers| fibers.any?(&:alive?) } ||
        @writable.values.any? { |fibers| fibers.any?(&:alive?) } ||
        @waiting.any? { |fiber, _| fiber.alive? } ||
        @sleeping.any? { |fiber, _| fiber.alive? } ||
        @pending.any?(&:alive?) ||
        @child_scopes.any?(&:pending_work?)
    end

    def register_child_scope(scope)
      @child_scopes.add(scope)
    end

    def deregister_child_scope(scope)
      @child_scopes.delete(scope)
    end

    def process_available_work
      @tracer.record_scope(@scope_id, :awaiting)

      cleanup_dead_fibers

      # Process pending fibers, skipping sleeping ones
      # Note: resume_fiber may re-append to @pending if work remains
      fibers_to_process = @pending
      @pending = []
      fibers_to_process.each do |fiber|
        next if @sleeping.key?(fiber)

        resume_fiber(fiber)
      end

      readable, writable = IO.select(
        @readable.keys,
        @writable.keys,
        [],
        next_timeout,
      )

      # Handle readable IOs
      readable&.each do |io|
        @readable[io].each do |fiber|
          # RubyLogger.debug("io_select: readable #{io} - resuming")
          resume_fiber(fiber)
        end
      end

      # Handle writable IOs
      writable&.each do |io|
        @writable[io].each do |fiber|
          # RubyLogger.debug("io_select: writable #{io} - resuming")
          resume_fiber(fiber)
        end
      end

      handle_timeouts(current_time)
    end

    def cancel!(reason = nil)
      return if @cancelled

      @cancelled = true
      @cancel_reason = reason
      cancellation_error = CancellationError.new(reason)

      @tracer.record_scope(@scope_id, :cancelling, cancellation_error.message)

      @child_scopes.each do |scope|
        scope.cancel!(@cancel_reason)
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
      # rescue => e
      #   RubyLogger.error("Error in Ori::Scope#cancel! [#{e.class}] #{e.message}")
      #   raise e
    end

    private

    def cancel_fiber(fiber, error)
      return unless fiber.alive?

      id = @fiber_ids[fiber]
      # RubyLogger.error("Cancelling fiber #{id}")
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
        # RubyLogger.debug("handle_timeouts: sleeping deadline: #{deadline}")
        next if deadline.nil?

        if deadline <= now
          fibers_to_resume << fiber
        end
      end

      fibers_to_resume.each do |fiber|
        # RubyLogger.debug("handle_timeouts: resuming sleeping fiber")
        @sleeping.delete(fiber)
        resume_fiber(fiber)
      end
    end

    def next_timeout
      timeouts = []

      # Add IO wait timeouts
      timeouts.concat(@waiting.values) unless @waiting.empty?

      # Add sleep timeouts (excluding nil values for indefinite sleeps)
      timeouts.concat(@sleeping.values.compact) unless @sleeping.empty?

      return 0 if timeouts.empty?

      # Calculate the nearest timeout
      nearest = timeouts.min
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
      @tracer.record(id, :resuming)

      begin
        # TODO: Unnecessary?
        raise CancellationError, @cancel_reason if @cancelled

        if Fiber.current == fiber
          # RubyLogger.warn("Resuming fiber #{id} that is the current fiber")
        end
        fiber.resume
        if fiber.alive?
          @pending << fiber
          @tracer.record(id, :yielded)
        end
      rescue CancellationError => e
        @tracer.record(id, :cancelled, e.message)
        fiber.kill
      rescue => error
        @tracer.record(id, :error, error.message)
        # RubyLogger.error("Error in fiber #{id}: [#{error.class}] #{error.message}")
        cancel!(error)
        raise error
      end
      @tracer.record(id, :completed) unless fiber.alive?
    end
  end
end
