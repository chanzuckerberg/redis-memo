# frozen_string_literal: true

require 'active_support/all'
require 'digest'
require 'json'
require 'securerandom'

module RedisMemo
  require 'redis_memo/memoize_method'
  require 'redis_memo/memoize_query'

  # A process-level +RedisMemo::Options+ instance that stores the global
  # options. This object can be modified by +RedisMemo.configure+.
  #
  # +memoize_method+ allows users to provide method-level configuration.
  # When no callsite-level configuration specified we will use the values in
  # +DefaultOptions+ as the default value.
  DefaultOptions = RedisMemo::Options.new

  # @todo Move thread keys to +RedisMemo::ThreadKey+
  THREAD_KEY_WITHOUT_MEMO = :__redis_memo_without_memo__
  THREAD_KEY_CONNECTION_ATTEMPTS_COUNT = :__redis_memo_connection_attempts_count__
  THREAD_KEY_MAX_CONNECTION_ATTEMPTS = :__redis_memo_max_connection_attempts__

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

  # @todo Move this method out of the top namespace
  def self.checksum(serialized)
    Digest::SHA1.base64digest(serialized)
  end

  # @todo Move this method out of the top namespace
  def self.uuid
    SecureRandom.uuid
  end

  # @todo Move this method out of the top namespace
  def self.deep_sort_hash(orig_hash)
    {}.tap do |new_hash|
      orig_hash.sort.each do |k, v|
        new_hash[k] = v.is_a?(Hash) ? deep_sort_hash(v) : v
      end
    end
  end

  # Whether the current execution context has been configured to skip
  # memoization and use the uncached code path.
  #
  # @return [Boolean]
  def self.without_memo?
    Thread.current[THREAD_KEY_WITHOUT_MEMO] == true
  end

  # Configure the wrapped code in the block to skip memoization.
  #
  # @yield [] no_args The block of code to skip memoization.
  def self.without_memo
    prev_value = Thread.current[THREAD_KEY_WITHOUT_MEMO]
    Thread.current[THREAD_KEY_WITHOUT_MEMO] = true
    yield
  ensure
    Thread.current[THREAD_KEY_WITHOUT_MEMO] = prev_value
  end

  # Set the max connection attempts to Redis per code block. If we fail to connect to Redis more than `max_attempts`
  # times, the rest of the code block will fall back to the uncached flow, `RedisMemo.without_memo`.
  #
  # @param [Integer] The max number of connection attempts.
  # @yield [] no_args the block of code to set the max attempts for.
  def self.with_max_connection_attempts(max_attempts)
    prev_value = Thread.current[THREAD_KEY_WITHOUT_MEMO]
    if max_attempts
      Thread.current[THREAD_KEY_CONNECTION_ATTEMPTS_COUNT] = 0
      Thread.current[THREAD_KEY_MAX_CONNECTION_ATTEMPTS] = max_attempts
    end
    yield
  ensure
    Thread.current[THREAD_KEY_WITHOUT_MEMO] = prev_value
    Thread.current[THREAD_KEY_CONNECTION_ATTEMPTS_COUNT] = nil
    Thread.current[THREAD_KEY_MAX_CONNECTION_ATTEMPTS] = nil
  end

  private
  def self.incr_connection_attempts # :nodoc:
    return if Thread.current[THREAD_KEY_MAX_CONNECTION_ATTEMPTS].nil? || Thread.current[THREAD_KEY_CONNECTION_ATTEMPTS_COUNT].nil?

    # The connection attempts count and max connection attempts are reset in RedisMemo.with_max_connection_attempts
    Thread.current[THREAD_KEY_CONNECTION_ATTEMPTS_COUNT] += 1
    if Thread.current[THREAD_KEY_CONNECTION_ATTEMPTS_COUNT] >= Thread.current[THREAD_KEY_MAX_CONNECTION_ATTEMPTS]
      Thread.current[THREAD_KEY_WITHOUT_MEMO] = true
    end
  end

  # @todo Move errors to a separate file errors.rb
  class ArgumentError < ::ArgumentError; end
  class RuntimeError < ::RuntimeError; end
  class WithoutMemoization < Exception; end
end
