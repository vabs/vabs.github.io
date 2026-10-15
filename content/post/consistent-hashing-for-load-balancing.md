---
title: "Consistent Hashing for Load Balancing"
date: 2026-05-22T10:15:00-04:00
draft: false
tags: [backend, distributed-systems, load-balancing, hashing, scalability]
---

## Why naive hashing breaks under scaling

The simplest way to distribute keys across a set of `N` backend nodes is modulo hashing: pick a node with `hash(key) % N`. It is fast, stateless, and uniform when the hash function is good. The problem appears the moment `N` changes.

When you add or remove a single node, the divisor in `hash(key) % N` changes for every key. The mapping is recomputed globally, and the fraction of keys that move is roughly `(N-1)/N` — almost all of them. For a cache layer this means a near-total cache miss storm; for a sharded database it means a massive rebalancing operation; for sticky sessions it means most users get bounced to a different server.

| Scheme | Keys remapped when 1 of N nodes leaves |
| --- | --- |
| Modulo `hash % N` | ~ (N-1)/N (almost all) |
| Consistent hashing | ~ 1/N (only the departing node's share) |

Consistent hashing fixes exactly this: when a node joins or leaves, only the keys that belonged to (or now belong to) that node move. The rest stay put.

## The hash ring

The core idea is to map both nodes and keys onto the same circular keyspace — conventionally the integers `0` to `2^32 - 1` arranged as a ring. A key is owned by the first node encountered when walking clockwise from the key's position.

{{< mermaid >}}
graph TD
    K1["key: user:42 (pos 120)"] --> N_B["Node B (pos 200)"]
    K2["key: cart:7 (pos 410)"] --> N_C["Node C (pos 500)"]
    K3["key: sess:9 (pos 950)"] --> N_A["Node A (pos 50, wraps around)"]
    N_A --> N_B --> N_C --> N_A
{{< /mermaid >}}

When Node B is removed, only the keys that mapped to B (those between A and B clockwise) need to find a new owner — they walk forward to Node C. Keys owned by A and C are untouched. That locality is the entire value proposition.

A first implementation that sorts node positions and binary-searches for the successor:

```python
import bisect
import hashlib

def _hash(value: str) -> int:
    digest = hashlib.md5(value.encode()).digest()
    return int.from_bytes(digest[:4], "big")  # 32-bit position

class Ring:
    def __init__(self):
        self._positions = []      # sorted ints
        self._owner = {}          # position -> node name

    def add_node(self, node: str):
        pos = _hash(node)
        idx = bisect.bisect(self._positions, pos)
        self._positions.insert(idx, pos)
        self._owner[pos] = node

    def get_node(self, key: str) -> str:
        if not self._positions:
            raise RuntimeError("ring is empty")
        pos = _hash(key)
        idx = bisect.bisect(self._positions, pos)
        # wrap around the ring
        if idx == len(self._positions):
            idx = 0
        return self._owner[self._positions[idx]]
```

Lookups are `O(log V)` where `V` is the number of points on the ring, and insertions are `O(V)` because of the list shift (acceptable since node-set changes are rare relative to lookups).

## The load-skew problem and virtual nodes

A single point per node distributes ownership badly. With three nodes you get three arcs of essentially random length; one node might own 55% of the ring while another owns 15%. The variance of arc length is high when the number of points is small.

The standard fix is **virtual nodes** (vnodes): each physical node is hashed multiple times with different suffixes, placing many points on the ring. A physical node owning, say, 200 vnodes ends up with 200 small arcs scattered around the ring, and the law of large numbers smooths the total share toward `1/N`.

```python
class WeightedRing:
    def __init__(self, vnodes_per_node=200):
        self._vnodes = vnodes_per_node
        self._positions = []
        self._owner = {}

    def add_node(self, node: str, weight: int = 1):
        for i in range(self._vnodes * weight):
            pos = _hash(f"{node}#{i}")
            idx = bisect.bisect(self._positions, pos)
            self._positions.insert(idx, pos)
            self._owner[pos] = node
```

Two bonuses fall out of vnodes:

- **Weighting.** A node with double the capacity gets double the vnodes and therefore double the expected load. This is how you run heterogeneous hardware in one pool.
- **Smoother failover.** When a node dies, its 200 arcs are inherited by 200 different successors rather than dumping the whole load onto one neighbor.

The trade-off is memory and lookup cost: more points mean a larger sorted structure. A few hundred vnodes per node is the usual sweet spot, balancing distribution quality against overhead.

| vnodes per node | Approx. load std-dev across nodes |
| --- | --- |
| 1 | very high (~100%) |
| 20 | ~22% |
| 100 | ~10% |
| 500 | ~4.5% |

## Bounded loads and hotspots

Consistent hashing distributes *keys* evenly, not *traffic*. If one key is wildly popular — a celebrity user, a flash-sale product — its single owner node gets hammered regardless of how balanced the ring is. Vnodes do not help, because a key still resolves to exactly one node.

Two production techniques address this:

1. **Consistent hashing with bounded loads (CHWBL).** Google's variant caps each node at `(1 + ε)` times the average load. When a lookup lands on a node already at capacity, it skips forward to the next node with spare room. This bounds the worst-case overload at the cost of slightly weakening the "only 1/N keys move" guarantee.
2. **Replication of hot keys.** Map a hot key to the *next `R` nodes* clockwise and pick among them per request. This is also how you build redundancy for availability — the read can be served by any replica.

```python
def get_nodes(self, key: str, replicas: int = 3):
    """Return the next R distinct physical nodes clockwise."""
    if not self._positions:
        return []
    pos = _hash(key)
    idx = bisect.bisect(self._positions, pos)
    result, seen = [], set()
    n = len(self._positions)
    for offset in range(n):
        p = self._positions[(idx + offset) % n]
        node = self._owner[p]
        if node not in seen:
            seen.add(node)
            result.append(node)
            if len(result) == replicas:
                break
    return result
```

## Where it shows up in real systems

Consistent hashing is the quiet workhorse behind a lot of infrastructure:

- **Distributed caches** like memcached client libraries and the original Amazon Dynamo paper use it to map keys to cache servers so that adding capacity does not flush everything.
- **Database sharding** in Cassandra and ScyllaDB places token ranges on a ring; each node owns one or more token ranges (one per vnode), and replication walks the ring.
- **Layer-7 load balancers** (Envoy's `ring_hash` and `maglev` policies, HAProxy's `hash-type consistent`) use it to keep a client pinned to the same upstream for cache affinity and sticky sessions without a shared session store.

### Maglev: a different point in the design space

Google's Maglev hashing deserves a mention because it trades a little disruption-resistance for much better lookup performance and distribution. Instead of a sorted ring, Maglev builds a fixed-size lookup table (a flat array) by having each node "claim" slots according to a permutation derived from its hash. Lookups are a single array index — `O(1)`, cache-friendly, no binary search. The downside is that a node change can shuffle slightly more than `1/N` of entries, but the bound is still small and the constant-time lookup is worth it for a software load balancer handling millions of packets per second.

{{< mermaid >}}
graph LR
    REQ["Incoming request"] --> H["hash(5-tuple)"]
    H --> T["Maglev table lookup O(1)"]
    T --> U1["Upstream 1"]
    T --> U2["Upstream 2"]
    T --> U3["Upstream 3"]
{{< /mermaid >}}

## Operational pitfalls

A few things bite teams that adopt consistent hashing:

- **Weak hash functions.** Using something like Java's `String.hashCode()` produces clustered positions and terrible distribution. Use a well-mixed hash (MD5, SHA-1 truncated, or MurmurHash) for ring placement even though cryptographic strength is irrelevant — you want uniformity, not security.
- **Forgetting that clients must agree.** In a client-side scheme (like a memcached client pool) every client must compute the *same* ring. If clients disagree on the node list or vnode count, they route the same key to different nodes and your hit rate collapses. Distribute the topology through a single source of truth.
- **Resharding on transient failures.** If a node blips for two seconds and you remove it from the ring, you trigger a wave of key movement, then another wave when it returns. Use health-check hysteresis and prefer marking nodes *down* (so traffic fails over) without rebuilding the ring unless the change is durable.
- **Assuming even traffic.** As covered above, even key distribution is not even load. Always measure per-node request rates, not just per-node key counts.

## Summary

Consistent hashing solves a specific, sharp problem: keeping the key-to-node mapping stable as the node set changes, so that scaling and failures move only a `1/N` slice of data instead of nearly all of it. Virtual nodes turn the basic ring into something that distributes evenly and supports weighting. Bounded-load variants and replication handle the hotspot cases that the base algorithm ignores. When you reach for it, get the hash function right, make sure every participant shares one view of the topology, and remember that balanced keys are not the same as balanced traffic.
