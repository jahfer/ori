# typed: true

require "test_helper"

module Ori
  class TaskTest < Minitest::Test
    def test_task_captures_value
      task = nil #: Task?

      Ori.sync do |scope|
        task = scope.fork { :result }
      end

      assert_equal(:result, task&.value)
    end

    def test_task_captures_error
      task = nil #: Task?

      assert_raises(RuntimeError) do
        Ori.sync do |scope|
          task = scope.fork { raise "error" }
        end
      end

      assert_nil(task)
    end

    def test_task_captures_killed_state
      task = nil #: Task?

      Ori.sync do |scope|
        task = scope.fork { sleep(1) }
        task.kill
      end

      assert_predicate(task, :killed?)
      assert_nil(task&.value)
    end
  end
end
