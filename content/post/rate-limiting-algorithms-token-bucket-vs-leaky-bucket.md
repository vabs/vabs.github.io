---
title: "Rate Limiting Algorithms: Token Bucket vs Leaky Bucket"
date: 2026-02-20T16:25:00-04:00
draft: false
tags: [backend, rate-limiting, algorithms, distributed-systems, throttling]
---

## Mental model

Rate limiting answers a deceptively simple question: *should this request be allowed right now?* The hard part is the "right now." A naive counter — "max 100 requests per minute" — is full of edge cases around how time is divided and whether bursts are allowed. The mature algorithms exist precisely to handle those edges cleanly.

Two algorithms dominate the conversation, and they are often confused because both use a "bucket" metaphor. They are not the same:

- **Token bucket** shapes how requests *enter*. The bucket holds tokens; a request must take a token to proceed. Tokens refill at a steady rate. This *permits bursts* up to the bucket size.
- **Leaky bucket** shapes how requests *leave*. The bucket holds queued requests; they drain (process) at a fixed rate. This *smooths bursts* into a constant output stream.

Token bucket controls the *average rate while allowing bursts*. Leaky bucket enforces a *constant output rate*. That distinction drives every design choice.

{{< mermaid >}}
graph LR
    subgraph "Token bucket"
    R1["Refill at rate r"] --> B1["Bucket cap = b tokens"]
    Req1["Request"] --> T{"Token available?"}
    B1 --> T
    T -->|yes| Allow1["Allow, take token"]
    T -->|no| Deny1["Reject / wait"]
    end
{{< /mermaid >}}

## Token bucket

A token bucket has two parameters: capacity `b` (max tokens, the burst size) and refill rate `r` (tokens per second, the sustained rate). Tokens accumulate up to `b`. Each request consumes one token. If the bucket is empty, the request is rejected (or delayed).

The elegant implementation does not run a background timer to add tokens. Instead it computes tokens lazily on each request based on elapsed time since the last refill:

```python
import time

class TokenBucket:
    def __init__(self, capacity: float, refill_per_sec: float):
        self.capacity = capacity
        self.rate = refill_per_sec
        self.tokens = capacity
        self.last = time.monotonic()

    def allow(self, cost: float = 1.0) -> bool:
        now = time.monotonic()
        # refill based on elapsed time, capped at capacity
        self.tokens = min(self.capacity,
                          self.tokens + (now - self.last) * self.rate)
        self.last = now
        if self.tokens >= cost:
            self.tokens -= cost
            return True
        return False
```

Two properties make token bucket the default choice for APIs:

- **Burst tolerance.** A client that has been idle accumulates up to `b` tokens and can fire a burst of `b` requests instantly. This matches real traffic — clients are bursty — while still bounding the long-run average to `r`.
- **Weighted costs.** Because each request consumes a configurable number of tokens, you can charge expensive operations more (`cost=5` for a heavy query, `cost=1` for a cheap one). This is how API quotas with "cost units" work.

## Leaky bucket

Leaky bucket models a bucket with a hole. Incoming requests are water poured in; they leak out at a constant rate `r`. If the bucket (queue) overflows its capacity, excess requests are dropped. The output — the rate at which requests are actually processed — is perfectly constant regardless of how bursty the input is.

```python
class LeakyBucket:
    def __init__(self, capacity: int, leak_per_sec: float):
        self.capacity = capacity      # max queued
        self.rate = leak_per_sec      # constant drain
        self.level = 0.0
        self.last = time.monotonic()

    def allow(self) -> bool:
        now = time.monotonic()
        # leak out whatever drained since last check
        self.level = max(0.0, self.level - (now - self.last) * self.rate)
        self.last = now
        if self.level + 1 <= self.capacity:
            self.level += 1
            return True
        return False  # bucket full -> drop
```

There are two flavors. The **queue** variant actually buffers requests and releases them at the fixed rate (true traffic shaping — adds latency but never drops within capacity). The **meter** variant, shown above, is effectively a counter that rejects when full; it is mathematically the same as a token bucket inverted, which is why people conflate them.

The headline property: leaky bucket produces a **smooth, constant output**. A spike of 1000 simultaneous requests does not hit your backend as 1000 simultaneous requests — they drain at `r` per second. That is its reason to exist.

{{< mermaid >}}
sequenceDiagram
    participant C as Bursty client
    participant LB as Leaky bucket queue
    participant S as Backend
    C->>LB: 20 requests at once
    Note over LB: Queue fills to capacity, rest dropped
    loop every 1/r seconds
        LB->>S: 1 request (constant rate)
    end
{{< /mermaid >}}

