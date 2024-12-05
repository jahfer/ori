# typed: true
# frozen_string_literal: true

module Ori
  class Semaphore
    def initialize(num_tickets)
      raise ArgumentError, "Number of tickets must be positive" if num_tickets <= 0

      @tickets = num_tickets
      @available = num_tickets
    end

    def synchronize
      acquire
      yield
    ensure
      release
    end

    def release
      raise "Semaphore overflow" if @available >= @tickets

      @available += 1
      true
    end

    def acquire
      Fiber.yield until available?
      @available -= 1
      true
    end

    def available?
      @available > 0
    end

    def count
      @available
    end
  end
end
