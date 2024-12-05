# typed: true
# frozen_string_literal: true

require "test_helper"

class OriTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil(::Ori::VERSION)
  end

  def test_foo
    ::Ori::Scope.boundary { sleep(0.1) }
  end
end
