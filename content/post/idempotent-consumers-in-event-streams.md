---
title: "Idempotent Consumers in Event Streams"
date: 2026-06-14T09:30:00-04:00
draft: false
tags: [backend, event-streaming, idempotency, kafka, reliability]
---

In any event-driven system, the consumer will eventually receive the same event twice. This is not a bug you can engineer away — it is a structural consequence of how reliable messaging works. Brokers guarantee at-least-once delivery, which means redelivery on uncertain acknowledgments. Producers retry on lost responses. Rebalances replay uncommitted offsets. Network partitions resurrect in-flight messages. The only robust response is to make the *consumer* tolerate duplicates: to build an **idempotent consumer**, one whose effect on the world is the same whether it processes an event once or ten times.

This post is a practical guide to building idempotent consumers: why duplicates are inevitable, the patterns for deduplication, the subtleties of partial failure, and the operational concerns of running deduplication at scale.

## Why Duplicates Are Inevitable

A consumer's lifecycle has a fundamental gap between *processing* a message and *committing* that it was processed. Whatever order you choose, a crash in the gap produces a duplicate or a loss.

{{< mermaid >}}
sequenceDiagram
  participant B as Broker
  participant C as Consumer
  B->>C: deliver event E (offset 50)
  C->>C: process E (side effects applied)
  Note over C: crash BEFORE committing offset 50
  C->>B: reconnect, resume from last commit (offset 50)
  B->>C: deliver event E AGAIN
  Note over C: duplicate processing
{{< /mermaid >}}

The consumer applied E's side effects, then crashed before committing. On restart it resumes from the last committed offset and reprocesses E. Committing the offset *before* processing would instead risk losing E if the crash lands the other way. Since you must pick at-least-once to avoid loss, duplicates are the price, and idempotency is how you pay it without corrupting data.

Sources of duplicates, summarized:

| Source | Cause |
|--------|-------|
| Consumer crash | Offset not committed before failure |
| Rebalance | Partition reassigned mid-processing, offset uncommitted |
| Producer retry | Lost ack causes the same event to be published twice |
| Replay/reprocessing | Intentional offset rewind for backfill or bug fix |
| Upstream duplication | The source system itself emitted the event twice |

## The Core Pattern: Deduplication by Idempotency Key

Every idempotent consumer needs a stable **idempotency key** that uniquely identifies the unit of work. The key must be derived from the event itself, not generated at processing time, or two deliveries of the same event would get different keys and defeat the purpose.

Good keys, in order of preference:

1. A business-meaningful unique id carried in the event (`order_id`, `payment_id`).
2. A producer-assigned event id (UUID) stamped at publication.
3. A composite of `(topic, partition, offset)` — works for broker-level duplicates but *not* for producer-level duplicates, since a retried publish lands at a different offset.

```python
def idempotency_key(event) -> str:
    # prefer an explicit, producer-stamped id
    if event.get("event_id"):
        return event["event_id"]
    # fall back to a deterministic hash of identifying fields
    return hashlib.sha256(
        f"{event['type']}:{event['aggregate_id']}:{event['version']}".encode()
    ).hexdigest()
```

With a key in hand, the consumer records which keys it has processed and skips any it has seen before.

## Pattern 1: The Inbox Table (Atomic Dedup)

The most reliable pattern stores processed keys in the *same* datastore as the business data, so the dedup check and the business write commit in **one local transaction**. This is the single most important idea in the whole topic: the dedup record and the side effect must be atomic, or a crash between them reintroduces the duplicate.

```sql
BEGIN;
  -- the unique constraint is the dedup; a replay aborts here
  INSERT INTO processed_events (event_id, processed_at)
  VALUES ('evt-9f3a', now());

  -- the actual business side effect
  UPDATE accounts SET balance = balance + 50 WHERE id = 'acct-1';
COMMIT;
```

If the same event is delivered again, the `INSERT` violates the primary-key constraint, the transaction aborts, and the balance is untouched. Processing and dedup succeed or fail together. The application catches the unique-violation and treats it as "already processed — ack and move on":

```python
def handle(event, db):
    try:
        with db.transaction():
            db.execute(
                "INSERT INTO processed_events (event_id) VALUES (%s)",
                (idempotency_key(event),),
            )
            apply_business_logic(event, db)   # same transaction
    except UniqueViolation:
        pass   # duplicate; safe no-op
```

The crucial requirement: `processed_events` and the business tables live in the same transactional store. If your side effect targets a different system (a cache, an external API), this pattern alone does not protect it — see partial failures below.

## Pattern 2: Natural Idempotency (No Dedup Store)

Sometimes the operation is *intrinsically* idempotent and needs no dedup table at all. If the side effect is a "set to this value" rather than a "change by this amount," replays are harmless by construction.

```sql
-- Idempotent: setting status is naturally replay-safe
UPDATE orders SET status = 'shipped', shipped_at = '2026-06-14T09:30:00Z'
WHERE id = 'order-42' AND status != 'shipped';

-- Also idempotent: upsert keyed by a deterministic id
INSERT INTO inventory_snapshots (sku, qty, as_of)
VALUES ('s1', 17, '2026-06-14')
ON CONFLICT (sku, as_of) DO UPDATE SET qty = EXCLUDED.qty;
```

Prefer this whenever possible. The cheapest dedup store is the one you do not need. Designing events to carry *absolute* state (`balance_after = 100`) rather than *deltas* (`add 50`) turns many consumers naturally idempotent.

