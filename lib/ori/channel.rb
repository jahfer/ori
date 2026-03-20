# typed: true

module Ori
  #: [E]
  class Channel
    include(Ori::Selectable)

    EMPTY = "empty"

    #: (Integer size) -> void
    def initialize(size)
      @size = size
      if size.zero?
        # Zero-sized channel state
        @taker_waiting = false
        @sender_waiting = false
        @value = EMPTY
      else
        # Buffered channel state
        @queue = []
      end
    end

    #: (E item) -> void
    def put(item)
      if @size.zero?
        put_zero_sized(item)
      else
        put_buffered(item)
      end
    end
    alias_method(:<<, :put)

    #: () -> E
    def take
      if @size.zero?
        take_zero_sized
      else
        take_buffered
      end
    end

    #: () -> E
    def peek
      if @size.zero?
        peek_zero_sized
      else
        peek_buffered
      end
    end

    #: () -> bool
    def value?
      if @size.zero?
        @value != EMPTY
      else
        !@queue.empty?
      end
    end

    alias_method :ready?, :value?

    #: () -> Channel[E]
    def await
      peek
      self
    end

    #: () -> Array[E]
    def deconstruct
      Ori.sync { peek }
      [take]
    end

    private

    # Zero-sized channel implementation
    def put_zero_sized(item)
      @sender_waiting = true
      begin
        @value = item
        Fiber.yield until @taker_waiting
      ensure
        @taker_waiting = false
      end
    end

    def take_zero_sized
      @taker_waiting = true
      begin
        Fiber.yield(self) until @value != EMPTY
        @value
      ensure
        @value = EMPTY
        @sender_waiting = false
      end
    end

    def peek_zero_sized
      Fiber.yield(self) until @sender_waiting
      @value
    end

    # Buffered channel implementation
    def put_buffered(item)
      Fiber.yield until @queue.size < @size
      @queue << item
    end

    def take_buffered
      Fiber.yield(self) until value?
      @queue.shift
    end

    def peek_buffered
      Fiber.yield(self) until value?
      @queue.first
    end
  end
end
