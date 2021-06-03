# config/initializers/redis_memo.rb
RedisMemo.configure do |config|
  # Static references: Those references are fixed when booting the app
  config.expires_in = 3.hours

  # On non-heroku environments, clear the cache when starting a new Rails
  # server process
  config.global_cache_key_version = ENV['HEROKU_SLUG_COMMIT']

  config.redis_error_handler = proc do |error, operation, extra|
    ErrorReporter.notify(error, tags: { operation: operation }, extra: extra)
  end

  config.logger { Rails.logger }

  config.tracer { Datadog.tracer }

  # <url>,<url>...;<url>,...;...
  redis_urls = ENV['REDIS_MEMO_REDIS_URLS']
  if redis_urls.present?
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
    config.connection_pool = {
      size: ENV['REDIS_MEMO_CONNECTION_POOL_SIZE'].to_i,
      timeout: ENV['REDIS_MEMO_CONNECTION_POOL_TIMEOUT']&.to_i || 0.2,
    }
  end

  config.cache_validation_sample_percentage = ENV['REDIS_MEMO_CACHE_VALIDATION_SAMPLE_PERCENTAGE']&.to_i
  config.cache_out_of_date_handler = proc do |ref, method_id, args, cached_result, fresh_result|
    ErrorReporter.notify(
      # There might be a cache invalidation bug if this fires a lot
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
