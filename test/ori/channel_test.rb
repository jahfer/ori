# typed: true
# frozen_string_literal: true

require "test_helper"

module Ori
  class ChannelTest < Minitest::Test
    def test_buffered_channel
      chan = Ori::Channel.new(2)
      results = []

      Ori.sync do |scope|
        scope.fork_each([1, nil, 3]) { |item| chan << item }
        scope.fork_each(3.times) { results << chan.take }
      end

      assert_equal([1, nil, 3], results)
    end

    def test_sync_channel
      chan = Ori::Channel.new(0)
      results = []

      Ori.sync do |scope|
        scope.fork do
          results << "Sending data..."
          chan << 42
          results << "Data sent!"
        end

        scope.fork do
          results << "Receiving data..."
          value = chan.take
          results << "Data received! #{value}"
        end
      end

      assert_equal(
        [
          "Sending data...",
          "Receiving data...",
          "Data received! 42",
          "Data sent!",
        ],
        results,
      )
    end
  end
end
