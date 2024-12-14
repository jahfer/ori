# typed: true
# frozen_string_literal: true

require "test_helper"

module Ori
  class MutexTest < Minitest::Test
    def test_mutex
      mutex = Ori::Mutex.new
      value = 2

      Ori.sync do |scope|
        scope.fork do
          mutex.sync do
            sleep(0.01)
            value += 1
          end
        end

        scope.fork do
          # waits for sleep
          mutex.sync { value *= 2 }
        end
      end

      assert_equal(6, value)
    end
  end
end
