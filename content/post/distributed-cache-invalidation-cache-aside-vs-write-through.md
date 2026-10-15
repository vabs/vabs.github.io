---
title: "Distributed Cache Invalidation: Cache-Aside vs Write-Through"
date: 2026-04-07T16:44:18-04:00
draft: false
featured: false
tags: [backend, caching, consistency, redis, distributed-systems]
---

There are only two hard things in computer science, the joke goes, and cache invalidation is one of them. The reason it's hard is that a cache is a deliberate copy of data that lives somewhere else, and the moment the source of truth changes, your copy is a lie until you do something about it. The strategy you choose — cache-aside, write-through, write-behind — determines *who* keeps the copy honest, *when*, and *what happens* in the window where they disagree. This post dissects the major patterns, their consistency guarantees, and the race conditions that make distributed caching genuinely treacherous.

## The Two Read Patterns

Caching strategies divide first on who is responsible for populating the cache.

**Cache-aside (lazy loading):** the application owns cache logic. On a read, it checks the cache; on a miss, it loads from the database and populates the cache itself.

```python
def get_user(user_id):
    key = f"user:{user_id}"
    cached = cache.get(key)
    if cached is not None:
        return cached
    user = db.query(user_id)        # miss: load from source
    cache.set(key, user, ex=300)    # populate
    return user
```

**Read-through:** the cache itself knows how to load from the backing store. The application only ever talks to the cache, and the cache fetches on a miss transparently. This pushes the loading logic into the caching layer (or a library wrapping it) rather than scattering it across application code.

| Aspect | Cache-aside | Read-through |
|--------|-------------|--------------|
| Who loads on miss | Application | Cache layer |
| Cache stores only what's read | Yes | Yes |
| Application coupling | High (cache logic everywhere) | Low (cache is opaque) |
| Resilience if cache down | Degrades to DB directly | Needs fallback path |

Both are *lazy*: data enters the cache only when first requested, so the cache holds the working set and cold data is never cached. The cost is the first-read penalty on every cold key.

## The Two Write Patterns

The write strategy is where consistency is won or lost.

**Write-through:** every write goes to the cache and the database synchronously, in the same operation, before the write is acknowledged.

```python
def update_user(user_id, data):
    db.update(user_id, data)              # write source of truth
    cache.set(f"user:{user_id}", data, ex=300)  # update cache
```

**Write-behind (write-back):** the write goes to the cache immediately and is acknowledged, then flushed to the database asynchronously later.

**Write-around:** writes go only to the database, bypassing the cache; the cache is populated lazily on subsequent reads.

{{< mermaid >}}
graph TD
  A["Write request"] --> B{"Strategy"}
  B -->|"Write-through"| C["Write DB + cache synchronously"]
  C --> D["Ack after both succeed"]
  B -->|"Write-behind"| E["Write cache, ack immediately"]
  E --> F["Async flush to DB later"]
  B -->|"Write-around"| G["Write DB only"]
  G --> H["Cache filled on next read"]
{{< /mermaid >}}

| Strategy | Write latency | Consistency | Data-loss risk |
|----------|--------------|-------------|----------------|
| Write-through | Higher (two writes) | Strong (cache always fresh) | None |
| Write-behind | Lowest (cache only) | Eventual | Yes, if cache dies pre-flush |
| Write-around | Normal (DB only) | Cache may be stale | None |

Write-behind is the fast-and-dangerous option: it absorbs write bursts and batches them to the database, but a cache failure before the flush loses acknowledged writes. It suits high-write, loss-tolerant workloads (metrics, counters) and is reckless for financial records.

## Update vs. Invalidate

A pivotal decision inside write-through: when data changes, do you **update** the cache entry with the new value, or **delete** it and let the next read repopulate?

```python
# Option A: update in place
cache.set(f"user:{user_id}", new_data, ex=300)

# Option B: invalidate, let read-through refill
cache.delete(f"user:{user_id}")
```

Invalidation (delete) is generally safer in distributed systems. Updating in place opens a race: two concurrent writers can interleave so that the cache ends up with an *older* value than the database. Deletion sidesteps this — the worst case is an extra cache miss, not a stale entry. The principle: **prefer deleting over updating cache entries on write**, because a miss is cheap and a stale-but-confident cache is expensive.

