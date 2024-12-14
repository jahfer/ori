# typed: strict
# frozen_string_literal: true

require "zeitwerk"
loader = Zeitwerk::Loader.for_gem
loader.setup

require "sorbet-runtime"

T::Configuration.default_checked_level = :tests

module Ori
  class CancellationError < StandardError
    extend(T::Sig)

    sig { returns(Scope) }
    attr_reader :scope

    sig { params(scope: Scope, message: T.nilable(String)).void }
    def initialize(scope, message = "Scope cancelled")
      @scope = scope
      super(message)
    end
  end

  class << self
    extend(T::Sig)

    sig do
      params(
        name: T.nilable(String),
        cancel_after: T.nilable(Numeric),
        raise_after: T.nilable(Numeric),
        block: T.proc.params(scope: Scope).void,
      ).returns(Scope)
    end
    def sync(name: nil, cancel_after: nil, raise_after: nil, &block)
      deadline = cancel_after || raise_after
      prev_scheduler = Fiber.current_scheduler

      # TODO: Use Ori::Mutex instead of creating a new scope?
      scope = Scope.new(
        prev_scheduler.is_a?(Scope) ? prev_scheduler : nil,
        name:,
        deadline:,
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

    sig do
      type_parameters(:U)
        .params(resources: T::Array[T.all(T.type_parameter(:U), Ori::Selectable)])
        .returns(T.type_parameter(:U))
    end
    def select(resources)
      Ori::Select.new(resources).await
    end
  end

  private_constant(:Scope)
end
