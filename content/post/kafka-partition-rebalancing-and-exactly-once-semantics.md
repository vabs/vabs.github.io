---
title: "Kafka Partition Rebalancing & Exactly-Once Semantics"
date: 2026-02-09T09:35:00-04:00
draft: false
tags: [backend, kafka, streaming, exactly-once, consumer-groups]
---

Two of the most misunderstood parts of running Apache Kafka in production are how consumer group rebalancing works and what "exactly-once" actually guarantees. Both are areas where the defaults are reasonable but the failure modes are subtle, and where a confident-sounding wrong mental model leads to duplicate processing, stalled consumers, and data loss. This post digs into the mechanics of rebalancing, why it can cripple throughput, and how Kafka's transactional machinery delivers exactly-once semantics — within the bounds of what is actually possible.

## Consumer groups and partition assignment

A topic is split into partitions, and a consumer group divides those partitions among its members so each partition is consumed by exactly one consumer in the group. This is how Kafka scales reads horizontally while preserving per-partition order. The group coordinator — a broker — tracks group membership and orchestrates who owns what.

Whenever membership changes (a consumer joins, leaves, or is presumed dead), or topic metadata changes (partitions added), the group must **rebalance**: reassign partitions among the current members.

{{< mermaid >}}
graph TD
  A["Consumer joins / leaves / times out"] --> B["Group coordinator detects change"]
  B --> C["Coordinator triggers rebalance"]
  C --> D["Members rejoin group, send subscriptions"]
  D --> E["Leader computes new assignment"]
  E --> F["Coordinator distributes assignments"]
  F --> G["Consumers resume from committed offsets"]
{{< /mermaid >}}

## The stop-the-world problem

The classic rebalance protocol is **eager**: when a rebalance starts, *every* consumer in the group revokes *all* of its partitions, then the group recomputes assignments from scratch, then everyone picks up their new set. During that window — which can last seconds — no partitions are being consumed. For a large group this is a stop-the-world pause, and it happens every time a single pod restarts during a deploy.

```text
Eager rebalance timeline (3 consumers, one restarts):

t0  C1, C2, C3 all consuming
t1  C3 restarts -> rebalance begins
t2  C1, C2, C3 ALL revoke ALL partitions   <- nobody consuming
t3  new assignment computed
t4  C1, C2, C3 resume                       <- gap = lost throughput
```

### Cooperative (incremental) rebalancing

Kafka 2.4+ introduced **cooperative rebalancing**, where only the partitions that actually need to move are revoked. Consumers keep processing the partitions they retain, dramatically shrinking the pause.

```java
// Use the cooperative protocol
props.put(
    ConsumerConfig.PARTITION_ASSIGNMENT_STRATEGY_CONFIG,
    "org.apache.kafka.clients.consumer.CooperativeStickyAssignor"
);
```

The `CooperativeStickyAssignor` also tries to *keep* partitions with their current owner across rebalances, which preserves warm caches and local state. This is the single highest-impact config change for groups that rebalance often.

## Taming rebalances

Several settings and practices reduce both the frequency and the cost of rebalances:

| Setting | Effect | Tradeoff |
| --- | --- | --- |
| `session.timeout.ms` | How long before a silent consumer is declared dead | Too low → false rebalances; too high → slow failure detection |
| `heartbeat.interval.ms` | Heartbeat frequency (keep ~1/3 of session timeout) | More heartbeats = more traffic |
| `max.poll.interval.ms` | Max time between `poll()` calls before eviction | Too low → slow processing triggers rebalance |
| `group.instance.id` | Enables **static membership** | Restart within timeout skips rebalance entirely |

**Static membership** deserves emphasis. By assigning each consumer a stable `group.instance.id`, a consumer that restarts (a rolling deploy, a pod reschedule) and rejoins within `session.timeout.ms` keeps its previous assignment without triggering a rebalance at all. Combined with cooperative rebalancing, this makes deploys nearly invisible to throughput.

A frequent self-inflicted wound: doing slow work between polls so that `max.poll.interval.ms` is exceeded, the consumer is evicted as dead, and a rebalance kicks off — which then evicts the *next* consumer too, producing a rebalance storm. Keep per-poll processing bounded, or offload slow work to a separate thread pool.

## Delivery semantics: the three levels

