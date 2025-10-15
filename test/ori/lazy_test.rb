# typed: false

require "test_helper"
require "ori/lazy"

module Ori
  class LazyBasicTest < Minitest::Test
    def test_lazy_initialization
      counter = 0
      lazy = Lazy.new(-> {
        counter += 1
        "result"
      })

      assert_equal(false, lazy.initialized?)
      assert_equal(0, counter)

      assert_equal("result", lazy.internal)
      assert_equal(1, counter)
      assert(lazy.initialized?)

      # Second call should use cached value
      assert_equal("result", lazy.internal)
      assert_equal(1, counter)
    end

    def test_lazy_with_nil_result
      lazy = Lazy.new(-> { nil })

      assert_equal(false, lazy.initialized?)
      assert_nil(lazy.internal)
      assert(lazy.initialized?)
    end
  end

  class LazyTest < Minitest::Test
    def test_lazy_hash_set
      hash = Ori::LazyHashSet.new
      assert_equal(Set.new, hash[:a])
    end

    def test_lazy_hash_set_add
      hash = Ori::LazyHashSet.new
      hash[:a].add(1)
      assert_equal(Set.new([1]), hash[:a])
    end
  end

  class LazyArrayTest < Minitest::Test
    def test_array_operations
      array = LazyArray.new
      assert_equal(0, array.size)
      assert_nil(array[0])

      array.push(1)
      assert_equal(1, array.size)
      assert_equal(1, array[0])

      array << 2
      assert_equal(2, array.size)
      assert_equal(2, array[1])

      array[2] = 3
      assert_equal(3, array.size)
      assert_equal(3, array[2])

      assert_equal(1, array.shift)
      assert_equal(2, array.size)
      assert_equal(2, array[0])
    end

    def test_array_enumerable
      array = LazyArray.new
      array.push(1)
      array.push(2)
      array.push(3)

      result = []
      array.each { |x| result << x }
      assert_equal([1, 2, 3], result)
    end
  end

  class LazyHashTest < Minitest::Test
    def test_hash_operations
      hash = LazyHash.new
      assert_nil(hash[:key])
      refute(hash.key?(:key))

      hash[:key] = "value"
      assert_equal("value", hash[:key])
      assert(hash.key?(:key))

      assert_equal("value", hash.fetch(:key))
      assert_equal("default", hash.fetch(:missing, "default"))

      hash.delete(:key)
      refute(hash.key?(:key))
    end

    def test_hash_enumerable
      hash = LazyHash.new
      hash[:a] = 1
      hash[:b] = 2

      assert_equal([1, 2], hash.values.sort)

      result = hash.reject { |k, _| k == :a }
      assert_equal({ b: 2 }, result)
    end
  end

  class LazyHashSetTest < Minitest::Test
    def test_none
      hash = LazyHashSet.new
      assert(hash.none?)

      hash[:a].add(1)
      refute(hash.none?)
      assert(hash.none? { |_, set| set.include?(2) })
    end

    def test_keys
      hash = LazyHashSet.new
      assert_empty(hash.keys)

      hash[:a].add(1)
      hash[:b].add(2)
      assert_equal([:a, :b], hash.keys.sort)
    end

    def test_delete
      hash = LazyHashSet.new
      hash[:a].add(1)
      hash[:b].add(2)

      hash.delete(:a)
      assert_equal([:b], hash.keys)
    end
  end
end
