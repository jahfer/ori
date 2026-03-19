# typed: true
# frozen_string_literal: true

require "test_helper"

module Ori
  class ScopeTest < Minitest::Test
    def test_basic_boundary
      result = nil #: String?
      captured_scope = nil #: Scope?

      Ori.sync do |scope|
        captured_scope = scope
        result = "executed"
      end

      assert_equal("executed", result)
      assert(captured_scope&.closed?)
    end

    def test_fork_execution
      results = []
      Ori.sync do |s|
        s.fork { results << 1 }
        s.fork { results << 2 }
      end

      assert_equal([1, 2], results.sort)
    end

    def test_fork_each
      results = []
      Ori.sync do |s|
        s.fork_each(1..3) do |i|
          results << i
        end
      end

      assert_equal([1, 2, 3], results.sort)
    end

    def test_io_operations
      reader, writer = IO.pipe
      message = "hello"
      received = nil #: String?

      Ori.sync do |s|
        s.fork do
          writer.write(message)
          writer.close
        end

        s.fork do
          received = reader.read
          reader.close
        end
      end

      assert_equal(message, received)
    ensure
      [reader, writer].each { |io| io&.close }
    end

    def test_process_stdout
      output = nil #: String?

      Ori.sync do |s|
        s.fork do
          output = IO.popen(["echo", "hello from process"], "r") { |io| io.read }
        end
      end

      assert_equal("hello from process\n", output)
    end

    def test_concurrent_process_and_fibers
      results = [] #: Array[String]

      Ori.sync do |s|
        s.fork do
          results << IO.popen(["echo", "process"], "r") { |io| io.read.strip }
        end

        s.fork do
          results << "fiber"
        end
      end

      assert_includes(results, "process")
      assert_includes(results, "fiber")
    end

    def test_io_read_with_gets
      lines = [] #: Array[String]

      Ori.sync do |s|
        reader, writer = IO.pipe

        s.fork do
          writer.puts "hello"
          writer.puts "world"
          writer.close
        end

        s.fork do
          while (line = reader.gets)
            lines << line.chomp
          end
          reader.close
        end
      end

      assert_equal(["hello", "world"], lines)
    end

    def test_io_write_through_scheduler
      result = nil #: String?

      Ori.sync do |s|
        reader, writer = IO.pipe

        s.fork do
          writer.write("scheduled write")
          writer.close
        end

        s.fork do
          result = reader.read
          reader.close
        end
      end

      assert_equal("scheduled write", result)
    end

    def test_deterministic_execution_order
      sequence = []
      Ori.sync do |s|
        s.fork do
          sequence << 1
          Fiber.yield
          sequence << 3
        end

        s.fork do
          sequence << 2
          Fiber.yield
          sequence << 4
        end
      end

      assert_equal([1, 2, 3, 4], sequence)
    end

    def test_interleaved_operations
      shared_value = 0
      operations = []

      Ori.sync do |s|
        s.fork do
          operations << [:read, shared_value]  # 0
          Fiber.yield
          shared_value = 1
          operations << [:write, 1]
          Fiber.yield
          operations << [:read, shared_value]  # 2
        end

        s.fork do
          Fiber.yield
          operations << [:read, shared_value]  # 1
          shared_value = 2
          operations << [:write, 2]
        end
      end

      expected = [
        [:read, 0],   # First fiber reads 0
        [:write, 1],  # First fiber writes 1
        [:read, 1],   # Second fiber reads value 1
        [:write, 2],  # Second fiber writes 2
        [:read, 2],   # First fiber reads final value 2
      ]
      assert_equal(expected, operations)
    end

    def test_cancel_after_timeout
      result = nil #: String?
      Ori.sync(cancel_after: 0.1) do |s|
        s.fork do
          result = "A"
          sleep(1)
          result = "B"
        end
      end

      assert_equal("A", result)
    end

    def test_raise_after_timeout
      assert_raises(CancellationError) do
        Ori.sync(raise_after: 0.001) do |scope|
          scope.fork do
            sleep(10)
          end
        end
      end
    end

    def test_nested_boundary_cancellation_cancels_parent
      result = []

      Ori.sync(cancel_after: 0.1) do |_|
        Ori.sync do |scope|
          scope.fork do
            result << "A"
            sleep(1)
            result << "B"
          end
        end
        result << "C"
      end

      assert_equal(["A"], result)
    end

    def test_timeout_doesnt_affect_completed_operations
      result = nil #: String?

      Ori.sync(cancel_after: 0.1) do |s|
        s.fork do
          result = "completed"
        end

        s.fork do
          sleep(1)
        end
      end

      assert_equal("completed", result)
    end

    def test_shutdown_stops_further_operations
      result = :before_shutdown

      Ori.sync do |scope|
        scope.fork { result = :in_task_a }

        scope.fork do
          Fiber.yield
          result = :in_task_b
        end

        scope.shutdown!
        result = :after_shutdown
      end

      assert_equal(:in_task_a, result)
    end

    def test_fiber_interrupt_cancels_task
      result = nil #: Symbol?

      Ori.sync do |scope|
        task = scope.fork do
          result = :started
          sleep(10)
          result = :finished
        end

        scope.fork do
          scope.fiber_interrupt(task.fiber, RuntimeError.new("interrupted"))
        end
      end

      assert_equal(:started, result)
    end

    def test_fiber_interrupt_from_another_thread
      result = nil #: Symbol?

      Ori.sync do |scope|
        task = scope.fork do
          result = :started
          sleep(10)
          result = :finished
        end

        Thread.new do
          sleep(0.05)
          scope.fiber_interrupt(task.fiber, RuntimeError.new("cross-thread interrupt"))
        end
      end

      assert_equal(:started, result)
    end

    def test_fiber_interrupt_unblocks_waiting_fiber
      results = [] #: Array[Symbol]

      Ori.sync do |scope|
        ch = Channel.new(0)

        task = scope.fork do
          results << :waiting
          ch.take
          results << :took
        end

        scope.fork do
          scope.fiber_interrupt(task.fiber, RuntimeError.new("stop waiting"))
        end
      end

      assert_equal([:waiting], results)
    end

    def test_unblock_resumes_fiber_via_wakeup_pipe
      result = nil #: String?

      Ori.sync do |scope|
        reader, writer = IO.pipe

        scope.fork do
          reader.read(1)
          result = "resumed"
          reader.close
        end

        Thread.new do
          sleep(0.05)
          writer.write(".")
          writer.close
        end
      end

      assert_equal("resumed", result)
    end

    def test_deadlock_detected_single_scope_channel
      assert_raises(DeadlockError) do
        Ori.sync do |scope|
          ch = Channel.new(0)

          scope.fork { ch.take }
          scope.fork { ch.take }
        end
      end
    end

    def test_deadlock_detected_single_scope_promise
      assert_raises(DeadlockError) do
        Ori.sync do |scope|
          p1 = Promise.new
          p2 = Promise.new

          scope.fork { p1.await }
          scope.fork { p2.await }
        end
      end
    end

    def test_deadlock_detected_single_scope_semaphore
      assert_raises(DeadlockError) do
        Ori.sync do |scope|
          sem = Semaphore.new(1)

          scope.fork do
            sem.acquire
            Fiber.yield
          end

          scope.fork { sem.acquire }
          scope.fork { sem.acquire }
        end
      end
    end

    def test_deadlock_detected_across_nested_scopes
      assert_raises(DeadlockError) do
        Ori.sync do |outer|
          ch = Channel.new(0)

          outer.fork { ch.take }

          Ori.sync do |inner|
            inner.fork { ch.take }
          end
        end
      end
    end

    def test_no_false_deadlock_when_work_remains
      result = nil #: Integer?

      Ori.sync do |scope|
        ch = Channel.new(1)

        scope.fork { ch.put(42) }
        scope.fork { result = ch.take }
      end

      assert_equal(42, result)
    end

    def test_no_false_deadlock_with_io_pending
      result = nil #: String?

      Ori.sync do |scope|
        ch = Channel.new(0)
        reader, writer = IO.pipe

        scope.fork do
          data = reader.read(1)
          ch.put(data)
        end

        scope.fork do
          result = ch.take
        end

        scope.fork do
          writer.write("x")
          writer.close
        end
      end

      assert_equal("x", result)
    end

    def test_no_false_deadlock_with_timer_pending
      result = nil #: Symbol?

      Ori.sync do |scope|
        ch = Channel.new(0)

        scope.fork do
          sleep(0.01)
          ch.put(:done)
        end

        scope.fork do
          result = ch.take
        end
      end

      assert_equal(:done, result)
    end
  end
end
