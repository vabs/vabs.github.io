---
title: "Database Transaction Isolation Levels: Serializable vs Snapshot"
date: 2026-01-16T09:42:00-04:00
draft: false
tags: [backend, databases, transactions, concurrency, isolation]
---

## Why isolation levels exist

A database that ran every transaction one at a time would be trivially correct and uselessly slow. Real systems interleave transactions to keep CPUs and disks busy, and that interleaving is where correctness goes to die. Isolation levels are the contract the database offers about *which* concurrency anomalies you are allowed to observe. Pick a weaker level and you trade some correctness guarantees for throughput; pick a stronger one and you pay in aborts, latency, or lock contention.

The ANSI SQL standard defines four levels by the anomalies they forbid, but that definition is famously incomplete. Modern engines like PostgreSQL, SQL Server, and Oracle implement multi-version concurrency control (MVCC), and the two levels worth understanding deeply are **Snapshot Isolation (SI)** and **Serializable**. The gap between them is subtle, expensive to close, and the source of an enormous number of production data-integrity bugs.

## The classic anomalies

Before comparing the two, it helps to name the phenomena each level prevents.

| Anomaly | Description | Forbidden at |
|---|---|---|
| Dirty read | Read uncommitted data from another transaction | Read Committed and above |
| Non-repeatable read | A row changes value between two reads in the same txn | Repeatable Read and above |
| Phantom read | New rows appear matching a predicate on re-query | Serializable (ANSI) |
| Lost update | Two txns read-modify-write, one overwrite is lost | Snapshot and above |
| Write skew | Two txns read overlapping data, write disjoint data, breaking an invariant | Serializable only |

That last row is the entire story. Snapshot Isolation prevents everything except write skew (and a related anomaly, the read-only transaction anomaly). Serializable prevents write skew too.

## How Snapshot Isolation works

Under SI, each transaction operates against a consistent snapshot of the database as of the moment it started (or its first statement, depending on the engine). Every row version is tagged with the transaction ID that created it and the one that deleted it. A reader sees only versions committed before its snapshot, and never sees in-flight writes.

{{< mermaid >}}
graph TD
    A["Transaction T1 begins"] --> B["Reads snapshot at timestamp 100"]
    C["Transaction T2 commits at 105"] --> D["Creates new row versions"]
    B --> E["T1 continues reading old versions"]
    D --> E
    E --> F["T1 never sees T2's writes"]
    F --> G["T1 commits at 110 - first-committer-wins on conflicts"]
{{< /mermaid >}}

Writes are governed by a **first-committer-wins** rule. If two concurrent transactions update the same row, the first to commit succeeds and the second aborts with a serialization failure. This single rule eliminates lost updates, which is why SI is strictly stronger than ANSI Repeatable Read.

The beauty of SI is that **readers never block writers and writers never block readers**. A long analytical read does not hold up an OLTP write path. This is why it became the default workhorse for high-concurrency systems.

```sql
-- PostgreSQL: REPEATABLE READ is actually Snapshot Isolation
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT balance FROM accounts WHERE id = 1;  -- sees snapshot
-- meanwhile another txn updates id = 1 and commits
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
-- ERROR: could not serialize access due to concurrent update
COMMIT;
```

Note the naming trap: in PostgreSQL, `REPEATABLE READ` gives you Snapshot Isolation, which is *stronger* than the ANSI definition of repeatable read because it also blocks phantoms within the snapshot.

## Write skew: the anomaly SI cannot catch

Write skew is the canonical reason SI is not serializable. Consider an on-call system with a constraint: *at least one doctor must be on call at all times.* Two doctors, Alice and Bob, are both on call. Each independently decides to go off call.

```sql
-- Both transactions run concurrently under Snapshot Isolation
-- T_alice
SELECT count(*) FROM doctors WHERE on_call = true;  -- returns 2, OK
UPDATE doctors SET on_call = false WHERE name = 'Alice';
COMMIT;

-- T_bob (concurrent)
SELECT count(*) FROM doctors WHERE on_call = true;  -- returns 2, OK
UPDATE doctors SET on_call = false WHERE name = 'Bob';
COMMIT;
```

