# typed: true
# frozen_string_literal: true

require "test_helper"

module Ori
  class SelectTest < Minitest::Test
    def test_select_with_channel
      promise = Promise.new
      chan = Channel.new(1)
      result = nil

      Ori.sync do |scope|
        scope.async do
          sleep(0.1)
          chan.put(:channel)
        end

        result = case Select.new([promise, chan]).await
        in Promise(_) then raise "Should not happen"
        in Channel(value) then value
        end
      end

      assert_equal(:channel, result)
    end

    def test_select_with_semaphore
      promise = Promise.new
      semaphore = Semaphore.new(1)
      result = T.let(nil, T.nilable(Symbol))

      Ori.sync do |scope|
        scope.async { semaphore.synchronize { sleep(0.1) } }

        result = case Select.new([promise, semaphore]).await
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
        scope.async do
          sleep(0.1)
          promise_a.resolve(:promise_a)
        end

        result = case Select.new([promise_a, promise_b]).await
        in Promise(_) => x if x == promise_b then raise "Should not happen"
        in Promise(value) => x if x == promise_a then value
        end
      end

      assert_equal(:promise_a, result)
    end

    def test_select_with_timeout
      promise = Promise.new
      timeout = Timeout.new(0.1)
      result = T.let(nil, T.nilable(Symbol))

      Ori.sync do |scope|
        scope.async do
          sleep(0.2)
          promise.resolve(:promise)
        end

        result = case Select.new([timeout, promise]).await
        in Promise(_) then raise "Should not happen"
        in Timeout then :timeout
        end
      end

      assert_equal(:timeout, result)
    end
  end
end
