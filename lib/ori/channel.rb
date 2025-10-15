# typed: true

module Ori
  class Channel
    extend(T::Sig)
    extend(T::Generic)
    include(Ori::Selectable)

    Elem = type_member
    EMPTY = "empty"

    sig { params(size: Integer).void }
    def initialize(size)
      @size = size
      if size.zero?
        # Zero-sized channel state
        @taker_waiting = false
        @sender_waiting = false
        @value = EMPTY
      else
        # Buffered channel state
        @queue = UnboundedQueue.new
      end
    end

    sig { params(item: Elem).void }
    def put(item)
      if @size.zero?
        put_zero_sized(item)
      else
        put_buffered(item)
      end
    end
    alias_method(:<<, :put)

    sig { returns(Elem) }
    def take
      if @size.zero?
        take_zero_sized
      else
        take_buffered
      end
    end

    sig { returns(Elem) }
    def peek
      if @size.zero?
        peek_zero_sized
      else
        peek_buffered
      end
    end

    sig { returns(T::Boolean) }
    def value?
      if @size.zero?
        @value != EMPTY
      else
        @queue.peek != UnboundedQueue::EMPTY
      end
    end

    sig { override.returns(Ori::Channel[Elem]) }
    def await
      peek
      self
    end

    sig { returns(T::Array[Elem]) }
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
      @queue.push(item)
    end

    def take_buffered
      Fiber.yield(self) until value?
      @queue.shift
    end

    def peek_buffered
      Fiber.yield(self) until value?
      @queue.peek
    end
  end

  # TODO: implement sliding queue, dropping queue
  class UnboundedQueue
    EMPTY = "empty"

    def initialize
      @buffer = []
    end

    def size
      @buffer.size
    end

    def push(item)
      @buffer << item
    end

    def peek
      if @buffer.empty?
        EMPTY
      else
        @buffer.first
      end
    end

    def shift
      @buffer.shift
    end
  end
  private_constant(:UnboundedQueue)
end
