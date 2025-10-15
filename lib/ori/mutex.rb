# typed: true

module Ori
  class Mutex < Semaphore
    def initialize
      super(1)
    end
  end
end
