---
title: "Lock-Free Data Structures"
date: 2026-05-18T13:27:00-04:00
draft: false
featured: false
tags: [backend, concurrency, cpu, performance, data-structures]
---

## What lock-free actually means

"Lock-free" is one of the most abused terms in concurrent programming. It does not mean "no locks in the code," and it does not mean "fast." It is a precise progress guarantee: a data structure is lock-free if, at any point, *at least one* thread is guaranteed to make progress in a finite number of steps, regardless of what other threads do, even if some of them are suspended mid-operation.

This matters because it rules out a specific failure mode. With locks, if a thread holding a lock is descheduled, every other thread waiting on that lock is stuck until it resumes. A lock-free structure has no such single point of stalling. There's a stronger property, **wait-free**, where *every* thread makes progress in bounded steps, but it's far harder to achieve and often not worth the complexity.

| Property | Guarantee | Practicality |
|----------|-----------|--------------|
| Blocking (locks) | None; can deadlock or stall | Simple, common |
| Obstruction-free | Progress if run in isolation | Rare |
| Lock-free | Some thread always progresses | Achievable, valuable |
| Wait-free | Every thread progresses in bounded steps | Hard, sometimes overkill |

The payoff for lock-free is resilience to scheduling and elimination of lock contention. The price is that the algorithms are subtle, error-prone, and built on a foundation of atomic primitives and careful memory ordering.

## The foundation: compare-and-swap

Almost every lock-free structure is built on a single atomic primitive: **compare-and-swap** (CAS). CAS atomically does the following: "if this memory location still holds the value I expect, replace it with this new value, and tell me whether you succeeded."

```c
// Atomic compare-and-swap, conceptually:
bool CAS(T* addr, T expected, T desired) {
    if (*addr == expected) {   // all of this happens
        *addr = desired;       // as one indivisible
        return true;           // atomic operation
    }
    return false;
}
```

The power of CAS is that it lets you implement optimistic concurrency. You read the current state, compute a new state, and attempt to swap it in *only if nothing changed underneath you*. If something did change (another thread won the race), CAS fails and you retry. This read-compute-CAS-retry loop is the heartbeat of lock-free programming.

```cpp
// The canonical CAS retry loop in C++.
std::atomic<int> counter{0};

void increment() {
    int old = counter.load(std::memory_order_relaxed);
    while (!counter.compare_exchange_weak(
               old, old + 1,
               std::memory_order_release,
               std::memory_order_relaxed)) {
        // old is updated to the current value on failure; just retry.
    }
}
```

If two threads race, one CAS succeeds and one fails. The failing thread retries with the fresh value. Notice the lock-free guarantee falling out naturally: one thread always wins each round, so the system as a whole always progresses.

{{< mermaid >}}
graph TD
  A["Read current value"] --> B["Compute new value"]
  B --> C["CAS: swap if unchanged"]
  C -->|"success"| D["Done"]
  C -->|"failed: value changed"| A
{{< /mermaid >}}

## A lock-free stack (Treiber stack)

The simplest non-trivial lock-free structure is the Treiber stack. It's a singly linked list where push and pop both operate on the head via CAS.

```cpp
template <typename T>
class LockFreeStack {
    struct Node { T value; Node* next; };
    std::atomic<Node*> head{nullptr};

public:
    void push(T value) {
        Node* node = new Node{value, nullptr};
        node->next = head.load(std::memory_order_relaxed);
        while (!head.compare_exchange_weak(
                   node->next, node,
                   std::memory_order_release,
                   std::memory_order_relaxed)) {
            // node->next refreshed on failure; retry.
        }
    }

    bool pop(T& out) {
        Node* old = head.load(std::memory_order_acquire);
        while (old &&
               !head.compare_exchange_weak(
                   old, old->next,
                   std::memory_order_acquire,
                   std::memory_order_acquire)) {  // old is dereferenced next round
            // old refreshed on failure; retry.
        }
        if (!old) return false;
        out = old->value;
        delete old;          // DANGER: this is where ABA and
        return true;         // use-after-free bugs live.
    }
};
```

This looks clean, and the push side is genuinely correct. The pop side, however, hides two of the deepest problems in lock-free programming: the ABA problem and safe memory reclamation.

## The ABA problem

CAS checks whether a value is *equal* to what you expect, not whether it has *changed and changed back*. This gap is the ABA problem.

Imagine thread 1 reads `head` pointing at node A, and gets descheduled. Meanwhile thread 2 pops A, pops B, then pushes A back. Now `head` points at A again, but A's `next` pointer is different, and B has been freed. Thread 1 wakes up, performs its CAS, sees `head == A` (true!), and succeeds, setting `head` to the stale `old->next`, which may point at freed memory. The structure is now corrupt.