## Pattern 3: Dedicated Dedup Cache

When the side effect lands in a non-transactional system, you cannot use the inbox-table trick. A common approximation is a fast key-value dedup store (Redis) checked before processing:

```python
def handle(event, redis, sink):
    key = idempotency_key(event)
    # atomic set-if-absent with a TTL
    if not redis.set(f"dedup:{key}", "1", nx=True, ex=DEDUP_TTL):
        return  # already processed
    sink.write(event)   # external, non-transactional
```

This is weaker than the inbox table because the dedup mark and the side effect are *not* atomic: if the process crashes after `redis.set` but before `sink.write`, the event is marked processed but never applied — a silent loss. To regain at-least-once safety you must mark *after* a confirmed write, which reopens the duplicate window. The honest framing: with a non-transactional sink you can have at-least-once or at-most-once, and you choose which way the crash window leans. True exactly-once needs either a transactional sink or an idempotent sink operation.

## The Partial Failure Problem

The hardest case is a consumer with *multiple* side effects — write to the DB, publish a downstream event, call an external API. If it completes two of three and crashes, redelivery reruns all three. Without care, the first two are applied twice.

{{< mermaid >}}
flowchart TD
  A["Receive event E"] --> B["Write to DB"]
  B --> C["Publish downstream event"]
  C --> D["Call external API"]
  D --> E["Commit offset"]
  B -.->|"crash here"| F["Replay reruns B, C, D"]
  C -.->|"crash here"| F
{{< /mermaid >}}

Two structural fixes:

1. **Transactional outbox.** Instead of publishing the downstream event directly, write it to an `outbox` table *inside the same transaction* as the DB change. A separate relay process reads the outbox and publishes. Now the DB write and the intent-to-publish are atomic; the relay is itself an at-least-once publisher whose duplicates the downstream consumer dedups. This collapses the multi-write problem back into the single-transaction inbox pattern.

2. **Make every individual side effect idempotent.** If the external API call is idempotent (via an idempotency key in the request) and the downstream publish is deduplicated by the next consumer, then rerunning all three on replay is safe. Each effect independently tolerates the duplicate.

```sql
-- Outbox: business change + outgoing event, one atomic commit
BEGIN;
  INSERT INTO processed_events (event_id) VALUES ('evt-9f3a');
  UPDATE accounts SET balance = balance + 50 WHERE id = 'acct-1';
  INSERT INTO outbox (id, topic, payload)
    VALUES ('out-1', 'account.credited', '{"acct":"acct-1","amount":50}');
COMMIT;
-- a relay later publishes from outbox and marks rows sent
```

## Operational Concerns

### Bounding the Dedup Store

A naive `processed_events` table grows forever. You must bound it, and the bound is governed by your **maximum redelivery window** — how far apart can two deliveries of the same event arrive? That depends on broker retention, retry policy, and how long replays might run.

| Strategy | Mechanism | Trade-off |
|----------|-----------|-----------|
| TTL eviction | Expire keys after N days | Simple; risks missing very late duplicates |
| Offset-based pruning | Keep keys above a watermark offset | Tight bound; needs offset tracking |
| Time-window table | Partition by day, drop old partitions | Cheap bulk deletes; coarse granularity |

Set the TTL comfortably longer than your worst-case redelivery gap. A key evicted too early lets an old duplicate slip through and corrupt data — the failure mode is silent, so err generous.

### Ordering and Concurrency

Within a single partition, Kafka preserves order, so a consumer processing one partition sequentially sees events in order and the dedup check is simple. But scaling consumers concurrently across keys introduces races: two threads handling the same idempotency key simultaneously can both pass the "have I seen this?" check before either writes. The atomic inbox-table pattern handles this naturally (the database enforces the unique constraint under concurrency); ad-hoc check-then-act in application code does not. Always rely on a storage-level atomic primitive — a unique constraint or an atomic `SET NX` — never a read followed by a separate write.

### Poison Messages

A duplicate that *always* fails (malformed event, a bug) will be redelivered forever, blocking the partition. Pair idempotent processing with a retry limit and a dead-letter queue: after N failed attempts, route the event aside, commit the offset, and alert. Idempotency keeps duplicates safe; the DLQ keeps a single bad message from halting the stream.

## A Checklist for Idempotent Consumers

- Derive the idempotency key from the event, deterministically — never from wall-clock or processing-time state.
- Prefer naturally idempotent operations (set/upsert) over deltas.
- Make the dedup record and the side effect atomic — same transaction, or an atomic store primitive.
- Use a transactional outbox for downstream publishes; rely on idempotency keys for external API calls.
- Bound the dedup store with a TTL safely larger than the worst-case redelivery window.
- Enforce dedup with a storage-level unique constraint, not application-level check-then-act.
- Add a retry limit and dead-letter queue for poison messages.

## Conclusion

Idempotent consumers are the consumer-side foundation of every reliable event-driven system. Because at-least-once delivery makes duplicates structurally unavoidable, correctness depends not on preventing redelivery but on ensuring redelivery is harmless. The toolkit is small and composable: a stable idempotency key, an atomic dedup-plus-side-effect commit, a transactional outbox for fan-out, and disciplined bounding of the dedup store. Get these right and you can reprocess, replay, rebalance, and crash freely — the system's observable state stays exactly what it should be, no matter how many times an event arrives.