## The Cache-Aside Race Condition

The most famous distributed caching bug lives in cache-aside, in the interleaving of a reader's miss and a writer's update.

{{< mermaid >}}
sequenceDiagram
  participant R as Reader
  participant C as Cache
  participant D as Database
  participant W as Writer
  R->>C: GET key (miss)
  R->>D: read old value (v1)
  W->>D: write new value (v2)
  W->>C: delete key
  R->>C: SET key = v1 (stale!)
  Note over C: Cache now holds v1, DB holds v2 — stale until TTL expires
{{< /mermaid >}}

The reader read `v1`, the writer then committed `v2` and invalidated the cache — but the reader's `SET` lands *after* the invalidation, writing the stale `v1` back into a cache that should be empty. Now the cache serves `v1` until the TTL expires, even though the database says `v2`. This is not a transient blip; it is durable corruption of the cache.

Mitigations:

- **TTLs as a backstop.** A short TTL bounds how long the stale value survives. This doesn't prevent the race, it just limits the damage window — and it should always be present as a safety net regardless of other measures.
- **Delete-after-write ordering with a delay (double delete).** The writer deletes the key, writes the DB, then deletes again after a short delay, hoping the second delete clears any stale value a slow reader wrote in between.
- **Versioning / CAS.** Store a version with the value and only accept a `SET` if it carries a newer version, rejecting the stale write.
- **Single-flight on misses.** Serialize concurrent misses for the same key so only one reader populates, shrinking the window.

None is perfect; this race is fundamentally why strong consistency and caching are in tension.

## Distributed Invalidation Across Nodes

In a multi-node cache (or per-instance local caches), invalidating one copy is not enough — every node holding the key must be told. Approaches:

- **Centralized cache (Redis/Memcached):** there's one copy, so invalidation is a single `DEL`. Simple, but the cache is a network hop and a shared dependency.
- **Local in-process caches with pub/sub invalidation:** each app instance caches locally for speed; a write publishes an invalidation message on a channel that all instances subscribe to and act on. Fast reads, but the pub/sub message is best-effort and can be missed, leaving a node stale.
- **TTL-only local caches:** no invalidation messaging at all; every entry just expires. Dead simple, accepts bounded staleness as the cost.

```python
# Local cache + Redis pub/sub invalidation
def update_and_broadcast(user_id, data):
    db.update(user_id, data)
    redis.publish("invalidate", f"user:{user_id}")  # tell all nodes

def on_invalidate(message):
    local_cache.pop(message["data"], None)  # redis-py: payload is in "data"
```

The hard part is that pub/sub delivery is not guaranteed — a node that was disconnected when the message fired never gets it and serves stale data indefinitely. This is why local caches with pub/sub invalidation almost always *also* carry a TTL: the TTL is the guarantee, the pub/sub is the optimization that makes invalidation fast in the common case.

## Choosing a Strategy

The right combination depends on your read/write ratio and consistency needs.

| Workload | Recommended combination |
|----------|------------------------|
| Read-heavy, tolerant of brief staleness | Cache-aside + TTL |
| Read-heavy, needs freshness on write | Read-through + write-through (invalidate) |
| Write-heavy, loss-tolerant | Write-behind |
| Rarely-read writes | Write-around (don't pollute cache) |
| Strong consistency required | Reconsider caching, or version + CAS |

A subtle point: write-around pairs naturally with cache-aside for data that is written often but read rarely. Writing such data into the cache (as write-through would) just evicts hotter entries to hold data nobody will read before its TTL. Matching the write strategy to the *read likelihood* of the data is a frequently overlooked optimization.

## Conclusion

Cache invalidation is hard because a cache is a promise to tell the truth about data you don't own, and every strategy is a different answer to "how hard will we try to keep that promise." Cache-aside is simple and ubiquitous but harbors a stale-write race that TTLs only bandage. Write-through buys freshness at the price of write latency and is safest when it invalidates rather than updates. Write-behind trades durability for speed. And in any distributed setup, invalidating one node is the easy half — the hard half is reliably telling every other node, which is why a TTL almost always lurks underneath as the real guarantee. There is no strategy that makes the problem disappear; there are only strategies that move the inconsistency window to where you can live with it. Choosing well means knowing exactly where that window is and proving you can tolerate it.
