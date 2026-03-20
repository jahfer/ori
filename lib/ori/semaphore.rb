# typed: true

module Ori
  class Semaphore
    include(Ori::Selectable)

    def initialize(num_tickets)
      raise ArgumentError, "Number of tickets must be positive" if num_tickets <= 0

      @tickets = num_tickets
      @available = num_tickets
    end

    def sync
      if @available > 0
        # Fast path: ticket available immediately
        @available -= 1
        begin
          yield
        ensure
          @available += 1
        end
      else
        acquire
        begin
          yield
        ensure
          release
        end
      end
    end

    def release
      raise "Semaphore overflow" if @available >= @tickets

      @available += 1
      true
    end

    def acquire
      Fiber.yield(self) until @available > 0
      @available -= 1
      true
    end

    def available?
      @available > 0
    end

    alias_method :ready?, :available?

    def count
      @available
    end

    def await
      Fiber.yield until available?
      true
    end
  end
end
