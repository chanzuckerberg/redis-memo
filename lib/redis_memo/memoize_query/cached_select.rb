# frozen_string_literal: true

##
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
#       extend RedisMemo::MemoizeQuery
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
class RedisMemo::MemoizeQuery::CachedSelect
  require_relative 'cached_select/bind_params'
  require_relative 'cached_select/connection_adapter'
  require_relative 'cached_select/statement_cache'

  @@enabled_models = {}

  # Thread locals to exchange information between RedisMemo and ActiveRecord
  RedisMemo::ThreadLocalVar.define :arel
  RedisMemo::ThreadLocalVar.define :substitues
  RedisMemo::ThreadLocalVar.define :arel_bind_params

  # @return [Hash] models enabled for caching
  def self.enabled_models
    @@enabled_models
  end

  def self.install(connection)
    klass = connection.class
    return if klass.singleton_class < RedisMemo::MemoizeMethod

    klass.class_eval do
      extend RedisMemo::MemoizeMethod

      memoize_method(
        :exec_query,
        method_id: proc { |_, sql, *| RedisMemo::Util.tagify_parameterized_sql(sql) },
      ) do |_, sql, _, binds, **|
        depends_on RedisMemo::MemoizeQuery::CachedSelect.current_query_bind_params

        depends_on RedisMemo::Memoizable.new(
          __redis_memo_memoize_query_memoize_query_sql__: sql,
          __redis_memo_memoize_query_memoize_query_binds__: binds.map do |bind|
            if bind.respond_to?(:value_for_database)
              bind.value_for_database
            else
              # In activerecord >= 6, a bind could be an actual database value
              bind
            end
          end,
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

  # Extract bind params from the query by inspecting the SQL's AST recursively
  # The bind params will be passed into the local thread variables. See
  # +construct_bind_params_recurse+ for how to construct binding params
  # recursively.
  #
  # @param sql [String] SQL query
  # @return [Boolean] indicating whether a query should be cached
  def self.extract_bind_params(sql)
    RedisMemo::Tracer.trace(
      'redis_memo.memoize_query.extract_bind_params',
      RedisMemo::Util.tagify_parameterized_sql(sql),
    ) do
      ast = RedisMemo::ThreadLocalVar.arel&.ast
      return false unless ast.is_a?(Arel::Nodes::SelectStatement)
      return false unless ast.to_sql == sql

      RedisMemo::ThreadLocalVar.substitues ||= {}
      # Iterate through the Arel AST in a Depth First Search
      bind_params = construct_bind_params_recurse(ast)
      return false unless bind_params&.should_cache?

      bind_params.extract!
      RedisMemo::ThreadLocalVar.arel_bind_params = bind_params
      true
    end
  end

  def self.current_query_bind_params
    RedisMemo::ThreadLocalVar.arel_bind_params
  end

  def self.current_query=(arel)
    RedisMemo::ThreadLocalVar.arel = arel
  end

  def self.current_substitutes=(substitutes)
    RedisMemo::ThreadLocalVar.substitues = substitutes
  end

  def self.reset_current_query
    RedisMemo::ThreadLocalVar.arel = nil
    RedisMemo::ThreadLocalVar.substitues = nil
    RedisMemo::ThreadLocalVar.arel_bind_params = nil
  end

  def self.with_new_query_context
    prev_arel = RedisMemo::ThreadLocalVar.arel
    prev_substitutes = RedisMemo::ThreadLocalVar.substitues
    prev_bind_params = RedisMemo::ThreadLocalVar.arel_bind_params
    RedisMemo::MemoizeQuery::CachedSelect.reset_current_query

    yield
  ensure
    RedisMemo::ThreadLocalVar.arel = prev_arel
    RedisMemo::ThreadLocalVar.substitues = prev_substitutes
    RedisMemo::ThreadLocalVar.arel_bind_params = prev_bind_params
  end

  # A pre-order Depth First Search
  #
  # Note: Arel::Nodes#each returns a list in post-order, and it does not step
  # into Union nodes. So we're implementing our own DFS
  #
  # @param node [Arel::Nodes::Node]
  #
  # @return [RedisMemo::MemoizeQuery::CachedSelect::BindParams]
  def self.construct_bind_params_recurse(node)
    # rubocop: disable Lint/NonLocalExitFromIterator
    bind_params = BindParams.new

    case node
    when NodeHasFilterCondition
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

      binding_relation = extract_binding_relation(table_node)
      return unless binding_relation

      rights = node.right.is_a?(Array) ? node.right : [node.right]
      substitutes = RedisMemo::ThreadLocalVar.substitues

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
            right.attribute.name.to_sym =>
              if right.respond_to?(:val)
                right.val
              else
                # activerecord >= 6
                right.value
              end,
          }
        else
          bind_params = bind_params.union(construct_bind_params_recurse(right))
          return if !bind_params
        end
      end

      bind_params
    when Arel::Nodes::SelectStatement
      node.cores.each do |core|
        # We don't support JOINs
        return unless core.source.right.empty?

        # Should have a WHERE if directly selecting from a table
        source_node = core.source.left
        binding_relation = nil
        case source_node
        when Arel::Table
          binding_relation = extract_binding_relation(source_node)

          return if core.wheres.empty? || binding_relation.nil?
        when Arel::Nodes::TableAlias
          bind_params = bind_params.union(
            construct_bind_params_recurse(source_node.left),
          )

          return unless bind_params
        else
          return
        end

        # Binds wheres before havings
        core.wheres.each do |where|
          bind_params = bind_params.union(
            construct_bind_params_recurse(where),
          )

          return unless bind_params
        end

        core.havings.each do |having|
          bind_params = bind_params.union(
            construct_bind_params_recurse(having),
          )

          return unless bind_params
        end
      end

      bind_params
    when Arel::Nodes::Grouping
      # Inline SQL
      construct_bind_params_recurse(node.expr)
    when Arel::Nodes::LessThan, Arel::Nodes::LessThanOrEqual, Arel::Nodes::GreaterThan, Arel::Nodes::GreaterThanOrEqual, Arel::Nodes::NotEqual
      bind_params
    when Arel::Nodes::And
      node.children.each do |child|
        bind_params = bind_params.product(
          construct_bind_params_recurse(child),
        )

        return unless bind_params
      end

      bind_params
    when Arel::Nodes::Union, Arel::Nodes::Or
      [node.left, node.right].each do |child|
        bind_params = bind_params.union(
          construct_bind_params_recurse(child),
        )

        return unless bind_params
      end

      bind_params
    else
      # Not yet supported
      nil
    end
    # rubocop: enable Lint/NonLocalExitFromIterator
  end

  # Retrieve the model info from the table node
  # table node is an Arel::Table object, e.g. <Arel::Table @name="sites" ...>
  # and we can retrieve the model info by inspecting thhe table name
  # See +RedisMemo::MemoizeQuery::memoize_table_column+ for how to construct enabled_models
  #
  # @params table_node [Arel::Table]
  def self.extract_binding_relation(table_node)
    enabled_models[table_node.try(:name)]
  end

  #
  # Identify whether the node has filter condition
  #
  class NodeHasFilterCondition
    def self.===(node)
      case node
      when Arel::Nodes::Equality, Arel::Nodes::In
        true
      else
        # In activerecord >= 6, a new arel node HomogeneousIn is introduced
        if defined?(Arel::Nodes::HomogeneousIn) &&
           node.is_a?(Arel::Nodes::HomogeneousIn)
          true
        else
          false
        end
      end
    end
  end
end
