---
title: "API Gateway Throttling & Caching Layers"
date: 2026-04-05T13:21:36-04:00
draft: false
featured: false
tags: [backend, api-gateway, rate-limiting, caching, scalability]
---

An API gateway is the front door to your backend, and the two responsibilities that most determine whether that door holds up under load are throttling and caching. Throttling protects your services from being overwhelmed; caching prevents them from doing the same work twice. Done well, the gateway absorbs traffic that would otherwise flatten your origin. Done badly, it either lets a stampede through or serves stale, incorrect data to every client. This post examines the algorithms behind gateway throttling, where caching belongs in the request path, and how the two interact.

## Why the Gateway Is the Right Place

You can rate-limit and cache inside individual services, but the gateway has a structural advantage: it sees *all* traffic before it fans out, and it can reject or serve cheaply without ever consuming backend resources. A request throttled at the gateway costs almost nothing; the same request throttled inside a service has already paid for connection handling, deserialization, and possibly a database round trip before being rejected.

{{< mermaid >}}
graph TD
  A["Client request"] --> B["API Gateway"]
  B --> C{"Throttle check"}
  C -->|"Over limit"| D["429 Too Many Requests"]
  C -->|"Under limit"| E{"Cache hit?"}
  E -->|"Yes"| F["Return cached response"]
  E -->|"No"| G["Forward to origin"]
  G --> H["Origin service"]
  H --> I["Cache response"]
  I --> J["Return to client"]
{{< /mermaid >}}

Note the ordering: **throttle first, then check cache.** A throttled client should be rejected before it can even benefit from the cache, otherwise abusive clients get cheap cached responses and your rate limit means little for protecting *capacity*. Some designs invert this deliberately (serve cache even to throttled clients to reduce origin load), but the default should be throttle-then-cache.

## Throttling Algorithms

Not all rate limiters behave the same under bursty traffic. The choice of algorithm determines whether a client can spike or must spread requests evenly.

| Algorithm | Burst behavior | Memory | Notes |
|-----------|---------------|--------|-------|
| Fixed window | Allows 2x burst at window edges | Tiny | Simple, has the boundary spike problem |
| Sliding window log | Exact, smooth | High (stores timestamps) | Accurate but costly at scale |
| Sliding window counter | Smooth approximation | Low | Best general-purpose choice |
| Token bucket | Allows controlled bursts | Low | Great when bursts are acceptable |
| Leaky bucket | Strictly smooth output | Low | Enforces a constant drain rate |

### The fixed-window boundary problem

A fixed window of "100 requests per minute" resets the counter at each minute boundary. A client can send 100 requests at 0:59 and another 100 at 1:00 — 200 requests in two seconds, double the intended rate. This boundary burst is why fixed windows are a poor fit for protecting capacity.

### Token bucket, in detail

Token bucket is the workhorse. A bucket holds up to `capacity` tokens and refills at `rate` tokens per second. Each request consumes a token; if the bucket is empty, the request is throttled.

```python
import time

class TokenBucket:
    def __init__(self, capacity, refill_rate):
        self.capacity = capacity
        self.refill_rate = refill_rate
        self.tokens = capacity
        self.last = time.monotonic()

    def allow(self, cost=1):
        now = time.monotonic()
        elapsed = now - self.last
        self.tokens = min(self.capacity, self.tokens + elapsed * self.refill_rate)
        self.last = now
        if self.tokens >= cost:
            self.tokens -= cost
            return True
        return False
```

The bucket naturally permits short bursts up to `capacity` while enforcing the average `refill_rate` over time — exactly the behavior most APIs want, since clients legitimately batch work. The `cost` parameter lets expensive endpoints consume multiple tokens, weighting the limit by actual resource consumption rather than raw request count.

## Distributed Rate Limiting

A single-node token bucket breaks the moment you run multiple gateway instances, because each instance has its own bucket and a client hitting all of them gets N times the intended limit. The standard solution is a shared store, typically Redis, where the counter lives centrally.

```lua
-- Atomic token bucket in Redis (Lua script)
local tokens = tonumber(redis.call("get", KEYS[1]) or ARGV[1])
local now = tonumber(ARGV[3])
local last = tonumber(redis.call("get", KEYS[2]) or now)
local refill = (now - last) * tonumber(ARGV[2])
tokens = math.min(tonumber(ARGV[1]), tokens + refill)
if tokens >= 1 then
  tokens = tokens - 1
  redis.call("set", KEYS[1], tokens)
  redis.call("set", KEYS[2], now)
  return 1
end
return 0
```

