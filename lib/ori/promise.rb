# typed: true

module Ori
  #: [E]
  class Promise
    include(Ori::Selectable)

    def initialize
      @resolved = false
      @value = nil
    end

    #: (E value) -> void
    def resolve(value)
      raise "Promise already resolved" if resolved?

      @resolved = true
      @value = value
    end

    #: () -> bool
    def resolved?
      @resolved
    end

    def deconstruct
      await unless resolved?
      [@value]
    end

    #: () -> E
    def await
      return @value if resolved?

      Fiber.yield(self) until resolved?
      @value
    end
  end
end
