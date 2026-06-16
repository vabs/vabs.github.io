---
title: "CRDTs & Conflict-Free Replicated Data Types"
date: 2026-02-07T11:25:00-04:00
draft: false
tags: [backend, distributed-systems, crdt, replication, consistency]
---

When two replicas of the same data accept writes independently and then sync, something has to decide what the merged result is. The usual answer is "ask a server" or "last write wins," and both have well-known failure modes: the server is a single point of contention, and last-write-wins silently throws away data. Conflict-free Replicated Data Types (CRDTs) take a different route. They are data structures designed so that *any* set of concurrent updates can be merged deterministically, without coordination, with the merge function guaranteeing that all replicas converge to the same state. No central authority, no conflict prompts, no lost updates — as long as the structure is built correctly.

This post covers the mathematical guarantee that makes CRDTs work, the two families they come in, several concrete designs, and the costs that the marketing tends to omit.

## The convergence guarantee

The promise of a CRDT is **Strong Eventual Consistency (SEC)**: any two replicas that have received the same set of updates are in the same state, regardless of the order or number of times those updates were delivered. Compare this to plain eventual consistency, which only promises convergence "eventually" and usually requires a conflict resolution step. SEC removes the resolution step entirely.

This works because the merge operation forms a mathematical structure called a **join-semilattice**. The merge must be:

- **Commutative:** `merge(a, b) = merge(b, a)` — order of delivery does not matter.
- **Associative:** `merge(merge(a, b), c) = merge(a, merge(b, c))` — grouping does not matter.
- **Idempotent:** `merge(a, a) = a` — receiving the same update twice does nothing.

If your merge has all three properties, the network can deliver updates out of order, duplicate them, and batch them however it likes, and every replica still lands on the same state. That is the whole trick.

{{< mermaid >}}
graph TD
  A["Replica 1 local update"] --> M["Merge (commutative,<br/>associative, idempotent)"]
  B["Replica 2 local update"] --> M
  C["Replica 3 offline update"] --> M
  M --> R["Identical converged state<br/>on every replica"]
{{< /mermaid >}}

## Two families: state-based and operation-based

CRDTs come in two flavors that trade off in opposite directions.

| | State-based (CvRDT) | Operation-based (CmRDT) |
| --- | --- | --- |
| What is sent | The full (or delta) state | Individual operations |
| Merge requirement | Join must be a semilattice | Ops must be commutative |
| Network requirement | At-least-once, any order | Reliable causal broadcast, exactly-once |
| Bandwidth | Higher (sends state) | Lower (sends ops) |
| Failure tolerance | Very robust to duplicates/reorder | Needs dedup + ordering |

**State-based CRDTs** propagate their entire state and merge it on the receiving side with the semilattice join. Because the join is idempotent and commutative, you can resend state freely — a dropped or duplicated message changes nothing. The downside is bandwidth, which delta-state CRDTs mitigate by shipping only the changed portion.

**Operation-based CRDTs** broadcast each operation. They use less bandwidth but demand more from the network: operations must be delivered exactly once and in causal order, otherwise the commutativity argument breaks.

## Concrete designs

### G-Counter (grow-only counter)

The simplest useful CRDT. Each replica owns one slot in a vector and only ever increments its own slot. The counter's value is the sum of all slots; merge takes the element-wise maximum.

```python
class GCounter:
    def __init__(self, replica_id, num_replicas):
        self.id = replica_id
        self.counts = [0] * num_replicas

    def increment(self, n=1):
        self.counts[self.id] += n

    def value(self):
        return sum(self.counts)

    def merge(self, other):
        # element-wise max is idempotent, commutative, associative
        self.counts = [max(a, b) for a, b in zip(self.counts, other.counts)]
```

Element-wise max is a textbook semilattice join. Two replicas that each incremented their own slots merge cleanly to the sum of both. To support decrements, a **PN-Counter** keeps two G-Counters — one for increments, one for decrements — and reports the difference.

### G-Set and LWW-Element-Set

