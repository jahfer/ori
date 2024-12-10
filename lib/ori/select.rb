# typed: false
# frozen_string_literal: true

module Ori
  class Select
    class << self
      def from(awaits)
        awaiter, value = Select.new(awaits).await
        [awaiter, value]
      end
    end

    def initialize(awaits)
      @awaits = awaits
    end

    def await
      winner = Promise.new

      Ori::Scope.boundary do |scope|
        scope.fork_each(@awaits) do |await|
          case await
          when Promise
            winner.resolve([await, await.await])
          when BaseChannel
            winner.resolve([await, await.take])
          when Semaphore
            winner.resolve([await, await.acquire])
          else
            raise "Unsupported await type: #{await.class}"
          end

          scope.cancel!
        end
      end

      winner.await
    end
  end
end
