# typed: strict

module Ori
  module Select
    class << self
      #: [U] (Array[U & Selectable] resources) -> U
      def await(resources)
        # Fast path: check if any resource is already ready
        resources.each do |resource|
          return resource if resource.respond_to?(:ready?) && resource.ready?
        end

        winner = Promise.new

        Ori.sync(name: "select") do |scope|
          # TODO: use pattern match against Ori::Task here
          # instead of Ori::Promise?
          scope.fork_each(resources) do |resource|
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
end
