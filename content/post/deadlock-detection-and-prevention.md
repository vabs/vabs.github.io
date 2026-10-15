---
title: "Deadlock Detection and Prevention"
date: 2026-01-24T16:48:00-04:00
draft: false
tags: [backend, concurrency, databases, locking, distributed-systems]
---

## The shape of a deadlock

A deadlock is the concurrency equivalent of two people in a hallway, each stepping the same direction to let the other pass, forever. Formally, it is a cycle of processes each holding a resource the next one needs. No process can proceed, none will release what it holds, and without intervention they wait indefinitely.

Deadlocks appear anywhere there is shared, exclusive resource acquisition: database row locks, mutexes in application code, distributed locks across services, file locks. The mechanisms differ, but the theory is universal, and it is worth understanding deeply because deadlock bugs are intermittent, load-dependent, and notoriously hard to reproduce.

## The four Coffman conditions

A deadlock can occur if and only if all four of these conditions hold simultaneously. Break any one and deadlock becomes impossible — this framing is the foundation of every prevention strategy.

| Condition | Meaning |
|---|---|
| Mutual exclusion | Resources cannot be shared; only one holder at a time |
| Hold and wait | A process holds resources while waiting for more |
| No preemption | Resources cannot be forcibly taken; only voluntarily released |
| Circular wait | A closed chain exists where each process waits on the next |

The classic illustration: two transactions each lock one row, then each tries to lock the row the other holds.

{{< mermaid >}}
graph LR
    A["Row A"] -->|"held by"| T1["Transaction 1"]
    B["Row B"] -->|"held by"| T2["Transaction 2"]
    T1 -->|"wants"| B
    T2 -->|"wants"| A
{{< /mermaid >}}

The arrows form a cycle, which is the visual signature of every deadlock. The entire field of deadlock handling is about either preventing that cycle from forming or detecting it once it does.

## Strategy 1: Detection and recovery

The pragmatic strategy used by most databases: let deadlocks happen, detect them, and break them by aborting a victim. The engine maintains a **wait-for graph** where each node is a transaction and each edge means "is waiting for a lock held by." A deadlock exists exactly when this graph contains a cycle.

{{< mermaid >}}
graph TD
    A["Lock request blocks"] --> B["Add edge to wait-for graph"]
    B --> C{"Cycle detected?"}
    C -->|"No"| D["Wait normally"]
    C -->|"Yes"| E["Select victim transaction"]
    E --> F["Roll back victim, release its locks"]
    F --> G["Surviving transactions proceed"]
    G --> H["Application retries victim"]
{{< /mermaid >}}

PostgreSQL runs cycle detection on a timer: when a transaction has waited for `deadlock_timeout` (default 1 second), it triggers a check. Running detection lazily avoids the overhead of checking on every lock acquisition, since most waits resolve on their own.

```sql
-- PostgreSQL detects this automatically
-- Session 1
BEGIN; UPDATE accounts SET bal = bal - 10 WHERE id = 1;  -- locks row 1
-- Session 2
BEGIN; UPDATE accounts SET bal = bal - 10 WHERE id = 2;  -- locks row 2
-- Session 1
UPDATE accounts SET bal = bal + 10 WHERE id = 2;  -- waits on session 2
-- Session 2
UPDATE accounts SET bal = bal + 10 WHERE id = 1;  -- cycle!
-- ERROR: deadlock detected
-- DETAIL: Process X waits for ShareLock... blocked by process Y
```

### Choosing the victim

Once a cycle is found, the engine aborts one transaction to break it. Victim selection balances fairness against wasted work:

- **Least work done** — abort the transaction that has modified the fewest rows, minimizing rollback cost.
- **Youngest transaction** — abort the one that started most recently.
- **Fewest locks held** — abort the one whose rollback releases the least.

The aborted transaction's application must retry. This is why **every transaction that takes locks needs a retry loop** — deadlock is a recoverable, expected outcome under contention, not a bug to be eliminated entirely.

```python
def transfer_with_retry(conn, src, dst, amount, retries=5):
    for attempt in range(retries):
        try:
            with conn.transaction():
                conn.execute("UPDATE accounts SET bal=bal-%s WHERE id=%s", (amount, src))
                conn.execute("UPDATE accounts SET bal=bal+%s WHERE id=%s", (amount, dst))
            return
        except DeadlockDetected:
            if attempt == retries - 1:
                raise
            sleep(random_backoff(attempt))  # jitter avoids re-collision
```

