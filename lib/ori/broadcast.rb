# typed: true

module Ori
  #: [E]
  class Broadcast
    def initialize
      @subscriptions = [] #: Array[Subscription[E]]
    end

    #: () -> Subscription[E]
    def subscribe
      subscription = Subscription.new(self)
      @subscriptions << subscription
      subscription
    end

    #: (Subscription[E] subscription) -> void
    def unsubscribe(subscription)
      @subscriptions.delete(subscription)
    end

    #: (E item) -> void
    def publish(item)
      @subscriptions.each { |sub| sub.__send_item(item) }
    end
    alias_method(:<<, :publish)

    #: [E]
    class Subscription
      include(Ori::Selectable)

      #: (Broadcast[E] broadcast) -> void
      def initialize(broadcast)
        @broadcast = broadcast
        @queue = [] #: Array[E]
      end

      #: () -> E
      def take
        if @queue.empty?
          Fiber.yield(self) until !@queue.empty?
        end
        @queue.shift #: as E
      end

      #: () -> E
      def peek
        if @queue.empty?
          Fiber.yield(self) until !@queue.empty?
        end
        @queue.first #: as E
      end

      #: () -> bool
      def value?
        !@queue.empty?
      end

      alias_method :ready?, :value?

      #: () -> Subscription[E]
      def await
        peek
        self
      end

      #: () -> Array[E]
      def deconstruct
        Ori.sync { peek }
        [take]
      end

      #: () -> void
      def unsubscribe
        @broadcast.unsubscribe(self)
      end

      # @api private
      #: (E item) -> void
      def __send_item(item)
        @queue << item
      end
    end
  end
end
