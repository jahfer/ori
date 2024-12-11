# typed: true
# frozen_string_literal: true

require "zeitwerk"
loader = Zeitwerk::Loader.for_gem
loader.setup

require "sorbet-runtime"

module Ori
  class << self
    extend(T::Sig)

    sig do
      params(
        name: T.nilable(String),
        cancel_after: T.nilable(Numeric),
        raise_after: T.nilable(Numeric),
        block: T.proc.params(scope: Ori::Scope).void,
      ).returns(Ori::Scope)
    end
    def sync(name: nil, cancel_after: nil, raise_after: nil, &block)
      deadline = cancel_after || raise_after
      prev_scheduler = Fiber.current_scheduler

      scope = Ori::Scope.new(
        prev_scheduler.is_a?(Ori::Scope) ? prev_scheduler : nil,
        name:,
        deadline:,
      )

      Fiber.set_scheduler(scope)

      begin
        if Fiber.current.blocking?
          scope.async { block.call(scope) }
        else
          yield(scope)
        end

        scope.await
        scope
      rescue Ori::Scope::CancellationError => error
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
        .params(resources: T::Array[T.type_parameter(:U)])
        .returns(T.type_parameter(:U))
    end
    def select(resources)
      Ori::Select.new(resources).await
    end
  end
end
