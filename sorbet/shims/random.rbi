# typed: false
# frozen_string_literal: true

class Random
  class << self
    sig { params(extra_timestamp_bits: Integer).returns(String) }
    def uuid_v7(extra_timestamp_bits: 0); end
  end
end
