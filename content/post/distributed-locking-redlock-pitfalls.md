---
title: "Distributed Locking: Redlock Pitfalls"
date: 2026-01-30T10:15:00-04:00
draft: false
tags: [backend, distributed-systems, redis, concurrency, locking]
---

Distributed locks are one of those primitives that look trivial until you deploy them. A single-node mutex protects a critical section because the operating system guarantees that only one thread holds it at a time. The moment you spread that critical section across machines, the guarantees you took for granted evaporate. Clocks drift, processes pause, networks partition, and the lock you thought you held has quietly expired and been granted to someone else.

Redis-based locking, and the Redlock algorithm in particular, is the most common approach people reach for. It is also the most commonly misused. This post walks through how naive Redis locks fail, what Redlock actually promises, and why even a correct Redlock implementation does not give you the mutual exclusion guarantee most applications assume.

## What a distributed lock is actually for

There are two fundamentally different reasons to want a lock, and conflating them is the root of most disasters.

| Goal | Failure mode if lock breaks | Correctness requirement |
| --- | --- | --- |
| Efficiency | Duplicate work, wasted CPU | Soft — occasional double-execution is fine |
| Correctness | Data corruption, double-charge | Hard — two holders must never coexist |

If you only need efficiency — say, preventing two workers from regenerating the same cache entry — a simple lock with a timeout is perfectly adequate. If it occasionally fails, you do redundant work and move on. If you need correctness — preventing a customer from being charged twice — then you need to be far more paranoid, and as we will see, Redis alone cannot deliver that guarantee.

## The naive single-instance lock

The simplest Redis lock uses `SET` with `NX` (only set if not exists) and `PX` (expiry in milliseconds).

```python
import uuid
import redis

r = redis.Redis()

def acquire_lock(key, ttl_ms):
    token = str(uuid.uuid4())
    acquired = r.set(key, token, nx=True, px=ttl_ms)
    return token if acquired else None

def release_lock(key, token):
    # WRONG: not atomic
    if r.get(key) == token:
        r.delete(key)
```

This has a subtle but fatal bug in `release_lock`. Between the `get` and the `delete`, the lock can expire and be acquired by another client. You then delete *their* lock. The fix is to make release atomic with a Lua script that checks and deletes in one round trip.

```lua
-- release.lua: only delete if the token matches
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
else
    return 0
end
```

```python
RELEASE = r.register_script(open("release.lua").read())

def release_lock(key, token):
    return RELEASE(keys=[key], args=[token])
```

The random token is not optional. Without it, any client can release any lock, and expiry-then-reacquire races silently corrupt your mutual exclusion. This is the first pitfall: people implement the happy path and forget that release must be conditional and atomic.

## Why a single instance is not enough

Even with the atomic release, a single Redis instance is a single point of failure. If it dies, every lock is gone. The obvious fix — adding a replica — makes things *worse*, not better, because Redis replication is asynchronous.

Consider this sequence:

{{< mermaid >}}
sequenceDiagram
  participant C1 as "Client 1"
  participant M as "Redis Master"
  participant R as "Redis Replica"
  participant C2 as "Client 2"
  C1->>M: "SET lock token1 NX PX 30000"
  M-->>C1: "OK (lock held)"
  Note over M,R: "Master crashes before replicating"
  R->>R: "Promoted to master (no lock key)"
  C2->>R: "SET lock token2 NX PX 30000"
  R-->>C2: "OK (lock held)"
  Note over C1,C2: "Both clients now believe they hold the lock"
{{< /mermaid >}}

The master acknowledged the lock to Client 1 but crashed before the write propagated to the replica. The replica gets promoted, has no record of the lock, and happily grants it to Client 2. Mutual exclusion is violated. This is exactly the failover scenario Redlock was designed to address.

## The Redlock algorithm

Redlock distributes the lock across N independent Redis masters (typically 5), with no replication between them. To acquire the lock, a client:

1. Records the current time.
2. Tries to acquire the lock on all N instances sequentially, using the same key and token, with a small per-instance timeout.
3. Computes elapsed time. The lock is considered acquired only if the client obtained it on a **majority** (N/2 + 1) of instances *and* the total elapsed time is less than the lock TTL.
4. The effective validity time is the original TTL minus the elapsed acquisition time.
5. If acquisition failed (minority, or too slow), the client releases the lock on all instances.

