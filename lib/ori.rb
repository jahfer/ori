# typed: strict

require "zeitwerk"
loader = Zeitwerk::Loader.for_gem
loader.setup

module Ori
  class CancellationError < StandardError
    #: Scope
    attr_reader :scope

    #: (Scope scope, ?String? message) -> void
    def initialize(scope, message = "Scope cancelled")
      @scope = scope
      super(message)
    end
  end

  class DeadlockError < CancellationError
    #: (Scope scope, ?String? message) -> void
    def initialize(scope, message = "All fibers are blocked, impossible to proceed")
      super(scope, message)
    end
  end

  class << self
    #: (?name: String?, ?cancel_after: Numeric?, ?raise_after: Numeric?, ?trace: bool) { (Scope) -> void } -> Scope
    def sync(name: nil, cancel_after: nil, raise_after: nil, trace: false, &block)
      prev_scheduler = Fiber.current_scheduler
      parent = prev_scheduler.is_a?(Scope) ? prev_scheduler : nil

      scope = Scope.new(
        parent,
        name,
        cancel_after || raise_after,
        trace,
      )

      Fiber.set_scheduler(scope)

      begin
        if parent
          yield(scope)
        else
          scope.fork { block.call(scope) }
        end

        scope.await
        scope
      rescue DeadlockError
        raise
      rescue CancellationError => error
        raise if error.scope != scope || !raise_after.nil?

        scope
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
