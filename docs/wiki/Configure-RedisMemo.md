### Options
You can configure and set various RedisMemo options in your initializer `config/initializers/redis_memo.rb`:
```ruby
RedisMemo.configure do |config|

  config.expires_in = 3.hours
  config.global_cache_key_version = SecureRandom.uuid
  ...
end
```

See https://www.rubydoc.info/gems/redis-memo/0.1.4/RedisMemo/Options for a full list of configurable options.

### Cache Sample Validation

RedisMemo has built-in cache sampling logic. An error reporter will be invoked if some methods have incorrect dependencies that cause the cache results to be out of date.

We highly recommend sampling at least 1% of the cached methods in production. When rolling out a new cached code path, one could start with a 100% cache sample rate until they feel confident enough to reduce the sample rate.

### Kill switches

Cached queries can be disabled per model by setting an ENV variable `REDIS_MEMO_DISABLE_<table name>`. RedisMemo can be turned off globally when `REDIS_MEMO_DISABLE_ALL` is set to true.