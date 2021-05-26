# frozen_string_literal: true

require 'digest'
require_relative '../after_commit'
require_relative '../cache'

# Module containing the logic to perform invalidation on +RedisMemo::Memoizable+s.
module RedisMemo::Memoizable::Invalidation
  class Task
    attr_reader :key
    attr_reader :version
    attr_reader :previous_version

    def initialize(key, version, previous_version)
      @key = key
      @version = version
      @previous_version = previous_version
      @created_at = current_timestamp
    end

    def current_timestamp
      Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    end

    def duration
      current_timestamp - @created_at
    end
  end

  # This is a thread safe data structure to handle transient network errors
  # during cache invalidation
  #
  # When an invalidation call arrives at Redis, we only bump to the specified
  # version (so the cached results using that version will become visible) if
  # the actual and expected previous_version on Redis match, to ensure eventual
  # consistency: If the versions mismatch, we will use a new version that has
  # not been associated with any cached_results.
  #
  #   - No invalid cached results will be read
  #
  #   - New memoized calculations will write back the fresh_results using the
  #     new version as part of their checksums.
  #
  # Note: Cached data is not guaranteed to be consistent by design. Between the
  # moment we should invalidate a version and the moment we actually
  # invalidated a version, we would serve out-dated cached results, as if the
  # operations that triggered the invalidation has not yet happened.
  @@invalidation_queue = Queue.new

  # Drains the invalidation queue by bumping the versions of all memoizable cache
  # keys currently in the queue. Performs invalidation asynchronously if an async
  # handler is configured; otherwise, invaidation is done synchronously.
  def self.drain_invalidation_queue
    async_handler = RedisMemo::DefaultOptions.async
    if async_handler.nil?
      drain_invalidation_queue_now
    else
      async_handler.call do
        drain_invalidation_queue_now
      end
    end
  end

  LUA_BUMP_VERSION = File.read(
    File.join(File.dirname(__FILE__), 'bump_version.lua'),
  )
  private_constant :LUA_BUMP_VERSION

  # Drains the invalidation queue synchronously by bumping the versions of all
  # memoizable cache keys currently in the queue. If invalidation on a cache key
  # fails due to transient Redis errors, the key is put back into the invalidation
  # queue and retried on the next invalidation queue drain.
  def self.drain_invalidation_queue_now
    retry_queue = []
    until @@invalidation_queue.empty?
      task = @@invalidation_queue.pop
      begin
        bump_version(task)
      rescue SignalException, Redis::BaseConnectionError,
             ::ConnectionPool::TimeoutError => error

        RedisMemo::DefaultOptions.redis_error_handler&.call(error, __method__)
        RedisMemo::DefaultOptions.logger&.warn(error.full_message)
        retry_queue << task
      end
    end
  ensure
    retry_queue.each { |t| @@invalidation_queue << t }
  end

  at_exit do
    # The best effort
    drain_invalidation_queue_now
  end

  class << self
    private

    def bump_version_later(key, version, previous_version: nil)
      if RedisMemo::AfterCommit.in_transaction?
        previous_version ||= RedisMemo::AfterCommit.pending_memo_versions[key]
      end

      local_cache = RedisMemo::Cache.local_cache
      if previous_version.nil? && local_cache&.include?(key)
        previous_version = local_cache[key]
      elsif RedisMemo::AfterCommit.in_transaction?
        # Fill an expected previous version so the later calculation results
        # based on this version can still be rolled out if this version
        # does not change
        previous_version ||= RedisMemo::Cache.read_multi(
          key,
          raw: true,
        )[key]
      end

      local_cache&.__send__(:[]=, key, version)
      if RedisMemo::AfterCommit.in_transaction?
        RedisMemo::AfterCommit.bump_memo_version_after_commit(
          key,
          version,
          previous_version: previous_version,
        )
      else
        @@invalidation_queue << Task.new(key, version, previous_version)
      end
    end

    def bump_version(task)
      RedisMemo::Tracer.trace('redis_memo.memoizable.bump_version', task.key) do
        ttl = RedisMemo::DefaultOptions.expires_in
        ttl = (ttl * 1000.0).to_i if ttl
        @@bump_version_sha ||= Digest::SHA1.hexdigest(LUA_BUMP_VERSION)
        RedisMemo::Cache.redis.run_script(
          LUA_BUMP_VERSION,
          @@bump_version_sha,
          keys: [task.key],
          argv: [task.previous_version, task.version, RedisMemo::Util.uuid, ttl],
        )
        RedisMemo::Tracer.set_tag(enqueue_to_finish: task.duration)
      end
    end
  end
end
