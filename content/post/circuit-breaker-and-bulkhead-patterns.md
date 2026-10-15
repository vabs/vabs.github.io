---
title: "Circuit Breaker and Bulkhead Patterns"
date: 2026-02-22T10:15:00-04:00
draft: false
tags: [backend, resilience, circuit-breaker, bulkhead, microservices]
---

## Mental model

In a distributed system, the dangerous failures are not the ones that crash a single service — they are the ones that *cascade*. Service A calls service B. B gets slow. A's threads pile up waiting on B. A runs out of threads and can no longer serve *any* request, including ones that have nothing to do with B. Now A is down, and everything that calls A starts to fail too. A slow dependency three hops away has taken down your whole platform.

Circuit breaker and bulkhead are the two patterns that stop cascades. They attack the problem from different angles:

- **Circuit breaker** stops you from *calling* a failing dependency. When B is clearly broken, the breaker "trips" and A fails fast instead of waiting on doomed calls.
- **Bulkhead** *isolates* the resources used for each dependency, so when B's calls pile up, they consume only B's allotted threads/connections — never A's entire capacity.

You almost always want both. The breaker handles "stop trying"; the bulkhead handles "even while trying, don't let one dependency drown everyone."

{{< mermaid >}}
graph TD
    A["Service A"] --> CB["Circuit breaker"]
    CB -->|closed| B["Service B (call)"]
    CB -->|open| F["Fail fast / fallback"]
    A --> BH["Bulkhead pools"]
    BH --> P1["Pool for B (8 threads)"]
    BH --> P2["Pool for C (8 threads)"]
    BH --> P3["Pool for D (8 threads)"]
{{< /mermaid >}}

## Circuit breaker: the state machine

A circuit breaker is a small state machine wrapping every call to a dependency. It has three states.

- **Closed** — normal operation. Calls pass through. The breaker counts failures.
- **Open** — the dependency is considered down. Calls are rejected *immediately* without even attempting the network call. This is the key win: you stop wasting threads and time on calls that will fail anyway, and you give the struggling dependency room to recover.
- **Half-open** — after a cooldown, the breaker lets a limited number of trial calls through. If they succeed, it closes (recovered). If they fail, it re-opens (still broken).

{{< mermaid >}}
stateDiagram-v2
    [*] --> Closed
    Closed --> Open: failure threshold exceeded
    Open --> HalfOpen: after cooldown timeout
    HalfOpen --> Closed: trial calls succeed
    HalfOpen --> Open: trial call fails
{{< /mermaid >}}

The transition rules deserve care:

- **Closed to open** triggers on a *rate* or *count* of failures, not a single error. A common policy: trip if the failure ratio exceeds 50% over a rolling window of at least N requests. Requiring a minimum request volume prevents one error during a quiet period from tripping the breaker.
- **Open to half-open** is purely time-based: wait a cooldown (e.g. 30s) then probe.
- **Half-open** must limit concurrency to a handful of probes. If you let full traffic through on the first probe, you re-overwhelm a dependency that was just starting to breathe.

```python
import time

class CircuitBreaker:
    def __init__(self, fail_threshold=0.5, window=20, cooldown=30):
        self.fail_threshold = fail_threshold
        self.window = window
        self.cooldown = cooldown
        self.state = "closed"
        self.results = []          # recent True/False
        self.opened_at = 0.0

    def call(self, fn):
        if self.state == "open":
            if time.monotonic() - self.opened_at >= self.cooldown:
                self.state = "half_open"
            else:
                raise CircuitOpenError()   # fail fast
        try:
            result = fn()
        except Exception:
            self._record(False)
            raise
        self._record(True)
        return result

    def _record(self, ok: bool):
        if self.state == "half_open":
            # one probe decides the outcome
            self.state = "closed" if ok else "open"
            self.opened_at = time.monotonic()
            self.results.clear()
            return
        self.results.append(ok)
        self.results = self.results[-self.window:]
        if len(self.results) >= self.window:
            fail_rate = self.results.count(False) / len(self.results)
            if fail_rate >= self.fail_threshold:
                self.state = "open"
                self.opened_at = time.monotonic()
```

The breaker turns a *slow, resource-eating failure* into a *fast, cheap failure*. That conversion is what protects the caller's thread pool and gives the callee time to recover.

## Fallbacks: what "open" returns

When the breaker is open, the call fails fast — but fast failure is still failure unless you have something to return. A *fallback* is the graceful degradation path:

- A cached/stale value ("last known price").
- A sensible default ("recommendations unavailable, show top sellers").
- A queued write to process later.
- A clear, fast error so the user retries instead of hanging.

