# typed: false
# frozen_string_literal: true

module Ori
  class Channel
    def initialize(size)
      @queue = UnboundedQueue.new
      @size = size
    end

    # TODO: block until receiver is ready if queue is size 0
    def send(item)
      Fiber.yield until @queue.size <= @size
      @queue.push(item)
    end
    alias_method :<<, :send

    def receive
      Fiber.yield while @queue.peek == UnboundedQueue::EMPTY
      @queue.shift
    end
  end

  class UnboundedQueue
    EMPTY = "empty"

    def initialize
      @queue = []
    end

    def size
      @queue.size
    end

    def push(item)
      @queue << item
    end

    def peek
      if @queue.empty?
        EMPTY
      else
        @queue.first
      end
    end

    def shift
      @queue.shift
    end
  end
  private_constant(:UnboundedQueue)
end
