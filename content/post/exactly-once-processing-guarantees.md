---
title: "Exactly-Once Processing Guarantees"
date: 2026-06-08T13:05:00-04:00
draft: false
tags: [backend, streaming, distributed-systems, kafka, transactions]
---

"Exactly-once" is the most misunderstood phrase in distributed systems. Taken literally — every message is delivered and processed precisely one time, no more, no less, under all failures — it is provably impossible in an asynchronous network with crashes. Yet "exactly-once" appears prominently in the marketing of Kafka, Flink, and every modern stream processor. The resolution to this apparent contradiction is the key to understanding the whole topic: what these systems actually provide is **exactly-once *processing semantics*** (often called effectively-once), achieved by combining at-least-once delivery with deduplication and atomic state commits — not exactly-once *delivery*.

This post unpacks the distinction, explains the three delivery semantics, and walks through how real systems engineer the illusion of exactly-once on top of a network that can only promise at-least-once.

## The Three Delivery Semantics

Every messaging system sits at one of three points on a spectrum defined by *when* it acknowledges a message relative to processing it.

| Semantic | Mechanism | Failure outcome | Use case |
|----------|-----------|-----------------|----------|
| At-most-once | Ack before processing (fire and forget) | Message can be lost | Metrics, logs where loss is tolerable |
| At-least-once | Ack after processing; retry on failure | Message can be duplicated | The default for most pipelines |
| Exactly-once | At-least-once + dedup/idempotence/transactions | No loss, no observable duplicate | Payments, billing, inventory |

At-most-once and at-least-once are easy and represent a genuine choice between losing data and duplicating it. Exactly-once is the engineering effort to get the no-loss property of at-least-once *and* eliminate the observable effect of the duplicates it produces.

### Why exactly-once delivery is impossible

Consider a producer sending a message and waiting for an ack. The ack is lost in the network. The producer cannot distinguish "message processed, ack lost" from "message never arrived." Its only safe choice is to resend — producing a duplicate. No protocol removes this fundamental ambiguity; you cannot atomically "send and know it was received" over an unreliable channel. So at the delivery layer, you are always choosing between possibly-lost and possibly-duplicated. Exactly-once is built *above* this layer.

