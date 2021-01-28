# frozen_string_literal: true

class RedisMemo::MemoizeQuery::CachedSelect
  module StatementCache
    def execute(*args)
      arel = query_builder.instance_variable_get(:@__redis_memo_memoize_query_memoize_query_arel)
      RedisMemo::MemoizeQuery::CachedSelect.current_query = arel
      RedisMemo::MemoizeQuery::CachedSelect.current_substitutes =
        bind_map.map_substitutes(args[0])

      super(*args)
    ensure
      RedisMemo::MemoizeQuery::CachedSelect.reset_current_query
    end
  end
end
