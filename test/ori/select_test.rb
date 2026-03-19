# typed: true

require "test_helper"

module Ori
  class SelectTest < Minitest::Test
    def test_select_with_channel
      promise = Promise.new
      chan = Channel.new(1)
      result = nil

      Ori.sync do |scope|
        scope.fork do
          sleep(0.1)
          chan.put(:channel)
        end

        result = case Select.await([promise, chan])
        in Promise(_) then raise "Should not happen"
        in Channel(value) then value
        end
      end

      assert_equal(:channel, result)
    end

    def test_select_with_semaphore
      promise = Promise.new
      semaphore = Semaphore.new(1)
      result = nil #: Symbol?

      Ori.sync do |scope|
        scope.fork { semaphore.sync { sleep(0.1) } }

        result = case Select.await([promise, semaphore])
        in Promise(_) then raise "Should not happen"
        in Semaphore then :semaphore
        end
      end

      assert_equal(:semaphore, result)
    end

    def test_select_with_promise
      promise_a = Promise.new
      promise_b = Promise.new
      result = nil

      Ori.sync do |scope|
        scope.fork do
          sleep(0.1)
          promise_a.resolve(:promise_a)
        end

        result = case Select.await([promise_a, promise_b])
        in Promise(_) => x if x == promise_b then raise "Should not happen"
        in Promise(value) => x if x == promise_a then value
        end
      end

      assert_equal(:promise_a, result)
    end

    def test_select_with_timeout
      promise = Promise.new
      timeout = Timeout.new(0.1)
      result = nil #: Symbol?

      Ori.sync do |scope|
        scope.fork do
          sleep(0.2)
          promise.resolve(:promise)
        end

        result = case Select.await([timeout, promise])
        in Promise(_) then raise "Should not happen"
        in Timeout then :timeout
        end
      end

      assert_equal(:timeout, result)
    end

    def test_select_with_task
      result = nil

      Ori.sync do |scope|
        scope.fork do
          sleep(5)
          :task_a
        end

        scope.fork { :task_b }

        # Select first task to finish
        Ori.select(scope.tasks) => Task(value)
        result = value
        # Stop processing any further tasks
        scope.shutdown!
      end

      assert_equal(:task_b, result)
    end

    def test_select_with_broadcast_subscription
      promise = Promise.new
      broadcast = Broadcast.new
      sub = broadcast.subscribe
      result = nil

      Ori.sync do |scope|
        scope.fork do
          sleep(0.1)
          broadcast << :event
        end

        result = case Select.await([promise, sub])
        in Promise(_) then raise "Should not happen"
        in Broadcast::Subscription(value) then value
        end
      end

      assert_equal(:event, result)
    end

    def test_select_broadcast_vs_timeout
      broadcast = Broadcast.new
      sub = broadcast.subscribe
      timeout = Timeout.new(0.1)
      result = nil #: Symbol?

      Ori.sync do |scope|
        scope.fork do
          sleep(0.2)
          broadcast << :too_late
        end

        result = case Select.await([sub, timeout])
        in Broadcast::Subscription(_) then raise "Should not happen"
        in Timeout then :timeout
        end
      end

      assert_equal(:timeout, result)
    end

    def test_concurrent_sleep_and_pending_io
      Ori.sync(cancel_after: 5) do |scope|
        r, w = IO.pipe

        scope.fork do
          r.readpartial(1)
        rescue EOFError
          nil
        end

        scope.fork { sleep(3) }

        scope.fork do
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Ori::Select.await([ch = Ori::Channel.new(1), timeout = Ori::Timeout.new(0.2)])
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

          assert(elapsed < 0.5, "Expected to wait less than 0.5 seconds, but waited #{elapsed} seconds")

          w.close
        end
      end
    end
  end
end
