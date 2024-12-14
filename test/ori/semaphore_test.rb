# typed: true
# frozen_string_literal: true

require "test_helper"

module Ori
  class SemaphoreTest < Minitest::Test
    def setup
      @semaphore = Semaphore.new(2)
    end

    def test_initialization
      assert_equal(2, @semaphore.count)
      assert(@semaphore.available?)

      assert_raises(ArgumentError) do
        Semaphore.new(0)
      end

      assert_raises(ArgumentError) do
        Semaphore.new(-1)
      end
    end

    def test_acquire_and_release
      assert_equal(2, @semaphore.count)
      @semaphore.acquire
      assert_equal(1, @semaphore.count)
      @semaphore.release
      assert_equal(2, @semaphore.count)
    end

    def test_sync
      initial_count = @semaphore.count
      result = @semaphore.sync { "test" }
      assert_equal("test", result)
      assert_equal(initial_count, @semaphore.count)
    end

    def test_sync_with_exception
      initial_count = @semaphore.count
      assert_raises(RuntimeError) do
        @semaphore.sync { raise "error" }
      end
      assert_equal(initial_count, @semaphore.count)
    end

    def test_release_overflow
      assert_raises(RuntimeError) do
        @semaphore.release
      end
    end

    def test_multiple_acquires
      @semaphore.acquire
      @semaphore.acquire
      assert_equal(0, @semaphore.count)
      refute(@semaphore.available?)
    end
  end
end
