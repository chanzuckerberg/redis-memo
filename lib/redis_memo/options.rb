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
    expires_in: nil
  )
    @compress = compress.nil? ? true : compress
    @compress_threshold = compress_threshold || 1.kilobyte
    @redis = redis
    @redis_client = nil
    @redis_error_handler = redis_error_handler
    @tracer = tracer
    @logger = logger
    @global_cache_key_version = global_cache_key_version
    @expires_in = expires_in
  end

  def redis(&blk)
    if blk.nil?
      return @redis_client if @redis_client.is_a?(RedisMemo::Redis)

      if @redis.respond_to?(:call)
        @redis_client = RedisMemo::Redis.new(@redis.call)
      elsif @redis
        @redis_client = RedisMemo::Redis.new(@redis)
      else
        @redis_client = RedisMemo::Redis.new
      end
    else
      @redis = blk
    end
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

  attr_accessor :async
  attr_accessor :bulk_operations_invalidation_limit
  attr_accessor :cache_out_of_date_handler
  attr_accessor :cache_validation_sampler
  attr_accessor :compress
  attr_accessor :compress_threshold
  attr_accessor :connection_pool
  attr_accessor :expires_in
  attr_accessor :redis_error_handler

  attr_writer :global_cache_key_version
  attr_writer :redis
  attr_writer :tracer
  attr_writer :logger
end
