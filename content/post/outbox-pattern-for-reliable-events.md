---
title: "Outbox Pattern for Reliable Events"
date: 2026-03-12T09:22:00-04:00
draft: false
tags: [backend, messaging, distributed-systems, kafka, consistency]
---

## The dual-write problem

Almost every service that owns data also needs to tell the rest of the system when that data changes. An order service writes a row to its `orders` table and then publishes an `OrderPlaced` event to Kafka. On paper this is two lines of code. In production it is one of the most common sources of silent data loss in distributed systems.

The trouble is that a database transaction and a message broker publish are two independent systems with two independent commit protocols. There is no shared transaction across them. So you are forced into a sequence:

```text
1. BEGIN
2. INSERT INTO orders ...
3. COMMIT
4. producer.send("OrderPlaced", payload)
```

Consider what happens if the process crashes between step 3 and step 4, or if the broker is briefly unreachable. The order exists in the database, but no event was ever published. Downstream consumers — inventory, billing, notifications — never learn about it. The reverse ordering is no better: publish first, then commit, and a rollback leaves you having announced an order that does not exist.

This is the **dual-write problem**: you cannot atomically update two heterogeneous stores. The outbox pattern solves it by collapsing the two writes into one.

## Core idea

Instead of writing to the database and the broker, you write to the database *twice* — both writes inside the same local transaction. The first write is the business change. The second is an `outbox` row describing the event you intend to publish. Because both rows land in the same ACID transaction, they either both commit or both roll back. There is no in-between.

A separate process — the **relay** or **message dispatcher** — reads unpublished outbox rows and forwards them to the broker, marking them published once the broker acknowledges.

{{< mermaid >}}
graph TD
    A["Application transaction"] --> B["INSERT INTO orders"]
    A --> C["INSERT INTO outbox"]
    B --> D["COMMIT (atomic)"]
    C --> D
    D --> E["Relay polls outbox"]
    E --> F["Publish to broker"]
    F --> G["Mark outbox row published"]
    F -.->|broker NACK or crash| E
{{< /mermaid >}}

The key insight is that the broker publish has been moved *out* of the critical path of the user request. The user's transaction succeeds the moment the local commit lands. Delivery to the broker becomes an asynchronous, retryable background job that cannot lose data because the source of truth — the outbox row — is durable.

## Schema design

A minimal outbox table looks like this:

```sql
CREATE TABLE outbox (
    id            BIGSERIAL PRIMARY KEY,
    aggregate_id  TEXT        NOT NULL,
    event_type    TEXT        NOT NULL,
    payload       JSONB       NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at  TIMESTAMPTZ,
    attempts      INT         NOT NULL DEFAULT 0
);

CREATE INDEX idx_outbox_unpublished
    ON outbox (created_at)
    WHERE published_at IS NULL;
```

A few details matter more than they appear:

- The **partial index** on `published_at IS NULL` keeps the relay's polling query fast even when the table has millions of historical rows. Without it the relay scans the whole table on every poll.
- `aggregate_id` lets you preserve per-entity ordering when the relay partitions work, and feeds the broker partition key.
- `attempts` supports backoff and eventually routing to a dead-letter table.

## The relay

The relay's job is deceptively simple: find unpublished rows, publish them, mark them done. The subtleties are all in correctness and ordering.

```sql
-- Claim a batch without two relay instances stepping on each other
UPDATE outbox
SET attempts = attempts + 1
WHERE id IN (
    SELECT id FROM outbox
    WHERE published_at IS NULL
    ORDER BY id
    LIMIT 100
    FOR UPDATE SKIP LOCKED
)
RETURNING id, aggregate_id, event_type, payload;
```

`FOR UPDATE SKIP LOCKED` is the workhorse here. It lets multiple relay instances run concurrently: each grabs a disjoint batch of rows, skipping any that a sibling has already locked. The row locks last only until the claiming transaction commits, so keep that transaction open while the batch is published. This gives you horizontal scaling of the relay without distributed coordination.

After publishing each event and receiving a broker ack, the relay marks the row:

```sql
UPDATE outbox SET published_at = now() WHERE id = $1;
```

### Polling versus log tailing

There are two ways to build the relay, with different operational profiles.

| Approach | How it reads changes | Latency | Database load | Complexity |
|----------|---------------------|---------|---------------|------------|
| Polling | `SELECT ... WHERE published_at IS NULL` on an interval | Tens to hundreds of ms | One query per poll interval | Low |
| Log tailing (CDC) | Reads the database WAL/binlog via Debezium | Single-digit ms | Near zero on the table | Higher; needs CDC infra |

