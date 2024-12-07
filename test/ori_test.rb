# typed: true
# frozen_string_literal: true

require "test_helper"

class OriTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil(::Ori::VERSION)
  end

  def test_mutex
    mutex = Ori::Mutex.new
    value = 2

    Ori::Scope.boundary do |scope|
      scope.fork do
        mutex.synchronize do
          sleep(0.01)
          value += 1
        end
      end

      scope.fork do
        # waits for sleep
        mutex.synchronize { value *= 2 }
      end
    end

    assert_equal(6, value)
  end

  def test_channel
    c = Ori::Channel.new(2)
    results = []

    Ori::Scope.boundary do |scope|
      scope.fork_each([1, nil, 3]) { |item| c << item }
      scope.fork_each(3.times) { results << c.receive }
    end

    assert_equal([1, nil, 3], results)
  end

  def test_cancel_after
    skip

    c = Ori::Channel.new(2)
    results = []

    Ori::Scope.boundary(cancel_after: 0.01) do
      results << c.receive
    end

    assert_equal([], results)
  end

  def test_raise_after
    skip

    c = Ori::Channel.new(2)

    assert_raises(Ori::Scope::Canceled) do
      Ori::Scope.boundary(raise_after: 0.01) do
        c.receive
      end
    end
  end
