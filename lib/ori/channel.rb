# typed: false
# frozen_string_literal: true

module Ori
  class Channel
    class << self
      extend(T::Sig)

      sig { params(size: Integer).returns(BaseChannel) }
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
    def send(item); end

    alias_method :<<, :send

    sig { abstract.returns(Elem) }
    def take; end
  end

  class ZeroSizedChannel
    extend(T::Sig)
    include(BaseChannel)

    sig { override.void }
    def initialize
      @queue = UnboundedQueue.new
      @sender_waiting = false
      @taker_waiting = false
    end

    sig { override.params(item: Elem).void }
    def send(item)
      @sender_waiting = true
      begin
        Fiber.yield until @taker_waiting
      ensure
        @taker_waiting = false
      end
      @queue.push(item)
    end
    alias_method :<<, :send

    sig { override.returns(Elem) }
    def take
      @taker_waiting = true
      begin
        Fiber.yield until @sender_waiting
      ensure
        @sender_waiting = false
      end
      @queue.shift
    end
  end

  class BufferedChannel
    extend(T::Sig)
    include(BaseChannel)

    sig { override.params(size: Integer).void }
    def initialize(size)
      @queue = UnboundedQueue.new
      @size = size
    end

    sig { override.params(item: Elem).void }
    def send(item)
      Fiber.yield until @queue.size < @size
      @queue.push(item)
    end
    alias_method :<<, :send

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
