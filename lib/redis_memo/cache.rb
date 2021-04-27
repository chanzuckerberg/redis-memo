 # frozen_string_literal: true
require_relative 'options'
require_relative 'redis'
require_relative 'connection_pool'

class RedisMemo::Cache < ActiveSupport::Cache::RedisCacheStore
  class Rescuable < Exception; end

  RedisMemo::ThreadLocalVar.define :local_cache
  RedisMemo::ThreadLocalVar.define :local_dependency_cache
  RedisMemo::ThreadLocalVar.define :raise_error

  @@redis = nil
  @@redis_store = nil

  @@redis_store_error_handler = proc do |method:, exception:, returning:|
    RedisMemo::DefaultOptions.redis_error_handler&.call(exception, method)
    RedisMemo::DefaultOptions.logger&.warn(exception.full_message)

    RedisMemo.send(:incr_connection_attempts) if exception.is_a?(Redis::BaseConnectionError)

    if RedisMemo::ThreadLocalVar.raise_error
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
    RedisMemo::ThreadLocalVar.local_cache
  end

  def self.local_dependency_cache
    RedisMemo::ThreadLocalVar.local_dependency_cache
  end

  # See https://github.com/rails/rails/blob/fe76a95b0d252a2d7c25e69498b720c96b243ea2/activesupport/lib/active_support/cache/redis_cache_store.rb#L477
  # We overwrite this private method so we can also rescue ConnectionPool::TimeoutErrors
  def failsafe(method, returning: nil)
    yield
  rescue ::Redis::BaseError, ::ConnectionPool::TimeoutError => e
    handle_exception exception: e, method: method, returning: returning
    returning
  end
  private :failsafe

  class << self
    def with_local_cache(&blk)
      RedisMemo::ThreadLocalVar.local_cache = {}
      RedisMemo::ThreadLocalVar.local_dependency_cache = {}
      blk.call
    ensure
      RedisMemo::ThreadLocalVar.local_cache = nil
      RedisMemo::ThreadLocalVar.local_dependency_cache = nil
    end

    # RedisCacheStore doesn't read from the local cache before reading from redis
    def read_multi(*keys, raw: false, raise_error: false)
      return {} if keys.empty?

      RedisMemo::ThreadLocalVar.raise_error = raise_error

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
      RedisMemo::ThreadLocalVar.raise_error = raise_error

      if local_cache
        local_cache[key] = value
      end

      async = RedisMemo::DefaultOptions.async
      if async.nil? || disable_async
        redis_store.write(key, value, **options)
      else
        async.call do
          RedisMemo::ThreadLocalVar.raise_error = raise_error
          redis_store.write(key, value, **options)
        end
      end
    end
  end
end
