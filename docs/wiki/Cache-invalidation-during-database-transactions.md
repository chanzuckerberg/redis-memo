Suppose we have `CachedUser` implemented like this:
```ruby
def fetch
  Rails.cache.fetch("user:#{user_id}") do
    User.find(user_id) # load from the database on cache-miss
  end
end

```
then we will run into issues when using it during database transactions.

### Mid-transaction invalidation
If the cache is invalidated immediately after a not-yet-committed write, the following cache read would fill the cache with data that could be rolled back later.

```ruby
user # actual: #<User id: 1, name: "Old Name">
CachedUser.new(user.id).fetch # cache: #<User id: 1, name: "Old Name">
User.transaction do
  user.update!(name: "✨ New Name ✨")
  CachedUser.new(user.id).invalidate # mid-transaction invalidation 🗑
  CachedUser.new(user.id).fetch # cache: #<User id: 1, name: "✨ New Name 
  raise ActiveRecord::Rollback
end
User.find(user.id) # actual: #<User id: 1, name: "Old Name">
CachedUser.new(user.id).fetch # cache: #<User id: 1, name: "✨ New Name ✨">
```

### Post-transaction invalidation
If the cache is invalidated after committing the transaction, the following cache read would use the stale data from the cache as if the changes did not occur.

```ruby
user # actual: #<User id: 1, name: "Old Name">
CachedUser.new(user.id).fetch # cache: #<User id: 1, name: "Old Name">
User.transaction do
  user.update!(name: "✨ New Name ✨")
  User.find(user.id) # actual: #<User id: 1, name: "✨ New Name ✨">
  CachedUser.new(user.id).fetch # cache: #<User id: 1, name: "Old Name">
  raise ActiveRecord::Rollback
end
CachedUser.new(user.id).invalidate # post-transaction invalidation 🗑
```

### With RedisMemo
RedisMemo resolves this issue by [implementing MVCC](https://github.com/chanzuckerberg/redis-memo/wiki/Multi-Version-Concurrency-Control).
