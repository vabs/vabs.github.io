---
title: "CAP Theorem in Practice"
date: 2026-02-03T14:40:00-04:00
draft: false
tags: [backend, distributed-systems, consistency, availability, databases]
---

Almost everyone who works with distributed databases has heard the CAP theorem reduced to a slogan: "pick two of consistency, availability, and partition tolerance." That summary is so lossy it is actively harmful. It implies you sit down at design time and choose two letters off a menu. In reality, partition tolerance is not optional, the choice between consistency and availability only matters *during* a partition, and the words "consistency" and "availability" in CAP mean something narrower and stranger than their everyday usage. This post unpacks what the theorem really says and how it shows up in systems you actually run.

## The precise statement

CAP, formalized by Gilbert and Lynch in 2002, concerns a distributed system of nodes that communicate over a network. The three properties have technical definitions:

- **Consistency (C):** Every read receives the most recent write or an error. This is *linearizability* — the system behaves as if there is a single, up-to-date copy of the data. This is **not** the same C as in ACID.
- **Availability (A):** Every request to a non-failing node receives a non-error response, without guarantee that it contains the most recent write.
- **Partition tolerance (P):** The system continues to operate despite arbitrary loss of messages between nodes.

The theorem proves that when a network partition occurs, you cannot have both C and A. You must sacrifice one.

## Why P is not a choice

The single most common misunderstanding is treating P as something you opt into. You do not. If your system runs on more than one machine connected by a network, partitions *will* happen — a switch fails, a cable is cut, a GC pause makes a node unreachable, a cloud availability zone loses connectivity. You cannot make a network that never drops messages.

So the real choice is binary and conditional: **when a partition happens, do you sacrifice consistency or availability?** Systems are therefore better described as **CP** or **AP**.

{{< mermaid >}}
graph TD
  A["Network partition occurs"] --> B{"A request arrives at a node<br/>cut off from its peers"}
  B -->|"CP: refuse to risk stale data"| C["Return error or block<br/>(sacrifice Availability)"]
  B -->|"AP: stay responsive"| D["Answer from local state<br/>(sacrifice Consistency)"]
{{< /mermaid >}}

## CP systems: choosing consistency

A CP system, when partitioned, would rather return an error than return possibly-stale or conflicting data. The minority side of a partition stops serving writes (and often reads) because it cannot be sure it has the latest state.

The canonical mechanism is a quorum over a consensus protocol like Raft or Paxos. Writes must be acknowledged by a majority of nodes. If a node finds itself in the minority partition, it cannot reach a majority, so it cannot commit — it errors out instead.

```text
5-node cluster, partition splits it 3 | 2

Majority side (3 nodes): can elect a leader, reach quorum,
                         continues serving reads and writes.

Minority side (2 nodes): cannot reach quorum,
                         rejects writes (and linearizable reads).
```

Examples in practice: etcd, ZooKeeper, Consul, Google Spanner, and most relational databases configured for strong replication. You reach for these when correctness is paramount — leader election, configuration that must be globally agreed, financial ledgers, anything where two divergent answers is catastrophic.

The cost is plain: during a partition, the minority side is *down* for writes. If you require coordination and a partition isolates you from the majority, your requests fail. That is the price of never being wrong.

## AP systems: choosing availability

An AP system keeps answering on every reachable node, even when those nodes cannot talk to each other. Both sides of a partition accept writes. The inevitable consequence is divergence: the two sides now hold conflicting data that must be reconciled when the partition heals.

{{< mermaid >}}
sequenceDiagram
  participant U1 as User in Region A
  participant NA as Node A
  participant NB as Node B
  participant U2 as User in Region B
  Note over NA,NB: Partition: A and B cannot communicate
  U1->>NA: set cart = [book]
  NA-->>U1: OK
  U2->>NB: set cart = [pen]
  NB-->>U2: OK
  Note over NA,NB: Partition heals
  NA->>NB: reconcile: merge carts
  Note over NA,NB: cart = [book, pen] (conflict resolution)
{{< /mermaid >}}

Examples: Amazon Dynamo and its descendants (Cassandra, Riak), DNS, and many caches. These systems lean on techniques like vector clocks, last-write-wins, or CRDTs to resolve the conflicts that availability makes inevitable. The classic Dynamo example is the shopping cart: never refuse an "add to cart," reconcile divergent carts later, and accept that a removed item might occasionally reappear.

## The dimension CAP ignores: latency

CAP only describes behavior *during* a partition. But partitions are rare, and your system spends 99.99% of its life with the network working fine. The PACELC model extends CAP to cover this gap:

> If there is a **P**artition, choose between **A**vailability and **C**onsistency; **E**lse (normal operation), choose between **L**atency and **C**onsistency.

This is the more useful framing day to day, because the latency-versus-consistency tradeoff is *constant*, not occasional.

| System | Partition behavior | Normal behavior | PACELC |
| --- | --- | --- | --- |
| Spanner | CP | Consistency at latency cost (TrueTime commit wait) | PC/EC |
| Cassandra | AP | Tunable, often favors latency | PA/EL |
| DynamoDB | AP (tunable) | Eventual by default, strong on request | PA/EL |
| etcd / ZooKeeper | CP | Consistency over latency | PC/EC |
| MongoDB | CP (default) | Consistency over latency | PC/EC |

Strong consistency in normal operation requires coordination — a write must reach a quorum before it is acknowledged, which adds round trips and latency. Relaxing to eventual consistency lets a node answer immediately from local state. That tradeoff exists every single millisecond, partition or not.

## Tunable consistency: the practical middle

Modern systems rarely force a single global choice. They expose per-operation knobs. Cassandra and DynamoDB let you specify a consistency level per query.

```python
# Cassandra: tune consistency per operation
from cassandra import ConsistencyLevel
from cassandra.query import SimpleStatement

# Strong-ish read: quorum reads + quorum writes => R + W > N
read_q = SimpleStatement(
    "SELECT balance FROM accounts WHERE id = %s",
    consistency_level=ConsistencyLevel.QUORUM,
)

# Fast, weakly-consistent read for a non-critical dashboard
read_fast = SimpleStatement(
    "SELECT view_count FROM stats WHERE id = %s",
    consistency_level=ConsistencyLevel.ONE,
)
```

The governing rule is the quorum inequality: if `R + W > N` (read replicas plus write replicas exceed total replicas), reads are guaranteed to see the latest acknowledged write, because the read and write sets must overlap on at least one node. With `N=3`, using `W=QUORUM` (2) and `R=QUORUM` (2) gives `2 + 2 > 3`, so reads are consistent. Drop reads to `ONE` and you trade that guarantee for lower latency.

This is the real practice of CAP: not a one-time architectural decree, but a continuous, per-workload negotiation. Your billing path uses quorum. Your "who viewed this profile" counter uses `ONE`.

## Applying it without the slogan

When you design or evaluate a distributed data system, ask sharper questions than "which two":

- **What must remain correct during a partition?** Those operations need CP semantics or a fencing/quorum guarantee. Everything else can probably tolerate AP.
- **What is my latency budget in the normal case?** This is the PACELC "else" branch, and it dominates your user experience because partitions are rare.
- **Can my domain absorb conflict resolution?** Shopping carts, counters, and presence indicators can. A double-spend cannot.
- **Where is the real arbiter of truth?** Even AP systems often funnel critical writes through a CP component (a strongly consistent ledger, a sequencer) while serving everything else cheaply.

The CAP theorem is a statement about an unavoidable physical limit: information cannot cross a broken network. Everything interesting in distributed systems design is about deciding, operation by operation, which side of that limit you want to live on.
