# typed: true
# frozen_string_literal: true

module Ori
  class Promise
    extend(T::Sig)
    extend(T::Generic)

    Elem = type_member

    def initialize
      @resolved = false
      @value = nil
    end

    sig { params(value: Elem).void }
    def resolve(value)
      raise "Promise already resolved" if resolved?

      @resolved = true
      @value = value
    end

    sig { returns(T::Boolean) }
    def resolved?
      @resolved
    end

    def deconstruct
      await unless resolved?
      [@value]
    end

    sig { returns(Elem) }
    def await
      return @value if resolved?

      Fiber.yield(self) until resolved?
      @value
    end
  end
end
