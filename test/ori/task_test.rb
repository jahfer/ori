# typed: true

require "test_helper"

module Ori
  class TaskTest < Minitest::Test
    def test_task_captures_value
      task = T.let(nil, T.nilable(Task))

      Ori.sync do |scope|
        task = scope.fork { :result }
      end

      assert_equal(:result, task&.value)
    end

    def test_task_captures_error
      task = T.let(nil, T.nilable(Task))

      assert_raises(RuntimeError) do
        Ori.sync do |scope|
          task = scope.fork { raise "error" }
        end
      end

      assert_nil(task)
    end

    def test_task_captures_killed_state
      task = T.let(nil, T.nilable(Task))

      Ori.sync do |scope|
        task = scope.fork { sleep(1) }
        task.kill
      end

      assert_predicate(task, :killed?)
      assert_nil(task&.value)
    end
  end
end
