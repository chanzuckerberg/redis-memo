It’s possible to memoize methods that are already using memoized methods. 

For example, consider the following method hash
```ruby
def hash
  {
    a: send_db_query(prop: :a),
    b: some_other_computation(prop: :b),
  }
end
```
Method `send_db_query` and `some_other_computation` have already been memoized.

Then to memoize method hash and pull in the dependencies of the inner memoized methods:
```ruby
memoize_method :hash do |ref|
  depends_on ref.dependency_of(:send_db_query, prop: :a)
  depends_on ref.dependency_of(:some_other_computation, prop: :b)
end
```

## Reuse Dependency
Caching at the application-level is often considered difficult. The main reason is that it’s pretty easy to make mistakes by forgetting to invalidate something.
For example, for the method hash, the inner method `some_other_computation` might have additional external dependencies -- if those dependencies have changed, the cached result for method hash should be invalidated. Yet, by looking at the method hash, there are no direct references to any of the external dependencies.
```ruby
def some_other_computation(prop:)
  aggregate_query_results(
    send_db_query(prop: prop),
    send_db_query(prop: fixed_prop),
  )
end
memoize_method :some_other_computation do |ref, prop:|
  depends_on ref.dependency_of(:send_db_query, prop: prop)
  depends_on ref.dependency_of(:send_db_query, prop: ref.fixed_prop)
end
```
With RedisMemo, we could reuse dependencies specified by any memoized methods. Assuming the dependencies are set up correctly, It is impossible to forget to invalidate something!

## Cache Miss
By setting up hierarchical caching, we would get performance improvements even when the outer method had a cache-miss, since the inner memoized methods could still get cache-hits.

By using `dependency_of`, we are conceptually constructing a Directed Acyclic Graph (DAG) of memoized methods. RedisMemo caches computational graphs and avoids re-extracting the dependencies repetitively when there’s a cache miss at any level.

Additionally, the inner methods could be used at any other call sites. Given the same write workload, the more often the inner memoized methods are used, the more likely to get a cache-hit from the inner memoized methods.