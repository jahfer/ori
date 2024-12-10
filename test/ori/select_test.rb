# typed: false
# frozen_string_literal: true

module Ori
  class SelectTest < Minitest::Test
    def test_select
      p1 = Promise.new
      p2 = Promise.new
      c1 = Channel.new(1)
      m1 = Semaphore.new(1)
      m2 = Mutex.new

      Ori::Scope.boundary do |scope|
        scope.fork do
          sleep(0.1)
          c1.put("Hello!")
        end

        result = case Select.from([p1, p2, c1, m1, m2])
        in ^p1, value then value
        in ^p2, value then value
        in ^c1, value then value
        in ^m1, value then value
        in ^m2, value then value
        end

        assert_equal("Hello!", result)
      end
    end
  end
end
