---
title: "ACID vs BASE Trade-offs"
date: 2026-01-17T13:27:00-04:00
draft: false
tags: [backend, distributed-systems, databases, consistency, scalability]
---

## Two philosophies of data

When a system stores data that multiple clients read and write, it must make promises about what they will see. ACID and BASE are two opposing sets of promises. ACID — Atomicity, Consistency, Isolation, Durability — is the relational tradition: the database guarantees correctness even under concurrency and failure, and the application can largely ignore the messy middle. BASE — Basically Available, Soft state, Eventually consistent — emerged from web-scale systems that found ACID's guarantees too expensive at planetary scale and chose to relax them in exchange for availability and horizontal scalability.

These are not merely different databases; they are different *contracts* with the application, and choosing wrong means either building correctness the database should have given you, or paying for guarantees you never needed.

## ACID, precisely

ACID is the property set of a single transaction in a traditional DBMS.

| Property | Guarantee |
|---|---|
| Atomicity | All operations in a transaction commit, or none do — no partial effects |
| Consistency | A transaction moves the database from one valid state to another, respecting all constraints |
| Isolation | Concurrent transactions appear to execute serially; intermediate states are hidden |
| Durability | Once committed, data survives crashes and power loss |

Each is implemented by concrete machinery. Atomicity and durability come from the **write-ahead log (WAL)**: changes are logged before being applied, so recovery can redo committed transactions and undo uncommitted ones. Isolation comes from locking or MVCC. Consistency is partly the database (constraints, triggers) and partly the application (the transaction's logic must itself be correct).

```sql
-- Atomicity: this transfer either fully happens or fully rolls back
BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
COMMIT;  -- crash before this and neither update survives
```

The power of ACID is that the application reasons about data as if it were the only client, even when thousands are writing concurrently. That simplicity is what made relational databases the default for decades.

## Why ACID gets expensive at scale

ACID's guarantees are cheap on a single node. The trouble starts when data spans many machines. Atomicity across nodes requires a coordination protocol like **two-phase commit**, which blocks if the coordinator fails and adds round-trips to every write. Isolation across nodes requires distributed locking or global timestamp ordering, both of which add latency and reduce availability. Strong consistency across replicas means a write is not done until enough replicas acknowledge it, so a network partition forces a choice: refuse writes (lose availability) or accept divergence (lose consistency).

That choice is not optional — it is forced by the **CAP theorem**.

## The CAP theorem frames the trade

CAP states that in the presence of a network **P**artition, a distributed system must choose between **C**onsistency (every read sees the latest write) and **A**vailability (every request gets a non-error response). You cannot have both during a partition.

{{< mermaid >}}
graph TD
    A["Network partition occurs"] --> B{"Node receives a write,<br/>cannot reach peers"}
    B -->|"Choose Consistency"| C["Reject the write or read - stay correct, lose availability"]
    B -->|"Choose Availability"| D["Accept the write locally - stay up, risk divergence"]
    C --> E["CP system: ACID-leaning"]
    D --> F["AP system: BASE-leaning"]
{{< /mermaid >}}

ACID systems lean **CP**: they sacrifice availability to preserve consistency. BASE systems lean **AP**: they sacrifice immediate consistency to stay available. The "C" in CAP (linearizability) is stricter than the "C" in ACID (constraint validity), which causes endless confusion, but the operational point holds: at scale, strong consistency and continuous availability are in tension, and your data model must pick a side per operation.

## BASE, precisely

BASE inverts ACID's priorities. It is less a formal definition than a design stance.

- **Basically Available** — the system stays responsive even when parts fail; it returns *something*, possibly stale.
- **Soft state** — the system's state may change over time without input, as replicas reconcile in the background.
- **Eventually consistent** — if writes stop, all replicas converge to the same value, given enough time. There is no guarantee about *when* a read sees a given write.

{{< mermaid >}}
graph LR
    A["Write to replica 1"] --> B["Ack to client immediately"]
    A --> C["Async replicate to 2, 3"]
    D["Read from replica 2<br/>before replication"] --> E["Returns stale value"]
    C --> F["Replicas converge"]
    F --> G["Later reads consistent"]
{{< /mermaid >}}

The application must now tolerate stale reads and concurrent-write conflicts. Conflict resolution becomes a first-class concern, handled by strategies like **last-write-wins** (simple, can lose data), **vector clocks** (detect concurrent writes for the app to merge), or **CRDTs** (data types that merge deterministically without coordination).

```python
# BASE store: write returns before global convergence
store.put("cart:42", cart, consistency="ONE")   # ack from one replica
# A concurrent read elsewhere might still see the old cart
value = store.get("cart:42", consistency="ONE")  # possibly stale
# Tunable: read/write with QUORUM to get strong consistency when needed
```

## Tunable consistency: the spectrum, not the binary

The cleanest mental upgrade is to stop treating ACID and BASE as a binary. Systems like Cassandra and DynamoDB expose **tunable consistency** per operation. With **N** replicas, a write to **W** of them and a read from **R** of them is strongly consistent when `R + W > N`, because the read and write quorums are guaranteed to overlap on at least one up-to-date replica.

| Config (N=3) | W | R | Property |
|---|---|---|---|
| Fast, weak | 1 | 1 | Eventual; lowest latency, highest availability |
| Read-heavy strong | 3 | 1 | Strong reads, slow writes |
| Balanced strong | 2 | 2 | Strong (R+W=4>3), tolerates one node down |
| Write-heavy strong | 1 | 3 | Strong reads only if all read replicas reachable |

This lets one system behave ACID-like for a financial write and BASE-like for a "number of likes" counter — consistency becomes a per-call decision rather than a database-wide religion.

## Choosing per use case

The right question is not "which is better" but "what does *this data* require."

**Choose ACID / strong consistency for:**

- Money movement, ledgers, billing — a double-spend or lost transfer is unacceptable.
- Inventory with hard limits — overselling the last unit has real cost.
- Anything with cross-entity invariants enforced in the database.
- Authentication and authorization state.

**Choose BASE / eventual consistency for:**

- Social feeds, view counts, like counts — a slightly stale number is harmless.
- Product catalogs, content delivery — read-mostly, tolerant of propagation delay.
- Shopping carts, session state — conflicts are rare and resolvable.
- Telemetry, logs, analytics ingestion — volume and availability dominate correctness.

The trap is applying one philosophy globally. Plenty of teams force eventual consistency onto a payments flow and then rebuild atomicity badly in application code, or insist on cross-region ACID for a counter and wonder why writes are slow and the system falls over during partitions. Mature architectures are **polyglot**: a strongly consistent store for money and identity, an eventually consistent store for feeds and counters, often in the same product.

## The deeper point

ACID and BASE are not about technology quality; they are about *where correctness lives*. ACID puts it in the database, so the application stays simple at the cost of coordination overhead and partition-time unavailability. BASE pushes it up into the application — conflict resolution, idempotency, tolerance of staleness — in exchange for availability and linear scalability. CAP is the law that makes the trade unavoidable during partitions, and tunable consistency is the modern recognition that you can choose differently for each operation rather than once for the whole system. The engineering skill is knowing, for each piece of data you store, exactly how much correctness it actually needs — and refusing to pay for more, or accept less.
