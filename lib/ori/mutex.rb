# typed: false
# frozen_string_literal: true

module Ori
  class Mutex < Semaphore
    def initialize
      super(1)
    end
  end
end
