---
title: "Optimistic Locking with Version Vectors"
date: 2026-04-09T16:30:00-04:00
draft: false
featured: false
tags: [backend, concurrency, version-vectors, distributed-systems, conflict-resolution]
---

Two users open the same record, both edit it, both save. Whose change wins? In a single-database world, optimistic locking with a simple version counter answers this cleanly: the second save is rejected because the row changed underneath it. But once data lives on multiple replicas that accept writes independently, a scalar version number is no longer enough to tell "this is a stale overwrite" apart from "these two edits happened concurrently on different nodes." Version vectors are the data structure that restores that distinction. This post builds up from the single-node case to version vectors and shows exactly when and why you need them.

## Optimistic versus pessimistic

Pessimistic locking takes a lock before reading, so no one else can touch the data until you release it. It guarantees no conflicts but serializes access, holds locks across user think-time, and deadlocks. Optimistic locking takes no lock. It lets everyone read and edit freely, and only at write time checks whether the data changed since you read it. If it did, your write is rejected and you reconcile.

Optimistic locking wins whenever conflicts are rare relative to reads — which is most of the time in user-facing systems. The cost is that you must handle the occasional rejected write, instead of the occasional held lock.

## The single-node version: a scalar counter

The classic implementation stores a `version` column and increments it on every update, checking it in the `WHERE` clause.

```sql
-- read
SELECT id, balance, version FROM accounts WHERE id = 42;
-- (returns balance=100, version=7)

-- write: only succeeds if nobody else wrote since we read
UPDATE accounts
   SET balance = 90, version = 8
 WHERE id = 42 AND version = 7;
-- rows affected = 0  -> someone else won, retry
```

If `rows affected` is zero, another transaction bumped the version between your read and your write. You re-read and retry. This is the entire mechanism, and on a single authoritative database it is correct and cheap.

{{< mermaid >}}
sequenceDiagram
  participant A as Client A
  participant B as Client B
  participant DB as Database
  A->>DB: read v7
  B->>DB: read v7
  A->>DB: update WHERE version=7 -> v8
  DB-->>A: 1 row (ok)
  B->>DB: update WHERE version=7 -> v8
  DB-->>B: 0 rows (conflict)
  Note over B: re-read v8, reconcile, retry
{{< /mermaid >}}

A scalar version works because there is exactly one authority deciding the order of writes. Every update is totally ordered: v7 happened before v8, full stop.

## Why a scalar breaks on multiple replicas

Now suppose two replicas each accept writes and reconcile later (multi-leader replication, an offline-capable mobile app, a geo-distributed store). Replica X and replica Y both start at version 7. A user edits on X, bumping it to 8. A different user edits on Y, also bumping it to 8. When the replicas sync, both have "version 8" — but they are *different* version 8s representing *different* edits made concurrently.

A scalar counter has thrown away the information you need. It cannot tell you whether one update *causally followed* the other (in which case the later one supersedes) or whether they happened *concurrently* (in which case you have a genuine conflict to resolve). Both look like "8 vs 8."

This is the core insight: **a single counter can only express a total order, but concurrent edits on independent nodes form a partial order.** You need a structure that captures "happened-before" and "concurrent with" as distinct relationships.

## Version vectors

A version vector is a map from node identifier to a per-node counter. Each replica increments only *its own* entry when it makes a local write, and merges by taking the element-wise maximum when it receives state from another replica.

```
VV = { X: 3, Y: 1, Z: 0 }
```

This reads as "I have seen 3 writes that originated on X, 1 on Y, and 0 on Z." To compare two version vectors, compare them component-wise:

- `A` **dominates** `B` (A is causally newer) if every component of A is ≥ the matching component of B, and at least one is strictly greater.
- `A` and `B` are **concurrent** if neither dominates the other — each has at least one component the other has not seen.
- They are **equal** if all components match.

```python
def compare(a, b):
    keys = set(a) | set(b)
    a_greater = any(a.get(k, 0) > b.get(k, 0) for k in keys)
    b_greater = any(b.get(k, 0) > a.get(k, 0) for k in keys)
    if a_greater and b_greater:
        return "concurrent"      # real conflict
    if a_greater:
        return "a_dominates"     # a is newer
    if b_greater:
        return "b_dominates"     # b is newer
    return "equal"
```