{{< mermaid >}}
sequenceDiagram
  participant P as Producer
  participant B as Broker
  P->>B: send(msg)
  B->>B: persist msg
  B-->>P: ack
  Note over P,B: ack lost in network
  P->>B: resend(msg) (timeout, can't tell if it landed)
  B->>B: persist DUPLICATE
{{< /mermaid >}}

## The Two Pillars of Effectively-Once

Real exactly-once semantics rest on two ideas. Either alone is insufficient; together they cover the duplicate problem end to end.

### Pillar 1: Idempotent Operations

An operation is idempotent if applying it multiple times yields the same result as applying it once. If processing is idempotent, duplicate delivery becomes harmless — reprocessing the same message a second time changes nothing observable.

Some operations are naturally idempotent: `SET balance = 100` (vs. the non-idempotent `ADD 50`), or `DELETE WHERE id = x`. Others must be *made* idempotent with a deduplication key:

```sql
-- Non-idempotent: re-running double-charges
UPDATE accounts SET balance = balance - 50 WHERE id = 'acct1';

-- Idempotent: a unique key makes the second apply a no-op
INSERT INTO ledger (txn_id, acct, delta) VALUES ('txn-789', 'acct1', -50)
ON CONFLICT (txn_id) DO NOTHING;
```

The `txn_id` is the deduplication key. The first insert applies the debit; a retried insert with the same key hits the conflict and does nothing. The "exactly-once" effect is achieved even though delivery was at-least-once.

### Pillar 2: Atomic State + Offset Commit

The subtler half. A stream processor reads a message, updates some state, and must record that it consumed the message (commit the offset). If these are two separate operations, a crash between them breaks the guarantee:

- Commit offset *then* crash before updating state → message effectively lost (at-most-once).
- Update state *then* crash before committing offset → message reprocessed (at-least-once).

The only way to get exactly-once is to make "update state" and "commit offset" **atomic** — they both happen or neither does. How you achieve atomicity defines the architecture.

{{< mermaid >}}
flowchart TD
  A["Consume message at offset N"] --> B["Process: compute state change"]
  B --> C{"Atomic commit"}
  C -->|"state update AND offset N persisted together"| D["Effectively exactly-once"]
  C -->|"two separate writes, crash in between"| E["Duplicate or loss"]
{{< /mermaid >}}

## How Kafka Implements It

Kafka's exactly-once is the canonical production implementation. It combines three features.

### 1. The Idempotent Producer

Each producer gets a Producer ID (PID), and every message carries a monotonic sequence number per partition. The broker tracks the highest sequence number it has accepted per (PID, partition). A retried send with an already-seen sequence number is acknowledged but *not* re-appended. This deduplicates the producer-to-broker hop — solving the lost-ack problem from earlier.

```properties
enable.idempotence=true   # PID + sequence numbers; dedup at the broker
acks=all                  # required: wait for all in-sync replicas
```

### 2. Transactions Across Topics

The idempotent producer only dedups within a single producer session and partition. For a consume-transform-produce loop you need more: the *consumer offset commit* and the *produced output records* must commit atomically. Kafka models the offset commit as just another write to an internal topic, then wraps everything in a transaction:

```java
producer.initTransactions();
while (running) {
    var records = consumer.poll(timeout);
    producer.beginTransaction();
    for (var rec : records) {
        producer.send(transform(rec));         // output records
    }
    // commit consumer offsets INSIDE the transaction
    producer.sendOffsetsToTransaction(offsetsOf(records), consumerGroupMetadata);
    producer.commitTransaction();              // atomic: outputs + offsets
}
```

If the process crashes mid-transaction, the broker aborts it on transaction timeout: the output records are marked aborted and the offsets are not advanced. On restart, the same input is reprocessed and a *fresh* transaction is committed. No duplicate is ever visible downstream.

### 3. Read-Committed Consumers

Aborted-transaction records physically exist in the log. A consumer must skip them:

```properties
isolation.level=read_committed   # never deliver records from aborted txns
```

With `read_committed`, downstream consumers see only the output of committed transactions. The duplicates produced by retries and the partial output of crashed transactions are filtered out, completing the end-to-end illusion.

## How Stream Processors Implement It (Flink)

Flink takes a different route: distributed snapshots via the Chandy-Lamport algorithm. Special *checkpoint barriers* flow through the dataflow graph. When an operator receives barriers on all its inputs, it snapshots its state. When the barrier reaches the sinks and all snapshots succeed, the checkpoint is committed.

For exactly-once to extend to *external* sinks, Flink uses two-phase commit:

```text
checkpoint N barrier arrives at sink
  -> phase 1: sink "pre-commits" (writes to a staging area / opens a txn)
  -> checkpoint coordinator confirms all operators snapshotted
  -> phase 2: sink "commits" (makes staged data visible)
  -> on failure before commit: restore from checkpoint N-1, replay, re-stage
```

Source offsets are part of the checkpointed state, so restoring a checkpoint atomically rewinds both the read position and the operator state to a consistent point — exactly the atomic offset+state property from Pillar 2, generalized across a distributed graph.

## The Sink Is Where Theory Meets Reality

The hardest part of exactly-once is almost always the *sink* — the boundary where your processed data leaves the system into a database, cache, or external API. Inside Kafka or Flink the guarantee is internal; the moment you write outward, you need the sink to participate.

There are three viable sink patterns:

1. **Transactional sink.** The sink supports transactions that the processor coordinates (Kafka-to-Kafka, or a DB with two-phase commit). Strongest, but requires sink cooperation.
2. **Idempotent sink.** The sink write is idempotent via a deduplication key (Pillar 1) — e.g., upsert by a deterministic primary key derived from the input. Works with any store that supports upserts; usually the pragmatic choice.
3. **Dedup table.** Maintain a table of processed message ids; check-and-insert atomically with the business write in one local transaction.

```sql
BEGIN;
  INSERT INTO processed_ids (msg_id) VALUES ('m-42');  -- fails if duplicate
  UPDATE inventory SET qty = qty - 1 WHERE sku = 's1';
COMMIT;  -- both or neither; the unique constraint on msg_id dedups
```

If the `processed_ids` insert and the business update are in the same local transaction, a replayed message aborts on the duplicate-key violation and the inventory is untouched. This is exactly-once built entirely from at-least-once delivery plus one local atomic write.

## Costs and When to Skip It

Exactly-once is not free:

| Cost | Impact |
|------|--------|
| Throughput | Transactions and `acks=all` add latency; expect a measurable drop |
| Latency | `read_committed` consumers wait for transaction commits |
| Complexity | Transactional coordination, dedup stores, careful sink design |
| State storage | Dedup keys and tables must be retained long enough to catch retries |

For metrics, logs, and analytics where a duplicate or a rare loss is immaterial, at-least-once with idempotent aggregation is simpler and faster. Reserve true exactly-once for operations with real-world side effects that must not double: charging a card, shipping an order, decrementing inventory, sending a single notification.

## Conclusion

Exactly-once is not a delivery guarantee — it is a *processing outcome* engineered on top of at-least-once delivery. The recipe is always the same two pillars: make operations idempotent (so duplicates are harmless) and make state-plus-offset commits atomic (so a crash never strands you between "did the work" and "recorded the work"). Kafka realizes this with idempotent producers, cross-topic transactions, and read-committed consumers; Flink with checkpoint barriers and two-phase-commit sinks; a humble service with a dedup table and one local transaction. When you next see "exactly-once" on a feature list, read it as "we have done the idempotence and atomicity work for you," and then check the one place it usually leaks: the sink.
