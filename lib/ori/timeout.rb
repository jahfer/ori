# typed: true

module Ori
  class Timeout
    include(Ori::Selectable)

    def initialize(duration)
      @duration = duration
    end

    def await
      sleep(@duration)
      true
    end
  end
end
