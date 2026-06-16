---
title: "Memory Barriers and CPU Cache Coherence"
date: 2026-05-09T16:33:00-04:00
draft: false
featured: false
tags: [backend, concurrency, cpu, performance, memory-model]
---

## When the hardware lies to you

You write code that stores to one variable and then another. You assume the rest of the system sees those stores happen in that order. On a single thread, the CPU guarantees this illusion. Across threads on different cores, the guarantee evaporates. The store you issued first might become visible to another core *after* the store you issued second. Your program is correct as written and broken as executed.

This is not a bug in the CPU. It's the deliberate result of optimizations, store buffers, out-of-order execution, and per-core caches, that exist to make single-threaded code fast. Memory barriers (also called fences) are the tools that let you reclaim ordering when you need it. To use them correctly you have to understand what the hardware is actually doing underneath, starting with cache coherence.

## Cache coherence and MESI

Each CPU core has its own L1 and L2 caches. The same memory location can sit in multiple cores' caches simultaneously. The cache coherence protocol keeps these copies consistent so that a write by one core eventually becomes visible to others. The dominant protocol is MESI, named for the four states a cache line can be in.

| State | Meaning |
|-------|---------|
| Modified | This core has the only copy and it's dirty (differs from memory) |
| Exclusive | This core has the only copy and it's clean |
| Shared | Multiple cores may have clean copies |
| Invalid | This copy is stale and cannot be used |

When core A wants to write to a line that core B has cached, A must send an invalidation message and wait for B to acknowledge. Only then can A move its line to Modified and perform the write. This handshake guarantees coherence but introduces latency, and that latency is the seed of the optimizations that break ordering.

{{< mermaid >}}
graph TD
  I["Invalid"] -->|"read miss, others have it"| S["Shared"]
  I -->|"read miss, no other copy"| E["Exclusive"]
  E -->|"local write"| M["Modified"]
  S -->|"local write, invalidate others"| M
  M -->|"another core reads"| S
  S -->|"another core writes"| I
{{< /mermaid >}}

Crucially, MESI guarantees coherence per cache line, but it does *not* by itself guarantee the *ordering* of writes to *different* locations as seen by other cores. That's where store buffers come in.

## Store buffers and why ordering breaks

Waiting for an invalidation acknowledgment on every write would stall the core badly. To avoid this, each core has a **store buffer**: a small queue where writes are parked while the coherence handshake completes in the background. The core records the write in the store buffer and immediately moves on, treating the write as done from its own perspective.

The consequence: a write sitting in the store buffer is visible to the writing core (which checks its own store buffer on loads, a feature called store forwarding) but *not yet visible to other cores*. If two cores each park a write and then read the other's variable, both can read stale values, because neither write has drained to a place the other can see.

This is the famous store buffer reordering, and it's the root of the classic two-thread litmus test:

```c
// Initially x = 0, y = 0. Shared variables.
// Thread 1:                 Thread 2:
x = 1;                       y = 1;
int r1 = y;                  int r2 = x;
```

Intuition says you can't end with `r1 == 0 && r2 == 0`, because at least one store should have happened first. But on x86 and most real hardware, both stores can sit in their respective store buffers when the loads execute, so both threads read `0`. The "impossible" outcome is routine.

```c
// invalidate queues on the receiving side add a symmetric delay:
// an invalidation can be acknowledged but not yet applied, so a
// core may briefly keep reading a stale (now-invalid) cached value.
```

So there are two asymmetric buffers in play. Store buffers delay when a write *leaves* a core; invalidate queues delay when an invalidation *takes effect* on a remote core. Both contribute to apparent reordering, and both are what barriers control.

## Memory barriers: reclaiming order

A memory barrier is an instruction that constrains the order in which memory operations become visible. There are three conceptual kinds.

A **store barrier** (write fence) ensures all stores before it drain from the store buffer before any store after it. It forces your writes to become visible to other cores in program order.

A **load barrier** (read fence) ensures all loads before it complete, and pending invalidations are applied, before any load after it. It forces your reads to see writes in program order.

A **full barrier** does both: no memory operation of any kind may move across it.

```c
// Conceptual fix for the store-buffer litmus test:
// Thread 1:
x = 1;
smp_mb();         // full barrier: drain store buffer
int r1 = y;       // now this load sees a coherent view

// Thread 2:
y = 1;
smp_mb();
int r2 = x;
```

With full barriers on both sides, the `r1 == 0 && r2 == 0` outcome becomes genuinely impossible. The barrier forces the store buffer to drain before the load proceeds.

