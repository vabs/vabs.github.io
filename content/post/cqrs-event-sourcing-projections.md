---
title: "CQRS and Event Sourcing Projections"
date: 2026-03-10T16:53:00-04:00
draft: false
featured: false
tags: [backend, cqrs, event-sourcing, architecture, projections]
---

Most applications use a single data model for both writing and reading: the same tables, the same objects, the same schema serve commands that change data and queries that fetch it. This works until the demands of writes and reads diverge so much that one model can't serve both well. **CQRS** (Command Query Responsibility Segregation) splits them apart. Paired with **event sourcing**, it produces a powerful architecture where the write side records facts and the read side builds whatever views it needs through **projections**. This post focuses on that last, often-underexplained piece: how projections turn an event stream into queryable read models, and the hard problems that come with them.

## The Three Ideas, Briefly

**CQRS** says: use one model to change state (the *command* side) and a different model to read state (the *query* side). They can have different schemas, different databases, even different consistency guarantees.

**Event sourcing** says: don't store the current state of an entity; store the full sequence of events that led to it. The current state is derived by replaying those events. Instead of a row that says `balance = 150`, you store `Deposited 100`, `Deposited 100`, `Withdrew 50`.

**Projections** are the bridge. A projection consumes the event stream and builds a read model optimized for a particular query. The same events can feed many projections, each shaped for a different need.

{{< mermaid >}}
graph LR
  C["Command"] --> AG["Aggregate"]
  AG -->|"emits events"| ES["Event Store"]
  ES -->|"event stream"| P1["Projection: Account Summary"]
  ES -->|"event stream"| P2["Projection: Transaction History"]
  ES -->|"event stream"| P3["Projection: Fraud Analytics"]
  P1 --> R1["Read DB (key-value)"]
  P2 --> R2["Read DB (SQL)"]
  P3 --> R3["Read DB (search index)"]
{{< /mermaid >}}

This is the key payoff: the write side stores facts once, and as many read models as you need are derived from those facts, each in whatever shape and storage technology suits it. A summary view in a fast key-value store, a transaction history in SQL, a fraud-detection feed in a search index, all from the same events.

## What a Projection Actually Is

A projection is a function that folds over events to produce a read model. Conceptually:

```
read_model = fold(apply, initial_state, event_stream)
```

In code, a projection is typically a handler that pattern-matches on event types and updates a read store:

```python
def apply(event, read_db):
    match event.type:
        case "AccountOpened":
            read_db.upsert(event.account_id, {"balance": 0, "owner": event.owner})
        case "Deposited":
            read_db.increment(event.account_id, "balance", event.amount)
        case "Withdrew":
            read_db.increment(event.account_id, "balance", -event.amount)
```

The projection consumes events in order and incrementally maintains a denormalized view. Crucially, the read model is *disposable*. Because it's derived purely from events, you can delete it and rebuild it from scratch by replaying the whole event stream. This is one of event sourcing's superpowers: you can introduce a brand-new read model months after the fact and populate it with full history, because the history was never thrown away.

## The Checkpoint: Tracking Position

A projection must know how far it has processed, so that after a restart it resumes rather than reprocessing everything. This position is called a **checkpoint** (or offset). The projection stores, alongside its read model, the position of the last event it successfully applied.

```python
def run_projection(event_store, read_db, checkpoint_store):
    position = checkpoint_store.load("account_summary") or 0
    for event in event_store.read_from(position):
        apply(event, read_db)
        position = event.global_position
        checkpoint_store.save("account_summary", position)
```

The interaction between updating the read model and saving the checkpoint is the source of the trickiest correctness problems, which we'll get to.

## Eventual Consistency Is the Price

The most important property to internalize: in CQRS with separate read models, the read side is **eventually consistent** with the write side. When a command succeeds and an event is stored, the projection hasn't necessarily processed it yet. There's a window, usually milliseconds but sometimes longer, where a query returns stale data.

This breaks the naive "write then immediately read your own write" expectation. A user updates their profile and the very next page load might show the old value because the projection lagged. You have to design the user experience and the API around this reality. Common strategies:

- **Read-your-writes via the write model.** For the specific entity just modified, read from the write side (or a synchronous cache) so the user sees their own change immediately.
- **Versioned reads.** Return the version the user just wrote and have the client poll the read model until it catches up to that version.
- **Optimistic UI.** Show the expected result client-side immediately and reconcile when the projection catches up.

Pretending the read side is strongly consistent is the most common way CQRS projects go wrong.

