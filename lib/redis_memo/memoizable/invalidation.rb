# typed: false

module RedisMemo::Memoizable::Invalidation
  # This is a thread safe data structure
  #
  # Handle transient network errors during cache invalidation
  # Each item in the queue is a tuple:
  #
  #   [key, version (a UUID), previous_version (a UUID)]
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

  def self.bump_version_later(key, version, previous_version: nil)
    RedisMemo::DefaultOptions.logger&.info("[received] Bump memo key #{key}")

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
      previous_version ||= RedisMemo::Cache.read_multi(key)[key]
    end

    local_cache&.send(:[]=, key, version)
    if RedisMemo::AfterCommit.in_transaction?
      RedisMemo::AfterCommit.bump_memo_version_after_commit(
        key,
        version,
        previous_version: previous_version,
      )
    else
      @@invalidation_queue << [key, version, previous_version]
    end
  end

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

  LUA_BUMP_VERSION = <<~LUA
    local key = KEYS[1]
    local expected_prev_version,
          desired_new_version,
          version_on_mismatch,
          ttl = unpack(ARGV)

    local actual_prev_version = redis.call('get', key)
    local new_version = version_on_mismatch
    local px = {}

    if (not actual_prev_version and expected_prev_version == '') or expected_prev_version == actual_prev_version then
      new_version = desired_new_version
    end

    if ttl ~= '' then
      px = {'px', ttl}
    end

    return redis.call('set', key, new_version, unpack(px))
  LUA

  def self.bump_version(cache_key, version, previous_version:)
    RedisMemo::Tracer.trace('redis_memo.memoizable.bump_version', nil) do
      ttl = RedisMemo::DefaultOptions.expires_in
      ttl = (ttl * 1000.0).to_i if ttl
      RedisMemo::Cache.redis.eval(
        LUA_BUMP_VERSION,
        keys: [cache_key],
        argv: [previous_version, version, SecureRandom.uuid, ttl],
      )
    end
    RedisMemo::DefaultOptions.logger&.info("[performed] Bump memo key #{cache_key}")
  end

  def self.drain_invalidation_queue_now
    retry_queue = []
    until @@invalidation_queue.empty?
      tuple = @@invalidation_queue.pop
      begin
        bump_version(tuple[0], tuple[1], previous_version: tuple[2])
      rescue SignalException, Redis::BaseConnectionError
        retry_queue << tuple
      end
    end
  ensure
    retry_queue.each { |t| @@invalidation_queue << t }
  end

  at_exit do
    # The best effort
    drain_invalidation_queue_now
  end
end
