 # frozen_string_literal: true
require_relative 'options'
require_relative 'redis'
require_relative 'connection_pool'

class RedisMemo::Cache < ActiveSupport::Cache::RedisCacheStore
  class Rescuable < Exception; end

  THREAD_KEY_LOCAL_CACHE            = :__redis_memo_cache_local_cache__
  THREAD_KEY_LOCAL_DEPENDENCY_CACHE = :__redis_memo_local_cache_dependency_cache__
  THREAD_KEY_RAISE_ERROR            = :__redis_memo_cache_raise_error__

  @@redis = nil
  @@redis_store = nil

  @@redis_store_error_handler = proc do |method:, exception:, returning:|
    RedisMemo::DefaultOptions.redis_error_handler&.call(exception, method)
    RedisMemo::DefaultOptions.logger&.warn(exception.full_message)

    if Thread.current[THREAD_KEY_RAISE_ERROR]
      raise RedisMemo::Cache::Rescuable
    else
      returning
    end
  end

  def self.redis
    @@redis ||=
      if RedisMemo::DefaultOptions.connection_pool
        RedisMemo::ConnectionPool.new(**RedisMemo::DefaultOptions.connection_pool)
      else
        RedisMemo::DefaultOptions.redis
      end
  end

  def self.redis_store
    @@redis_store ||= new(
      compress: RedisMemo::DefaultOptions.compress,
      compress_threshold: RedisMemo::DefaultOptions.compress_threshold,
      error_handler: @@redis_store_error_handler,
      expires_in: RedisMemo::DefaultOptions.expires_in,
      redis: redis,
    )
  end

  # We use our own local_cache instead of the one from RedisCacheStore, because
  # the local_cache in RedisCacheStore stores a dumped
  # ActiveSupport::Cache::Entry object -- which is slower comparing to a simple
  # hash storing object references
  def self.local_cache
    Thread.current[THREAD_KEY_LOCAL_CACHE]
  end

  def self.local_dependency_cache
    Thread.current[THREAD_KEY_LOCAL_DEPENDENCY_CACHE]
  end

  class << self
    def with_local_cache(&blk)
      Thread.current[THREAD_KEY_LOCAL_CACHE] = {}
      Thread.current[THREAD_KEY_LOCAL_DEPENDENCY_CACHE] = {}
      blk.call
    ensure
      Thread.current[THREAD_KEY_LOCAL_CACHE] = nil
      Thread.current[THREAD_KEY_LOCAL_DEPENDENCY_CACHE] = nil
    end

    # RedisCacheStore doesn't read from the local cache before reading from redis
    def read_multi(*keys, raw: false, raise_error: false)
      return {} if keys.empty?

      Thread.current[THREAD_KEY_RAISE_ERROR] = raise_error

      local_entries = local_cache&.slice(*keys) || {}

      keys_to_fetch = keys
      keys_to_fetch -= local_entries.keys unless local_entries.empty?
      return local_entries if keys_to_fetch.empty?

      remote_entries = redis_store.read_multi(*keys_to_fetch, raw: raw)
      local_cache&.merge!(remote_entries)

      if local_entries.empty?
        remote_entries
      else
        local_entries.merge!(remote_entries)
      end
    end

    def write(key, value, disable_async: false, raise_error: false, **options)
      Thread.current[THREAD_KEY_RAISE_ERROR] = raise_error

      if local_cache
        local_cache[key] = value
      end

      async = RedisMemo::DefaultOptions.async
      if async.nil? || disable_async
        redis_store.write(key, value, **options)
      else
        async.call do
          Thread.current[THREAD_KEY_RAISE_ERROR] = raise_error
          redis_store.write(key, value, **options)
        end
      end
    end
  end
end
