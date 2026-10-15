---
title: "Eventual Consistency in Cache"
date: 2026-04-11T14:20:00-04:00
draft: false
featured: false
tags: [backend, caching, consistency, distributed-systems, replication]
---

A cache exists to answer a read faster than the source of truth can. The moment you place a copy of data somewhere other than its authoritative home, you create the possibility that the copy and the source disagree. Eventual consistency is the honest name for the contract most caches actually offer: reads may return stale data for some window, but if writes stop, all replicas eventually converge to the same value. This post digs into why that window exists, how to reason about it, and how to keep it small enough that your users never notice.

## What "eventual" actually means

Eventual consistency is a liveness guarantee, not a safety guarantee. It promises that *eventually* every replica reflects the latest write, assuming no new writes arrive. It says nothing about how long "eventually" takes, nor about what a reader sees in the meantime. A cache that is eventually consistent can legally serve a value that is minutes old, as long as it stops doing so once propagation completes.

The practical questions are therefore not "is it consistent?" but "how long is the staleness window?" and "what can a reader observe during that window?" Two systems can both be eventually consistent and have wildly different user experiences depending on those answers.

There are stronger sub-guarantees worth knowing:

| Model | Guarantee | Typical cache use |
|-------|-----------|-------------------|
| Read-your-writes | A client always sees its own latest write | Session-affined caches |
| Monotonic reads | A client never sees data go backwards in time | Sticky routing to one replica |
| Bounded staleness | Staleness never exceeds T seconds | TTL-driven caches |
| Eventual only | Converges someday | Best-effort CDN edges |

Most caching layers default to "eventual only" and bolt the stronger models on through routing tricks, TTLs, or versioning.

## Where staleness comes from

Staleness enters a cache through three doors: time-based expiry, asynchronous invalidation, and replication lag.

A TTL-based cache simply trusts that data does not change faster than the TTL. When it does, the cache serves stale data until the entry expires. The staleness window equals the remaining TTL at the moment of the underlying write.

An invalidation-based cache tries to evict or update entries when the source changes. But the invalidation message travels asynchronously, and between the write committing and the invalidation arriving, every cache node still serves the old value.

A replicated cache (Redis with replicas, a multi-region setup) adds replication lag on top. A write lands on the primary, but read replicas apply it later.

{{< mermaid >}}
sequenceDiagram
  participant C as Client
  participant DB as Database (source of truth)
  participant P as Cache primary
  participant R as Cache replica
  C->>DB: write value=42
  DB-->>C: ack
  C->>P: invalidate key
  Note over R: replica still holds value=41
  C->>R: read key
  R-->>C: 41 (stale)
  P->>R: replicate eviction
  C->>R: read key
  R-->>C: miss, fetch 42
{{< /mermaid >}}

The diagram shows the canonical race: a read hits a replica after the write but before propagation, and gets a value that no longer exists in the source.

## Invalidation versus write-through versus refresh-ahead

The strategy you pick for keeping a cache fresh determines the shape of your staleness window.

### Cache-aside with invalidation

The application reads from cache, falls back to the database on a miss, and explicitly invalidates the cache after a write. This is the most common pattern because it is simple, but it has a notorious race condition.

```python
def update_user(user_id, data):
    db.update(user_id, data)        # 1. write source of truth
    cache.delete(f"user:{user_id}") # 2. invalidate

def get_user(user_id):
    key = f"user:{user_id}"
    cached = cache.get(key)
    if cached is not None:
        return cached
    value = db.get(user_id)         # 3. miss -> read DB
    cache.set(key, value, ttl=300)  # 4. repopulate
    return value
```

The race: a reader misses at step 3, reads an *old* value from a lagging replica, and is about to set it at step 4 — but a concurrent writer has already invalidated at step 2. The reader then writes the stale value back into the cache, where it lives until the TTL saves you. This is why cache-aside still needs a TTL as a backstop even when invalidation is "correct."

### Write-through

Writes go through the cache, which synchronously updates both itself and the database. Reads are always fresh from the cache's perspective, but write latency increases and you pay the consistency cost on the write path.

### Refresh-ahead

The cache proactively refreshes hot keys before they expire, so popular entries rarely go stale and rarely cause a thundering-herd miss. It trades extra background load for a smaller staleness window on the keys that matter most.

