---
title: "Eventual Consistency Anti-Patterns"
date: 2026-02-01T16:50:00-04:00
draft: false
tags: [backend, distributed-systems, consistency, databases, microservices]
---

Eventual consistency is a deal: you give up the guarantee that a read immediately reflects the latest write, and in exchange you get availability, lower latency, and horizontal scale. It is a perfectly good deal for the right workloads. The trouble starts when teams adopt an eventually consistent store — DynamoDB, Cassandra, an event-driven microservice mesh, a read replica — and then write code as if it were strongly consistent. The bugs that follow are intermittent, environment-dependent, and nearly impossible to reproduce on a developer laptop. This post catalogs the recurring anti-patterns and the patterns that actually work.

## The core misunderstanding

Eventual consistency guarantees exactly one thing: **in the absence of new writes, all replicas will eventually converge to the same value.** It does not say *when*. It does not guarantee that you read your own writes. It does not guarantee that two reads in a row return non-decreasing values. It does not order unrelated operations.

Every anti-pattern below comes from assuming a guarantee the system never made.

## Anti-pattern 1: Read-after-write expectation

The most common bug. A service writes a record, then immediately reads it back — perhaps to render a confirmation page or to make a follow-up decision — and the read hits a replica that has not yet received the write.

```python
# ANTI-PATTERN: assumes the read sees the write
def create_and_show(profile):
    db.write(profile)                # goes to primary
    saved = db.read(profile.id)      # may hit a lagging replica -> None
    return render(saved)             # boom: NoneType has no attribute ...
```

{{< mermaid >}}
sequenceDiagram
  participant App as Application
  participant P as Primary
  participant R as Read Replica
  App->>P: write(profile)
  P-->>App: ack
  App->>R: read(profile.id)
  Note over P,R: replication still in flight
  R-->>App: null (not replicated yet)
  Note over App: renders empty / crashes
{{< /mermaid >}}

**Fixes**, in order of preference:

- **Read your own writes locally.** You already have the object you just wrote — render from that, do not re-read it.
- **Route reads to the primary** for a short window after a write, often keyed on the user's session.
- **Use a consistency knob.** DynamoDB offers `ConsistentRead=True`; Cassandra lets you read at `QUORUM`. These cost latency, so use them only where read-after-write actually matters.

## Anti-pattern 2: Treating absence as deletion

In an eventually consistent system, "I queried and didn't find it" can mean three different things: it never existed, it was deleted, or it exists but hasn't replicated here yet. Code that interprets absence as "deleted" or "safe to recreate" causes duplicates and resurrected data.

```python
# ANTI-PATTERN: absence treated as "doesn't exist, safe to create"
if db.read(user.email) is None:
    db.create(user)   # two concurrent requests both see None -> two users
```

Two requests racing on a replica that lags both read `None` and both create. You now have duplicate accounts. The fix is to push uniqueness to a place that can enforce it atomically: a conditional write (`PutItem` with `attribute_not_exists`), a unique index on a strongly consistent store, or an upsert that is idempotent by design.

## Anti-pattern 3: Distributed transactions across services

Teams coming from monoliths try to recreate ACID transactions across service boundaries, often by chaining synchronous calls and hoping they all succeed.

```python
# ANTI-PATTERN: no atomicity across services
order_svc.create(order)        # succeeds
payment_svc.charge(order)      # succeeds
inventory_svc.reserve(order)   # FAILS — now order + charge are orphaned
```

There is no rollback here. The order exists, the customer is charged, and inventory was never reserved. The fix is the **Saga pattern**: model the workflow as a sequence of local transactions, each with a compensating action that undoes it.

{{< mermaid >}}
graph TD
  A["Create Order"] --> B["Charge Payment"]
  B --> C["Reserve Inventory"]
  C -->|"success"| D["Order Confirmed"]
  C -->|"failure"| E["Compensate: Refund Payment"]
  E --> F["Compensate: Cancel Order"]
  F --> G["Order Failed (clean state)"]
{{< /mermaid >}}

Sagas trade atomicity for availability and require you to design compensations explicitly. They never give you isolation — intermediate states are visible — so model your domain to tolerate "pending" and "reversed" states.

## Anti-pattern 4: Non-idempotent message handlers

Eventually consistent and event-driven systems almost always deliver messages **at least once**. That means duplicates are not an exception — they are guaranteed to happen eventually. A handler that assumes exactly-once delivery double-charges, double-ships, or double-counts.

```python
# ANTI-PATTERN: not idempotent
def handle_payment_event(event):
    account.balance -= event.amount   # replayed event subtracts twice
```

```python
# FIX: idempotent via deduplication key
def handle_payment_event(event):
    if processed_events.exists(event.id):
        return                         # already handled, ignore
    with db.transaction():
        account.balance -= event.amount
        processed_events.insert(event.id)
```

Make every side-effecting handler idempotent. Use the event's unique ID as a deduplication key, or design the operation to be naturally idempotent (set a state to a value rather than incrementing).

## Anti-pattern 5: Ignoring causal ordering

Eventual consistency does not preserve the order of *unrelated* writes, but worse, naive systems can reorder *causally related* ones. If "user posts a comment" and "user deletes the comment" arrive out of order at a replica, you can end up with a deleted comment that reappears, or an update applied before the creation it depends on.

| Symptom | Underlying cause |
| --- | --- |
| Deleted item reappears | Delete delivered, then a delayed update re-creates it |
| Update lost | Update arrives before the create it depends on, gets dropped |
| Comment without parent | Reply replicated before the post |

The fix is to make causality explicit with version vectors, sequence numbers, or logical timestamps, and to reject or buffer out-of-order operations. Many CRDT-based and event-sourced systems do this for you; if you roll your own, you must do it yourself.

## Anti-pattern 6: Polling immediately and giving up

UIs and orchestration code often kick off an async operation, then poll once, see nothing, and report failure — when the operation simply hasn't propagated yet.

```python
# ANTI-PATTERN: single poll, no tolerance for lag
start_export(job_id)
result = check_export(job_id)   # not ready yet
if result is None:
    raise Exception("export failed")  # false negative
```

Replace this with bounded retries and exponential backoff, or better, an event/webhook that fires when the work is genuinely done. Treat "not yet" as a normal state distinct from "failed."

## A checklist that prevents most of these

When building on an eventually consistent foundation, walk through these questions for every operation:

- **Does this read need to see the latest write?** If yes, render from the local copy, route to the primary, or request strong consistency explicitly — and pay for it knowingly.
- **Can this handler run twice safely?** If not, add a deduplication key or redesign for idempotency.
- **What does "not found" mean here?** Distinguish "absent" from "deleted" from "not yet replicated."
- **Does this multi-step workflow need atomicity?** If yes, design a saga with compensations; do not chain calls and pray.
- **Do these writes have a causal relationship?** If yes, attach version information and handle reordering.
- **Does this poll tolerate propagation delay?** Add backoff or switch to event-driven notification.

The throughline is simple: stop pretending the system is strongly consistent. Eventual consistency is not strong consistency with extra latency — it is a different contract. Code written against the contract you actually have is boring and reliable. Code written against the contract you *wish* you had produces the most expensive class of bug there is: the one that only shows up in production, under load, at 3 a.m.
