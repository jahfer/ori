# typed: true
# frozen_string_literal: true

require "test_helper"

module Ori
  class ScopeTest < Minitest::Test
    def test_basic_boundary
      result = nil
      captured_scope = nil

      Scope.boundary do |scope|
        captured_scope = scope
        result = "executed"
      end

      assert_equal("executed", result)
      assert(captured_scope.closed?)
    end

    def test_nested_scopes
      outer_scope = nil
      inner_scope = nil

      Scope.boundary do |s1|
        outer_scope = s1
        Scope.boundary do |s2|
          inner_scope = s2
        end
      end

      assert_equal(outer_scope.scope_id, inner_scope.parent_scope.scope_id)
    end

    def test_fork_execution
      results = []
      Scope.boundary do |s|
        s.fork { results << 1 }
        s.fork { results << 2 }
      end

      assert_equal([1, 2], results.sort)
    end

    def test_fork_each
      results = []
      Scope.boundary do |s|
        s.fork_each(1..3) do |i|
          results << i
        end
      end

      assert_equal([1, 2, 3], results.sort)
    end

    def test_io_operations
      reader, writer = IO.pipe
      message = "hello"
      received = nil

      Scope.boundary do |s|
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
      [reader, writer].each { |io| io.close unless io.closed? }
    end

    def test_deterministic_execution_order
      sequence = []
      Scope.boundary do |s|
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

      Scope.boundary do |s|
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
      result = nil
      Scope.boundary(cancel_after: 0.1) do |s|
        s.fork do
          result = "A"
          sleep(1)
          result = "B"
        end
      end

      assert_equal("A", result)
    end

    def test_raise_after_timeout
      assert_raises(Ori::Scope::CancellationError) do
        Scope.boundary(raise_after: 0.001) do |scope|
          scope.fork do
            sleep(10)
          end
        end
      end
    end

    def test_nested_boundary_cancellation_cancels_parent
      result = []

      Scope.boundary(cancel_after: 0.1) do |_|
        Scope.boundary do |scope|
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
      result = nil

      Scope.boundary(cancel_after: 0.1) do |s|
        s.fork do
          result = "completed"
        end

        s.fork do
          sleep(1)
        end
      end

      assert_equal("completed", result)
    end
  end
end
