# typed: true

module Ori
  class Lazy
    def initialize(init_proc)
      @proc = init_proc
    end

    def internal
      @internal ||= @proc.call
    end

    def initialized?
      instance_variable_defined?(:@internal)
    end
  end

  class LazyEnumerable < Lazy
    def each(&block)
      return enum_for(:each) unless block_given?
      return self unless initialized?

      internal.each(&block)
    end

    def delete_if(&block)
      return self unless initialized?

      internal.delete_if(&block)
    end

    def any?(&block)
      return false unless initialized?

      internal.any?(&block)
    end

    def empty?
      return true unless initialized?

      internal.empty?
    end
  end

  class LazyArray < LazyEnumerable
    INIT = proc { [] }
    def initialize
      super(INIT)
    end

    def [](index)
      internal[index] if initialized?
    end

    def push(value)
      internal.push(value)
    end

    def []=(index, value)
      internal[index] = value
    end

    alias_method :<<, :push

    def size
      return 0 unless initialized?

      internal.size
    end

    def shift
      return unless initialized?

      internal.shift
    end
  end

  class LazyHash < LazyEnumerable
    INIT = proc { {} }

    def initialize
      super(INIT)
    end

    def [](key)
      internal[key] if initialized?
    end

    def []=(key, value)
      internal[key] = value
    end

    def delete(key)
      internal.delete(key) if initialized?
    end

    def key?(key)
      return false unless initialized?

      internal.key?(key)
    end

    def fetch(index, default = nil)
      internal[index] || default
    end

    def reject(&block)
      return self unless initialized?

      internal.reject(&block)
    end

    def keys
      return [] unless initialized?

      internal.keys
    end

    def values
      return [] unless initialized?

      internal.values
    end

    def none?
      return true unless initialized?

      internal.none?
    end
  end

  class LazyHashSet < LazyEnumerable
    INIT = proc { Hash.new { |hash, key| hash[key] = Set.new } }

    def initialize
      super(INIT)
    end

    def [](key)
      internal[key]
    end

    def []=(key, value)
      internal[key] = value
    end

    def none?(&block)
      return true unless initialized?

      internal.none?(&block)
    end

    def keys
      return [] unless initialized?

      internal.keys
    end

    def delete(key)
      internal.delete(key) if initialized?
    end
  end
end
