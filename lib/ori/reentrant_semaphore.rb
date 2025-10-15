# typed: true

module Ori
  class ReentrantSemaphore
    include(Ori::Selectable)

    def initialize(num_tickets)
      raise ArgumentError, "Number of tickets must be positive" if num_tickets <= 0

      @tickets = num_tickets
      @available = num_tickets
      @owners = Hash.new(0) # Track fiber -> acquire count
    end

    def sync
      acquire
      begin
        yield
      ensure
        release
      end
    end

    def release
      current = Fiber.current

      if @owners[current] > 0
        @owners[current] -= 1
        if @owners[current] == 0
          @owners.delete(current)
          @available += 1
        end
        return true
      end

      raise "Cannot release semaphore - not owned by current fiber"
    end

    def acquire
      current = Fiber.current

      # If this fiber already owns the semaphore, increment its count
      if @owners[current] > 0
        @owners[current] += 1
        return true
      end

      # Otherwise wait for an available ticket
      Fiber.yield(self) until available?
      @available -= 1
      @owners[current] = 1
      true
    end

    def available?
      @available > 0 || @owners[Fiber.current] > 0
    end

    def count
      @available
    end

    def await
      Fiber.yield until available?
      true
    end
  end
end
