# typed: true
# frozen_string_literal: true

require "nio"
require "io/nonblock"
require "random/formatter"
require "ori/lazy"
require "English"

module Ori
  class Scope
    class ThreadLocalState
      attr_reader :fiber_ids,
        :tasks,
        :pending,
        :readable,
        :writable,
        :waiting,
        :blocked

      def initialize
        @fiber_ids = {}
        @tasks = {}
        @pending = []
        @readable = Hash.new { |hash, key| hash[key] = Set.new }
        @writable = Hash.new { |hash, key| hash[key] = Set.new }
        @waiting = {}
        @blocked = {}
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

      @wakeup_mutex = ::Mutex.new
      @wakeup_queue = [] #: Array[Fiber]
      @pending_interrupts = {} #: Hash[Fiber, Exception]
      @wakeup_reader = nil
      @wakeup_writer = nil

      @state = ThreadLocalState.new
      @needs_cleanup = false

      inherit_or_register_deadline(deadline)

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

    # -------------------
    # --- Public API ---
    # -------------------

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

    # ----------------------------------------------------
    # --- Ruby FiberScheduler interface implementation ---
    # ----------------------------------------------------

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
      cleanup_io_wait(fiber, io, added) if added
      cleanup_timeout(fiber) if timeout && fiber
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
      cleanup_timeout(fiber) if fiber
    end

    def block(...)
      unless fiber_ids.key?(Fiber.current)
        return @parent_scope.block(...) if @parent_scope
      end

      # TODO: Track blocked fibers separately so we don't
      # try to resume them indefinitely prior to unblock

      Fiber.yield
    end

    def unblock(blocker, fiber)
      unless fiber_ids.key?(fiber)
        return @parent_scope.unblock(blocker, fiber) if @parent_scope
      end

      # Thread-safe: enqueue the fiber and signal the event loop
      # via the wakeup pipe. unblock may be called from any thread.
      @wakeup_mutex.synchronize { @wakeup_queue << fiber }
      ensure_wakeup_pipe
      @wakeup_writer.write_nonblock(".") rescue nil # rubocop:disable Style/RescueModifier
    end

    def fiber_interrupt(fiber, exception)
      @wakeup_mutex.synchronize do
        @pending_interrupts[fiber] = exception
        @wakeup_queue << fiber
      end
      ensure_wakeup_pipe
      @wakeup_writer.write_nonblock(".") rescue nil # rubocop:disable Style/RescueModifier
    end

    def io_read(io, buffer, length, offset)
      return @parent_scope.io_read(io, buffer, length, offset) unless fiber_ids.key?(Fiber.current)

      io.nonblock = true unless io.closed?
      total = 0 #: Integer

      loop do
        maximum_size = buffer.size - offset - total
        break if maximum_size <= 0

        case result = Fiber.blocking { io.read_nonblock(maximum_size, exception: false) }
        when :wait_readable
          break if total > 0

          io_wait(io, IO::READABLE)
        when nil # EOF
          break
        else
          buffer.set_string(result, offset + total)
          total += result.bytesize
          break if length == 0 || total >= length
        end
      end

      total
    rescue SystemCallError => e
      (total || 0) > 0 ? total : -(e.errno || 0)
    end

    def io_write(io, buffer, length, offset)
      return @parent_scope.io_write(io, buffer, length, offset) unless fiber_ids.key?(Fiber.current)

      io.nonblock = true unless io.closed?
      total = 0 #: Integer
      max_bytes = buffer.size - offset

      while total < max_bytes
        chunk = buffer.get_string(offset + total, max_bytes - total)
        case result = Fiber.blocking { io.write_nonblock(chunk, exception: false) }
        when :wait_writable
          io_wait(io, IO::WRITABLE)
        else
          total += result
        end
      end

      total
    rescue SystemCallError => e
      (total || 0) > 0 ? total : -(e.errno || 0)
    end

    def process_wait(pid, flags)
      return @parent_scope.process_wait(pid, flags) unless fiber_ids.key?(Fiber.current)

      fiber = Fiber.current
      id = fiber_ids[fiber]
      @tracer&.record(id, :waiting_process, "pid=#{pid}")

      # Bridge thread-based process waiting into the IO event loop.
      # A pipe signals completion; the thread closes its end when done.
      reader, writer = IO.pipe

      thread = Thread.new(writer) do |w|
        ::Process.wait(pid, flags)
        $CHILD_STATUS # return the Process::Status
      ensure
        w.syswrite(".") rescue nil # rubocop:disable Style/RescueModifier
        w.close rescue nil # rubocop:disable Style/RescueModifier
      end

      # Register directly on the event loop's readable set
      readable[reader].add(fiber)
      Fiber.yield

      thread.value
    ensure
      readable[reader]&.delete(fiber) if reader
      readable.delete(reader) if reader && readable[reader]&.empty?
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end

    # TODO: Implement these
    # def io_pread(...) = ()
    # def io_pwrite(...) = ()
    # def timeout_after(...) = ()
    # def address_resolve(...) = ()

    protected

    attr_reader :scope_id
    attr_reader :deadline_owner

    #: () -> LazyHash
    def fiber_ids = @state.fiber_ids

    def remaining_deadline
      return unless @deadline_at

      remaining = @deadline_at - current_time
      remaining.positive? ? remaining : 0
    end

    def pending_work?
      return false if closed?

      # Fast non-empty checks before expensive alive? iteration
      return true unless @wakeup_queue.empty?
      return true unless pending.empty?
      return true unless waiting.empty?
      return true unless blocked.empty?
      return true unless readable.empty?
      return true unless writable.empty?
      return true if child_scopes? && child_scopes.any? { |scope| scope.pending_work? } # rubocop:disable Style/SymbolProc (protected method called)

      false
    end

    def root_scope
      @parent_scope ? @parent_scope.root_scope : self
    end

    # Purposefully excludes blocked fibers from checks
    def has_active_work?
      return false if closed?

      return true unless @wakeup_queue.empty?
      return true unless pending.empty?
      return true unless waiting.empty?
      return true unless readable.empty?
      return true unless writable.empty?
      return true if child_scopes? && child_scopes.any? { |scope| scope.has_active_work? }

      false
    end

    def register_child_scope(scope)
      child_scopes.add(scope)
    end

    def deregister_child_scope(scope)
      child_scopes.delete(scope)
    end

    def nearest_timeout_at
      candidates = [] #: Array[Numeric]
      candidates.concat(waiting.values.compact) unless waiting.empty?
      candidates << @deadline_at if @deadline_at

      if child_scopes?
        child_scopes.each do |scope|
          child_nearest = scope.nearest_timeout_at
          candidates << child_nearest if child_nearest
        end
      end

      candidates.min
    end

    private

    attr_reader :parent_scope

    def ensure_wakeup_pipe
      return if @wakeup_reader

      @wakeup_reader, @wakeup_writer = IO.pipe
    end

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
      @state.child_scopes?
    end

    # -----------------------
    # --- Scope lifecycle ---
    # -----------------------

    def process_available_work
      check_deadline!

      if @needs_cleanup
        cleanup_dead_fibers
        @needs_cleanup = false
      end

      process_pending_fibers
      process_blocked_fibers
      process_io_operations
      process_timeouts
    end

    def process_pending_fibers
      pending.size.times do
        fiber = pending.shift
        # TODO???
        next if waiting.key?(fiber)

        task = task_queue[fiber]
        resume_task_or_fiber(task || fiber)
      end
    end

    def process_blocked_fibers
      return if blocked.empty?

      fibers_to_resume = nil

      blocked.each do |fiber, resource|
        if resource.ready?
          (fibers_to_resume ||= []) << fiber
        end
      end

      unless fibers_to_resume
        check_stalled_fibers!
        return
      end

      fibers_to_resume.each do |fiber|
        blocked.delete(fiber)
        task = task_queue[fiber]
        resume_task_or_fiber(task || fiber)
      end
    end

    def process_io_operations(now = nil)
      has_io = !readable.empty? || !writable.empty?

      # Fast path: skip mutex if no wakeups queued (check without lock)
      has_wakeup = !@wakeup_queue.empty?

      # Process any already-queued wakeups before selecting
      drain_wakeup_queue if has_wakeup

      return unless has_io

      ensure_wakeup_pipe
      select_readable = readable.keys
      select_readable << @wakeup_reader

      readable_out, writable_out = IO.select(select_readable, writable.keys, [], next_timeout(now))

      # Drain wakeup pipe if signaled
      if readable_out&.delete(@wakeup_reader)
        @wakeup_reader.read_nonblock(256) rescue nil # rubocop:disable Style/RescueModifier
        drain_wakeup_queue
      end

      process_ready_io(readable_out, readable)
      process_ready_io(writable_out, writable)
    end

    def process_ready_io(ready_ios, io_map)
      return unless ready_ios

      ready_ios.each do |io|
        io_map[io].each { |fiber| resume_fiber(fiber) }
      end
    end

    def drain_wakeup_queue
      interrupts = nil #: Hash[Fiber, Exception]?
      fibers = @wakeup_mutex.synchronize do
        unless @pending_interrupts.empty?
          interrupts = @pending_interrupts.dup
          @pending_interrupts.clear
        end
        @wakeup_queue.shift(@wakeup_queue.size)
      end

      fibers.each do |fiber|
        next unless fiber.alive?

        if (exception = interrupts&.delete(fiber))
          interrupt_fiber(fiber, exception)
        else
          resume_fiber(fiber)
        end
      end
    end

    def close_scope
      @closed = true
      @tracer&.record_scope(@scope_id, :closed)
      @wakeup_reader&.close unless @wakeup_reader&.closed?
      @wakeup_writer&.close unless @wakeup_writer&.closed?
    end

    # ------------------------------
    # --- Timeouts and deadlines ---
    # ------------------------------

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def process_timeouts(now = current_time)
      check_deadline!

      return if waiting.empty?

      fibers_to_resume = nil
      waiting.each do |fiber, deadline|
        if deadline <= now
          (fibers_to_resume ||= []) << fiber
        end
      end

      return unless fibers_to_resume

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
      return false if root_scope.has_active_work?

      error = DeadlockError.new(self)
      shutdown!(error)
      raise(error)
    end

    def next_timeout(now = nil)
      nearest = nearest_timeout_at
      return 0 unless nearest

      now ||= current_time
      delay = nearest - now

      # Return 0 if the timeout is in the past, otherwise return the delay
      [0, delay].max
    end

    # ------------------------
    # --- Fiber management ---
    # ------------------------

    def create_task(&block)
      return false if @cancelled
      raise "Scope is closed" if closed?

      task = Task.new(&block)
      register_task(task)
      task
    end

    def resume_fiber(fiber)
      resume_task_or_fiber(task_queue.fetch(fiber, fiber))
    end

    def resume_task_or_fiber(task_or_fiber)
      return unless task_or_fiber.alive?

      fiber = task_or_fiber.is_a?(Task) ? task_or_fiber.fiber : task_or_fiber

      begin
        return if @cancelled # Early return if cancelled

        result = task_or_fiber.resume
        case result
        when CancellationError
          if @tracer
            id = fiber_ids[fiber]
            @tracer.record(id, :cancelled, result.message)
          end
          task_or_fiber.kill
          @needs_cleanup = true
        when Task
          pending << fiber
        when Ori::Selectable
          if @tracer
            id = fiber_ids[fiber]
            @tracer.record(id, :resource_wait, result.class.name)
          end
          blocked[fiber] = result
        else
          if fiber.alive?
            pending << fiber
          else
            @needs_cleanup = true
          end
        end
      rescue => error
        if @tracer
          id = fiber_ids[fiber]
          @tracer.record(id, :error, error.message)
        end
        shutdown!(error)
        raise(error)
      end

      if @tracer && !fiber.alive?
        id = fiber_ids[fiber]
        @tracer.record(id, :completed)
      end
    end

    def interrupt_fiber(fiber, exception)
      waiting.delete(fiber)
      blocked.delete(fiber)

      cancel_fiber!(fiber, exception)
    end

    def cancel_fiber!(fiber, error)
      return unless fiber.alive?

      id = fiber_ids[fiber]
      @tracer&.record(id, :cancelling, error.message)

      if (task = task_queue[fiber])
        task.cancel(error)
      else
        fiber.raise(error)
      end

      @tracer&.record(id, :cancelled, error.message)
    end

    # --------------------
    # --- Registration ---
    # --------------------

    def inherit_or_register_deadline(duration)
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

    def register_task(task)
      fiber_ids[task.fiber] = task.id
      task_queue[task.fiber] = task

      if @tracer
        @tracer.register_fiber(task.id, @scope_id)
        @tracer.record(task.id, :created)
      end
    end

    def register_timeout(fiber, deadline)
      return unless deadline

      waiting[fiber] = current_time + deadline
    end

    def register_io_wait(fiber, io, events)
      added = {
        readable: false,
        writable: false,
      } #: Hash[Symbol, bool]

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

    # ---------------
    # --- Cleanup ---
    # ---------------

    def cleanup_dead_fibers
      # Fast path: collect dead fibers without intermediate array
      dead_fibers = nil
      fiber_ids.each_key do |fiber|
        unless fiber.alive?
          (dead_fibers ||= []) << fiber
        end
      end
      return unless dead_fibers

      dead_fibers.each do |fiber|
        fiber_ids.delete(fiber)
        task_queue.delete(fiber)
        waiting.delete(fiber)
      end

      unless readable.empty?
        readable.each { |_, fibers| dead_fibers.each { |f| fibers.delete(f) } }
        readable.delete_if { |_, fibers| fibers.empty? }
      end

      unless writable.empty?
        writable.each { |_, fibers| dead_fibers.each { |f| fibers.delete(f) } }
        writable.delete_if { |_, fibers| fibers.empty? }
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
      s = @state
      return unless s

      s.readable[io]&.delete(fiber) if added[:readable]
      s.writable[io]&.delete(fiber) if added[:writable]

      s.readable.delete(io) if s.readable[io]&.empty?
      s.writable.delete(io) if s.writable[io]&.empty?
    end

    def cleanup_timeout(fiber)
      @state&.waiting&.delete(fiber)
    end

    # -------------
    # --- State ---
    # -------------

    def state
      @state
    end

    #: () -> LazyHash
    def task_queue = @state.tasks

    #: () -> LazyArray
    def pending = @state.pending

    #: () -> LazyHashSet
    def readable = @state.readable

    #: () -> LazyHashSet
    def writable = @state.writable

    #: () -> LazyHash
    def waiting = @state.waiting

    #: () -> LazyHash
    def blocked = @state.blocked

    #: () -> Set[Scope]
    def child_scopes = @state.child_scopes

    # -----------------
    # --- Debugging ---
    # -----------------

    def tag(name)
      @tracer&.record_scope(@scope_id, :tag, name)
    end

    def print_ascii_trace
      @tracer&.visualize
    end

    def write_html_trace(directory)
      @tracer&.write_timeline_data(directory)
    end
  end
end
