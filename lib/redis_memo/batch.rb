# frozen_string_literal: true

require_relative 'cache'
require_relative 'tracer'

##
# This class facilitates the batching of Redis calls triggered by +memoize_method+
# to minimize the number of round trips to Redis.
#
# - Batches cannot be nested
# - When a batch is still open (while still in the +RedisMemo.batch+ block)
#   the return value of any memoized method is a +RedisMemo::Future+ instead of
#   the actual method value
# - The actual method values are returned as a list, in the same order as
#   invoking, after exiting the block
#
# @example
#   results = RedisMemo.batch do
#     5.times { |i| memoized_calculation(i) }
#     nil # Not the return value of the block
#   end
#   results # [1,2,3,4,5] (results from the memoized_calculation calls)
class RedisMemo::Batch
  RedisMemo::ThreadLocalVar.define :batch

  # Opens a new batch. If a batch is already open, raises an error
  # to prevent nested batches.
  def self.open
    if current
      raise RedisMemo::RuntimeError.new('Batch can not be nested')
    end

    RedisMemo::ThreadLocalVar.batch = []
  end

  # Closes the current batch, returning the futures in that batch.
  def self.close
    return unless current

    futures = current
    RedisMemo::ThreadLocalVar.batch = nil
    futures
  end

  # Retrieves the current open batch.
  def self.current
    RedisMemo::ThreadLocalVar.batch
  end

  # Executes all the futures in the current batch using batched calls to
  # Redis and closes it.
  def self.execute
    futures = close
    return unless futures

    cached_results = {}
    method_cache_keys = nil

    RedisMemo::Tracer.trace('redis_memo.cache.batch.read', nil) do
      method_cache_keys = RedisMemo::MemoizeMethod.__send__(
        :method_cache_keys,
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
