--[[
Script to bump the version of a memoizable's cache key.

RedisMemo can be used safely within transactions because it implements multi
version concurrency control (MVCC).

Before bumping dependency versions, RedisMemo will save its current version
prior to the update. While bumping the version on Redis, RedisMemo would check
if the current version still matches the expectation (in a Lua script to ensure atomicity).
If not, we would use a different version that has not been used before, thus
we have automatically invalidated the records that are being updated by overlapping
transactions.

Note: When Redis memory is full, bumping versions only works on Redis versions 6.x.
Prior versions of Redis have a bug in Lua where an OOM error is thrown instead of
eviction when Redis memory is full https://github.com/redis/redis/issues/6565

--   KEYS = cache_key
--   ARGV = [expected_prev_version desired_new_version version_on_mismatch ttl]
--]]
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
