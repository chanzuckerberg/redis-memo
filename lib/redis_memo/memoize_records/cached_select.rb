# frozen_string_literal: true

#
# Inspect a SQL's AST to memoize SELECT statements
#
# As Rails applies additional logic on top of the rows returned from the
# database:
#
#  - `belongs_to ..., inverse_of: ...`: By using `inverse_of`, Rails could
#  prevent instantiating the different objects from the DB when the objects are
#  really the same.
#
#  - Associations may have scopes that add more filtering to the existing query
#
#  - +ActiveRecord::Relation+ defers the data fetching until the end
#
#  - +ActiveRecord::Relation+ could preload associations to avoid N+1 queries
#
# Memoizing each SQL query by inspecting its AST is the best approach we have
# to reliably perform query caching with ActiveRecord.
#
# Here's how this works at a high level:
#
# First, we extract dependencies from SQL queries. Consider the following query
#
#     SELECT * FROM my_records WHERE value = 'a'
#
# The rows returned from the database would not change unless records with the
# value 'a' have been updated. Therefore, if we are to cache this query, we
# need to set dependencies on this query and discard the cache if the
# dependencies have changed.
#
# Here's the dependency (aka a +Memoizable+) for the above query:
#
#     Memoizable.new(model: MyRecord, value: 'a')
#
# We bump the column dependencies automatically when updating a record that has
# the `memoize_table_column` declaration on the model class.
#
#     class MyRecord < ApplicationRecord
#       extend RedisMemo::MemoizeRecords
#       memoize_table_column :value
#     end
#
# After saving any MyRecord, we will bump the dependencies versions filled with
# the record's current and past values:
#
#     my_record.update(value: 'new_value') # from 'old_value'
#
# Then we will bump the versions for at least two memoizables:
#
#     Memoizable.new(model: MyRecord, value: 'new_value')
#     Memoizable.new(model: MyRecord, value: 'old_value')
#
#       When the another_value column is also memoized, we have another
#       memoizable to bump version for, regardless whether the another_value
#       filed of my_record has been changed:
#
#         Memoizable.new(model: MyRecord, another_value:  'current_value')
#
#       We need to do this because other columns could be cached in
#
#         SELECT * FROM ... WHERE another_value = ?
#
#       queries. Those query result sets become stale after the update.
#
# By setting dependencies on the query, we will use the dependencies versions
# as a part of the query cache key. After we bump the dependencies versions,
# the following request will produce a different new query cache key, so the
# request will end up with a cache_miss:
#   - Compute the fresh query result and it will actually send the query to the database
#   - Fill the new query cache key with the fresh query result
#
# After saving my_record and bumping the dependencies versions, all currently
# cached SQL queries that have `value = 'new_value'` or `value = 'old_value'`
# in their WHERE clause (or any WHERE conditions that's using the current
# memoized column values of my_record) can no longer be accessed by any new
# requests; Those entries will be automatically deleted through cache expiry or
# cache eviction.
#
# We can only memoize SQL queries that can be automatically invalidated through
# this mechanism:
#
#   - The query contains only =, IN conditions
#   - And those conditions are on table columns that have been memoized via
#   +memoized_table_column+
#
# See +extract_bind_params+ for the precise detection logic.
#
class RedisMemo::MemoizeRecords::CachedSelect
  # TODO: merge this into RedisMemo::MemoizeQuery
  def self.install(connection)
    klass = connection.class
    return if klass.singleton_class < RedisMemo::MemoizeMethod

    klass.class_eval do
      extend RedisMemo::MemoizeMethod

      memoize_method(
        :exec_query,
        method_id: proc do |_, sql, *args|
          sql.gsub(/(\$\d+)/, '?')      # $1 -> ?
             .gsub(/((, *)*\?)+/, '?')  # (?, ?, ? ...) -> (?)
        end,
      ) do |_, sql, name, binds, **kwargs|
        RedisMemo::MemoizeRecords::CachedSelect
          .current_query_bind_params
          .params
          .each do |model, attrs_set|
            attrs_set.each do |attrs|
              depends_on model, **attrs
            end
          end

        depends_on RedisMemo::Memoizable.new(
          __redis_memo_memoize_records_memoize_query_sql__: sql,
          __redis_memo_memoize_records_memoize_query_binds__: binds.map(&:value_for_database),
        )
      end
    end

    klass.prepend(ConnectionAdapter)
    ActiveRecord::StatementCache.prepend(StatementCache)

    # Cached result objects could be sampled to compare against fresh result
    # objects. Overwrite the == operator to make the comparison meaningful.
    ActiveRecord::Result.class_eval do
      def ==(other)
        columns == other.columns && rows == other.rows
      end
    end

    ActiveRecord::StatementCache::BindMap.class_eval do
      def map_substitutes(values)
        ret = {}
        @indexes.each_with_index do |offset, i|
          bound_attr = @bound_attributes[offset]
          substitute = bound_attr.value
          ret[substitute] = values[i]
        end
        ret
      end
    end
  end

  module ConnectionAdapter
    def cacheable_query(*args)
      query, binds = super(*args)

      # Persist the arel object to StatementCache#execute
      query.instance_variable_set(:@__redis_memo_memoize_records_memoize_query_arel, args.last)

      [query, binds]
    end

    def exec_query(*args)
      # An Arel AST in Thread local is set prior to supported query methods
      if !RedisMemo.without_memo? &&
          RedisMemo::MemoizeRecords::CachedSelect.extract_bind_params(args[0])
        # [Reids $model Load] $sql $binds
        RedisMemo::DefaultOptions.logger&.info(
          "[Redis] \u001b[36;1m#{args[1]} \u001b[34;1m#{args[0]}\u001b[0m #{
            args[2].map { |bind| [bind.name, bind.value_for_database]}
          }"
        )

        super(*args)
      else
        RedisMemo.without_memo { super(*args) }
      end
    end

    def select_all(*args)
      if args[0].is_a?(Arel::SelectManager)
        RedisMemo::MemoizeRecords::CachedSelect.current_query = args[0]
      end

      super(*args)
    ensure
      RedisMemo::MemoizeRecords::CachedSelect.reset_current_query
    end
  end

  module StatementCache
    def execute(*args)
      arel = query_builder.instance_variable_get(:@__redis_memo_memoize_records_memoize_query_arel)
      RedisMemo::MemoizeRecords::CachedSelect.current_query = arel
      RedisMemo::MemoizeRecords::CachedSelect.current_substitutes =
        bind_map.map_substitutes(args[0])

      super(*args)
    ensure
      RedisMemo::MemoizeRecords::CachedSelect.reset_current_query
    end
  end

  def self.extract_bind_params(sql)
    ast = Thread.current[THREAD_KEY_AREL]&.ast
    return false unless ast.is_a?(Arel::Nodes::SelectStatement)
    return false unless ast.to_sql == sql

    Thread.current[THREAD_KEY_SUBSTITUTES] ||= {}
    # Iterate through the Arel AST in a Depth First Search
    bind_params = extract_bind_params_recurse(ast)
    return false unless bind_params

    bind_params.uniq!
    return false unless bind_params.memoizable?

    Thread.current[THREAD_KEY_AREL_BIND_PARAMS] = bind_params
    true
  end

  def self.current_query_bind_params
    Thread.current[THREAD_KEY_AREL_BIND_PARAMS]
  end

  def self.current_query=(arel)
    Thread.current[THREAD_KEY_AREL] = arel
  end

  def self.current_substitutes=(substitutes)
    Thread.current[THREAD_KEY_SUBSTITUTES] = substitutes
  end

  def self.reset_current_query
    Thread.current[THREAD_KEY_AREL] = nil
    Thread.current[THREAD_KEY_SUBSTITUTES] = nil
    Thread.current[THREAD_KEY_AREL_BIND_PARAMS] = nil
  end

  private

  # A pre-order Depth First Search
  #
  # Note: Arel::Nodes#each returns a list in post-order, and it does not step
  # into Union nodes. So we're implementing our own DFS
  def self.extract_bind_params_recurse(node)
    bind_params = BindParams.new

    case node
    when Arel::Nodes::Equality, Arel::Nodes::In
      attr_node = node.left
      return unless attr_node.is_a?(Arel::Attributes::Attribute)

      table_node =
        case attr_node.relation
        when Arel::Table
          attr_node.relation
        when Arel::Nodes::TableAlias
          attr_node.relation.left
        else
          # Not yet supported
          return
        end

      type_caster = table_node.send(:type_caster)
      binding_relation =
        case type_caster
        when ActiveRecord::TypeCaster::Map
          type_caster.send(:types)
        when ActiveRecord::TypeCaster::Connection
          type_caster.instance_variable_get(:@klass)
        else
          return
        end

      rights = node.right.is_a?(Array) ? node.right : [node.right]
      substitutes = Thread.current[THREAD_KEY_SUBSTITUTES]

      rights.each do |right|
        case right
        when Arel::Nodes::BindParam
          # No need to type cast as they're only used to create +memoizables+
          # (used as strings)
          value = right.value.value_before_type_cast

          if value.is_a?(ActiveRecord::StatementCache::Substitute)
            value = substitutes[value]
          end

          bind_params.params[binding_relation] << {
            right.value.name.to_sym => value,
          }
        when Arel::Nodes::Casted
          bind_params.params[binding_relation] << {
            right.attribute.name.to_sym => right.val,
          }
        else
          bind_params = bind_params.union(extract_bind_params_recurse(right))
          if bind_params
            next
          else
            return
          end
        end
      end

      bind_params
    when Arel::Nodes::SelectStatement
      # No OREDER BY
      return unless node.orders.empty?

      node.cores.each do |core|
        # Should have a WHERE if directly selecting from a table
        source_node = core.source.left
        case source_node
        when Arel::Table
          return if core.wheres.empty?
        when Arel::Nodes::TableAlias
          bind_params = bind_params.union(
            extract_bind_params_recurse(source_node.left)
          )

          return unless bind_params
        else
          return
        end

        # Binds wheres before havings
        core.wheres.each do |where|
          bind_params = bind_params.union(
            extract_bind_params_recurse(where)
          )

          return unless bind_params
        end

        core.havings.each do |having|
          bind_params = bind_params.union(
            extract_bind_params_recurse(having)
          )

          return unless bind_params
        end
      end

      bind_params
    when Arel::Nodes::Grouping
      # Inline SQL
      return if node.expr.is_a?(Arel::Nodes::SqlLiteral)

      extract_bind_params_recurse(node.expr)
    when Arel::Nodes::And
      node.children.each do |child|
        bind_params = bind_params.product(
          extract_bind_params_recurse(child)
        )

        return unless bind_params
      end

      bind_params
    when Arel::Nodes::Join, Arel::Nodes::Union, Arel::Nodes::Or
      [node.left, node.right].each do |child|
        bind_params = bind_params.union(
          extract_bind_params_recurse(child)
        )

        return unless bind_params
      end

      bind_params
    else
      # Not yet supported
      return
    end
  end

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
          return false unless RedisMemo::MemoizeRecords
            .memoized_columns(model)
            .include?(attrs.keys.sort)
        end
      end

      true
    end
  end

  # Thread locals to exchange information between RedisMemo and ActiveRecord
  THREAD_KEY_AREL = :__redis_memo_memoize_records_cached_select_arel__
  THREAD_KEY_SUBSTITUTES = :__redis_memo_memoize_records_cached_select_substitues__
  THREAD_KEY_AREL_BIND_PARAMS = :__redis_memo_memoize_records_cached_select_arel_bind_params__
end
