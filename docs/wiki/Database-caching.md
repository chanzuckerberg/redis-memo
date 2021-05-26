### Performance
Caching database queries can improve application performance by
- Skipping slow or expensive database queries
- Skipping calculations that require multiple database round trips
- Reducing the overhead from using a disk-based relational (SQL) database (Footnote 1)


### Scalability
A caching layer functions like a “content delivery network” (CDN) for delivering database queries. Applications often use a CDN to multiply their web servers' effective capacity. Similarly, caching increases an individual database’s capacity by protecting it from repetitive queries. A Rails application typically has a single SQL database that is queried by many application processes (Figure 1).

<p align="center">
<img align="center" src="https://github.com/chanzuckerberg/redis-memo/blob/main/docs/images/app_arch.png?raw=true" width="70%"/>
</p>

When application usage increases, the number of requests grows, and so does the number of database queries. There is a hard limit on the size of a single relational database. [The largest database instances](https://aws.amazon.com/ec2/instance-types/x1e/) offered by AWS come with 64 cores. A Redis cluster, however, can scale to [1000 nodes](https://redis.io/topics/cluster-spec).

Cache data can be easily partitioned into multiple Redis clusters, which essentially makes the Redis cache layer infinitely scalable. Partitioning the SQL database is much more challenging and not always practical.


### Cost Efficiency

Scaling the Redis cache layer is more cost-effective than scaling the database layer. If you use a [db.m5.4xlarge](https://aws.amazon.com/rds/instance-types/) database instance on AWS, you will pay $2,097 per month. If you add a 4-node Redis cache cluster which lets you move down to the [db.m5.2xlarge](https://aws.amazon.com/rds/instance-types/) instance, your total cost is $1,688, a savings of $409. The tradeoff only gets larger as your site grows.

#### Footnotes
1. Querying data from a key-value in-memory store is generally faster compared to querying from a disk-based SQL database since there’s no need to parse the SQL query, create an execution plan and execute it. However, the reduced overhead is often marginal compared to the time spent on the network round trip. Therefore, for the fast database queries, caching is not about improving the performance, but instead improving the scalability of the application.
