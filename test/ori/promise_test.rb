# typed: true

require "test_helper"

module Ori
  class PromiseTest < Minitest::Test
    def test_initialize_creates_unresolved_promise
      promise = Promise.new
      refute(promise.resolved?)
    end

    def test_resolve_sets_value_and_marks_as_resolved
      promise = Promise.new
      promise.resolve(42)

      assert(promise.resolved?)
      assert_equal(42, promise.await)
    end

    def test_cannot_resolve_twice
      promise = Promise.new
      promise.resolve(42)

      assert_raises(RuntimeError, "Promise already resolved") do
        promise.resolve(43)
      end
    end

    def test_await_returns_immediately_if_resolved
      promise = Promise.new
      promise.resolve("hello")

      assert_equal("hello", promise.await)
    end

    def test_await_waits_for_resolution
      promise = Promise.new

      Ori.sync do |scope|
        scope.fork do
          assert_equal("done", promise.await)
        end

        scope.fork do
          promise.resolve("done")
        end
      end
    end
  end
end