## Side by side

| Property | Token bucket | Leaky bucket |
|----------|-------------|--------------|
| Controls | input/admission rate | output/processing rate |
| Bursts | allows up to bucket size | smooths into constant stream |
| Output shape | bursty (up to b at once) | perfectly constant |
| Latency added | none (instant allow/reject) | queue variant adds delay |
| Weighted requests | natural (variable cost) | awkward |
| Idle credit | accumulates tokens | none |
| Best for | API quotas, fairness with bursts | protecting fragile downstreams |

The mental shortcut: **token bucket protects the consumer's quota; leaky bucket protects the producer's backend.** If you want clients to be able to burst but not exceed an average, token bucket. If you want your database to never see more than 200 writes/sec no matter what, leaky bucket queue.

## Related algorithms worth knowing

Two windowing approaches show up alongside the buckets:

- **Fixed window counter.** Count requests per discrete time window (e.g. per calendar minute), reset at the boundary. Trivial to implement but has a *boundary burst* bug: a client can send `limit` requests at 11:59:59 and `limit` again at 12:00:00 — `2*limit` in two seconds, straddling the reset.
- **Sliding window log / sliding window counter.** Track timestamps (or weighted partial windows) so the limit applies to any rolling interval. Fixes the boundary burst at the cost of more state. The sliding window counter approximates the log cheaply by blending the current and previous window proportionally.

```python
# sliding window counter approximation
def allowed(prev_count, cur_count, limit, elapsed_frac):
    estimate = prev_count * (1 - elapsed_frac) + cur_count
    return estimate < limit
```

## Distributed rate limiting

Single-process buckets are easy. The real engineering is making the limit hold across N application instances behind a load balancer. Each instance with its own local bucket means the effective global limit is `N * local_limit` — usually wrong.

The standard solution is centralized state in Redis. The bucket state lives in Redis and every instance reads/writes it. The catch: the read-modify-write must be **atomic**, or two instances racing on the same key will both think a token is available. Use a Lua script so the whole refill-and-decrement runs atomically server-side:

```lua
-- token bucket in Redis (KEYS[1]=bucket key)
-- ARGV: capacity, rate, now, cost
local b = redis.call('HMGET', KEYS[1], 'tokens', 'ts')
local tokens = tonumber(b[1]) or tonumber(ARGV[1])
local ts = tonumber(b[2]) or tonumber(ARGV[3])
local delta = math.max(0, tonumber(ARGV[3]) - ts) * tonumber(ARGV[2])
tokens = math.min(tonumber(ARGV[1]), tokens + delta)
local cost = tonumber(ARGV[4])
local allowed = tokens >= cost
if allowed then tokens = tokens - cost end
redis.call('HMSET', KEYS[1], 'tokens', tokens, 'ts', ARGV[3])
redis.call('EXPIRE', KEYS[1], 3600)
return allowed and 1 or 0
```

Tradeoffs to weigh in distributed mode:

- **Latency.** Every check is now a network round trip. Many systems use a hybrid: a small local bucket for the common case plus periodic reconciliation with Redis, accepting some slop for speed.
- **Failure mode.** If Redis is down, do you fail open (allow everything — protects availability, risks overload) or fail closed (reject everything — protects backend, risks outage)? Decide deliberately.
- **Hot keys.** A single popular key (e.g. a global limit) funnels all traffic to one Redis slot. Shard or use approximate counting if that becomes the bottleneck.

## Responding to clients

Rejection should be informative. Return HTTP 429 with headers so clients can back off intelligently:

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 12
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1718900000
```

`Retry-After` tells a well-behaved client exactly when to try again, which prevents the thundering-herd retry storm that turns a rate limit into a self-inflicted outage. Pair server limits with client-side exponential backoff and jitter.

## Takeaways

Token bucket and leaky bucket solve adjacent but distinct problems: token bucket admits requests while permitting bounded bursts and per-request costs, making it the natural fit for API quotas; leaky bucket enforces a constant output rate, making it the tool for shielding fragile downstreams from spikes. Fixed and sliding windows are simpler counting cousins with a known boundary-burst pitfall that sliding windows fix. In production the algorithm is the easy half — the hard half is enforcing the limit atomically across many instances (Redis + Lua), choosing your fail-open/closed behavior, and returning 429s with `Retry-After` so clients back off instead of stampeding.
