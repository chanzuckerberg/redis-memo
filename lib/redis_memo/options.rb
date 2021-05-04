# frozen_string_literal: true

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

  def redis
    @redis_client ||= RedisMemo::Redis.new(redis_config)
  end

  def redis_config
    @redis_config || {}
  end

  def redis=(config)
    @redis_config = config
    @redis_client = nil
    redis
  end

  def tracer(&blk)
    if blk.nil?
      return @tracer if @tracer.respond_to?(:trace)

      @tracer&.call
    else
      @tracer = blk
    end
  end

  def logger(&blk)
    if blk.nil?
      return @logger if @logger.respond_to?(:warn)

      @logger&.call
    else
      @logger = blk
    end
  end

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

  def disable_model(model)
    @disabled_models << model
  end

  def model_disabled_for_caching?(model)
    ENV["REDIS_MEMO_DISABLE_#{model.table_name.upcase}"] == 'true' || @disabled_models.include?(model)
  end

  attr_accessor :async
  attr_accessor :cache_out_of_date_handler
  attr_accessor :cache_validation_sampler
  attr_accessor :compress
  attr_accessor :compress_threshold
  attr_accessor :connection_pool
  attr_accessor :expires_in
  attr_accessor :max_connection_attempts
  attr_accessor :redis_error_handler
  attr_accessor :disable_all
  attr_accessor :disable_cached_select

  attr_writer :global_cache_key_version
  attr_writer :tracer
  attr_writer :logger
end
