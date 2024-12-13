# typed: true
# frozen_string_literal: true

require "test_helper"

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
    n = 1000
    channels = Array.new(n) { Ori::Channel.new(0) }

    Ori.sync do |scope|
      # Create 1000 fibers that each send to a channel
      scope.each_async(channels) do |c|
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
  end
end
