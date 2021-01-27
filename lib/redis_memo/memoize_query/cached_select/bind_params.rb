# frozen_string_literal: true

class RedisMemo::MemoizeQuery::CachedSelect
  class BindParams
    def params
      #
      # Bind params is hash of sets: each key is a model class, each value is a
      # set of hashes for memoized column conditions. Example:
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
      @params ||= Hash.new do |models, model|
        models[model] = []
      end
    end

    def union(other)
      return unless other

      # The tree is almost always right-heavy. Merge into the right node for better
      # performance.
      other.params.merge!(params) do |_, other_attrs_set, attrs_set|
        if other_attrs_set.empty?
          attrs_set
        elsif attrs_set.empty?
          other_attrs_set
        else
          attrs_set + other_attrs_set
        end
      end

      other
    end

    def product(other)
      #  Example:
      #
      #  and(
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
      return unless other

      # The tree is almost always right-heavy. Merge into the right node for better
      # performance.
      params.each do |model, attrs_set|
        next if attrs_set.empty?

        # The other model does not have any conditions so far: carry the
        # attributes over to the other node
        if other.params[model].empty?
          other.params[model] = attrs_set
          next
        end

        # Distribute the current attrs into the other
        other_attrs_set_size = other.params[model].size
        other_attrs_set = other.params[model]
        merged_attrs_set = Array.new(other_attrs_set_size * attrs_set.size)

        attrs_set.each_with_index do |attrs, i|
          other_attrs_set.each_with_index do |other_attrs, j|
            k = i * other_attrs_set_size + j
            merged_attrs = merged_attrs_set[k] = other_attrs.dup
            attrs.each do |name, val|
              # Conflict detected. For example:
              #
              #   (a = 1 or b = 1) and (a = 2 or b = 2)
              #
              #  Keep:     a = 1 and b = 2, a = 2 and b = 1
              #  Discard:  a = 1 and a = 2, b = 1 and b = 2
              if merged_attrs.include?(name) && merged_attrs[name] != val
                merged_attrs_set[k] = nil
                break
              end

              merged_attrs[name] = val
            end
          end
        end

        merged_attrs_set.compact!
        other.params[model] = merged_attrs_set
      end

      other
    end

    def uniq!
      params.each do |_, attrs_set|
        attrs_set.uniq!
      end
    end

    def memoizable?
      return false if params.empty?

      params.each do |model, attrs_set|
        return false if attrs_set.empty?

        attrs_set.each do |attrs|
          return false unless RedisMemo::MemoizeQuery
            .memoized_columns(model)
            .include?(attrs.keys.sort)
        end
      end

      true
    end
  end
end
