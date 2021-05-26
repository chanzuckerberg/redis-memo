There could be a lot of cache results to invalidate depending on the content of the cache results. Consider the following example:
```ruby
class CachedPostAuthor
  def fetch
   Rails.cache.fetch("post_author:post:#{post_id}") do
      post = Post.find(post_id)
      post.author.display_name # an implicit dependency with the user
    end
  end
end

class User < ApplicationRecord
  def invalidate_cache
    posts.each do |post| # this could take many seconds
      CachedPostAuthor.new(post.id).invalidate
    end
  end
end
```


Each time a user updates their display name, we have to iterate through all their posts and invalidate the cache for each of them. Before finishing this process, users might see partially inconsistent data (some posts with the old display, some posts with the new display name).

### With RedisMemo
RedisMemo is a [version-addressable](https://github.com/chanzuckerberg/redis-memo/wiki/Version-Addressable) caching system, similar to Git, a content-addressable storage system. Git computes a checksum of objects to retrieve those objects from its database. RedisMemo computes a checksum of dependency versions to retrieve cached method results. Version-addressability is the core of RedisMemo that brings performance and reliability.

Each memoized method has one or more dependencies. Bumping the dependency version is an **O(1)** operation that takes about **2 milliseconds** ([atomicity and consistency assured](https://github.com/chanzuckerberg/redis-memo/wiki/Multi-Version-Concurrency-Control#transaction-serialization) with [Redis Lua scripting](https://redis.io/commands/eval)). Millions or even billions of associated cached results could be invalidated immediately after updating a single dependency version. Using RedisMemo, we can effectively resolve the issue described above.

```ruby
class Post < ApplicationRecord
  extend RedisMemo::MemoizeMethod
  def author_display_name
    author.display_name
  end
  memoize_method :author_display_name do |post|
    depends_on Post.where(id: post.id)
    # an explicit dependency with the user
    depends_on User.where(id: post.author_id) # changes to a user record would bump the version of this dependency
  end
end
```
