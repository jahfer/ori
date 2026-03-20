# typed: strict

module Ori
  module Selectable
    #: () -> untyped
    def await; end

    #: () -> bool
    def ready?; false; end
  end
end
