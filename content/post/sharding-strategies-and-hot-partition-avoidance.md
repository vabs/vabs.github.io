---
title: "Sharding Strategies and Hot Partition Avoidance"
date: 2026-03-14T16:48:00-04:00
draft: false
tags: [backend, sharding, scalability, databases, partitioning]
---

## Why shard at all

A single database node has a ceiling. Eventually the working set no longer fits in memory, write throughput saturates a single disk, or the table grows so large that index maintenance and vacuum become unmanageable. Vertical scaling — bigger boxes — buys time but ends at the largest instance your provider sells, and at a price that grows faster than the capacity.

Sharding is horizontal partitioning of data across multiple independent nodes, each owning a disjoint subset of rows. Done well, it gives near-linear scaling of both storage and throughput. Done badly, it concentrates load on one unlucky node — a **hot partition** — and you get all the operational complexity of a distributed system with none of the scaling benefit.

The entire game is choosing how to map each row to a shard. That choice is the **shard key** and the **sharding function**.

## The three classic strategies

### Range sharding

Rows are assigned to shards by contiguous ranges of the shard key. User ids 1–1,000,000 go to shard A, 1,000,001–2,000,000 to shard B, and so on. Time-series data is often range-sharded by timestamp.

```text
shard A: key in [0,        1_000_000)
shard B: key in [1_000_000, 2_000_000)
shard C: key in [2_000_000, 3_000_000)
```

Range sharding makes **range scans efficient** — "all events between March 1 and March 7" hits one or two shards. But it has a notorious failure mode: if the key is monotonically increasing (auto-increment id, current timestamp), every new write lands on the *same* last shard. That shard is hot for writes while the others sit idle. This is the classic time-series anti-pattern.

### Hash sharding

The shard key is run through a hash function and the result modulo the shard count picks the shard.

```python
def shard_for(key: str, num_shards: int) -> int:
    return hash(key) % num_shards
```

Hashing spreads sequential keys uniformly, which kills the monotonic-write hot spot. The cost is that **range scans are destroyed** — adjacent keys land on different shards, so a range query must fan out to every shard and merge. Hash sharding is the right default when your access pattern is point lookups by key.

Its hidden cost appears when you change `num_shards`. With plain modulo, adding one shard remaps almost every key. That is where consistent hashing comes in.

### Directory (lookup) sharding

A lookup table maps each key (or key range) to a shard explicitly. The mapping lives in a metadata service or a small, highly-cached table.

This is the most flexible strategy. You can move a single noisy tenant to its own shard, rebalance arbitrarily, and split ranges on demand. The price is an extra lookup on the read path and a piece of critical infrastructure — the directory — that must be highly available and consistent.

| Strategy | Range scans | Even write spread | Rebalancing | Extra hop |
|----------|-------------|-------------------|-------------|-----------|
| Range | Excellent | Poor for monotonic keys | Split/merge ranges | No |
| Hash | Poor | Excellent | Hard (without consistent hashing) | No |
| Directory | Depends on mapping | Excellent | Easy | Yes |

## Consistent hashing

The problem with `hash(key) % N` is that changing `N` reshuffles nearly everything. Consistent hashing fixes this by mapping both keys and shards onto the same circular hash space (the "ring"). A key belongs to the first shard found clockwise from the key's position.

{{< mermaid >}}
graph TD
    A["Key hashes to position p"] --> B["Walk clockwise on ring"]
    B --> C["First node at or after p owns the key"]
    C --> D["Add a node: only keys between it and its predecessor move"]
    C --> E["Remove a node: its keys go to the next node clockwise"]
{{< /mermaid >}}

When you add a node, only the keys that fall in the arc between the new node and its predecessor move — roughly `1/N` of the data, not all of it. To avoid uneven arcs (a node owning a huge slice by luck), each physical node is placed at many positions on the ring using **virtual nodes**. A few hundred vnodes per physical node smooths the distribution and makes rebalancing finer-grained.

```python
class ConsistentHashRing:
    def __init__(self, nodes, vnodes=200):
        self.ring = {}          # hash position -> node
        self.sorted_keys = []
        for node in nodes:
            for v in range(vnodes):
                h = hash(f"{node}#{v}")
                self.ring[h] = node
                self.sorted_keys.append(h)
        self.sorted_keys.sort()

    def get_node(self, key):
        h = hash(key)
        # binary search for first ring position >= h, wrapping around
        idx = bisect.bisect(self.sorted_keys, h) % len(self.sorted_keys)
        return self.ring[self.sorted_keys[idx]]
```

## Anatomy of a hot partition

