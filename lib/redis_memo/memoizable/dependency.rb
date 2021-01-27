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

  def depends_on(memo_or_model, **conditions)
    if !memo_or_model.is_a?(RedisMemo::Memoizable)
      [
        memo_or_model.redis_memo_class_memoizable,
        RedisMemo::MemoizeQuery.create_memo(memo_or_model, **conditions),
      ].each do |memo|
        nodes[memo.cache_key] = memo
      end

      return
    end

    memo = memo_or_model
    return if nodes.include?(memo.cache_key)
    nodes[memo.cache_key] = memo

    if memo.depends_on
      # Extract dependencies from the current memoizable and recurse
      instance_exec(&memo.depends_on)
    end
  end
end
