# typed: true
# frozen_string_literal: true

module Ori
  class Channel
    extend(T::Sig)
    extend(T::Generic)

    Elem = type_template

    class << self
      extend(T::Sig)

      sig { params(size: Integer).returns(BaseChannel[Elem]) }
      def new(size)
        if size.zero?
          ZeroSizedChannel.new
        else
          BufferedChannel.new(size)
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
    def take; end
  end

  class ZeroSizedChannel
    extend(T::Sig)
    extend(T::Generic)
    include(BaseChannel)

    Elem = type_member
    EMPTY = "empty"

    sig { override.void }
    def initialize
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
  end

  class BufferedChannel
    extend(T::Sig)
    extend(T::Generic)
    include(BaseChannel)

    Elem = type_member

    sig { override.params(size: Integer).void }
    def initialize(size)
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