A grow-only set (G-Set) merges by union, which is trivially a semilattice. The problem is removal — once you allow remove, union no longer captures intent. The **LWW-Element-Set** tags each add and remove with a timestamp and keeps two sets. An element is "in" the set if its latest add timestamp is greater than its latest remove timestamp.

```python
class LWWElementSet:
    def __init__(self):
        self.adds = {}     # element -> latest add timestamp
        self.removes = {}  # element -> latest remove timestamp

    def add(self, e, ts):
        self.adds[e] = max(self.adds.get(e, 0), ts)

    def remove(self, e, ts):
        self.removes[e] = max(self.removes.get(e, 0), ts)

    def contains(self, e):
        a = self.adds.get(e)
        r = self.removes.get(e, -1)
        return a is not None and a > r

    def merge(self, other):
        for e, ts in other.adds.items():
            self.add(e, ts)
        for e, ts in other.removes.items():
            self.remove(e, ts)
```

LWW still discards concurrent edits to the same element by timestamp, but it does so deterministically. For sets where you want to *keep* concurrent adds even after removes, the **OR-Set** (Observed-Remove Set) tags each add with a unique token and only removes the tokens it has actually observed — so a concurrent add survives a remove.

### Sequence CRDTs for text

Collaborative text editing (think Google Docs or Figma) needs a CRDT for ordered sequences. RGA, Logoot, and Yjs's YATA assign each character a unique, densely-orderable identifier so that concurrent insertions at the same position get a stable, deterministic ordering rather than fighting over an index. This is what lets two people type in the same paragraph offline and reconcile without scrambling each other's words.

## The causality problem

For operation-based CRDTs, "concurrent" must be defined precisely. The standard tool is the **vector clock**: each replica tracks a counter per replica, and comparing two vectors tells you whether one update happened-before another or whether they are truly concurrent.

{{< mermaid >}}
sequenceDiagram
  participant A as "Replica A"
  participant B as "Replica B"
  A->>A: "op1, clock [1,0]"
  A->>B: "deliver op1"
  B->>B: "apply op1, clock [1,0]"
  B->>B: "op2, clock [1,1] (causally after op1)"
  A->>A: "op3, clock [2,0] (concurrent with op2)"
  Note over A,B: "op2 and op3 are concurrent;<br/>CRDT merge must handle both orders identically"
{{< /mermaid >}}

When the merge sees two concurrent operations, the semilattice/commutativity property guarantees the result is the same regardless of which it processes first. The vector clock is how the system *detects* concurrency so it can apply the right rule.

## The costs nobody puts on the box

CRDTs are not free, and the metadata is where the bodies are buried.

- **Tombstones and garbage.** Removing an element from an OR-Set leaves behind metadata so a late-arriving concurrent add can still be reconciled. Without garbage collection, this metadata grows unbounded. Safe GC requires knowing every replica has seen the removal — itself a coordination problem.
- **Metadata overhead.** Vector clocks grow with the number of replicas. Sequence CRDTs attach unique IDs to every character. A document's CRDT representation can be several times larger than the visible text.
- **Semantic surprises.** "Convergence" means all replicas agree, not that the result matches user intent. In an OR-Set, concurrently adding and removing the same item leaves it present. In LWW, a higher timestamp silently wins. Whether that is "correct" is a product decision, not a math theorem.
- **You still need a transport.** State-based CRDTs tolerate any delivery, but op-based ones need reliable causal broadcast, which is real infrastructure.

## When to reach for them

CRDTs shine when you need offline-capable, multi-writer data with no central coordinator and you can express your domain in terms of grow-only, observed-remove, or LWW semantics: collaborative editors, distributed caches, shopping carts, presence systems, and multi-region counters. They are the wrong tool when you need invariants that span multiple keys (a uniqueness constraint, a non-negative balance enforced globally) — those still require coordination, because no per-object merge function can enforce a cross-object rule.

Used in their sweet spot, CRDTs deliver something genuinely rare in distributed systems: correctness without consensus. The price is paid in metadata and in carefully matching your merge semantics to what users actually expect. Get both right and you get a system that never says "no" to a write and never asks the user to resolve a conflict.
