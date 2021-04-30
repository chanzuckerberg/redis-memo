# frozen_string_literal: true

require 'active_support/all'
require 'digest'
require 'json'
require 'securerandom'

module RedisMemo
  require 'redis_memo/thread_local_var'

  ThreadLocalVar.define :without_memo
  ThreadLocalVar.define :connection_attempts_count
  ThreadLocalVar.define :max_connection_attempts

  require 'redis_memo/errors'
  require 'redis_memo/memoize_method'
  require 'redis_memo/memoize_query' if defined?(ActiveRecord)
  require 'redis_memo/railtie' if defined?(Rails) && defined?(Rails::Railtie)

  # A process-level +RedisMemo::Options+ instance that stores the global
  # options. This object can be modified by +RedisMemo.configure+.
  #
  # +memoize_method+ allows users to provide method-level configuration.
  # When no callsite-level configuration specified we will use the values in
  # +DefaultOptions+ as the default value.
  DefaultOptions = RedisMemo::Options.new

  # Configure global-level default options. Those options will be used unless
  # some options specified at +memoize_method+ callsite level. See
  # +RedisMemo::Options+ for all the possible options.
  #
  # @yieldparam [RedisMemo::Options] default_options
  # +RedisMemo::DefaultOptions+
  # @return [void]
  def self.configure(&blk)
    blk.call(DefaultOptions)
  end

  # Batch Redis calls triggered by +memoize_method+ to minimize the round trips
  # to Redis.
  # - Batches cannot be nested
  # - When a batch is still open (while still in the +RedisMemo.batch+ block)
  # the return value of any memoized method is a +RedisMemo::Future+ instead of
  # the actual method value
  # - The actual method values are returned as a list, in the same order as
  # invoking, after exiting the block
  #
  # @example
  #   results = RedisMemo.batch do
  #     5.times { |i| memoized_calculation(i) }
  #     nil # Not the return value of the block
  #   end
  #   results.size == 5 # true
  #
  # See +RedisMemo::Batch+ for more information.
  def self.batch(&blk)
    RedisMemo::Batch.open
    blk.call
    RedisMemo::Batch.execute
  ensure
    RedisMemo::Batch.close
  end

  # Whether the current execution context has been configured to skip
  # memoization and use the uncached code path.
  #
  # @return [Boolean]
  def self.without_memo?
    RedisMemo::DefaultOptions.disable_all || ThreadLocalVar.without_memo == true
  end

  # Configure the wrapped code in the block to skip memoization.
  #
  # @yield [] no_args The block of code to skip memoization.
  def self.without_memo
    prev_value = ThreadLocalVar.without_memo
    ThreadLocalVar.without_memo = true
    yield
  ensure
    ThreadLocalVar.without_memo = prev_value
  end

  # Set the max connection attempts to Redis per code block. If we fail to
  # connect to Redis more than `max_attempts` times, the rest of the code block
  # will fall back to the uncached flow, `RedisMemo.without_memo`.
  #
  # @param [Integer] The max number of connection attempts.
  # @yield [] no_args the block of code to set the max attempts for.
  def self.with_max_connection_attempts(max_attempts)
    prev_value = ThreadLocalVar.without_memo
    ThreadLocalVar.connection_attempts_count = 0
    ThreadLocalVar.max_connection_attempts = max_attempts

    yield
  ensure
    ThreadLocalVar.without_memo = prev_value
    ThreadLocalVar.connection_attempts_count = nil
    ThreadLocalVar.max_connection_attempts = nil
  end

  private_class_method def self.incr_connection_attempts # :nodoc:
    return unless ThreadLocalVar.max_connection_attempts && ThreadLocalVar.connection_attempts_count

    # The connection attempts count and max connection attempts are reset in
    # RedisMemo.with_max_connection_attempts
    ThreadLocalVar.connection_attempts_count += 1
    if ThreadLocalVar.connection_attempts_count >= ThreadLocalVar.max_connection_attempts
      ThreadLocalVar.without_memo = true
    end
  end
end
