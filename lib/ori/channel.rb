# typed: true
# frozen_string_literal: true

module Ori
  class Channel
    class << self
      extend(T::Sig)
      extend(T::Generic)

      Elem = type_member

      sig { params(size: Integer).returns(BaseChannel[Elem]) }
      def new(size)
        if size.zero?
          ZeroSizedChannel[Elem].new
        else
          BufferedChannel[Elem].new(size)
        end
      end
    end
  end

  # Base class for different channel implementations
  module BaseChannel
    extend(T::Sig)
    extend(T::Generic)

    Elem = type_member

    abstract!

    sig { abstract.params(item: Elem).void }
    def put(item); end

    alias_method :<<, :put

    sig { abstract.returns(Elem) }
    def peek; end

    sig { abstract.returns(Elem) }
    def take; end

    sig { returns(T::Array[Elem]) }
    def deconstruct
      value = T.let(nil, T.nilable(Elem))

      Ori.sync { value = take }

      [T.must(value)]
    end
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
        Fiber.yield until @taker_waiting
      ensure
        @taker_waiting = false
      end
    end
    alias_method :<<, :put

    sig { override.returns(Elem) }
    def take
      @taker_waiting = true
      begin
        Fiber.yield until @value != EMPTY
        @value
      ensure
        @value = EMPTY
        @sender_waiting = false
      end
    end

    sig { override.returns(Elem) }
    def peek
      Fiber.yield until @value != EMPTY
      @value
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
      Fiber.yield until @queue.size < @size
      @queue.push(item)
    end
    alias_method :<<, :put

    sig { override.returns(Elem) }
    def take
      Fiber.yield while @queue.peek == UnboundedQueue::EMPTY
      @queue.shift
    end

    sig { override.returns(Elem) }
    def peek
      Fiber.yield while @queue.peek == UnboundedQueue::EMPTY
      @queue.peek
    end
  end

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
