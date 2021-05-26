With Rails low-level caching, race conditions between cache invalidation and cache writing would lead to cache inconsistency. For example:
- Process A: Fetch from the cache, cache miss. Read user.display_name.
- Process B: Update user.display_name, then invalidate the cache.
Process A: Write the previously read user.display_name (which is now stale) to the cache. All subsequent requests would use the stale data from the cache.

### With RedisMemo
Since RedisMemo is [version-addressable](https://github.com/chanzuckerberg/redis-memo/wiki/Version-Addressable), the race condition would not happen:
- Process A: Fetch from the cache, cache miss. Read user.display_name.
- Process B: Update user.display_name, then bump the dependency version for that user.
- Process A: Write the previously read user.display_name to the cache using the old user dependency version -- it is only referenceable using the old dependency version. All subsequent requests would use the new dependency version process B has just set, data associated with the old dependency version is no longer referenceable, thus the stale data has been discarded.
