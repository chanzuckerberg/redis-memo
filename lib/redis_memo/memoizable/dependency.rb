# frozen_string_literal: true

# A Directed Acyclic Graph (DAG) of Memoizables
class RedisMemo::Memoizable::Dependency
  attr_accessor :nodes

  def initialize
    @nodes = {}
  end

  def memos
    @nodes.values
  end

  def depends_on(dependency)
    case dependency
    when self.class
      nodes.merge!(dependency.nodes)
    when RedisMemo::Memoizable
      memo = dependency
      return if nodes.include?(memo.cache_key)

      nodes[memo.cache_key] = memo

      if memo.depends_on
        # Extract dependencies from the current memoizable and recurse
        instance_exec(&memo.depends_on)
      end
    when ActiveRecord::Relation
      extracted = self.class.extract_from_relation(dependency)
      nodes.merge!(extracted.nodes)
    when RedisMemo::MemoizeQuery::CachedSelect::BindParams
      dependency.params.each do |model, attrs_set|
        memo = model.redis_memo_class_memoizable
        nodes[memo.cache_key] = memo

        attrs_set.each do |attrs|
          memo = RedisMemo::MemoizeQuery.create_memo(model, **attrs)
          nodes[memo.cache_key] = memo
        end
      end
    else
      raise RedisMemo::ArgumentError.new("Invalid dependency #{dependency}")
    end
  end

  def self.extract_from_relation(relation)
    connection = ActiveRecord::Base.connection
    unless connection.respond_to?(:dependency_of)
      raise RedisMemo::WithoutMemoization.new('Caching active record queries is currently disabled on RedisMemo')
    end

    # Extract the dependent memos of an Arel without calling exec_query to actually execute the query
    RedisMemo::MemoizeQuery::CachedSelect.with_new_query_context do
      query, binds, = connection.__send__(:to_sql_and_binds, relation.arel)
      RedisMemo::MemoizeQuery::CachedSelect.current_query = relation.arel
      is_query_cached = RedisMemo::MemoizeQuery::CachedSelect.extract_bind_params(query)

      unless is_query_cached
        raise RedisMemo::WithoutMemoization.new('Arel query is not cached using RedisMemo')
      end

      connection.dependency_of(:exec_query, query, nil, binds)
    end
  end
end
