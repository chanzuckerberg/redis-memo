# frozen_string_literal: true
require 'redis'
require 'redis/distributed'

require_relative 'options'

# Redis::Distributed does not support reading from multiple read replicas. This
# class adds this functionality
class RedisMemo::Redis < Redis::Distributed
  def initialize(options={})
    clients =
      if options.is_a?(Array)
        options.map do |option|
          if option.is_a?(Array)
            RedisMemo::Redis::WithReplicas.new(option)
          else
            option[:logger] ||= RedisMemo::DefaultOptions.logger
            ::Redis.new(option)
          end
        end
      else
        options[:logger] ||= RedisMemo::DefaultOptions.logger
        [::Redis.new(options)]
      end

    # Pass in our own hash ring to use the clients with multi-read-replica
    # support
    hash_ring = Redis::HashRing.new(clients)

    super([], ring: hash_ring)
  end

  class WithReplicas < ::Redis
    def initialize(options)
      primary_option = options.shift
      @replicas = options.map do |option|
        option[:logger] ||= RedisMemo::DefaultOptions.logger
        ::Redis.new(option)
      end

      primary_option[:logger] ||= RedisMemo::DefaultOptions.logger
      super(primary_option)
    end

    alias_method :get_primary, :get
    alias_method :mget_primary, :mget
    alias_method :mapped_mget_primary, :mapped_mget

    def get(key)
      return get_primary(key) if @replicas.empty?

      @replicas.sample(1).first.get(key)
    end

    def mget(*keys, &blk)
      return mget_primary(*keys, &blk) if @replicas.empty?

      @replicas.sample(1).first.mget(*keys)
    end

    def mapped_mget(*keys)
      return mapped_mget_primary(*keys) if @replicas.empty?

      @replicas.sample(1).first.mapped_mget(*keys)
    end
  end
end
