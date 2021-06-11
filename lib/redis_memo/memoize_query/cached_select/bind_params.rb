# frozen_string_literal: true

class RedisMemo::MemoizeQuery::CachedSelect
  class BindParams
    def initialize(left = nil, right = nil, opt = nil)
      @left = left
      @right = right
      @opt = opt
      @plan = nil
    end

    def union(other)
      return unless other

      self.class.new(self, other, __method__)
    end

    def product(other)
      return unless other

      self.class.new(self, other, __method__)
    end

    def should_cache?
      plan!
      return false if plan.dependency_size > RedisMemo::DefaultOptions.max_query_dependency_size

      plan.model_attrs.each do |model, attrs_set|
        return false if attrs_set.empty?

        attrs_set.each do |attrs|
          return false unless RedisMemo::MemoizeQuery
            .memoized_columns(model)
            .include?(attrs.keys.sort)
        end
      end

      !plan.model_attrs.empty?
    end

    def plan!
      self.plan = Plan.new(self)
      return if opt.nil?

      left.plan!
      right.plan!
      __send__(:"plan_#{opt}")
    end

    #
    # Extracted bind params is hash of sets: each key is a model class, each
    # value is a set of hashes for memoized column conditions. Example:
    #
    #   {
    #      Site => [
    #        {name: 'a', city: 'b'},
    #        {name: 'a', city: 'c'},
    #        {name: 'b', city: 'b'},
    #        {name: 'b', city: 'c'},
    #      ],
    #   }
    #
    def extract!
      return if opt.nil?

      left.extract!
      right.extract!
      __send__(:"#{opt}!")
    end

    def params
      @params ||= Hash.new do |models, model|
        models[model] = Set.new
      end
    end

    protected

    attr_accessor :left
    attr_accessor :right
    attr_accessor :opt
    attr_accessor :plan

    def union_attrs_set(left, right)
      left.merge(right) do |_, attrs_set, other_attrs_set|
        next attrs_set if other_attrs_set.empty?
        next other_attrs_set if attrs_set.empty?
        attrs_set + other_attrs_set
      end
    end

    def plan_union
      plan.dependency_size = left.plan.dependency_size + right.plan.dependency_size
      plan.model_attrs = union_attrs_set(left.plan.model_attrs, right.plan.model_attrs)
    end

    def union!
      @params = union_attrs_set(left.params, right.params)
    end

    def product_attrs_set(left, right)
      #  Example:
      #
      #  product(
      #    [{a: 1}, {a: 2}],
      #    [{b: 1}, {b: 2}],
      #  )
      #
      #  =>
      #
      #  [
      #    {a: 1, b: 1},
      #    {a: 1, b: 2},
      #    {a: 2, b: 1},
      #    {a: 2, b: 2},
      #  ]
      left.merge(right) do |_, attrs_set, other_attrs_set|
        next attrs_set if other_attrs_set.empty?
        next other_attrs_set if attrs_set.empty?

        # distribute the current attrs into the other
        merged_attrs_set = Set.new
        attrs_set.each do |attrs|
          other_attrs_set.each do |other_attrs|
            merged_attrs = other_attrs.dup
            should_add = true
            attrs.each do |name, val|
              # conflict detected. for example:
              #
              #   (a = 1 or b = 1) and (a = 2 or b = 2)
              #
              #  keep:     a = 1 and b = 2, a = 2 and b = 1
              #  discard:  a = 1 and a = 2, b = 1 and b = 2
              if merged_attrs.include?(name) && merged_attrs[name] != val
                should_add = false
                break
              end

              merged_attrs[name] = val
            end
            merged_attrs_set << merged_attrs if should_add
          end
        end

        merged_attrs_set
      end
    end

    def plan_product
      plan.dependency_size = left.plan.dependency_size * right.plan.dependency_size
      plan.model_attrs = product_attrs_set(left.plan.model_attrs, right.plan.model_attrs)
    end

    def product!
      @params = product_attrs_set(left.params, right.params)
    end

    class Plan
      attr_accessor :dependency_size
      attr_accessor :model_attrs

      def initialize(bind_params)
        @dependency_size = 0
        @model_attrs = Hash.new do |models, model|
          models[model] = Set.new
        end

        # An aggregated bind_params node can only obtain params by combining
        # its children nodes
        return if !bind_params.__send__(:opt).nil?

        bind_params.params.each do |model, attrs_set|
          @dependency_size += attrs_set.size
          attrs_set.each do |attrs|
            @model_attrs[model] << attrs.keys.map { |k| [k, nil] }.to_h
          end
        end
      end
    end
  end
end
