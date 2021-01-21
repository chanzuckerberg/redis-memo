# typed: fals
class RedisMemo::Batch
  THREAD_KEY = :__redis_memo_current_batch__

  def self.open
    if current
      raise RedisMemo::RuntimeError, 'Batch can not be nested'
    end

    Thread.current[THREAD_KEY] = []
  end

  def self.close
    if current
      futures = current
      Thread.current[THREAD_KEY] = nil
      futures
    end
  end

  def self.current
    Thread.current[THREAD_KEY]
  end

  def self.execute
    futures = close
    return unless futures

    cached_results = {}
    method_cache_keys = nil

    RedisMemo::Tracer.trace('redis_memo.cache.batch.read', nil) do
      method_cache_keys = RedisMemo::MemoizeMethod.method_cache_keys(
        futures.map(&:context),
      )

      if method_cache_keys
        cached_results = RedisMemo::Cache.read_multi(*method_cache_keys)
      end
    end

    RedisMemo::Tracer.trace('redis_memo.cache.batch.execute', nil) do
      results = Array.new(futures.size)
      futures.each_with_index do |future, i|
        future.method_cache_key = method_cache_keys ? method_cache_keys[i] : ''
        results[i] = future.execute(cached_results)
      end
      results
    end
  end
end
