---
title: "Two-Phase Commit vs Saga Pattern"
date: 2026-01-26T10:33:00-04:00
draft: false
tags: [backend, distributed-systems, microservices, transactions, saga]
---

## The problem of distributed atomicity

A single database gives you atomic transactions for free: a transfer that debits one account and credits another either fully commits or fully rolls back. The moment that logic spans multiple services or databases — order service, payment service, inventory service — that guarantee vanishes. There is no `COMMIT` that spans three databases owned by three teams. You now need a protocol to make several independent commits behave as one logical unit, or to clean up convincingly when they cannot.

Two answers dominate: **Two-Phase Commit (2PC)**, which tries to preserve true atomicity across nodes, and the **Saga pattern**, which abandons atomicity in favor of eventual consistency through compensation. They sit at opposite ends of the consistency-availability trade, and choosing between them shapes the entire reliability posture of a system.

## Two-Phase Commit

2PC is a consensus protocol that coordinates a commit across multiple participants using a **coordinator**. As the name says, it has two phases.

{{< mermaid >}}
graph TD
    C["Coordinator"] -->|"1. PREPARE"| P1["Participant A"]
    C -->|"1. PREPARE"| P2["Participant B"]
    P1 -->|"vote: YES (locked, logged)"| C
    P2 -->|"vote: YES (locked, logged)"| C
    C -->|"2. COMMIT (all voted yes)"| P1
    C -->|"2. COMMIT"| P2
    P1 -->|"ack"| C
    P2 -->|"ack"| C
{{< /mermaid >}}

**Phase 1 (prepare/voting):** the coordinator asks every participant "can you commit?" Each participant does all the work — validates, acquires locks, writes the change to a durable log — but does *not* commit. It then votes YES (promising it can commit if told to) or NO. A YES vote is a binding promise; the participant must hold its locks until it hears the final decision.

**Phase 2 (commit/abort):** if all voted YES, the coordinator records "commit" durably and tells everyone to commit. If any voted NO (or timed out), it tells everyone to abort. Participants apply the decision and release locks.

```text
Coordinator log:                Participant log:
  PREPARE sent          ->        prepared (locks held)
  all YES received      ->        voted YES
  COMMIT decision (durable)
  COMMIT sent           ->        committed, locks released
```

The result is genuine atomicity: every participant commits or every participant aborts, and the outcome is consistent everywhere.

### Why 2PC hurts

2PC is correct but operationally fragile, and the pain is structural, not incidental:

- **It is blocking.** Between voting YES and receiving the decision, a participant is in an *in-doubt* state holding locks. If the coordinator crashes after collecting votes but before broadcasting the decision, participants are stuck holding locks indefinitely — they cannot unilaterally commit (others might abort) or abort (others might commit). This is the notorious blocking problem.
- **Locks held across the network.** Resources stay locked for the full duration of two round-trips plus participant processing, drastically reducing throughput and concurrency.
- **Coordinator is a single point of failure.** Its availability bounds the system's availability.
- **It does not scale.** Latency grows with the slowest participant, and the protocol assumes participants that support a prepare/commit interface — most modern services and many datastores simply do not.

2PC remains appropriate inside tightly controlled environments — XA transactions across a few databases in a single data center, distributed transactions in systems like Spanner that pair 2PC with Paxos to make the coordinator fault-tolerant. But across loosely coupled microservices, its blocking nature is usually disqualifying.

## The Saga pattern

A Saga abandons the goal of global atomicity. Instead it models a distributed transaction as a **sequence of local transactions**, each committed immediately in its own service. If a later step fails, the Saga runs **compensating transactions** that semantically undo the earlier committed steps. The system is never globally locked; it is eventually consistent.

The crucial mental shift: there is no rollback. A committed local transaction stays committed. "Undo" means *executing a new transaction that reverses the business effect* — refunding a payment, releasing reserved inventory, cancelling an order.

{{< mermaid >}}
graph LR
    A["Create order (pending)"] --> B["Reserve inventory"]
    B --> C["Charge payment"]
    C --> D["Confirm order"]
    C -->|"payment fails"| E["Compensate: release inventory"]
    E --> F["Compensate: cancel order"]
{{< /mermaid >}}

### Orchestration vs choreography

Sagas come in two coordination styles.

**Orchestration** — a central orchestrator explicitly drives the steps and triggers compensations. The flow is centralized, visible, and easy to reason about and monitor, at the cost of a component that knows about every participant.

```python
class OrderSaga:
    def execute(self, order):
        try:
            self.order_svc.create(order)
            self.inventory_svc.reserve(order)
            self.payment_svc.charge(order)
            self.order_svc.confirm(order)
        except StepFailed as e:
            self.compensate(order, failed_at=e.step)

    def compensate(self, order, failed_at):
        # run compensations in reverse, only for completed steps
        if failed_at > PAYMENT:    self.payment_svc.refund(order)
        if failed_at > INVENTORY:  self.inventory_svc.release(order)
        if failed_at > CREATE:     self.order_svc.cancel(order)
```

**Choreography** — no central coordinator; each service listens for events and emits its own. The order service publishes `OrderCreated`, inventory reacts and publishes `InventoryReserved`, payment reacts, and failures publish events that trigger compensations. This is decoupled and resilient but the overall flow is implicit and hard to trace — a "where did this saga get stuck" debugging nightmare as it grows.

| Aspect | Orchestration | Choreography |
|---|---|---|
| Coordination | Central orchestrator | Events, peer-to-peer |
| Visibility | High; flow is explicit | Low; flow is emergent |
| Coupling | Orchestrator knows all | Services loosely coupled |
| Failure handling | Centralized, clear | Distributed, harder to trace |
| Best for | Complex flows, many steps | Simple flows, autonomy-focused teams |

### The hard parts of Sagas

Sagas trade 2PC's blocking for a different set of obligations the application must satisfy:

- **No isolation.** Because each step commits immediately, other transactions can see intermediate states — an order exists before payment clears. This is a **lack of isolation** anomaly. You mitigate it with semantic locks (a `pending` status that other reads must respect), commutative updates, or versioning.
- **Compensations must be designed.** Every step needs a meaningful reverse action, and some actions are not cleanly reversible (an email was sent). The fix is often a *pivot* step after which the saga can only go forward, with reversible steps before it.
- **Idempotency is mandatory.** Messages get retried and delivered more than once. Every step and every compensation must be safe to apply multiple times, typically via a deduplication key.
- **Compensations can fail too.** Retry with backoff, and ultimately a dead-letter queue plus human intervention for the genuinely stuck cases.

## Choosing between them

The decision hinges on coupling, scale, and how much temporary inconsistency the business can tolerate.

**Lean toward 2PC when:** participants are few, co-located, and under your control; they natively support prepare/commit (XA-capable databases); the operations are short; and the business truly cannot tolerate ever observing a partial state. Even then, prefer a fault-tolerant coordinator (consensus-backed) over naive 2PC.

**Lean toward Sagas when:** the transaction spans independently deployed microservices; high availability and throughput matter more than instantaneous global consistency; long-running flows would hold 2PC locks unacceptably long; and the business can tolerate brief, visible intermediate states as long as the system converges and compensates correctly. This is the default for modern microservice architectures.

The honest framing: 2PC keeps the simple programming model (atomicity) but pays with availability, locking, and a fragile coordinator. Sagas keep availability and scalability but push real complexity — compensation logic, idempotency, and the absence of isolation — up into the application. There is no free lunch; the distributed atomicity you got for free in a single database must be paid for somewhere, and these two patterns are simply different invoices. The skill is recognizing which cost your system can actually afford.
