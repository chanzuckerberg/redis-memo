RedisMemo
=========
Caching is made easy.

[![Gem Version](https://badge.fury.io/rb/redis-memo.svg)](https://badge.fury.io/rb/redis-memo)
[![Build Status](https://travis-ci.com/chanzuckerberg/redis-memo.svg?branch=main)](https://travis-ci.com/chanzuckerberg/redis-memo)
[![codecov](https://codecov.io/gh/chanzuckerberg/redis-memo/branch/main/graph/badge.svg?token=XG83PSWPG0)](https://codecov.io/gh/chanzuckerberg/redis-memo)

A Redis-based [version-addressable](https://github.com/chanzuckerberg/redis-memo/wiki/Version-Addressable) caching system. Memoize pure functions, aggregated database queries, and 3rd party API calls.

## Getting Started
### Add to your Gemfile
```ruby
# -- Gemfile --
gem 'redis-memo'
```

### Memoize Methods
#### Pure Functions
When a method does not have any dependencies other than its arguments, it is considered a pure function. Pure functions can be cached on Redis as follow:

```ruby
class FibonacciSequence
  extend RedisMemo::MemoizeMethod

  def [](i); i <= 2 ? 1 : self[i - 1] + self[i - 2]; end
  memoize_method :[]
end
```

The method arguments are used as part of the cache key to store the actual computation result on Redis.

#### Third-Party API calls (or any external dependencies)
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
```
For each `load` call, the cached result on Redis will be used until its dependencies have been invalidated.

### Memoize Database Queries (ActiveRecord)
RedisMemo has out of box support for ActiveRecord.

Use `memoize_table_column` to cache SQL queries that have filter conditions on specified columns.
```ruby
class Site < ApplicationRecord
  extend RedisMemo::MemoizeQuery

  memoize_table_column :id
  memoize_table_column :name
end
```

The following method calls will automatically try to load from Redis first and use the database only as a fallback. Cache invalidation is handled automatically!

```ruby
Site.find(1)
Site.find_by_id(2)
Site.where(name: 'site_name')
```
You may memoize a method that depends on multiple database queries to improve its performance:

```ruby
def students_i_teach; end

memoize_method :students_i_teach do |teacher|
  # depends_on accepts an ActiveRecord::Relation
  depends_on Student.where(site_id: teacher.site_ids)
  depends_on Role.where(user_id: teacher.id)
end
```


You may also reuse the dependencies on any other memoized methods as follow:
```ruby
memoize_method :students_teachers_teach do |teachers|
  teachers.each do |teacher|
    depends_on teacher.dependency_of(:students_i_teach)
  end
end
```

## How does it work?
RedisMemo is a [version-addressable](https://github.com/chanzuckerberg/redis-memo/wiki/Version-Addressable) caching system: It separates the versions from the cache results.

Two Redis Queries Per Call: In order to find a cached result, RedisMemo makes an additional round trip to Redis, retrieves the latest versions of its dependencies, then calculates a cache key that represents the latest version of the cached result.

This design allows RedisMemo to:

*   Have a clean API
    *   Add caching without invading any business logic
    *   Reuse dependencies
*   Provide auto-invalidation (with ActiveRecord)
*   Ensure consistency during deployments
*   Ensure consistency with multi-version concurrency control (with ActiveRecord)


## Learn More
*   Configuration
*   More examples of caching database queries
    *   Batching
    *   Escape memoization
    *   Cache queries on tables with high-write throughput
*   Performance
*   Reliability
*   Monitoring
