# typed: true
# frozen_string_literal: true

module Ori
  class Promise
    def initialize
      @resolved = false
      @value = nil
    end

    def resolve(value)
      raise "Promise already resolved" if resolved?

      @resolved = true
      @value = value
    end

    def resolved?
      @resolved
    end

    def await
      return @value if resolved?

      Fiber.yield until resolved?
      @value
    end
  end
end
