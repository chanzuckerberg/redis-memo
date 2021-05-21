# frozen_string_literal: true

##
# This class allows users to configure various RedisMemo options. Options can be set in
# your initializer +config/initializers/redis_memo.rb+
#   RedisMemo.configure do |config|
#     config.expires_in = 3.hours
#     config.global_cache_key_version = SecureRandom.uuid
#   end
#
class RedisMemo::Options
  def initialize(
    async: nil,
    compress: nil,
    compress_threshold: nil,
    redis: nil,
    redis_error_handler: nil,
    tracer: nil,
    global_cache_key_version: nil,
    expires_in: nil,
    max_connection_attempts: nil,
    disable_all: false,
    disable_cached_select: false,
    disabled_models: Set.new
  )
    @async = async
    @compress = compress.nil? ? true : compress
    @compress_threshold = compress_threshold || 1.kilobyte
    @redis_config = redis
    @redis_client = nil
    @redis_error_handler = redis_error_handler
    @tracer = tracer
    @logger = logger
    @global_cache_key_version = global_cache_key_version
    @expires_in = expires_in
    @max_connection_attempts = ENV['REDIS_MEMO_MAX_ATTEMPTS_PER_REQUEST']&.to_i || max_connection_attempts
    @disable_all = ENV['REDIS_MEMO_DISABLE_ALL'] == 'true' || disable_all
    @disable_cached_select = ENV['REDIS_MEMO_DISABLE_CACHED_SELECT'] == 'true' || disable_cached_select
    @disabled_models = disabled_models
  end

  # Retrieves the redis client, initializing it if it does not exist yet.
  def redis
    @redis_client ||= RedisMemo::Redis.new(redis_config)
  end

  # Retrieves the config values used to initialize the Redis client.
  def redis_config
    @redis_config || {}
  end

  # Set configuration values to pass to the Redis client. If multiple configurations are passed
  # to this method, we assume that the first config corresponds to the primary node, and subsequent
  # configurations correspond to replica nodes.
  #
  # For example, if your urls are specified as <tt><url>,<url>...;<url>,...;...,</tt> where <tt>;</tt> delimits
  # different clusters and <tt>,</tt> delimits primary and read replicas, then in your configuration:
  #
  #   RedisMemo.configure do |config|
  #     config.redis = redis_urls.split(';').map do |urls|
  #       urls.split(',').map do |url|
  #         {
  #           url: url,
  #           # All timeout values are specified in seconds
  #           connect_timeout: ENV['REDIS_MEMO_CONNECT_TIMEOUT']&.to_f || 0.2,
  #           read_timeout: ENV['REDIS_MEMO_READ_TIMEOUT']&.to_f || 0.5,
  #           write_timeout: ENV['REDIS_MEMO_WRITE_TIMEOUT']&.to_f || 0.5,
  #           reconnect_attempts: ENV['REDIS_MEMO_RECONNECT_ATTEMPTS']&.to_i || 0
  #         }
  #       end
  #     end
  #   end
  #
  def redis=(config)
    @redis_config = config
    @redis_client = nil
    redis
  end

  # Sets the tracer object. Allows the tracer to be dynamically determined at
  # runtime if a blk is given.
  def tracer(&blk)
    if blk.nil?
      return @tracer if @tracer.respond_to?(:trace)

      @tracer&.call
    else
      @tracer = blk
    end
  end

  # Sets the logger object in RedisMemo. Allows the logger to be dynamically
  # determined at runtime if a blk is given.
  def logger(&blk)
    if blk.nil?
      return @logger if @logger.respond_to?(:warn)

      @logger&.call
    else
      @logger = blk
    end
  end

  # Sets the global cache key version. Allows the logger to be dynamically
  # determined at runtime if a blk is given.
  def global_cache_key_version(&blk)
    # this method takes a block to be consistent with the inline memo_method
    # API
    if blk.nil?
      if !@global_cache_key_version.respond_to?(:call)
        return @global_cache_key_version
      end

      @global_cache_key_version&.call
    else
      # save the global cache_key_version eagerly
      @global_cache_key_version = blk
    end
  end

  # Disables the model for caching and invalidation
  def disable_model(model)
    @disabled_models << model
  end

  # Checks if a model is disabled for redis memo caching
  def model_disabled_for_caching?(model)
    ENV["REDIS_MEMO_DISABLE_#{model.table_name.upcase}"] == 'true' || @disabled_models.include?(model)
  end

  # A handler used to asynchronously perform cache writes and invalidations. If no value is provided,
  # RedisMemo will perform these operations synchronously.
  attr_accessor :async

  # Handler called when the cached result does not match the uncached result (sampled at the
  # `cache_validation_sample_rate`). This might indicate that invalidation is happening too slowly or
  # that there are incorrect dependencies specified on a cached method.
  attr_accessor :cache_out_of_date_handler

  # TODO: Remove and replace with cache_validation_sample_rate
  attr_accessor :cache_validation_sampler

  # Passed along to the Rails {RedisCacheStore}[https://api.rubyonrails.org/classes/ActiveSupport/Cache/RedisCacheStore.html], determines whether or not to compress entries before storing
  # them. default: `true`
  attr_accessor :compress

  # Passed along to the Rails {RedisCacheStore}[https://api.rubyonrails.org/classes/ActiveSupport/Cache/RedisCacheStore.html], the size threshold for which to compress cached entries.
  # default: 1.kilobyte
  attr_accessor :compress_threshold

  # Configuration values for connecting to RedisMemo using a connection pool. It's recommended to use a
  # connection pool in multi-threaded applications, or when an async handler is set.
  attr_accessor :connection_pool

  # Passed along to the Rails {RedisCacheStore}[https://api.rubyonrails.org/classes/ActiveSupport/Cache/RedisCacheStore.html], sets the TTL on cache entries in Redis.
  attr_accessor :expires_in

  # The max number of failed connection attempts RedisMemo will make for a single request before bypassing
  # the caching layer. This helps make RedisMemo resilient to errors and performance issues when there's
  # an issue with the Redis cluster itself.
  attr_accessor :max_connection_attempts

  # Passed along to the Rails {RedisCacheStore}[https://api.rubyonrails.org/classes/ActiveSupport/Cache/RedisCacheStore.html], the error handler called for Redis related errors.
  attr_accessor :redis_error_handler

  # A global kill switch to disable all RedisMemo operations.
  attr_accessor :disable_all

  # A kill switch to disable RedisMemo caching on database queries. This does not disable the invalidation
  # after_save hooks that are installed on memoized models.
  attr_accessor :disable_cached_select

  # A kill switch to set the list of models to disable caching and invalidation after_save hooks on.
  attr_accessor :disabled_models

  # A global cache key version prepended to each cached entry. For example, the commit hash of the current
  # version deployed to your application.
  attr_writer :global_cache_key_version

  # Object used to trace RedisMemo operations to collect latency and error metrics, e.g. `Datadog.tracer`
  attr_writer :tracer

  # Object used to log RedisMemo operations.
  attr_writer :logger
end
