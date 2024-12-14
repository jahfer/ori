# typed: strict
# frozen_string_literal: true

module Ori
  module Selectable
    extend(T::Sig)
    extend(T::Helpers)

    abstract!

    sig { abstract.returns(T.untyped) }
    def await; end
  end
end
