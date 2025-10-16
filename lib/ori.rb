# typed: strict

require "zeitwerk"
loader = Zeitwerk::Loader.for_gem
loader.setup

module Ori
  class CancellationError < StandardError

    #: -> Scope
    attr_reader :scope

    #: (scope: Scope, ?message: String?) -> void
    def initialize(scope, message = "Scope cancelled")
      @scope = scope
      super(message)
    end
  end

  class << self
    #: (name: String?, cancel_after: Number?, raise_after: Number?, trace: Boolean, &block: (Scope) -> void) -> Scope
    def sync(name: nil, cancel_after: nil, raise_after: nil, trace: false, &block)
      deadline = cancel_after || raise_after
      prev_scheduler = Fiber.current_scheduler

      scope = Scope.new(
        prev_scheduler.is_a?(Scope) ? prev_scheduler : nil,
        name,
        deadline,
        trace,
      )

      Fiber.set_scheduler(scope)

      begin
        if Fiber.current.blocking?
          scope.fork { block.call(scope) }
        else
          yield(scope)
        end

        scope.await
        scope
      rescue CancellationError => error
        # Re-raise if:
        # 1. The error is from a different scope, or
        # 2. This is our error but it's from raise_after
        raise if error.scope != scope || !raise_after.nil?

        scope # Return the scope even when cancelled
      ensure
        Fiber.set_scheduler(prev_scheduler)
      end
    end

    # sig do
    #   type_parameters(:U)
    #     .params(resources: T::Array[T.all(T.type_parameter(:U), Ori::Selectable)])
    #     .returns(T.type_parameter(:U))
    # end
    #: [U] (Array[U & Selectable] resources) -> U
    def select(resources)
      Ori::Select.await(resources)
    end
  end

  private_constant(:Scope)
end
