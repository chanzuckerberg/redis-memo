### Reading stale data from the cache
If cache results normally could not be used in database transactions: The cached values and the actual database values could have diverged since most databases implement multi-version concurrency control during transactions.

Here’s an example:
```ruby
ActiveRecord::Base.transaction do
  site = Site.find(1) # site(id: 1, name: ‘old name’)
  site.update(name: ‘new name) 
  redis.get(‘site:id:1’) # site(id: 1, name: ‘old name’) # reading from cache might cause issues
end
```

We cannot invalidate the cache within the transaction either since it might cause writing data that has been rolled back and lead to cache inconsistency:
```ruby
ActiveRecord::Base.transaction do
  # ...
  site.update(name: ‘new name) 
  redis.write(‘site:id:1’, site)
  raise ActiveRecord::Rollback # the rows are not really updated on the database
End
```

However, without updating the cache in transactions, we’d run into the same issue demonstrated in the first snippet. 

### Version Addressable
With RedisMemo, we can safely use the Redis cache in (ActiveRecord) database transactions.
RedisMemo uses ActiveRecord model hooks to record “pending versions” in the “after_save” and “after_destroy” callbacks  (learn more about [version addressable](https://github.com/chanzuckerberg/redis-memo/wiki/Version-Addressable)).

Using pending versions, we can support MVCC seamlessly:
- Pending versions are local to each database connection
- Pending versions are only rolled out and become globally accessible after a transaction is committed. We flush out the pending versions in the “after_commit” callback
- Pending versions are discarded if a transaction is rolled back. Cache results associated with those pending versions would no longer be referencable

### Transaction serialization
When there’re overlapping database transactions, both transactions could be committed if they’re seralizable. For example,
```ruby
# transaction 1 start
# transaction 2 start
site.update(name: ‘new_name) # transaction 1
site.update(location: ‘new_location’) # transaction 2
# transaction 1 commit
# transaction 2 commit
Site.find(site.id) # site(name: ‘new_name’, location: ‘new_location’)
```

However, when we save records to the cache after each update, we can only save one version of the transactions. The final cache for `site` would only have `new_name` or `new_location`, but not both, which is consistent with the value in the database.

Before updating dependencies versions, RedisMemo would save its current version prior to the update. During updating on Redis, RedisMemo would check if the current version still matches the expectation (in a Lua script to ensure atomicity). If not, we would use a different version that has not been used before, thus we have automatically invalidated the records that are being updated by overlapping transactions.

```ruby
# transaction 1 start
# transaction 2 start
# transaction 1, save the current version of site (ad051)
site.update(name: ‘new_name) # transaction 1
# transaction 2, save the current version of site (ad051)
site.update(location: ‘new_location’) # transaction  2
# transaction 1 commit
# bumping site version from ad051 to 0ak82
# transaction 2 commit
# bumping site version from ad051 to i4o095
#   version mismatch! Expected ad051, actual 0ak82
#   setting version to 99z281
```
Then we will use version `99z281` to fetch cache results. Since version `99z281` has not been seen before, we have a cache miss and fetch directly from the database. 
```ruby
Site.find(site.id) # site(name: ‘new_name’, location: ‘new_location’) 
```