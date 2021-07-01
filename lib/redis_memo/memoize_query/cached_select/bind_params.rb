# frozen_string_literal: true

class RedisMemo::MemoizeQuery::CachedSelect
  class BindParams
    def initialize(left = nil, right = nil, operator = nil)
      @left = left
      @right = right
      @operator = operator
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

      if plan.model_attrs.empty? || plan.dependency_size_estimation.to_i > RedisMemo::DefaultOptions.max_query_dependency_size
        return false
      end

      plan.model_attrs.each do |model, attrs_set|
        return false if attrs_set.empty?

        attrs_set.each do |attrs|
          return false unless RedisMemo::MemoizeQuery
            .memoized_columns(model)
            .include?(attrs.keys.sort)
        end
      end

      true
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
      return if operator.nil?

      left.extract!
      right.extract!
      __send__(:"#{operator}!")
    end

    def params
      @params ||= Hash.new do |models, model|
        models[model] = Set.new
      end
    end

    protected

    # BindParams is built recursively when iterating through the Arel AST
    # nodes. BindParams represents a binary tree. Query parameters are added to
    # the leaf nodes of the tree, and the leaf nodes are connected by
    # operators, such as `union` (or conditions) or `product` (and conditions).
    attr_accessor :left
    attr_accessor :right
    attr_accessor :operator
    attr_accessor :plan

    def plan!
      self.plan = Plan.new(self)
      return if operator.nil?

      left.plan!
      right.plan!
      __send__(:"plan_#{operator}")
    end

    def plan_union
      plan.dependency_size_estimation = left.plan.dependency_size_estimation + right.plan.dependency_size_estimation
      plan.model_attrs = union_attrs_set(left.plan.model_attrs, right.plan.model_attrs)
    end

    def plan_product
      plan.dependency_size_estimation = left.plan.dependency_size_estimation * right.plan.dependency_size_estimation
      plan.model_attrs = product_attrs_set(left.plan.model_attrs, right.plan.model_attrs)
    end

    def union!
      @params = union_attrs_set(left.params, right.params)
    end

    def product!
      @params = product_attrs_set(left.params, right.params)
    end

    def union_attrs_set(left, right)
      left.merge(right) do |_, attrs_set, other_attrs_set|
        next attrs_set if other_attrs_set.empty?
        next other_attrs_set if attrs_set.empty?

        attrs_set + other_attrs_set
      end
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
            should_add_attrs = true
            attrs.each do |name, val|
              # Conflict detected. For example:
              #
              #   (a = 1 or b = 1) and (a = 2 or b = 2)
              #
              #  Keep:     a = 1 and b = 2, a = 2 and b = 1
              #  Discard:  a = 1 and a = 2, b = 1 and b = 2
              if merged_attrs.include?(name) && merged_attrs[name] != val
                should_add_attrs = false
                break
              end

              merged_attrs[name] = val
            end
            merged_attrs_set << merged_attrs if should_add_attrs
          end
        end

        merged_attrs_set
      end
    end

    # Prior to actually extracting the bind parameters, we first quickly
    # estimate if it makes sense to do so. If a query contains too many
    # dependencies, or contains dependencies that have not been memoized, then
    # the query itself cannot be cached correctly/efficiently, so there’s no
    # point to actually extract.
    #
    # The planning phase is similar to the extraction phase. Though in the
    # planning phase, we can ignore all the actual attribute values and only
    # look at the attribute names. This way, we can precompute the dependency
    # size without populating their actual values.
    #
    # For example, in the planning phase,
    #
    #   {a:nil} x {b: nil} => {a: nil, b: nil}
    #   {a:nil, b:nil} x {a: nil: b: nil} => {a: nil, b: nil}
    #
    # and in the extraction phase, that's where the # of dependency can
    # actually grow significantly:
    #
    #   {a: [1,2,3]} x {b: [1,2,3]} => [{a: 1, b: 1}, ....]
    #   {a:[1,2], b:[1,2]} x {a: [1,2,3]: b: [1,2,3]} => [{a: 1, b: 1}, ...]
    #
    class Plan
      class DependencySizeEstimation
        def initialize(hash = nil)
          @hash = hash
        end

        def +(other)
          merged_hash = hash.dup
          other.hash.each do |k, v|
            merged_hash[k] += v
          end
          self.class.new(merged_hash)
        end

        def *(other)
          merged_hash = hash.dup
          other.hash.each do |k, v|
            if merged_hash.include?(k)
              merged_hash[k] *= v
            else
              merged_hash[k] = v
            end
          end
          self.class.new(merged_hash)
        end

        def [](key)
          hash[key]
        end

        def []=(key, val)
          hash[key] = val
        end

        def to_i
          ret = 0
          hash.each do |_, v|
            ret += v
          end
          ret
        end

        protected

        def hash
          @hash ||= Hash.new(0)
        end
      end

      attr_accessor :dependency_size_estimation
      attr_accessor :model_attrs

      def initialize(bind_params)
        @dependency_size_estimation = DependencySizeEstimation.new
        @model_attrs = Hash.new do |models, model|
          models[model] = Set.new
        end

        # An aggregated bind_params node can only obtain params by combining
        # its children nodes
        return if !bind_params.__send__(:operator).nil?

        bind_params.params.each do |model, attrs_set|
          @dependency_size_estimation[model] += attrs_set.size
          attrs_set.each do |attrs|
            # [k, nil]: Ignore the attr value and keep the name only
            @model_attrs[model] << attrs.keys.map { |k| [k, nil] }.to_h
          end
        end
      end
    end
  end
end