The concurrent case is precisely the one a scalar counter could not detect. Now you can detect it and decide what to do.

{{< mermaid >}}
flowchart TD
  A["Incoming write with VV_in"] --> B{"compare(VV_in, VV_local)"}
  B -->|"VV_in dominates"| C["Accept: incoming is newer"]
  B -->|"VV_local dominates"| D["Reject: incoming is stale"]
  B -->|"equal"| E["No-op: same version"]
  B -->|"concurrent"| F["Conflict: invoke resolution"]
{{< /mermaid >}}

## A worked example

Start with both replicas in sync at `{X:1, Y:1}`.

| Step | Node | Action | Resulting VV |
|------|------|--------|--------------|
| 1 | X | local write | `{X:2, Y:1}` |
| 2 | Y | local write | `{X:1, Y:2}` |
| 3 | sync | compare X's `{X:2,Y:1}` vs Y's `{X:1,Y:2}` | concurrent |

Neither dominates: X has a higher X-component, Y has a higher Y-component. The system correctly reports a conflict rather than silently letting one clobber the other. Contrast with the scalar case where both would read "version 2" and one would blindly overwrite the other.

After resolution, the merged value carries the element-wise max plus an increment by the resolving node:

```python
def merge_vv(a, b):
    return {k: max(a.get(k, 0), b.get(k, 0)) for k in set(a) | set(b)}

# resolved on X:
resolved = merge_vv({"X":2,"Y":1}, {"X":1,"Y":2})  # {X:2, Y:2}
resolved["X"] += 1                                  # {X:3, Y:2}
```

That `{X:3, Y:2}` now dominates both prior versions, so future syncs converge cleanly.

## Resolving the conflicts you detect

Version vectors *detect* conflicts; they do not resolve them. Detection is the hard, valuable part — resolution is a policy you choose per data type:

- **Last-write-wins by timestamp** — simplest, but sheds data and is vulnerable to clock skew. Acceptable for low-stakes fields like a UI preference.
- **Merge function** — for a shopping cart, union the items; for a counter, sum the per-node deltas. This is the CRDT-flavored approach and loses nothing.
- **Surface to the user** — for high-stakes edits (a shared document, a wiki page), present both versions and let a human pick. Git does exactly this with merge conflicts.
- **Multi-value register** — keep *both* concurrent values (siblings) and let the next write that dominates both collapse them. Dynamo-style stores do this.

The point is that you now get to choose, because the version vector told you a conflict exists instead of hiding it.

## Costs and a practical middle ground

Version vectors are not free. The vector grows with the number of writing nodes, so a system with thousands of ephemeral clients can see vectors bloat. Mitigations include:

| Problem | Mitigation |
|---------|-----------|
| Unbounded growth with many clients | Use stable server-side replica IDs, not per-client IDs |
| Stale entries from retired nodes | Prune entries below a cluster-wide low-watermark |
| Storage overhead per row | Dotted version vectors compress sibling tracking |

A common pragmatic design: clients are *not* writing replicas. They use the simple scalar optimistic-locking check against a single logical record, and version vectors live only between the handful of server-side replicas that actually accept independent writes. This keeps vectors small (bounded by replica count, not client count) while still detecting cross-replica concurrency.

## When you actually need version vectors

Be honest about your topology before reaching for this. If you have a single primary database — even with read replicas — a scalar version column is correct and far simpler, because all writes are totally ordered by the primary. You need version vectors only when **more than one node accepts writes for the same data and they reconcile asynchronously**: multi-leader replication, active-active across regions, or offline-first clients that edit locally and sync later.

## Conclusion

Optimistic locking is the right default for read-heavy, conflict-rare systems: let everyone edit, and check at write time. On a single authority, a scalar version counter captures the total order of writes perfectly. The moment writes happen independently on multiple nodes, that scalar collapses two fundamentally different situations — causal supersession and genuine concurrency — into one indistinguishable number. Version vectors restore the distinction by tracking per-node causality, letting you detect true conflicts and apply a deliberate resolution policy instead of silently losing a user's work. Use the scalar when you can, and reach for version vectors precisely when independent writers force a partial order on you.