## Delivery Semantics and Idempotency

Event delivery to a projection is rarely exactly-once. If the projection crashes after applying an event but before saving its checkpoint, on restart it will reprocess that event. So projections must tolerate reprocessing. There are two ways to achieve this.

**Idempotent updates.** Design the apply logic so that processing the same event twice produces the same result. `read_db.upsert(...)` with the full new value is idempotent; a blind `increment` is *not*, because applying `Deposited 100` twice adds 200. To make increments safe, track the last-applied event version per entity and skip events you've already seen:

```python
def apply_deposit(event, read_db):
    row = read_db.get(event.account_id)
    if event.version <= row["last_version"]:
        return                      # already applied, skip
    row["balance"] += event.amount
    row["last_version"] = event.version
    read_db.put(event.account_id, row)
```

**Atomic checkpoint + update.** Alternatively, write the read-model change and the checkpoint in a single transaction so they can never diverge. This requires the read store and checkpoint store to share a transaction, which constrains your technology choices but eliminates the reprocessing problem entirely.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Reading
  Reading --> Applying: fetch next event
  Applying --> Checkpointing: update read model
  Checkpointing --> Reading: save position (atomic with update)
  Applying --> Crashed: process dies
  Crashed --> Reading: restart, replay from last checkpoint
{{< /mermaid >}}

## Ordering Matters

A projection that increments balances must process an account's events **in order**, or it will compute the wrong result. Most event stores guarantee ordering within a single stream (one aggregate), which is enough if your projection only cares about per-entity order. But a global projection consuming many streams must decide how to handle cross-stream ordering. Two common approaches:

- **Single-threaded global projection.** Consume one global, totally-ordered event log (the approach a log like Kafka with a single partition, or an event store's global position, gives you). Simple and correct but a throughput bottleneck.
- **Partitioned projections.** Shard the projection by entity (e.g., by account ID hash) so each partition processes its events in order independently and in parallel. Scales well but only preserves per-partition order, so your read model must not depend on cross-partition ordering.

## Rebuilding and Versioning Projections

Because projections are derived, you can rebuild them. This is invaluable when you:

- **Fix a bug** in projection logic. Correct the code, delete the read model, replay from event zero.
- **Add a new read model** for a feature that didn't exist when the events were written.
- **Change the read schema.** Build the new version alongside the old, replay history into it, then switch reads over.

A robust pattern is the **blue-green projection**: stand up `v2` of a projection, let it replay the full history into a fresh read store while `v1` continues serving live traffic, and once `v2` catches up to the live position, atomically switch reads to it. This lets you reshape read models with zero downtime.

| Operation | How event sourcing enables it |
|---|---|
| Add new read view | Replay history into a new projection |
| Fix projection bug | Delete read model, replay corrected logic |
| Change read schema | Blue-green: build v2, switch over |
| Audit / debug | The event log is the complete history |
| Temporal queries | Replay events up to any point in time |

## Costs and When to Avoid It

This architecture is not free, and it's frequently over-applied. The costs:

- **Operational complexity.** You run an event store, multiple projections, multiple read databases, checkpoint tracking, and rebuild tooling. That's a lot of moving parts.
- **Eventual consistency.** As discussed, it changes how every read works and complicates the UX.
- **Event schema evolution.** Events live forever, so old event versions must remain readable. You need an upcasting strategy to translate old event shapes into new ones during replay.
- **Cognitive load.** Developers must think in events and accept that "current state" is a derived concept.

Use CQRS with event sourcing when you genuinely need its strengths: a complete audit trail, complex domains where the *sequence* of changes is itself valuable business information, dramatically different read and write workloads, or the ability to derive new views from history. Avoid it for simple CRUD applications where a single relational model serves reads and writes perfectly well. Reaching for this architecture on a basic web app trades real, daily complexity for benefits you'll never use.

## Conclusion

Projections are the engine that makes CQRS and event sourcing pay off. By treating stored events as the single source of truth and deriving read models from them, you gain the freedom to build any number of query-optimized views, rebuild them when logic changes, and add entirely new ones from full history. The price is eventual consistency and a set of correctness disciplines: idempotent or atomically-checkpointed updates to survive reprocessing, careful ordering, and a strategy for evolving long-lived events. Get those disciplines right and projections give you a system that's auditable, flexible, and able to answer questions you hadn't even thought of when you wrote the events. Get them wrong, or apply the pattern where it isn't needed, and you've bought complexity with no return.
