Instead of building separate cached code paths or providing new API such as `Product.fetch`, RedisMemo takes advantage of metaprogramming in Ruby and adds caching to existing code paths as annotation:

```ruby
class Post < ApplicationRecord
  extend RedisMemo::MemoizeMethod
  def author_display_name
    author.display_name
  end
  memoize_method :author_display_name do |post|
    depends_on Post.where(id: post.id)
    depends_on User.where(id: post.author_id)
  end
end
```

Here are some of the motivations:
- Caching should be the default behavior, rather than a conscious choice each developer has to make every time; they might not even be aware of the existence of the cached code path.
- Cached and uncached code paths can diverge over time.
Switching to the cached ones may require changing a ton of files; it’s not always possible to change all the call sites, since some of them could be used in some gem code.
- Separate code paths such as `Product.fetch` have other usability and compatibility issues with ActiveRecord. Learn more about those issues [here](https://github.com/chanzuckerberg/redis-memo/wiki/Issues-with-separate-cached-ActiveRecord--code-paths).

### Footnotes
1. We’re aware of [Shopify/identity_cache](https://github.com/Shopify/identity_cache), a gem that also provides query caching with automatic cache invalidation. It documented the motivation for providing separate cached query code paths in its [caveats](https://github.com/Shopify/identity_cache#caveats). With RedisMemo, caching is still a deliberate decision: there are models and computations that would not benefit from caching. When caching does make sense, RedisMemo makes caching easy and robust.