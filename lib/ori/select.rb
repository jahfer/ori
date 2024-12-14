# typed: true
# frozen_string_literal: true

require "ori/channel"

module Ori
  class Select
    extend(T::Sig)

    sig { params(resources: T::Array[Ori::Selectable]).void }
    def initialize(resources)
      @resources = resources
    end

    def await
      winner = Promise.new

      Ori.sync do |scope|
        scope.fork_each(@resources) do |resource|
          case resource
          when Ori::Timeout
            # Timeout returns nil if it was cancelled
            winner.resolve(resource) if resource.await
          when Ori::Selectable # Ori::Promise, Ori::Task, Ori::Channel, Ori::Semaphore
            resource.await
            winner.resolve(resource)
          else
            raise "Unsupported await type: #{resource.class}"
          end

          scope.shutdown!
        end
      end

      winner.await
    end
  end
end