**Polling** is the pragmatic default. You poll every 100–500 ms, process a batch, sleep, repeat. It is trivial to operate and reason about. Its downsides are added latency and the steady drumbeat of queries.

**Change Data Capture (CDC)** via a tool like Debezium tails the transaction log directly. The moment a transaction commits, the new outbox row appears in the WAL and is streamed out. There is no polling query at all, latency is minimal, and the database is barely touched. The cost is operational: you now run a Kafka Connect cluster, manage connector offsets, and handle schema evolution in the log stream.

## Delivery semantics: at-least-once

The outbox pattern gives you **at-least-once** delivery, not exactly-once. This is not a weakness to apologize for; it is the honest guarantee, and you should design around it.

Why at-least-once? Consider the relay publishing an event, the broker accepting it, and then the relay crashing before it can run the `UPDATE ... SET published_at`. On restart the relay sees the row still marked unpublished and publishes it again. The consumer sees the event twice.

```text
relay: publish(event 42)      -> broker ACK
relay: CRASH (before UPDATE)
relay: restart
relay: publish(event 42)      -> broker ACK   # duplicate!
```

Because duplicates are unavoidable, **consumers must be idempotent**. The standard technique is a consumer-side dedup table keyed on the event id:

```sql
INSERT INTO processed_events (event_id) VALUES ($1)
ON CONFLICT (event_id) DO NOTHING;
-- if zero rows affected, we have already processed this; skip
```

The event id flows from the outbox `id`, so it is stable across redeliveries. Combined with the consumer's own business write in the same transaction, you get effective exactly-once *processing* on top of at-least-once *delivery*.

## Ordering

Many domains require events for a single aggregate to arrive in order: you cannot apply `OrderCancelled` before `OrderPlaced`. The outbox preserves per-aggregate order naturally because writes to one aggregate are serialized and the relay reads them ordered by `id`. (Sequence ids are assigned at insert, not at commit, so order across concurrent transactions is not guaranteed.)

To keep that ordering through the broker, route by `aggregate_id` so all events for one order land on the same partition. Within a partition Kafka preserves order; across partitions it does not. The trade-off is throughput: a hot aggregate funnels all its traffic to one partition. For most systems per-aggregate ordering with cross-aggregate parallelism is exactly the right granularity.

{{< mermaid >}}
stateDiagram-v2
    [*] --> Pending: row written in business txn
    Pending --> Publishing: relay claims batch
    Publishing --> Published: broker ACK + UPDATE
    Publishing --> Pending: relay crash before UPDATE
    Publishing --> DeadLetter: attempts exceed max
    Published --> [*]
    DeadLetter --> [*]
{{< /mermaid >}}

## Operational concerns

**Table growth.** The outbox accumulates rows forever unless you prune. Run a periodic job that deletes rows where `published_at < now() - interval '7 days'`. Keep a retention window long enough to debug and replay, short enough to keep the table lean. Deleting in small batches avoids long-held locks and replication lag spikes.

**Poison messages.** A payload that always fails to serialize, or a broker topic that no longer exists, will be retried forever. Cap `attempts` and route exhausted rows to a `dead_letter` table or column for human inspection. Never let one bad row block the head of the queue.

**Monitoring.** The single most important metric is **outbox lag**: the age of the oldest unpublished row, `now() - min(created_at) WHERE published_at IS NULL`. If this grows, the relay is falling behind or stuck. Alert on it. Also track publish rate, attempt counts, and dead-letter volume.

**Throughput.** A single-threaded polling relay tops out around a few thousand events per second. To go higher, run multiple relay instances with `SKIP LOCKED`, increase batch size, or move to CDC. Watch out for producer batching settings — `linger.ms` and `batch.size` on the producer dramatically affect effective throughput.

## When not to use it

The outbox pattern adds a table, a relay process, and a pruning job. That cost is justified when losing or duplicating events corrupts your domain — orders, payments, inventory. It is overkill for fire-and-forget analytics events where occasional loss is acceptable and you would rather not run the infrastructure.

It also assumes your service owns a relational (or otherwise transactional) store. If your write store has no transactions, you cannot get the atomic dual-write that makes the whole pattern work, and you need a different approach such as event sourcing where the event log *is* the source of truth.

## Summary

The outbox pattern turns an impossible atomic dual-write into a possible single transactional write plus an asynchronous, retryable relay. You trade a small amount of latency and some operational machinery for the guarantee that every committed business change eventually, durably, produces its event. Pair it with idempotent consumers and per-aggregate partitioning and you have a reliable eventing backbone that survives crashes, network partitions, and broker outages without losing a single event.
