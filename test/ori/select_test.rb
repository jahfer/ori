# typed: false
# frozen_string_literal: true

require "test_helper"

module Ori
  class SelectTest < Minitest::Test
    def test_select_with_channel
      promise = Promise.new
      chan = Channel.new(1)
      result = nil

      Ori::Scope.boundary do |scope|
        scope.fork do
          sleep(0.1)
          chan.put(:channel)
        end

        result = case Select.from([promise, chan])
        in ^promise, _value then raise "Should not happen"
        in ^chan, value then value
        end
      end

      assert_equal(:channel, result)
    end

    def test_select_with_semaphore
      promise = Promise.new
      semaphore = Semaphore.new(1)
      result = nil

      Ori::Scope.boundary do |scope|
        scope.fork { semaphore.synchronize { sleep(0.1) } }

        result = case Select.from([promise, semaphore])
        in ^promise, _value then raise "Should not happen"
        in ^semaphore then :semaphore
        end
      end

      assert_equal(:semaphore, result)
    end

    def test_select_with_promise
      promise_a = Promise.new
      promise_b = Promise.new
      result = nil

      Ori::Scope.boundary do |scope|
        scope.fork do
          sleep(0.1)
          promise_a.resolve(:promise_a)
        end

        result = case Select.from([promise_a, promise_b])
        in ^promise_a, value then value
        in ^promise_b, _value then raise "Should not happen"
        end
      end

      assert_equal(:promise_a, result)
    end

    def test_select_with_timeout
      promise = Promise.new
      timeout = Timeout.new(0.1)
      result = nil

      Ori::Scope.boundary do |scope|
        scope.fork do
          sleep(0.2)
          promise.resolve(:promise)
        end

        result = case Select.from([timeout, promise])
        in ^promise, _value then raise "Should not happen"
        in Timeout then :timeout
        end
      end

      assert_equal(:timeout, result)
    end
  end
end
