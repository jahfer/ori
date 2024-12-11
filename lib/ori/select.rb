# typed: false
# frozen_string_literal: true

require "ori/channel"

module Ori
  class Select
    class << self
      def from(awaits)
        Select.new(awaits).await
      end
    end

    def initialize(resources)
      @resources = resources
    end

    def await
      winner = Promise.new

      Ori.sync do |scope|
        scope.each_async(@resources) do |resource|
          case resource
          when Ori::Timeout
            winner.resolve(resource) if resource.await
          when Ori::Promise
            winner.resolve([resource, resource.await])
          when Ori::BaseChannel
            winner.resolve([resource, resource.take])
          when Ori::Semaphore
            Fiber.yield until resource.available?
            winner.resolve(resource)
          else
            raise "Unsupported await type: #{resource.class}"
          end

          scope.cancel!
        end
      end

      winner.await
    end
  end
end
