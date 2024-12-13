# typed: true
# frozen_string_literal: true

module Ori
  # Base class for different channel implementations
  module BaseChannel
    extend(T::Sig)
    extend(T::Generic)

    Elem = type_member

    abstract!

    sig { abstract.params(item: Elem).void }
    def put(item); end

    sig { params(item: Elem).void }
    def <<(item) = put(item)

    sig { abstract.returns(Elem) }
    def peek; end

    sig { abstract.returns(Elem) }
    def take; end

    sig { abstract.returns(T::Boolean) }
    def value?; end

    sig { returns(T::Array[Elem]) }
    def deconstruct
      Ori.sync { peek }
      [take]
    end
  end

  class Channel
    extend(T::Sig)
    extend(T::Generic)
    include(BaseChannel)

    Elem = type_member

    sig { params(size: Integer).void }
    def initialize(size)
      @chan = if size.zero?
        ZeroSizedChannel[Elem].new
      else
        BufferedChannel[Elem].new(size)
      end
    end

    def put(...) = @chan.put(...)
    def take = @chan.take
    def peek = @chan.peek
    def value? = @chan.value?
  end

  class ZeroSizedChannel
    extend(T::Sig)
    extend(T::Generic)
    include(BaseChannel)

    Elem = type_member
    EMPTY = "empty"

    sig { override.void }
    def initialize
      super
      @taker_waiting = false
      @value = EMPTY
    end

    sig { override.params(item: Elem).void }
    def put(item)
      @sender_waiting = true
      begin
        @value = item
        # TODO: Communicate blocking condition to scope
        Fiber.yield until @taker_waiting
      ensure
        @taker_waiting = false
      end
    end

    sig { override.returns(Elem) }
    def take
      @taker_waiting = true
      begin
        Fiber.yield(self) until @value != EMPTY
        @value
      ensure
        @value = EMPTY
        @sender_waiting = false
      end
    end

    sig { override.returns(Elem) }
    def peek
      Fiber.yield(self) until @sender_waiting
      @value
    end

    sig { override.returns(T::Boolean) }
    def value?
      @value != EMPTY
    end
  end

  class BufferedChannel
    extend(T::Sig)
    extend(T::Generic)
    include(BaseChannel)

    Elem = type_member

    sig { override.params(size: Integer).void }
    def initialize(size)
      super()
      @queue = UnboundedQueue.new
      @size = size
    end

    sig { override.params(item: Elem).void }
    def put(item)
      Fiber.yield until @queue.size < @size # TODO: Fiber.yield(-> { @queue.size < @size })
      @queue.push(item)
    end

    sig { override.returns(Elem) }
    def take
      Fiber.yield(self) until value?
      @queue.shift
    end

    sig { override.returns(Elem) }
    def peek
      Fiber.yield(self) until value?
      @queue.peek
    end

    sig { override.returns(T::Boolean) }
    def value?
      @queue.peek != UnboundedQueue::EMPTY
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