## Strategy 2: Prevention

Prevention attacks one of the Coffman conditions structurally so that deadlock can never arise.

### Break circular wait: lock ordering

The most practical and widely used technique. Define a global total order on all lockable resources and require every process to acquire locks in that order. If everyone locks lower-numbered resources before higher-numbered ones, a cycle is mathematically impossible — a cycle requires someone to wait "backward" in the ordering, which the rule forbids.

```python
# Always lock accounts in ascending id order, regardless of transfer direction
def transfer(conn, src, dst, amount):
    first, second = sorted([src, dst])
    conn.execute("SELECT * FROM accounts WHERE id=%s FOR UPDATE", (first,))
    conn.execute("SELECT * FROM accounts WHERE id=%s FOR UPDATE", (second,))
    # now safe to update both
```

The earlier deadlock disappears: both transactions now lock row 1 before row 2, so one simply waits for the other and then proceeds. The discipline cost is real — every code path that takes multiple locks must agree on the ordering — but the payoff is total elimination of this deadlock class.

### Break hold-and-wait: acquire all at once

Require a process to request all the locks it will need in a single atomic step, and grant only if all are available. If it cannot get everything, it gets nothing and retries. This prevents the partial-acquisition state that deadlock needs, at the cost of reduced concurrency and the difficulty of knowing your full lock set in advance.

### Break no-preemption: timeouts and wound-wait

Allow locks to be taken away. The simplest form is a **lock timeout**: a transaction that waits too long gives up and rolls back. PostgreSQL offers `lock_timeout`; this converts a potential deadlock into a bounded wait followed by an abort.

More sophisticated are timestamp-based schemes used in distributed databases:

| Scheme | Rule | Behavior |
|---|---|---|
| Wait-die | Older waits for younger; younger requesting older's lock dies | Non-preemptive; older txns wait, younger restart |
| Wound-wait | Older wounds (aborts) younger holder; younger waits for older | Preemptive; older txns proceed, younger restart |

Both use transaction start timestamps to impose a consistent priority, guaranteeing no cycle because priority is a total order. They prevent the *starvation* that naive timeout retries can cause, since an aborted transaction keeps its original (now older, higher-priority) timestamp on retry and eventually wins.

## Distributed deadlocks

In a single database, the wait-for graph lives in one process and cycle detection is straightforward. Across services holding distributed locks — say, two microservices each holding a lock the other needs via a lock manager like Redis or ZooKeeper — no single node sees the whole graph. Options:

- **Global lock ordering** across services (prevention) — the most robust answer.
- **Lease-based locks with TTL** — every distributed lock auto-expires, so a deadlock self-heals after the lease elapses. This is why production distributed locks almost always carry a timeout.
- **Edge-chasing detection** — probe messages travel along wait-for edges; if a probe returns to its origin, a cycle exists. Powerful but complex and rarely worth it versus leases.

## Livelock: the lookalike

A close cousin worth naming: **livelock**, where processes are not blocked but keep responding to each other and make no progress — the hallway shuffle where both keep stepping aside in sync. Naive deadlock recovery can cause it: two transactions repeatedly deadlock, both abort, both retry simultaneously, deadlock again. The fix is **randomized exponential backoff** so retries desynchronize, which is why the retry loop above uses jitter.

## Choosing an approach

For most application code against a single database, the answer is layered: **rely on the database's built-in detection**, wrap transactions in retry loops with jittered backoff, and **impose consistent lock ordering** in any code path that touches multiple rows or tables to slash the deadlock rate at the source. Reserve prevention schemes like wound-wait for distributed systems where centralized detection is impractical, and always give distributed locks a TTL so the system cannot wedge permanently.

The unifying insight is the four Coffman conditions: every technique is just a choice of which one to break, and the trade-off is always concurrency and complexity against the certainty of never deadlocking. Detection accepts deadlocks and pays at recovery time; prevention pays up front in discipline and lost parallelism. Knowing which condition your strategy targets tells you exactly what it costs and what it guarantees.
