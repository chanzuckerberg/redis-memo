**RedisMemo** is a version-addressable caching system. But what exactly is “version-addressable”?

Version Addressable is a made-up term, derived from the term “**content-addressable**”.

https://en.wikipedia.org/wiki/Content-addressable_storage
> Content-addressable storage, also referred to as content-addressed storage or abbreviated CAS, is a way to store information so it can be retrieved based on its content, not its location.

Similar to a content-addressable storage system, RedisMemo store information on Redis so it can be 
retrieved based on its **version**, not its location (aka its raw cache key).

![Version Addressable](https://lucid.app/publicSegments/view/d4742c99-a4f9-4785-bb8b-4bd51f5dd937/image.png)

In order to find a cached result, RedisMemo makes an additional roundtrip to Redis, retrieves the latest versions of its dependencies, then calculates a cache key that represents the latest version of the cached result (a checksum of the dependencies versions).
- If any of the dependencies versions have been changed, the actual cache key (checksum of the dependencies version) would differ, and result in a cache miss.
- If the latest version of the cached result is not yet available (cache miss), then RedisMemo executes the original code path and fills the cached result for that particular version.
