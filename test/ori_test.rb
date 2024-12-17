# typed: true
# frozen_string_literal: true

require "test_helper"
require "objspace"
require "allocation_stats"

class OriTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil(::Ori::VERSION)
  end

  def test_select_with_promise
    promise = Ori::Promise.new
    chan = Ori::Channel.new(1)

    promise.resolve(:promise)

    result = case Ori.select([promise, chan])
    in Ori::Promise(value) then value
    in Ori::Channel(value) then raise "should not happen"
    end

    assert_equal(:promise, result)
  end

  def test_select_with_channel
    promise = Ori::Promise.new
    chan = Ori::Channel.new(1)

    chan << :chan

    result = case Ori.select([promise, chan])
    in Ori::Promise(value) then raise "should not happen"
    in Ori::Channel(value) then value
    end

    assert_equal(:chan, result)
  end

  def test_select_with_object_identification
    promise_a = Ori::Promise.new
    promise_b = Ori::Promise.new

    promise_a.resolve(:a)

    result = case Ori.select([promise_a, promise_b])
    in Ori::Promise(value) => p if p == promise_a
      value
    in Ori::Promise(value) => p if p == promise_b
      raise "should not happen"
    end

    assert_equal(:a, result)
  end

  def test_channel_scale
    stats = AllocationStats.trace do
      alloc_start = GC.stat(:total_allocated_objects)
      n = 1000
      channels = Array.new(n) { Ori::Channel.new(0) }

      Ori.sync do |scope|
        # Create 1000 fibers that each send to a channel
        scope.fork_each(channels) do |c|
          c << "hi"
        end

        n.times do
          case Ori.select(channels)
          in Ori::Channel(value) => chan
            assert_equal("hi", value)
            channels.delete(chan)
          end
        end
      end

      alloc_end = GC.stat(:total_allocated_objects)
      puts "Allocations: #{alloc_end - alloc_start}"
    end

    puts stats.allocations(alias_paths: true).from("/ori/").sort_by_size.group_by(
      :sourcefile,
      :sourceline,
      :class,
      :memsize,
    ).to_text

    puts stats.allocations(alias_paths: true).from("/ori/").bytes.all.sum
  end
end