Both transactions read the same snapshot showing two doctors on call. Each checks the invariant and finds it satisfied. They write to *different rows*, so first-committer-wins never fires. Both commit. Now zero doctors are on call and the invariant is silently violated.

The structural signature of write skew is: two transactions read an overlapping set, then each writes to a disjoint part of it, where their combined effect breaks a constraint that neither broke alone. SI cannot see this because it only checks for write-write conflicts on the *same* rows.

## How Serializable closes the gap

There are two main implementation families.

### Two-phase locking (2PL)

The traditional approach: acquire shared locks on reads, exclusive locks on writes, and hold them until commit. Predicate locks or index-range locks handle phantoms. This is what SQL Server's `SERIALIZABLE` does. It is correct but pessimistic, and lock contention and deadlocks become the dominant cost.

### Serializable Snapshot Isolation (SSI)

PostgreSQL's `SERIALIZABLE` uses a smarter, optimistic technique invented by Cahill, Fekete, and Rohm. It runs transactions under ordinary Snapshot Isolation but *tracks read-write dependencies* between concurrent transactions. The key insight: every non-serializable execution under SI contains a specific structure called a **dangerous skew** — two consecutive rw-dependency edges forming a cycle.

{{< mermaid >}}
graph LR
    A["T1 reads X"] -->|"rw-dependency"| B["T2 writes X"]
    B -->|"rw-dependency"| C["T3 writes data T1 read"]
    C -.->|"forms cycle"| A
    A --> D["SSI detects pivot, aborts one txn"]
{{< /mermaid >}}

When SSI detects that a transaction is the *pivot* of two such edges, it aborts one of the participants with a serialization failure before the anomaly can commit. The cost is bookkeeping (SIReadLocks that track what each transaction read) and occasional false-positive aborts, but readers and writers still do not block each other.

```sql
BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) FROM doctors WHERE on_call = true;
UPDATE doctors SET on_call = false WHERE name = 'Alice';
COMMIT;
-- If concurrent T_bob did the same, one gets:
-- ERROR: could not serialize access due to read/write dependencies
```

Under SSI the doctor scenario is caught: one of the two transactions aborts, and the application retries.

## Performance and the cost of correctness

The practical comparison comes down to abort rates and bookkeeping overhead.

| Property | Snapshot Isolation | Serializable (SSI) | Serializable (2PL) |
|---|---|---|---|
| Readers block writers | No | No | Yes |
| Prevents lost update | Yes | Yes | Yes |
| Prevents write skew | No | Yes | Yes |
| Abort source | write-write conflicts | rw-dependency cycles | deadlocks |
| Memory overhead | version chains | + read tracking | lock tables |
| Best for | high-concurrency OLTP | correctness-critical OLTP | low-contention, predictable |

The critical operational reality: **anything stronger than Read Committed requires your application to retry on serialization failures.** Code that runs a transaction must wrap it in a retry loop, because the engine will sometimes reject an otherwise valid transaction to preserve correctness.

```python
def run_with_retry(conn, fn, max_retries=5):
    for attempt in range(max_retries):
        try:
            with conn.transaction(isolation="serializable"):
                return fn(conn)
        except SerializationFailure:
            if attempt == max_retries - 1:
                raise
            backoff(attempt)  # exponential backoff reduces contention
```

## Choosing a level

Use **Serializable** when you have invariants spanning multiple rows that cannot tolerate write skew — financial ledgers, inventory with reservations, scheduling constraints, uniqueness enforced in application code. The retry cost is real but bounded, and SSI keeps the non-blocking advantages of MVCC.

Use **Snapshot Isolation** when your invariants are per-row (covered by first-committer-wins) or enforced by database constraints (unique indexes, foreign keys, check constraints push the invariant down where SI is sufficient). Most CRUD applications live here happily.

The deepest takeaway is that **isolation level is a property of the whole transaction mix, not of one query.** A single transaction cannot be "serializable" in isolation; serializability is a guarantee about the equivalence of an interleaved schedule to *some* serial order. That is why the engine must track relationships between transactions, and why correctness sometimes costs an abort. Understanding *which* anomaly you are exposed to — and whether your invariants can be expressed as constraints — is worth far more than memorizing the four ANSI level names.
