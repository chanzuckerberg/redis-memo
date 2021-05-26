RedisMemo has built-in support for monitoring services such as [Datadog](https://www.datadoghq.com/). One could set up alerts on some monitoring metrics (such as overall cache-hit rate) to take action proactively.

## Available Metrics
### redis_memo.cache.read
This span wraps around a cache read operation.

Values: `count`, `latency`
Tags: `method_id`, `cache_hit` (`true` or `false`)

### redis_memo.cache.write
This span wraps around a cache write operation (cache miss from cache read).

Values: `count`, `latency`  
Tags: `method_id`

### redis_memo.cache.batch.read
This span wraps around a batch cache read operation.

Values: `count`, `latency`  
Tags: n/a

### redis_memo.cache.batch.execute
This span wraps around a batch cache execution operation (the read results contain cache misses).

Values: `count`, `latency`  
Tags: n/a

### redis_memo.memoizable.bump_version
This span wraps around bumping a memoizable's version.

Values: `count`, `latency`  
Tags: `memoizable_key_name`, `enqueue_to_finish` (duration)

### redis_memo.memoizable.invalidate_all
This span wraps around model operations that would require invalidating cache results for the entire model.

Values: `count`, `latency`  
Tags: `model_name`

### redis_memo.memoize_query.invalidation
This span wraps around model operations that would require invalidating cache results for some model records.

Values: `count`, `latency`  
Tags: `operation_name`