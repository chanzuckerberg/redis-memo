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
    case
    when dependency.is_a?(self.class)
      nodes.merge!(dependency.nodes)
    when dependency.is_a?(RedisMemo::Memoizable)
      memo = dependency
      return if nodes.include?(memo.cache_key)
      nodes[memo.cache_key] = memo

      if memo.depends_on
        # Extract dependencies from the current memoizable and recurse
        instance_exec(&memo.depends_on)
      end
    when RedisMemo::MemoizeQuery.using_active_record?(dependency)
      [
        dependency.redis_memo_class_memoizable,
        RedisMemo::MemoizeQuery.create_memo(dependency, **conditions),
      ].each do |memo|
        nodes[memo.cache_key] = memo
      end
    else
      raise(
        RedisMemo::ArgumentError,
        "Invalid dependency type #{dependency.class}"
      )
    end
  end
end