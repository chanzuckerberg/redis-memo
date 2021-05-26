Suppose we are adding separate cached code paths for some ActiveRecord methods:
- `teacher.sites` -> `teacher.cached_sites`
- `Site.find` -> `Site.cached_find`
- `Site.where` -> `Site.cached_where`

## Lazy Loading
Many querying methods return an `ActiveRecord::Relation`. There’s no data fetching until it’s absolutely necessary. If we simply added cached methods such as `teacher.cached_sites` and `Site.cached_where`, we would not be able to implement lazy loading.

## Association Preloading
A common technique to avoid N+1 query:
```ruby
teachers = Teacher.preload(:site).where(...)

teachers.map(&:site) # no additional queries!
```
Simply adding a `cached_where` would bypass this optimization. 

## Association Scope
With ActiveRecord, one could have associations with a scope as follows:

```ruby
belongs_to :local_site, -> { where(location: ...) }
```
Simply adding a `cached_local_site` would not be ideal:
- It interferes with the association cache
- It does not support lazy loading

## inverse_of
One could use `inverse_of` to retrieve the same Ruby object instance using different querying methods ([example](https://rossta.net/blog/use-inverse-of.html)). Simply adding a cached code path would bypass this functionality.

```ruby
# app/models/author.rb
class Author < ActiveRecord::Base
  has_many :posts, inverse_of: :author
end
```

## Not always possible to change all the call sites
External gem code could use any ActiveRecord query methods. It’s not practical to patch all the gems to use the cached ActiveRecord code path (for example, ActiveJob serializes and deserializes job arguments).