{{< mermaid >}}
graph LR
  S1["T1 reads head = A"] --> S2["T1 paused"]
  S2 --> S3["T2 pops A, pops B"]
  S3 --> S4["T2 pushes A back"]
  S4 --> S5["head = A again"]
  S5 --> S6["T1 CAS sees A, succeeds wrongly"]
{{< /mermaid >}}

The classic fix is a **tagged pointer**: pack a version counter alongside the pointer and increment it on every modification. Now the CAS compares both pointer and tag, so a pointer that was reused has a different tag and the CAS correctly fails. This requires a double-width CAS (`CMPXCHG16B` on x86-64) to atomically swap pointer plus counter.

```cpp
struct TaggedPtr {
    Node* ptr;
    uintptr_t tag;       // bumped on every change
};
// CAS over the full {ptr, tag} pair defeats ABA.
```

## Safe memory reclamation

ABA is really a symptom of a bigger problem: *when is it safe to free a node?* In `pop`, after CAS succeeds we `delete old`. But what if another thread is still reading `old`? Freeing it causes a use-after-free. With locks this is trivial; lock-free, it's one of the hardest problems in the field.

There are three main industrial solutions.

**Hazard pointers.** Each thread publishes the pointers it's currently accessing into a global, per-thread "hazard" slot. Before any thread frees a node, it scans all hazard slots; if the node is hazarded by anyone, it defers the free. This bounds memory usage and is safe, at the cost of a scan and per-access publication overhead.

**Epoch-based reclamation (EBR).** Threads operate within "epochs." A node retired in epoch N can only be freed once all threads have advanced past N, guaranteeing no one holds a reference. EBR has lower per-operation overhead than hazard pointers but can delay reclamation indefinitely if a thread stalls inside a critical section.

**RCU (Read-Copy-Update).** Heavily used in the Linux kernel. Readers proceed without any synchronization; writers create new versions and wait for a "grace period" (all pre-existing readers to finish) before freeing the old version. Phenomenal for read-heavy workloads.

| Technique | Reader cost | Reclaim latency | Complexity |
|-----------|-------------|-----------------|------------|
| Hazard pointers | Moderate (publish) | Bounded | High |
| Epoch-based | Low | Unbounded if stall | Moderate |
| RCU | Near zero | Grace period | High (writer side) |
| Garbage collection | Zero (language does it) | GC-dependent | Low for the dev |

This table reveals a quiet truth: in garbage-collected languages like Java and Go, the reclamation problem largely disappears. The GC won't collect a node anyone can still reach, so ABA-via-free and use-after-free vanish. This is a major reason lock-free structures are more approachable in Java than in C++. The Michael-Scott queue, for example, is famously cleaner to implement on the JVM.

## The Michael-Scott queue

The standard lock-free FIFO queue, due to Michael and Scott, is the basis for Java's `ConcurrentLinkedQueue`. It maintains separate `head` and `tail` atomic pointers so enqueue and dequeue contend on different cache lines. Enqueue does two CAS operations: one to link the new node, and a "helping" CAS to advance the tail. That helping behavior, where any thread that notices a lagging tail will advance it, is what preserves the lock-free property even if the enqueuer stalls between its two steps.

The helping pattern generalizes: in robust lock-free designs, threads cooperatively fix up inconsistent states they observe rather than waiting for the responsible thread to do it. This is what makes "some thread always progresses" hold even under arbitrary preemption.

## When lock-free is worth it (and when it isn't)

Lock-free is not automatically faster. Under low contention, a well-implemented lock (especially an adaptive or spinlock) often beats a lock-free structure because the CAS retry loops, memory barriers, and reclamation machinery have real cost. The CAS itself is expensive: it's a full read-modify-write that often forces cache-line ownership transfers between cores, the dreaded cache-line ping-pong.

Lock-free pays off when:

- Contention is high and lock convoying or priority inversion would otherwise stall threads.
- You cannot tolerate a descheduled thread blocking others (real-time, kernel, interrupt contexts).
- The structure is a known hot spot and you've measured a lock as the bottleneck.

Lock-free is the wrong choice when:

- Contention is low; a simple mutex is faster and far easier to get right.
- The operation is complex; multi-step transactions are brutal to make lock-free.
- You haven't measured. Hand-rolled lock-free code is a notorious source of rare, undebuggable corruption.

The pragmatic advice: reach first for battle-tested library implementations (`ConcurrentLinkedQueue`, `java.util.concurrent` collections, Boost.Lockfree, crossbeam in Rust) rather than writing your own. The people who wrote those spent years getting the memory ordering and reclamation right, and they tested on weakly-ordered hardware where your x86 intuition would have failed.

## The takeaway

Lock-free programming rests on CAS, optimistic retry loops, and a precise progress guarantee. Its hardest problems aren't the happy-path algorithm but ABA and safe memory reclamation, which is why GC'd languages make it dramatically more tractable. Use it where contention and progress guarantees genuinely demand it, lean on proven libraries, and never trust a lock-free structure you validated only on strongly-ordered hardware.