Before exactly-once, understand what it is improving on.

- **At-most-once:** Commit offsets *before* processing. If you crash after committing but before finishing, the message is lost. No duplicates, possible loss.
- **At-least-once:** Process *then* commit. If you crash after processing but before committing, you reprocess on restart. No loss, possible duplicates. This is the default and the most common choice.
- **Exactly-once:** Each message affects the output state once and only once, even across failures and retries.

At-least-once is fine if your processing is idempotent. Exactly-once is what you need when it is not — and Kafka provides it through two mechanisms working together: the **idempotent producer** and **transactions**.

## The idempotent producer

The first half of the puzzle is preventing duplicate *writes*. Without it, a producer that sends a message, fails to receive the ack due to a network blip, and retries will write the message twice.

The idempotent producer assigns each producer a Producer ID (PID) and a monotonic sequence number per partition. The broker tracks the last sequence number it accepted per (PID, partition) and rejects duplicates.

```java
props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, true);
// implies acks=all, retries > 0, max.in.flight <= 5
```

This guarantees exactly-once delivery *to a single partition* from a single producer session. It does not span partitions or coordinate with consumer offsets — that requires transactions.

## Transactions and the consume-process-produce loop

The hard case is a stream processor: it consumes from input topics, does work, and produces to output topics. "Exactly-once" here means the output writes **and** the input offset commit either all happen or none happen — atomically. Kafka transactions make the offset commit a participant in the same transaction as the produced records.

{{< mermaid >}}
sequenceDiagram
  participant C as "Consumer"
  participant App as "Processor"
  participant P as "Transactional Producer"
  participant T as "Transaction Coordinator"
  C->>App: "poll records (input topic)"
  App->>P: "beginTransaction()"
  P->>P: "produce output records"
  P->>T: "sendOffsetsToTransaction(input offsets)"
  P->>T: "commitTransaction()"
  T-->>P: "atomic: outputs + offsets committed together"
  Note over C,T: "On crash before commit, transaction aborts;<br/>nothing is visible, offsets not advanced"
{{< /mermaid >}}

```java
producer.initTransactions();
while (true) {
    ConsumerRecords<K, V> records = consumer.poll(Duration.ofMillis(100));
    producer.beginTransaction();
    try {
        for (var rec : records) {
            producer.send(transform(rec));   // produce output
        }
        // commit consumed offsets as part of THIS transaction
        producer.sendOffsetsToTransaction(
            offsetsOf(records), consumer.groupMetadata());
        producer.commitTransaction();        // atomic
    } catch (Exception e) {
        producer.abortTransaction();          // nothing leaks out
    }
}
```

The final piece is on the consumer of the *output* topic: it must set `isolation.level=read_committed` so it only sees records from committed transactions and never reads aborted or in-flight ones.

```java
consumerProps.put(ConsumerConfig.ISOLATION_LEVEL_CONFIG, "read_committed");
```

Kafka Streams wraps this entire loop behind a single setting, `processing.guarantee=exactly_once_v2`, which is the recommended way to get exactly-once for stream topologies rather than hand-rolling the transactional loop.

## The boundary of "exactly-once"

The marketing phrase hides an important caveat: Kafka's exactly-once is **end-to-end within Kafka**. It covers reading from Kafka, processing, and writing back to Kafka atomically. The moment your side effect leaves Kafka — writing to an external database, calling a payment API, sending an email — the transaction cannot enroll that external system. A crash between the external call and the Kafka commit reintroduces the duplicate-or-lost dilemma.

To get effective exactly-once against an external system, you still need one of:

- **Idempotent writes** to the external system (upsert keyed on the message ID).
- **Transactional outbox**, where the external write and an outgoing event are committed in the same external-DB transaction, and a relay publishes the event.
- **Two-phase or distributed transactions**, which most teams rightly avoid for their complexity and availability cost.

So the practical guidance is layered: turn on the idempotent producer always; use Kafka transactions (or `exactly_once_v2` in Streams) for Kafka-to-Kafka pipelines; and for the boundary to the outside world, make your effects idempotent. Get the mental model right — that exactly-once is an atomic *consume-process-produce* guarantee inside Kafka, not a magic spell against all duplication — and you will configure these systems correctly instead of being surprised when an external double-write slips through.