| Strategy | Staleness window | Write cost | Failure mode |
|----------|------------------|-----------|--------------|
| Cache-aside + invalidation | Until invalidation propagates | Low | Stale write-back race |
| Write-through | Near zero | High | Slow writes, write amplification |
| Refresh-ahead | Sub-TTL on hot keys | Medium | Wasted refreshes on cold keys |
| TTL-only | Full TTL | None | Predictably stale |

## Quantifying the window

You can put a number on staleness. If invalidation propagation has a 99th-percentile latency of `Lp`, and replication lag has a 99th-percentile of `Lr`, then for an invalidation-based replicated cache the staleness window at p99 is roughly:

```
window_p99 ≈ Lp + Lr
```

For a TTL-only cache it is simply the TTL. The useful insight is that these compose: a TTL-only cache *with* replication still bounds staleness at the TTL, because the TTL forces a refetch regardless of replication state. That is why a modest TTL is such a cheap safety net — it caps the worst case even when your invalidation pipeline misbehaves.

## Convergence and the role of versioning

Eventual consistency requires that replicas can decide *which* value is newer when they finally exchange state. Without an ordering, two nodes that both received different writes have no way to converge. Caches solve this with version stamps — a monotonically increasing version, a logical clock, or a last-write-wins timestamp.

Last-write-wins (LWW) is the most common and the most dangerous: if two writes have close timestamps and clock skew exceeds the gap, the wrong write can win silently. A safer approach attaches a version counter that the source of truth controls:

```python
def set_if_newer(key, value, version):
    current = cache.get_with_version(key)
    if current is None or version > current.version:
        cache.set_versioned(key, value, version)
        return True
    return False  # ignore stale update arriving late
```

This makes invalidation idempotent and reorder-safe: a late, out-of-order update carrying an older version is simply dropped rather than overwriting fresher data. It is the single most effective defense against the stale write-back race described earlier.

{{< mermaid >}}
flowchart TD
  A["Write v5 to source"] --> B["Invalidation carries version=5"]
  C["Late read repopulates with version=3"] --> D{"Cache compares versions"}
  B --> D
  D -->|"5 > current"| E["Accept v5"]
  D -->|"3 < current"| F["Reject v3, keep v5"]
{{< /mermaid >}}

## Making staleness invisible to users

A staleness window only matters if a user can observe an inconsistency that breaks their mental model. The art of caching is hiding the window where it would be noticed and tolerating it where it would not.

The strongest lever is **read-your-writes** consistency. After a user updates their own profile, route their subsequent reads to the primary or to their own session cache, so they never see their change vanish. Other users can tolerate seeing the old profile for a few seconds; the author cannot.

The second lever is **monotonic reads** through sticky routing. If a client always hits the same replica, it never observes data going backwards, even if that replica is behind. Bouncing between replicas with different lag is what produces the jarring "my comment appeared, then disappeared, then reappeared" experience.

The third lever is **scoping the TTL to the data's volatility**. Reference data that changes daily can cache for hours. A live inventory count needs seconds. Mixing them under one TTL forces you to choose between staleness on the slow data and churn on the fast data.

```python
TTL_BY_KIND = {
    "country_list": 86400,   # changes ~never
    "user_profile": 300,     # changes occasionally
    "inventory": 5,          # changes constantly
}
```

## Operational signals to watch

Eventual consistency fails quietly, so instrument it deliberately:

- **Replication lag** as a histogram, alerting on the tail rather than the mean. The mean is almost always fine; the tail is what burns a user.
- **Invalidation delivery latency and drop rate.** A dropped invalidation turns a 300ms window into a full-TTL window without any error appearing.
- **Stale-serve counter** — instrument the version-compare path so you can count how often a read returned an older version than the source had at that instant. This is your ground-truth staleness metric.
- **Cache hit ratio segmented by key kind**, so a falling ratio on hot keys tips you off to refresh-ahead problems before they become miss storms.

## Conclusion

Eventual consistency is not a flaw to be engineered away; it is the price of putting a copy of data closer to the reader. The win is in making the staleness window *bounded, measured, and invisible where it counts*. Use a TTL as an unconditional backstop, attach versions so late updates cannot resurrect stale data, route writers and individual sessions to fresh replicas, and tune TTLs to each data type's volatility. Do that, and "eventual" arrives fast enough that nobody ever has to think about it.
