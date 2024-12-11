# typed: false
# frozen_string_literal: true

require "ori/channel"

module Ori
  class Select
    def initialize(resources)
      @resources = resources
    end

    def await
      winner = Promise.new

      Ori.sync do |scope|
        scope.each_async(@resources) do |resource|
          case resource
          when Ori::Timeout
            # If timeout returns nil, it was cancelled
            winner.resolve(resource) if resource.await
          when Ori::Promise
            resource.await
            winner.resolve(resource)
          when Ori::BaseChannel
            resource.peek
            winner.resolve(resource)
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
