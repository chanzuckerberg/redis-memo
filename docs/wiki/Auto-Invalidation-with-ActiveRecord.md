### Forgetting to invalidate the cache
Developers must manually invalidate the cached results after changes to associated database records. Forgetting to do this is common, and causes subtle bugs.

```ruby
def fetch
  Rails.cache.fetch("user:#{user_id}") do
    User.find(user_id) # load from the database on cache-miss
  end
end

def invalidate
  # 🤙 don’t forget to call me, pls?
  Rails.cache.delete("user:#{user_id}")
end
```

### Query analysis and auto-invalidation
If you track a column with RedisMemo, any SQL queries (ActiveRecord) with that column will be automatically cached, and automatically invalidated.

Cached database queries in RedisMemo are memoized methods at the database adaptor level. RedisMemo analyzes the SQL query and tracks the dependencies of those queries automatically. Each dependency has a version that is automatically updated when database records are changed (by using some [ActiveRecord callbacks](https://guides.rubyonrails.org/active_record_callbacks.html)).

<p align="center">
<img src="https://github.com/chanzuckerberg/redis-memo/blob/main/docs/images/query_deps_tracking.png?raw=true" width="80%" />
</p>

For example, after tracking some user table columns as dependencies,
```ruby
class User < ApplicationRecord
  extend RedisMemo::MemoizeQuery
  memoize_table_column :id
  memoize_table_column :first_name
end
```

queries such as
- `record.user`
- `User.find(user_id)`
- `User.where(id: user_id).first`
- `User.where(first_name: first_name).first`
- `User.find_by_first_name(first_name)`

will first check the Redis cache for the data before hitting the SQL database; the cache results are invalidated automatically when user records are changed.