The script runs atomically, eliminating the race where two instances both read "1 token left" and both allow. The tradeoff is a network round trip per request to Redis. For very high throughput, gateways use a hybrid: a local bucket that allows a small burst optimistically and periodically reconciles with the central counter, trading perfect accuracy for lower latency.

## Communicating Limits to Clients

A throttle that returns a bare `429` is hostile. Well-behaved gateways tell clients what happened and when to retry, using standard (`Retry-After`) and IETF-draft (`RateLimit-*`) headers:

```
HTTP/1.1 429 Too Many Requests
RateLimit-Limit: 100
RateLimit-Remaining: 0
RateLimit-Reset: 37
Retry-After: 37
```

`Retry-After` is the contract that lets a client back off intelligently instead of hammering. Combined with client-side exponential backoff and jitter, this prevents the thundering-herd retry storm where every throttled client retries at exactly the same moment.

## Caching at the Gateway

Gateway caching stores responses keyed on request attributes and serves them without touching the origin. The make-or-break decision is the **cache key**.

A naive key of just the path collapses responses that should differ. A correct key includes everything that affects the response:

- Path and query string
- Relevant headers (`Accept`, `Accept-Language`)
- Auth context **only if** responses are user-specific

That last point is the most dangerous caching bug in existence: caching a user-specific response under a key that omits the user identity, then serving user A's data to user B. Any endpoint that returns personalized data must either not be cached at the gateway or must include the auth principal in the key. The `Vary` header exists precisely to declare which request headers participate in the cache key.

### TTL and invalidation

```yaml
# Gateway cache policy
cache:
  enabled: true
  ttl: 60s
  key:
    - path
    - query: ["page", "limit"]
    - header: ["Accept"]
  cache_control_override: false
```

Two philosophies govern freshness:

| Approach | Mechanism | Tradeoff |
|----------|-----------|----------|
| TTL-based | Entry expires after N seconds | Simple, but serves stale data within the window |
| Event-based invalidation | Origin purges keys on write | Fresh, but requires the origin to know cache keys |

TTL is easy and self-healing but always permits staleness up to the TTL. Event-based invalidation is precise but couples the origin to the gateway's keying scheme. Many systems combine a short TTL (a safety net) with explicit purges on known mutations (precision where it matters).

## The Cache Stampede

When a popular cached entry expires, every concurrent request for it misses simultaneously and all of them hit the origin at once — a stampede that can knock over the very backend the cache was protecting.

{{< mermaid >}}
graph TD
  A["Hot key expires"] --> B["1000 concurrent requests miss"]
  B --> C["All 1000 hit origin"]
  C --> D["Origin overloaded"]
  D --> E["Latency spike / failures"]
  F["Mitigation: request coalescing"] -.-> G["1 request to origin, 999 wait"]
{{< /mermaid >}}

The mitigations:

- **Request coalescing (single-flight):** when N requests miss the same key, only one goes to the origin and the rest wait for its result. This is the most important stampede defense.
- **Stale-while-revalidate:** serve the expired entry immediately while refreshing it in the background, so clients never wait on a cold origin.
- **Jittered TTLs:** add randomness to expiry so a batch of entries written together does not all expire at the same instant.

## How Throttling and Caching Reinforce Each Other

These two mechanisms are complementary, not independent. A high cache hit ratio means most requests never reach the origin, so the throttle's real job becomes protecting against *cache-miss* traffic — the requests that actually cost something. This suggests a sophisticated policy: looser limits on cacheable, idempotent reads (they're cheap once warm) and tighter limits on writes and uncacheable endpoints (they always hit the origin). Treating every endpoint with one global limit ignores that the gateway already knows which requests are expensive.

## Conclusion

The gateway's throttling and caching layers are the cheapest place in your architecture to shed load and avoid redundant work, but both are full of sharp edges: the fixed-window boundary burst, the per-instance limit multiplication in distributed setups, the catastrophic user-data cache key leak, and the stampede when a hot key expires. The teams that get this right pick a burst-aware algorithm like token bucket, centralize counters carefully, key caches on everything that affects the response, and defend hot keys with coalescing and stale-while-revalidate. The payoff is a front door that stays standing when traffic triples — which is exactly the day you'll find out whether you built it correctly.
