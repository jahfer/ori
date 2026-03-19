# typed: true

require "test_helper"

module Ori
  class BroadcastTest < Minitest::Test
    def test_single_subscriber_receives_all_messages
      broadcast = Ori::Broadcast.new
      sub = broadcast.subscribe
      results = []

      Ori.sync do |scope|
        scope.fork do
          broadcast << :a
          broadcast << :b
          broadcast << :c
        end

        scope.fork do
          3.times { results << sub.take }
        end
      end

      assert_equal([:a, :b, :c], results)
    end

    def test_multiple_subscribers_each_receive_all_messages
      broadcast = Ori::Broadcast.new
      sub1 = broadcast.subscribe
      sub2 = broadcast.subscribe
      results1 = []
      results2 = []

      Ori.sync do |scope|
        scope.fork do
          broadcast << 1
          broadcast << 2
          broadcast << 3
        end

        scope.fork { 3.times { results1 << sub1.take } }
        scope.fork { 3.times { results2 << sub2.take } }
      end

      assert_equal([1, 2, 3], results1)
      assert_equal([1, 2, 3], results2)
    end

    def test_peek_does_not_consume
      broadcast = Ori::Broadcast.new
      sub = broadcast.subscribe
      results = []

      Ori.sync do |scope|
        scope.fork { broadcast << :hello }

        scope.fork do
          results << sub.peek
          results << sub.peek
          results << sub.take
        end
      end

      assert_equal([:hello, :hello, :hello], results)
    end

    def test_value_returns_false_when_empty
      broadcast = Ori::Broadcast.new
      sub = broadcast.subscribe

      refute(sub.value?)
    end

    def test_value_returns_true_after_publish
      broadcast = Ori::Broadcast.new
      sub = broadcast.subscribe

      Ori.sync do |scope|
        scope.fork { broadcast << 42 }
        scope.fork do
          Fiber.yield until sub.value?
          assert(sub.value?)
        end
      end
    end

    def test_unsubscribe_stops_delivery
      broadcast = Ori::Broadcast.new
      sub1 = broadcast.subscribe
      sub2 = broadcast.subscribe
      results1 = []
      results2 = []

      Ori.sync do |scope|
        scope.fork do
          broadcast << :first
          sub2.unsubscribe
          broadcast << :second
        end

        scope.fork { 2.times { results1 << sub1.take } }
        scope.fork { results2 << sub2.take }
      end

      assert_equal([:first, :second], results1)
      assert_equal([:first], results2)
    end

    def test_late_subscriber_only_receives_new_messages
      broadcast = Ori::Broadcast.new
      sub1 = broadcast.subscribe
      results1 = []
      results2 = []

      Ori.sync do |scope|
        scope.fork do
          broadcast << :before
          sub2 = broadcast.subscribe
          broadcast << :after

          scope.fork { results2 << sub2.take }
        end

        scope.fork { 2.times { results1 << sub1.take } }
      end

      assert_equal([:before, :after], results1)
      assert_equal([:after], results2)
    end

    def test_pattern_matching
      broadcast = Ori::Broadcast.new
      sub = broadcast.subscribe

      Ori.sync do |scope|
        scope.fork { broadcast << 42 }

        result = Ori.select([sub])
        case result
        in Ori::Broadcast::Subscription(value)
          assert_equal(42, value)
        end
      end
    end

    def test_fan_out_to_many_subscribers
      broadcast = Ori::Broadcast.new
      subs = 5.times.map { broadcast.subscribe }
      results = Array.new(5) { [] }

      Ori.sync do |scope|
        scope.fork_each(1..3) { |n| broadcast << n }

        subs.each_with_index do |sub, i|
          scope.fork { 3.times { results[i] << sub.take } }
        end
      end

      expected = [1, 2, 3]
      results.each { |r| assert_equal(expected, r) }
    end
  end
end
