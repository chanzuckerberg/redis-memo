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

  def depends_on(dependency, **conditions)
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
      extracted = extract_dependencies_for_relation(dependency)
      nodes.merge!(extracted.nodes)
    when UsingActiveRecord
      [
        dependency.redis_memo_class_memoizable,
        RedisMemo::MemoizeQuery.create_memo(dependency, **conditions),
      ].each do |memo|
        nodes[memo.cache_key] = memo
      end
    else
      raise(
        RedisMemo::ArgumentError,
        "Invalid dependency #{dependency}"
      )
    end
  end

  def extract_dependencies_for_relation(relation)
    # Extract the dependent memos of an Arel without calling exec_query to actually execute the query
    RedisMemo::MemoizeQuery::CachedSelect.with_new_query_context do
      connection = ActiveRecord::Base.connection
      query, binds, _ = connection.send(:to_sql_and_binds, relation.arel)
      RedisMemo::MemoizeQuery::CachedSelect.current_query = relation.arel
      is_query_cached = RedisMemo::MemoizeQuery::CachedSelect.extract_bind_params(query)
        raise(
          RedisMemo::ArgumentError,
          "Invalid Arel dependency. Query is not enabled for RedisMemo caching."
        ) unless is_query_cached
        extracted_dependency = connection.dependency_of(:exec_query, query, nil, binds)
    end
  end

  class UsingActiveRecord
    def self.===(dependency)
      RedisMemo::MemoizeQuery.using_active_record?(dependency)
    end
  end
end
