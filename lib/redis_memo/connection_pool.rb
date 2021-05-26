# frozen_string_literal: true

require 'connection_pool'
require_relative 'redis'

class RedisMemo::ConnectionPool
  def initialize(**options)
    @connection_pool = ::ConnectionPool.new(**options) do
      # Construct a new client every time the block gets called
      RedisMemo::Redis.new(RedisMemo::DefaultOptions.redis_config)
    end
  end

  # Avoid method_missing when possible for better performance
  %i[get mget mapped_mget set eval evalsha run_script].each do |method_name|
    define_method method_name do |*args, &blk|
      @connection_pool.with do |redis|
        redis.__send__(method_name, *args, &blk)
      end
    end
  end

  def method_missing(method_name, *args, &blk)
    @connection_pool.with do |redis|
      redis.__send__(method_name, *args, &blk)
    end
  end
end