A hot partition is any shard receiving disproportionate load. Three distinct causes, each with a different fix:

1. **Skewed key distribution.** The shard key has a power-law popularity. A "celebrity" user with millions of followers, or a single tenant that is 100x larger than the rest, lands all its traffic on one shard regardless of how well the hash spreads keys. Hashing distributes *keys* evenly, not *traffic per key*.

2. **Monotonic keys.** Already covered — sequential keys on a range-sharded cluster funnel writes to the tail shard.

3. **Temporal hot spots.** A flash sale, a viral post, a daily batch job that touches one tenant. The skew is transient but brutal while it lasts.

The diagnostic is per-shard metrics: request rate, CPU, and key-cardinality histograms. If one shard's QPS is 5x the median, you have a hot partition. Aggregate cluster metrics will hide it — the cluster looks fine at 30% average utilization while one node is on fire.

## Avoiding and mitigating hot partitions

### Choose a high-cardinality, low-skew key

The first defense is key selection. A good shard key has many distinct values, each with similar load. `user_id` is usually fine; `country` is terrible (a handful of values, wildly uneven). `status` is the worst kind — a few values where one dominates.

### Composite and salted keys

When the natural key is skewed, combine it with something high-cardinality. For a time-series write hot spot, prefix the timestamp with a hash bucket:

```text
plain key:    2026-03-14T10:00:00          -> all writes to one shard
salted key:   bucket=07 | 2026-03-14T10:00 -> writes spread over N buckets
```

Reads now fan out across the `N` buckets and merge, trading a wider read for an even write distribution. This is the standard pattern for high-write time-series and is exactly how systems like DynamoDB recommend handling write hot spots.

### Split the celebrity

For a single hot key (the celebrity user), salting splits its writes across sub-keys: `user_42#0`, `user_42#1`, ... `user_42#K`. Writes round-robin or hash across the `K` sub-shards; reads gather all `K`. This trades read amplification for write capacity and is worth it only for the handful of genuinely hot keys, applied selectively rather than globally.

### Caching in front of read hot spots

If the hot partition is read-heavy (a viral post being fetched millions of times), the cheapest fix is a cache. A hot read key is, almost by definition, highly cacheable. Put the celebrity behind a CDN or an in-memory cache and the shard never sees the storm.

{{< mermaid >}}
graph TD
    A["Incoming write for hot key"] --> B{"Key known to be hot?"}
    B -->|No| C["Route by hash to single shard"]
    B -->|Yes| D["Append salt bucket 0..K"]
    D --> E["Route salted key to one of K shards"]
    F["Read for hot key"] --> G{"Cache hit?"}
    G -->|Yes| H["Serve from cache"]
    G -->|No| I["Scatter-gather across K shards, merge, cache"]
{{< /mermaid >}}

## Rebalancing without downtime

Even with good keys, data and traffic drift, and you eventually need to add capacity. The hard part is moving data while serving traffic.

The general recipe: pick the ranges or vnodes to move, copy them to the destination shard in the background, then do a brief cutover where new writes for those keys go to the destination while a final delta is reconciled. During the copy, dual-write or use the directory to atomically flip ownership. Consistent hashing with vnodes makes this incremental — you move a few vnodes at a time, never the whole dataset.

The directory strategy makes rebalancing operationally simplest because ownership is just a row update, at the cost of the lookup hop on every request. Many large systems combine consistent hashing for the default placement with a directory-style override table for the small set of keys that need special placement.

## Cross-shard operations

The cost you pay for sharding is that some operations no longer fit on one node:

- **Joins** across shards must be done in the application or via a query layer that scatters and gathers. Denormalizing to keep related data co-located on the same shard (by sharding parent and child on the same key) avoids most of these.
- **Transactions** spanning shards need two-phase commit or saga patterns, both of which are expensive and complex. Designing your shard key so that a unit of work touches a single shard — entity-group sharding — is far better than making cross-shard transactions fast.
- **Aggregations** (counts, sums across all data) require fan-out. Maintain rollups or accept scatter-gather latency.

## Summary

Sharding scales storage and throughput by mapping rows to nodes, and the shard key choice decides whether you get linear scaling or a hot partition. Hash sharding spreads load but kills range scans; range sharding enables scans but invites monotonic hot spots; directory sharding is flexible at the cost of a lookup. Consistent hashing with virtual nodes makes rebalancing cheap. Hot partitions come from key skew, monotonic keys, or temporal spikes — and you defend against them with high-cardinality keys, salting, selective splitting of celebrity keys, and caching in front of read hot spots. Design so that the common unit of work lives on one shard, and cross-shard joins and transactions stay rare.
