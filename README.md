<img align="left" src="https://github.com/chanzuckerberg/redis-memo/blob/main/docs/images/icon.png?raw=true" alt="drawing" width="120"/>

# RedisMemo

[![Gem Version](https://badge.fury.io/rb/redis-memo.svg)](https://badge.fury.io/rb/redis-memo)
[![Build Status](https://travis-ci.com/chanzuckerberg/redis-memo.svg?branch=main)](https://travis-ci.com/chanzuckerberg/redis-memo)
[![codecov](https://codecov.io/gh/chanzuckerberg/redis-memo/branch/main/graph/badge.svg?token=XG83PSWPG0)](https://codecov.io/gh/chanzuckerberg/redis-memo)


## Add to your Gemfile
```ruby
# -- Gemfile --
gem 'redis-memo'
```
:warning: **Required Redis Version:** >= 6.0.0 ([reference](https://github.com/chanzuckerberg/redis-memo/blob/91ec911766ad072b1e003f695c35594bb31f0e67/lib/redis_memo/memoizable/bump_version.lua#L14-L16))
## Usage
### Cache simple ActiveRecord queries
In the `User` model:
```ruby
class User < ApplicationRecord
  extend RedisMemo::MemoizeQuery
  memoize_table_column :id
end
```

`SELECT "users".* FROM "users" WHERE "users"."id" = $1` queries will **load the data from Redis** instead of the database:
```
[1] (rails console)> Post.last.author
  Post Load (0.5ms)  SELECT "posts".* FROM "posts" ORDER BY "posts"."id" DESC LIMIT $1
[Redis] User Load SELECT "users".* FROM "users" WHERE "users"."id" = $1 LIMIT $2
[Redis] command=MGET args="RedisMemo::Memoizable:wBHc40/aONKsqhl6C51RyF2RhRM=" "RedisMemo::Memoizable:fMu973somRtsGSPlWfQjq0F8yh0=" "RedisMemo::Memoizable:xjlaWFZ6PPfdd8hCQ2OjJi6i0hw="
[Redis] call_time=0.54 ms
[Redis] command=MGET args="RedisMemo:SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = ? LIMIT ?::P+HaeUnujDi9eH7jZfkTzWuv6CA="
[Redis] call_time=0.44 ms
=> #<User id: 1>
```
Learn more [here](https://github.com/chanzuckerberg/redis-memo/wiki/Auto-Invalidation-with-ActiveRecord).

### Cache aggregated ActiveRecord queries
Some computation might depend on multiple database records, for example:
```ruby
class Post < ApplicationRecord
  extend RedisMemo::MemoizeMethod
  def display_title
    "#{title} by #{author.display_name}"
  end
  memoize_method :display_title do |post|
    depends_on Post.where(id: post.id)
    depends_on User.where(id: post.author_id)
  end
end
```
* Note that calling `Post.where(id: post.id)` does not trigger any database queries -- it's just an [ActiveRecord Relation](https://api.rubyonrails.org/v6.1.3.1/classes/ActiveRecord/Relation.html) representing the SQL query.

In order to use `depends_on` to extract dependencies from a Relation, we need to memoize the referenced table columns on the `Post` and `User` model:
```ruby
class Post < ApplicationRecord
  extend RedisMemo::MemoizeQuery
  memoize_table_column :id
end
```

It's also possible to pull in existing dependencies on other memoized methods and perform [hierarchical caching](https://github.com/chanzuckerberg/redis-memo/wiki/Hierarchical-Caching).

### Cache Pure Functions
When a method does not have any dependencies other than its arguments, it is considered a pure function. Pure functions can be cached on Redis as follow:

```ruby
class FibonacciSequence
  extend RedisMemo::MemoizeMethod

  def [](i); i <= 2 ? 1 : self[i - 1] + self[i - 2]; end
  memoize_method :[]
end
```

The method arguments are used as part of the cache key to store the actual computation result on Redis.

### Cache Third-Party API calls (or any external dependencies)
When a method’s result can not only be derived from its arguments, set dependencies explicitly as follow:
*   Call  `invalidate` in `after_save`
*   Set dependencies in `memoize_method`

```ruby
class Document
  extend RedisMemo::MemoizeMethod

  def memoizable
    @memoizable ||= RedisMemo::Memoizable.new(document_id: id)
  end

  def after_save
     RedisMemo::Memoizable.invalidate([memoizable])
  end

  # Make an API request to load the document, for example, from AWS S3
  def load; end

  memoize_method :load do |doc|
    depends_on doc.memoizable
  end
end
```
For each `load` call, the cached result on Redis will be used until its dependencies have been invalidated.

## Configure RedisMemo
You can configure various RedisMemo options in your initializer `config/initializers/redis_memo.rb`:
```ruby
RedisMemo.configure do |config|
  config.expires_in = 3.hours
  config.global_cache_key_version = SecureRandom.uuid
  ...
end
```
Learn more [here](https://github.com/chanzuckerberg/redis-memo/wiki/Configure-RedisMemo).

## Why RedisMemo?

1. [Database caching](https://github.com/chanzuckerberg/redis-memo/wiki/Database-caching): Quick review of why caching is important
2. Challenges with application-level caching  
    2.1 [Forgetting to invalidate the cache](https://github.com/chanzuckerberg/redis-memo/wiki/Auto-Invalidation-with-ActiveRecord#forgetting-to-invalidate-the-cache)  
    2.2 [Cache invalidation during database transactions](https://github.com/chanzuckerberg/redis-memo/wiki/Cache-invalidation-during-database-transactions)  
    2.3 [Cache invalidation could be slow and expensive](https://github.com/chanzuckerberg/redis-memo/wiki/Cache-invalidation-could-be-slow-and-expensive-with-Rails-low-level-caching)  
    2.4 [Possible race conditions](https://github.com/chanzuckerberg/redis-memo/wiki/Possible-race-conditions-with-Rails-low-level-caching)  
    2.5 [Cache inconsistency during deployments](https://github.com/chanzuckerberg/redis-memo/wiki/Ensure-consistency-during-deployments)  
   
3. How caching is easily done with RedisMemo  
    3.1 [Performant and reliable cache invalidation](https://github.com/chanzuckerberg/redis-memo/wiki/Cache-invalidation-could-be-slow-and-expensive-with-Rails-low-level-caching#with-redismemo)  
    3.2 [Auto-invalidation](https://github.com/chanzuckerberg/redis-memo/wiki/Auto-Invalidation-with-ActiveRecord)  
    3.3 [Add caching without changing any call sites](https://github.com/chanzuckerberg/redis-memo/wiki/Add-caching-without-changing-any-call-sites)  
    3.4 Add caching confidently    
        &nbsp;&nbsp;&nbsp;&nbsp;3.4.1 [Avoid mistakes by pulling in existing dependencies](https://github.com/chanzuckerberg/redis-memo/wiki/Hierarchical-Caching#reuse-dependency)  
        &nbsp;&nbsp;&nbsp;&nbsp;3.4.2 [Monitoring](https://github.com/chanzuckerberg/redis-memo/wiki/Monitoring)  
        &nbsp;&nbsp;&nbsp;&nbsp;3.4.3 [Safely roll out changes](https://github.com/chanzuckerberg/redis-memo/wiki/Configure-RedisMemo#cache-sample-validation)  

## Related Work
We’re aware of [Shopify/identity_cache](https://github.com/Shopify/identity_cache), a gem that provides query caching with automatic cache invalidation; however, it is affected by most of the other issues we want to address when caching queries at the application-level. You can learn more about the challenges with using the Rails low-level caching API or other caching technologies such as IdentityCache [here](https://github.com/chanzuckerberg/redis-memo/wiki).

IdentityCache is [deliberately opt-in](https://github.com/Shopify/identity_cache#caveats) for all call sites that want to use caching. In comparison, RedisMemo is still deliberate in that clients should specify what computation and models should be cached. However, when caching does make sense, RedisMemo makes caching easy and robust by automatically using the cached code paths.
