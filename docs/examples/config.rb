# config/initializers/redis_memo.rb
RedisMemo.configure do |config|
  # Passed along to the Rails
  # {RedisCacheStore}[https://api.rubyonrails.org/classes/ActiveSupport/Cache/RedisCacheStore.html],
  # sets the TTL on cache entries in Redis.
  config.expires_in = 3.hours

  # A global cache key version prepended to each cached entry. For example, the
  # commit hash of the current version deployed to your application.
  config.global_cache_key_version = ENV['HEROKU_SLUG_COMMIT']

  config.redis_error_handler = proc do |error, operation, extra|
    ErrorReporter.notify(error, tags: { operation: operation }, extra: extra)
  end

  # Object used to log RedisMemo operations.
  config.logger { Rails.logger }

  # Sets the tracer object. Allows the tracer to be dynamically determined at
  # runtime if a blk is given.
  config.tracer { Datadog.tracer }

  # <url>,<url>...;<url>,...;...
  redis_urls = ENV['REDIS_MEMO_REDIS_URLS']
  if redis_urls.present?
    # Set configuration values to pass to the Redis client. If multiple
    # configurations are passed to this method, we assume that the first config
    # corresponds to the primary node, and subsequent configurations correspond
    # to replica nodes.
    config.redis = redis_urls.split(';').map do |urls|
      urls.split(',').map do |url|
        {
          url: url,
          # All timeout values are specified in seconds
          connect_timeout: ENV['REDIS_MEMO_CONNECT_TIMEOUT']&.to_f || 0.2,
          read_timeout: ENV['REDIS_MEMO_READ_TIMEOUT']&.to_f || 0.5,
          write_timeout: ENV['REDIS_MEMO_WRITE_TIMEOUT']&.to_f || 0.5,
          reconnect_attempts: ENV['REDIS_MEMO_RECONNECT_ATTEMPTS']&.to_i || 0,
        }
      end
    end
  end

  if !Rails.env.test?
    thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: ENV['REDIS_MEMO_MAX_THREADS']&.to_i || 20,
      max_queue: 100,
      # If we're overwhelmed, discard the current invalidation request and
      # retry later
      fallback_policy: :discard,
      auto_terminate: false,
    )

    # A handler used to asynchronously perform cache writes and invalidations.
    # If no value is provided, RedisMemo will perform these operations
    # synchronously.
    config.async = proc do |&blk|
      # Skip async in rails console since the async logs would interfere with
      # the console outputs
      if defined?(Rails::Console)
        blk.call
      else
        thread_pool.post { blk.call }
      end
    end
  end

  unless ENV['REDIS_MEMO_CONNECTION_POOL_SIZE'].nil?
    # Configuration values for connecting to RedisMemo using a connection pool.
    # It's recommended to use a connection pool in multi-threaded applications,
    # or when an async handler is set.
    config.connection_pool = {
      size: ENV['REDIS_MEMO_CONNECTION_POOL_SIZE'].to_i,
      timeout: ENV['REDIS_MEMO_CONNECTION_POOL_TIMEOUT']&.to_i || 0.2,
    }
  end

  # Specify the global sampled percentage of the chance to call the cache
  # validation, a value between 0 to 100, when the value is 100, it will call
  # the handler every time the cached result does not match the uncached result
  # You can also specify inline cache validation sample percentage by
  # memoize_method :method, cache_validation_sample_percentage: #{value}
  config.cache_validation_sample_percentage = ENV['REDIS_MEMO_CACHE_VALIDATION_SAMPLE_PERCENTAGE']&.to_i

  # Handler called when the cached result does not match the uncached result
  # (sampled at the `cache_validation_sample_percentage`). This might indicate
  # that invalidation is happening too slowly or that there are incorrect
  # dependencies specified on a cached method.
  config.cache_out_of_date_handler = proc do |ref, method_id, args, cached_result, fresh_result|
    ErrorReporter.notify(
      "Cache does not match its current value: #{method_id}",
      tags: { method_id: method_id },
      extra: {
        self: ref.to_s,
        args: args,
        cached_result: cached_result,
        fresh_result: fresh_result,
      },
    )
  end
end
