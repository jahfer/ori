# typed: true
# frozen_string_literal: true

require "nio"
require "random/formatter"
require "ori/lazy"

module Ori
  class Scope
    extend(T::Sig)

    # Add thread-local state management
    class ThreadLocalState
      attr_reader :fiber_ids,
        :tasks,
        :pending,
        :readable,
        :writable,
        :waiting,
        :blocked

      def initialize
        @fiber_ids = LazyHash.new
        @tasks = LazyHash.new
        @pending = LazyArray.new
        @readable = LazyHashSet.new
        @writable = LazyHashSet.new
        @waiting = LazyHash.new
        @blocked = LazyHash.new
      end

      def child_scopes
        @child_scopes ||= Set.new
      end

      def child_scopes?
        defined?(@child_scopes) && !@child_scopes.empty?
      end
    end

    attr_reader :tracer

    HASH_SET_LAMBDA = ->(hash, key) { hash[key] = Set.new }

    def initialize(parent_scope, name, deadline = nil, trace = false)
      @name = name
      @parent_scope = parent_scope
      @parent_scope&.register_child_scope(self)

      @tracer = if trace || parent_scope&.tracing?
        parent_scope&.tracer || Tracer.new
      end

      @cancelled = false
      @closed = false

      # Instead, use thread-local storage
      thread_local_state[object_id] = ThreadLocalState.new

      inherit_or_set_deadline(deadline)

      if @tracer
        @scope_id = Random.uuid_v7(extra_timestamp_bits: 12)
        creating_fiber_id = parent_scope.fiber_ids[Fiber.current] if parent_scope
        @tracer.register_scope(@scope_id, parent_scope&.scope_id, creating_fiber_id, name: @name)
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

    def fork(&block)
      task = create_task(&block)
      resume_task_or_fiber(task) if task
      task
    end

    def fork_each(enumerable)
      return enum_for(:fork_each, enumerable) unless block_given?

      enumerable.each { |item| fork { yield(item) } }
    end

    def tasks
      task_queue.values
    end

    def closed? = @closed

    def tracing? = !@tracer.nil?

    def cancellation_error = @cancellation_error ||= CancellationError.new(self)

    def shutdown!(cause = nil)
      return if @cancelled

      @cancelled = true
      exn = cause.is_a?(CancellationError) ? cause : cancellation_error

      @tracer&.record_scope(@scope_id, :cancelling, exn.message)

      if child_scopes?
        child_scopes.each do |scope|
          scope.shutdown!(cause)
        end
      end

      pending.each { |fiber| cancel_fiber!(fiber, exn) }
      waiting.each { |fiber, _| cancel_fiber!(fiber, exn) }
      blocked.each { |fiber, _| cancel_fiber!(fiber, exn) }

      cleanup_io_resources

      @tracer&.record_scope(@scope_id, :cancelled)

      raise(cause || exn)
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
      task = fork(&block)
      task.fiber
    end

    def io_wait(io, events, timeout = nil)
      return @parent_scope.io_wait(io, events, timeout) unless fiber_ids.key?(Fiber.current)

      fiber = Fiber.current
      id = fiber_ids[fiber]
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
      unless fiber_ids.key?(Fiber.current)
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
      return @parent_scope.kernel_sleep(duration) unless fiber_ids.key?(Fiber.current)

      fiber = Fiber.current
      id = fiber_ids[fiber]
      @tracer&.record(id, :sleeping, duration)

      if duration > 0
        register_timeout(fiber, duration)
        Fiber.yield
      end
    ensure
      cleanup_timeout(fiber)
    end

    def block(...)
      unless fiber_ids.key?(Fiber.current)
        return @parent_scope.block(...) if @parent_scope
      end

      Fiber.yield
    end

    def unblock(blocker, fiber)
      unless fiber_ids.key?(Fiber.current)
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

    attr_reader :scope_id
    attr_reader :deadline_owner

    sig { returns(LazyHash) }
    def fiber_ids = state.fiber_ids

    def remaining_deadline
      return unless @deadline_at

      remaining = @deadline_at - current_time
      remaining.positive? ? remaining : 0
    end

    def pending_work?
      return false if closed?

      return true if pending.any?(&:alive?)
      return true if waiting.any? { |fiber, _| fiber.alive? }
      return true if blocked.any? { |fiber, _| fiber.alive? }
      return true if readable.any? { |_, fibers| fibers.any?(&:alive?) }
      return true if writable.any? { |_, fibers| fibers.any?(&:alive?) }
      return true if child_scopes? && child_scopes.any? { |scope| scope.pending_work? } # rubocop:disable Style/SymbolProc (protected method called)

      false
    end

    def register_child_scope(scope)
      child_scopes.add(scope)
    end

    def deregister_child_scope(scope)
      child_scopes.delete(scope)
    end

    private

    attr_reader :parent_scope

    def thread_local_state
      return @thread_local_state if defined?(@thread_local_state)

      state = Thread.current.thread_variable_get(:ori_scope_states)
      if state.nil?
        state = {}
        Thread.current.thread_variable_set(:ori_scope_states, state)
      end

      @thread_local_state = state
    end

    def child_scopes?
      state.child_scopes?
    end

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
      now = current_time
      check_deadline!(now)

      cleanup_dead_fibers

      process_pending_fibers
      process_blocked_fibers
      process_io_operations(now)
      process_timeouts(now)
    end

    def process_pending_fibers
      pending.size.times do
        fiber = pending.shift
        # TODO???
        next if waiting.key?(fiber)

        resume_fiber(fiber)
      end
    end

    def process_blocked_fibers
      fibers_to_resume = []

      # TODO: shuffle blocked before processing?
      blocked.each do |fiber, resource|
        case resource
        when Ori::Channel
          fibers_to_resume << fiber if resource.value?
        when Ori::Promise
          fibers_to_resume << fiber if resource.resolved?
        when Ori::Semaphore, Ori::ReentrantSemaphore
          fibers_to_resume << fiber if resource.available?
        end
      end

      check_stalled_fibers! if fibers_to_resume.empty?

      fibers_to_resume.each do |fiber|
        blocked.delete(fiber)
        resume_fiber(fiber)
      end
    end

    def process_io_operations(now = nil)
      return if readable.none? && writable.none?

      readable_out, writable_out = IO.select(readable.keys, writable.keys, [], next_timeout(now))

      process_ready_io(readable_out, readable)
      process_ready_io(writable_out, writable)
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
      thread_local_state&.delete(object_id)
    end

    # Timeouts and deadlines

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def process_timeouts(now = current_time)
      check_deadline!

      fibers_to_resume = []
      waiting.each do |fiber, deadline|
        if deadline <= now
          fibers_to_resume << fiber
        end
      end

      fibers_to_resume.each do |fiber|
        waiting.delete(fiber)
        resume_fiber(fiber)
      end
    end

    def check_deadline!(now = nil)
      return unless @deadline_at

      now ||= current_time
      if now >= @deadline_at
        error = CancellationError.new(@deadline_owner)
        shutdown!(error)
        raise(error)
      end
    end

    def check_stalled_fibers!
      return false if blocked.none?

      if pending.empty? && waiting.empty? && readable.empty? && writable.empty?
        error = CancellationError.new(self, "All fibers are blocked, impossible to proceed")
        shutdown!(error)
        raise(error)
      end
    end

    def next_timeout(now = nil)
      timeouts = T.let([], T::Array[Numeric])
      timeouts.concat(waiting.values.compact) unless waiting.empty?
      timeouts << @deadline_at if @deadline_at

      return 0 if timeouts.empty?

      now ||= current_time
      nearest = T.must(timeouts.min)
      delay = nearest - now

      # Return 0 if the timeout is in the past, otherwise return the delay
      [0, delay].max
    end

    # Fiber management

    def create_task(&block)
      return false if @cancelled
      raise "Scope is closed" if closed?

      task = Task.new(&block)
      register_task(task)
      task
    end

    def register_task(task)
      fiber_ids[task.fiber] = task.id
      task_queue[task.fiber] = task

      if @tracer
        @tracer.register_fiber(task.id, @scope_id)
        @tracer.record(task.id, :created)
      end
    end

    def resume_fiber(fiber)
      resume_task_or_fiber(task_queue.fetch(fiber, fiber))
    end

    def resume_task_or_fiber(task_or_fiber)
      return unless task_or_fiber.alive?

      fiber = task_or_fiber.is_a?(Task) ? task_or_fiber.fiber : task_or_fiber
      id = fiber_ids[fiber]

      begin
        return if @cancelled # Early return if cancelled

        result = task_or_fiber.resume
        case result
        when CancellationError
          @tracer&.record(id, :cancelled, result.message)
          task_or_fiber.kill
        when Ori::Channel, Ori::Promise, Ori::Semaphore, Ori::ReentrantSemaphore
          @tracer&.record(id, :resource_wait, result.class.name)
          blocked[fiber] = result
        when Task
          pending << fiber
        else
          pending << fiber if fiber.alive?
        end
      rescue => error
        @tracer&.record(id, :error, error.message)
        shutdown!(error)
        raise(error)
      end

      @tracer&.record(id, :completed) unless fiber.alive?
    end

    def cancel_fiber!(fiber, error)
      return unless fiber.alive?

      id = fiber_ids[fiber]
      @tracer&.record(id, :cancelling, error.message)

      if (task = task_queue[fiber])
        task.cancel(error)
      else
        # For raw fibers, we still need to resume them one last time
        # to give them a chance to cleanup
        fiber.raise(error)
      end

      @tracer&.record(id, :cancelled, error.message)
    end

    # Registration

    def register_timeout(fiber, deadline)
      return unless deadline

      waiting[fiber] = current_time + deadline
    end

    def register_io_wait(fiber, io, events)
      added = {
        readable: T.let(false, T::Boolean),
        writable: T.let(false, T::Boolean),
      }

      if (events & IO::READABLE).nonzero?
        readable[io].add(fiber)
        added[:readable] = true
      end

      if (events & IO::WRITABLE).nonzero?
        writable[io].add(fiber)
        added[:writable] = true
      end

      added
    end

    # Cleanup

    def cleanup_dead_fibers
      dead_fibers = fiber_ids.reject { |fiber, _| fiber.alive? }.to_set
      return if dead_fibers.empty?

      readable.each { |_, fibers| fibers.subtract(dead_fibers) }
      readable.delete_if { |_, fibers| fibers.empty? }

      writable.each { |_, fibers| fibers.subtract(dead_fibers) }
      writable.delete_if { |_, fibers| fibers.empty? }

      waiting.delete_if { |fiber, _| dead_fibers.include?(fiber) }

      dead_fibers.each do |fiber|
        fiber_ids.delete(fiber)
        task_queue.delete(fiber)
      end
    end

    def cleanup_io_resources
      readable.each do |io, _|
        io.close unless io.closed?
      rescue => e
        @tracer&.record_scope(@scope_id, :error, "Failed to close readable: #{e.message}")
      end

      writable.each do |io, _|
        io.close unless io.closed?
      rescue => e
        @tracer&.record_scope(@scope_id, :error, "Failed to close writable: #{e.message}")
      end
    end

    def cleanup_io_wait(fiber, io, added)
      readable[io].delete(fiber) if added[:readable]
      writable[io].delete(fiber) if added[:writable]

      readable.delete(io) if readable[io]&.empty?
      writable.delete(io) if writable[io]&.empty?
    end

    def cleanup_timeout(fiber)
      waiting.delete(fiber)
    end

    # Add helper method to access thread-local state
    def state
      thread_local_state&.[](object_id) or
        raise "Scope accessed from wrong thread"
    end

    # Update all instance variable references to use state

    sig { returns(LazyHash) }
    def task_queue = state.tasks

    sig { returns(LazyArray) }
    def pending = state.pending

    sig { returns(LazyHashSet) }
    def readable = state.readable

    sig { returns(LazyHashSet) }
    def writable = state.writable

    sig { returns(LazyHash) }
    def waiting = state.waiting

    sig { returns(LazyHash) }
    def blocked = state.blocked

    sig { returns(T::Set[Scope]) }
    def child_scopes = state.child_scopes
  end
end