```python
import time

def acquire_redlock(clients, key, token, ttl_ms):
    quorum = len(clients) // 2 + 1
    start = time.monotonic()
    acquired = 0
    for c in clients:
        try:
            if c.set(key, token, nx=True, px=ttl_ms):
                acquired += 1
        except redis.RedisError:
            pass  # treat as failure, keep going
    elapsed_ms = (time.monotonic() - start) * 1000
    validity = ttl_ms - elapsed_ms - 2  # subtract clock drift allowance
    if acquired >= quorum and validity > 0:
        return validity
    # failed: clean up everywhere
    for c in clients:
        try:
            release_lock_on(c, key, token)
        except redis.RedisError:
            pass
    return None
```

The majority requirement means a single instance failure or even a minority partition does not break the lock. That is a genuine improvement over the master-replica setup.

## The clock assumption that breaks Redlock

Redlock's correctness depends on a critical assumption: that expiry across all the Redis instances happens at roughly the same wall-clock rate, and that the client's measurement of elapsed time is accurate. This is where the famous critique from Martin Kleppmann comes in.

The problem is **timing**. Redlock assumes bounded clock drift and bounded process pauses. Real systems honor neither. Consider a stop-the-world garbage collection pause, a hypervisor descheduling your VM, or a slow page fault:

{{< mermaid >}}
graph TD
  A["Client acquires lock (TTL 30s)"] --> B["Client begins critical section"]
  B --> C["Long GC pause / VM freeze (40s)"]
  C --> D["Lock expires on all instances"]
  D --> E["Client 2 acquires the same lock"]
  E --> F["Original client resumes, still believes it holds the lock"]
  F --> G["Both clients write — corruption"]
{{< /mermaid >}}

The client has no way to know that it was paused for 40 seconds. When it wakes up, the lock object in its memory still says "valid," but the lock in Redis has long since expired and been granted elsewhere. No amount of quorum protects against this, because the failure is on the *client* side of the lock, not the storage side.

This is the deepest Redlock pitfall: it is an *unsafe* lock for correctness purposes, because it relies on timing assumptions that distributed systems cannot guarantee.

## Fencing tokens: the real fix

The only robust defense is a **fencing token** — a monotonically increasing number handed out with each lock grant. The protected resource (a database, a file store) must check the token and reject any write carrying a token lower than the highest it has seen.

{{< mermaid >}}
sequenceDiagram
  participant C1 as "Client 1"
  participant L as "Lock Service"
  participant S as "Storage"
  participant C2 as "Client 2"
  C1->>L: "acquire"
  L-->>C1: "token = 33"
  Note over C1: "GC pause, lock expires"
  C2->>L: "acquire"
  L-->>C2: "token = 34"
  C2->>S: "write (token 34)"
  S-->>C2: "OK, max token = 34"
  C1->>S: "write (token 33)"
  S-->>C1: "REJECTED (33 < 34)"
{{< /mermaid >}}

Even though Client 1 woke up thinking it held the lock, its stale token 33 is rejected. The storage layer becomes the final arbiter of mutual exclusion. Note that once you have fencing tokens enforced at the resource, the lock service itself only needs to provide monotonic tokens — and a single Redis instance with `INCR`, or any consensus system, suffices. Redlock's quorum stops being load-bearing.

## Practical guidance

A few rules that keep teams out of trouble:

- **Always use a random token and atomic release.** Non-negotiable, even for efficiency locks.
- **Set TTLs longer than your worst-case critical section, then add a watchdog.** Many clients (Redisson, for example) auto-extend the lock while the holder is alive, reducing the window for expiry-during-work.
- **For correctness, demand fencing tokens.** If your resource cannot reject stale writes, no distributed lock makes you safe.
- **Prefer purpose-built consensus for hard correctness.** ZooKeeper, etcd, or Consul give you linearizable sessions and ephemeral nodes designed for this exact problem.

Redlock is a reasonable tool for the efficiency case. Treat it as a correctness guarantee and you will eventually get the double-write, the double-charge, or the corrupted file. Match the tool to the requirement, and put the final check where the data actually lives.