## Hardware memory models differ wildly

This is where portability gets dangerous. Different CPU architectures provide different default ordering guarantees, so the *same* lock-free code can be correct on one and broken on another.

| Architecture | Memory model | Reordering allowed |
|--------------|--------------|--------------------|
| x86 / x86-64 | TSO (Total Store Order) | Only store-load reordering |
| ARM (AArch64) | Weak | Most reorderings allowed |
| POWER | Weak | Most reorderings allowed |
| RISC-V (RVWMO) | Weak | Most reorderings allowed |

x86 is *strongly ordered*: the only reordering it permits is store-load (a later load passing an earlier store, exactly the litmus test above). It never reorders store-store or load-load. This lulls developers into a false sense of security. Code that "works" on x86 because it relies on store-store ordering for free will break spectacularly on ARM, which freely reorders stores.

This is why you must never reason about lock-free correctness by testing on x86 alone. The strong x86 model hides bugs that weak models expose.

## The C++ and Java memory models

Rather than write architecture-specific barriers, modern languages give you a portable abstraction: the language memory model. You express *what ordering you need* and the compiler emits the right barriers (or none, on architectures that don't need them) for the target.

In C++, `std::atomic` operations take a memory order parameter:

```cpp
std::atomic<bool> ready{false};
int data = 0;

// Producer
data = 42;
ready.store(true, std::memory_order_release);   // release fence

// Consumer
if (ready.load(std::memory_order_acquire)) {    // acquire fence
    assert(data == 42);                         // guaranteed to hold
}
```

The acquire/release pair is the workhorse of lock-free code. A **release** store guarantees that all writes before it (here, `data = 42`) are visible to any thread that performs an **acquire** load seeing that store. This is exactly the publish/subscribe pattern: the producer publishes data with a release, the consumer acquires it and is guaranteed to see everything published before.

| memory_order | Guarantee | Cost |
|--------------|-----------|------|
| relaxed | Atomicity only, no ordering | Cheapest |
| acquire | Later ops can't move before this load | Cheap on x86 |
| release | Earlier ops can't move after this store | Cheap on x86 |
| acq_rel | Both, for read-modify-write | Moderate |
| seq_cst | Global total order across all threads | Most expensive |

The default, `seq_cst`, is the easiest to reason about (everything appears in one global order) but the most expensive, often requiring full barriers. Reaching for `relaxed` where you only need atomicity (like incrementing a statistics counter) avoids unnecessary fences.

Java provides the same semantics through `volatile` (which gives acquire/release semantics on reads/writes) and the `java.util.concurrent.atomic` package, with VarHandles offering finer-grained control since Java 9.

## A concrete publish pattern

Here's the canonical safe-publication pattern that ties it together:

{{< mermaid >}}
graph LR
  A["Producer writes data"] --> B["Producer: release store flag"]
  B --> C["Flag visible to consumer"]
  C --> D["Consumer: acquire load flag"]
  D --> E["Consumer sees all prior writes"]
{{< /mermaid >}}

```cpp
// Lock-free single-producer publication, portable across architectures.
struct Message { int a, b, c; };
Message msg;
std::atomic<bool> published{false};

void produce() {
    msg.a = 1; msg.b = 2; msg.c = 3;   // plain writes
    published.store(true, std::memory_order_release);
}

bool consume(Message& out) {
    if (!published.load(std::memory_order_acquire))
        return false;
    out = msg;                          // guaranteed to see a,b,c
    return true;
}
```

The plain writes to `msg` need no atomics of their own. The release/acquire pair on `published` creates a happens-before relationship that drags all the prior writes along with it. The compiler emits a store barrier on the release and a load barrier on the acquire, and on x86 these often compile to ordinary instructions because TSO already provides the ordering.

## Practical guidance

Prefer the language memory model over hand-written barriers; it's portable and the compiler knows the target's quirks. Use acquire/release for publish/subscribe handoffs, which covers the vast majority of lock-free needs. Reserve `seq_cst` for when you genuinely need a global order across multiple variables, and reach for `relaxed` only when ordering truly doesn't matter, such as independent counters.

Above all, never validate concurrent code on x86 alone. Its strong TSO model silently masks missing barriers that a weakly-ordered ARM or POWER chip will surface as rare, maddening, production-only corruption. Test on weak hardware, or use a tool like a thread sanitizer and a model checker, before you trust lock-free code.

The hardware optimizations that make your single-threaded code fast are precisely what make multi-threaded ordering subtle. Memory barriers are how you tell the hardware: here, and only here, I need you to stop pretending.
