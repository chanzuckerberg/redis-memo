# frozen_string_literal: true

class RedisMemo::MemoizeQuery::CachedSelect
  module ConnectionAdapter
    def cacheable_query(*args)
      query, binds = super(*args)

      # Persist the arel object to StatementCache#execute
      query.instance_variable_set(:@__redis_memo_memoize_query_memoize_query_arel, args.last)

      [query, binds]
    end

    def exec_query(*args)
      # An Arel AST in Thread local is set prior to supported query methods
      if !RedisMemo.without_memo? &&
          RedisMemo::MemoizeQuery::CachedSelect.extract_bind_params(args[0])
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
        RedisMemo::MemoizeQuery::CachedSelect.current_query = args[0]
      end

      super(*args)
    ensure
      RedisMemo::MemoizeQuery::CachedSelect.reset_current_query
    end
  end
end
