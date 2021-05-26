<img align="left" src="https://github.com/chanzuckerberg/redis-memo/blob/main/docs/images/icon.png?raw=true" alt="drawing" width="50"/>

**RedisMemo**  
Caching is made easy

-----
RedisMemo is a [version-addressable](https://github.com/chanzuckerberg/redis-memo/wiki/Version-Addressable) caching system:  Memoize pure functions, aggregated database queries, and 3rd party API calls.


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

