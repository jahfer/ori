# typed: true

module Ori
  class Task
    include(Ori::Selectable)

    EMPTY = :empty

    attr_reader :fiber

    def initialize(&block)
      @fiber = Fiber.new(&block)
      @killed = false
      @value = EMPTY
      @cancellation_error = nil
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
      @killed
    end

    def kill
      @fiber.kill
      @killed = true
      @value = EMPTY
    end

    def id
      @id
    end

    def resume
      if @cancellation_error
        @fiber.kill
        return @cancellation_error
      end

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
      @cancellation_error = error
      resume
    end
  end
end
