# typed: strict

module Ori
  module Select
    class << self
      extend(T::Sig)

      sig do
        type_parameters(:U)
          .params(resources: T::Array[T.all(T.type_parameter(:U), Ori::Selectable)])
          .returns(T.type_parameter(:U))
      end
      def await(resources)
        # TODO: Check if any resources are already resolved
        # before spawning fibers
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
