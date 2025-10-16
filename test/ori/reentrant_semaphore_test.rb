# typed: true

require "test_helper"

module Ori
  class ReentrantSemaphoreTest < Minitest::Test
    def test_reentrant_acquire
      sem = ReentrantSemaphore.new(1)

      # First acquisition should succeed
      assert(sem.acquire)

      # Same fiber should be able to acquire again
      assert(sem.acquire)
      assert(sem.acquire)

      # Releases should work in reverse
      assert(sem.release)
      assert(sem.release)
      assert(sem.release)

      # Should be available for other fibers now
      assert(sem.available?)
    end

    def test_release_requires_ownership
      sem = ReentrantSemaphore.new(1)

      assert_raises(RuntimeError) do
        sem.release
      end
    end

    def test_multiple_fibers
      sem = ReentrantSemaphore.new(1)

      f1 = Fiber.new do
        sem.acquire
        sem.acquire  # Reentrant acquire
        Fiber.yield  # Let f2 try to acquire
        sem.release
        sem.release
      end

      f2 = Fiber.new do
        refute(sem.available?) # Should not be available while f1 holds it
        sem.acquire  # Will yield until f1 releases
        sem.release
      end

      f1.resume
      f2.resume
      f1.resume
      f2.resume
    end

    def test_sync_block
      sem = ReentrantSemaphore.new(1)
      result = nil #: String?

      sem.sync do
        sem.sync do  # Nested sync should work due to reentrancy
          result = "success"
        end
      end

      assert_equal("success", result)
    end
  end
end
