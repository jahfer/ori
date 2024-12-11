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
    in Ori::BaseChannel(value) then raise "should not happen"
    end

    assert_equal(:promise, result)
  end

  def test_select_with_channel
    promise = Ori::Promise.new
    chan = Ori::Channel.new(1)

    chan << :chan

    result = case Ori.select([promise, chan])
    in Ori::Promise(value) then raise "should not happen"
    in Ori::BaseChannel(value) then value
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
end
