# typed: false
# frozen_string_literal: true

class Fiber
  class << self
    sig { returns(Fiber) }
    def current; end

    sig { params(scheduler: T.untyped).void }
    def set_scheduler(scheduler); end

    sig { returns(T.untyped) }
    def current_scheduler; end
  end

  sig { params(block: T.proc.void).void }
  def initialize(&block); end

  sig { returns(T::Boolean) }
  def blocking?; end
end