The discipline is that the fallback must not itself depend on the broken thing. A fallback that calls another instance of the same dead service is no fallback at all.

## Bulkhead: isolation by compartment

The name comes from ships: the hull is divided into watertight compartments so a breach in one does not flood the entire vessel. In software, you partition a shared resource — usually threads or connections — so that exhaustion in one partition cannot starve the others.

Without a bulkhead, all calls share one thread pool. When dependency B slows, its calls hold threads for the full timeout. With enough slow B-calls, every thread in the shared pool is parked on B, and calls to healthy dependencies C and D get no threads. B's illness becomes everyone's illness.

With a bulkhead, each dependency gets its own bounded pool:

```java
// each dependency confined to its own pool
ExecutorService poolB = new ThreadPoolExecutor(
    8, 8, 0L, TimeUnit.MILLISECONDS,
    new ArrayBlockingQueue<>(16),               // bounded queue
    new ThreadPoolExecutor.AbortPolicy());      // reject when full

try {
    Future<Result> f = poolB.submit(() -> callServiceB(req));  // throws RejectedExecutionException when full
    return f.get(200, TimeUnit.MILLISECONDS);   // per-call timeout
} catch (RejectedExecutionException | TimeoutException e) {
    return fallbackB();                          // shed load gracefully
}
```

Now if B saturates `poolB`, new B-calls are rejected (and fall back), but C and D still have their full pools. The blast radius is confined to one compartment.

There are two implementation styles:

| Style | How it isolates | Cost |
|-------|-----------------|------|
| Thread-pool bulkhead | separate pool per dependency | extra threads, context-switch overhead, allows timeouts on blocking calls |
| Semaphore bulkhead | a counter caps concurrent calls per dependency | cheap, but caller's own thread blocks (no separate timeout) |

Thread-pool bulkheads cost more but let you enforce timeouts and isolate even badly-behaved blocking clients. Semaphore bulkheads are lighter and fine when the calls are already non-blocking/async.

## Why you need both, plus timeouts

These patterns are layers, and a missing layer leaves a hole:

- **Timeouts** are the foundation. Without an aggressive per-call timeout, a thread waits indefinitely on a hung dependency — and *nothing else can save you*. The breaker can't detect failures that never return; the bulkhead just fills up with parked threads. Always set timeouts first.
- **Bulkheads** bound *how much* of your capacity any one dependency can consume while it's slow.
- **Circuit breakers** stop you from *spending* even that bounded capacity on a dependency that is clearly down, and give it room to heal.

| Pattern | Problem solved | What happens without it |
|---------|----------------|-------------------------|
| Timeout | unbounded waits | threads park forever |
| Bulkhead | one dependency hogs all threads | local exhaustion, total outage |
| Circuit breaker | hammering a dead dependency | wasted capacity, no recovery window |
| Fallback | nothing to return on failure | fast errors still break UX |

{{< mermaid >}}
graph TD
    Req["Incoming request"] --> TO["Timeout guard"]
    TO --> BH["Bulkhead: bounded pool"]
    BH --> CB["Circuit breaker"]
    CB -->|closed| Dep["Call dependency"]
    CB -->|open| FB["Fallback"]
    BH -->|pool full| FB
    Dep -->|timeout/error| FB
{{< /mermaid >}}

## Operational pitfalls

- **Thresholds too sensitive.** A breaker that trips on transient blips causes more outages than it prevents. Require a minimum request volume and a meaningful failure ratio.
- **No jitter on recovery.** If every instance's breaker opens and half-opens on the same schedule, they all probe the dependency simultaneously — a synchronized thundering herd. Add jitter to cooldowns.
- **Counting client errors as failures.** A 400 (bad request) is the caller's fault, not the dependency's. Counting 4xx toward the failure rate trips the breaker for healthy services. Only count 5xx, timeouts, and connection errors.
- **Unbounded queues in bulkheads.** A bulkhead with an unbounded queue isn't a bulkhead — the queue grows until you OOM. Bound the queue and reject (then fall back) when full.
- **No observability.** Emit metrics for breaker state transitions and bulkhead rejections. A silently-open breaker masking a real outage is a debugging nightmare.

## Takeaways

Cascading failure is the defining risk of distributed systems, and it spreads through shared, unbounded resources held by slow dependencies. Timeouts cap how long any call can wait; bulkheads cap how much of your capacity one dependency can consume; circuit breakers stop you from spending capacity on a dependency that's already down and grant it a recovery window; fallbacks make the resulting fast-failures graceful. None of these is sufficient alone — they are defense in depth. Tune thresholds conservatively, only count real server-side failures, bound every queue, add jitter, and instrument the state transitions so you can see the breaker doing its job.
