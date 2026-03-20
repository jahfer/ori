# typed: true

module Ori
  class Task
    include(Ori::Selectable)

    EMPTY = :empty

    attr_reader :fiber, :id

    def initialize(&block)
      @fiber = Fiber.new(&block)
      @value = EMPTY
      @id = @fiber.object_id
    end

    def alive?
      @fiber.alive?
    end

    def value
      @value unless @value == EMPTY
    end

    def raise_error(error)
      @fiber.raise(error)
    end

    def killed?
      !@fiber.alive? && @value == EMPTY
    end

    def kill
      @fiber.kill
      @value = EMPTY
    end

    # @api private — used by Scope to set value directly
    def _set_value(v)
      @value = v
    end

    def resume
      fiber_result = @fiber.resume

      # Check for resource yielded by fiber (Channel, Promise, Semaphore, etc.)
      if fiber_result.is_a?(Ori::Selectable)
        fiber_result
      elsif @fiber.alive?
        self
      else
        @value = fiber_result
      end
    rescue => error
      @fiber.kill
      raise error
    end

    def await
      Fiber.yield while @fiber.alive?
      @value
    end

    def deconstruct
      [await]
    end

    def cancel(error)
      @fiber.kill
      error
    end
  end
end
