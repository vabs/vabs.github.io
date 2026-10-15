---
title: "Database Failover and Split-Brain Prevention"
date: 2026-04-24T09:14:32-04:00
draft: false
featured: false
tags: [backend, databases, high-availability, distributed-systems, consensus]
---

## Why Failover Is Harder Than It Looks

A database failover sounds simple: the primary dies, a replica takes over, traffic resumes. In practice, the operation sits squarely in the middle of one of distributed computing's nastiest problems. You cannot reliably distinguish a *crashed* node from a *slow* or *partitioned* node. A primary that stopped responding might be dead, or it might be alive on the other side of a network partition still accepting writes. Promote a replica in that second case and you now have two primaries. That condition is called **split-brain**, and it is the single most dangerous outcome in any high-availability database topology.

This post walks through how failover actually works, why split-brain happens, and the concrete mechanisms — quorum, fencing, leases, and STONITH — that production systems use to prevent it.

## The Anatomy of a Failover

A typical leader-based replication setup has one primary accepting writes and one or more replicas streaming the write-ahead log. Failover involves four phases.

| Phase | What happens | Failure mode |
|-------|--------------|--------------|
| Detection | A monitor decides the primary is unhealthy | False positives from network blips |
| Election | A new primary is chosen among replicas | Two nodes both think they won |
| Promotion | Chosen replica becomes writable | Old primary still accepting writes |
| Reconfiguration | Clients & replicas point at new primary | Stale clients write to old primary |

{{< mermaid >}}
graph TD
  A["Primary healthy"] --> B["Health check fails"]
  B --> C{"Quorum agrees<br/>primary is down?"}
  C -- "No" --> A
  C -- "Yes" --> D["Elect new primary"]
  D --> E["Fence old primary"]
  E --> F["Promote replica"]
  F --> G["Reconfigure clients"]
  G --> H["New primary healthy"]
{{< /mermaid >}}

The critical edge in that diagram is `E -> F`. Fencing the old primary *before* promotion is what separates a safe failover from a data-corrupting one.

## How Split-Brain Actually Occurs

Consider a three-node cluster split by a partition: node A (the old primary) is isolated, while nodes B and C remain connected to each other and to most clients.

If the failover controller lives on B/C's side, it sees A as unreachable and promotes B. But A has not crashed — it still believes it is primary. Any client that can still reach A keeps writing there. Now you have divergent histories:

```text
Old primary A:  W1, W2, W3, W4(A-only)
New primary B:  W1, W2, W3, W5(B-only)
```

When the partition heals, you must reconcile `W4` and `W5`. There is no automatic correct answer. One set of acknowledged writes will be lost or require manual surgery. This is why prevention beats reconciliation.

## Quorum: The First Line of Defense

The foundational rule is that **a node may only act as primary if it can confirm membership in a majority of the cluster.** With `N` nodes, a majority is `floor(N/2) + 1`. A minority partition can never form a quorum, so it can never elect or sustain a primary.

| Cluster size | Quorum | Max failures tolerated |
|--------------|--------|------------------------|
| 3 | 2 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

This is why you almost always run an **odd** number of voting members. A 4-node cluster tolerates only 1 failure (same as 3) but doubles the number of two-node failures that break quorum (six pairs instead of three) — strictly worse. When a true majority cannot be reached, the correct behavior is to refuse writes rather than risk a second primary. Availability is sacrificed to preserve consistency, the classic CP choice in CAP terms.

Where you cannot afford a third full database node, deploy a lightweight **witness** or **arbiter** — a vote-only participant that holds no data but breaks ties.

## Leader Leases: Time-Bounded Authority

Quorum decides *who* may lead; a **lease** bounds *how long* that authority lasts without renewal. A primary holds a lease valid for, say, 10 seconds. It must renew the lease against the quorum before it expires. If it cannot renew — because it is partitioned — it must voluntarily step down and stop accepting writes.

The promotion logic on the other side waits out the lease before activating a new primary:

```python
LEASE_TTL = 10.0          # seconds
CLOCK_SKEW_BUDGET = 2.0   # safety margin

def safe_to_promote(old_lease_expiry, now):
    # Only promote after the old primary's lease has
    # provably expired, accounting for clock skew.
    return now > old_lease_expiry + CLOCK_SKEW_BUDGET

def primary_loop(store):
    while True:
        renewed = store.renew_lease(LEASE_TTL)
        if not renewed:
            step_down()    # stop serving writes immediately
            return
        sleep(LEASE_TTL / 3)
```

The crucial property: the new primary does not activate until the old lease has *certainly* expired, plus a clock-skew margin. The old primary, unable to renew, has stopped serving by then. The two activity windows never overlap. This is the same insight behind etcd, Consul, and Google's Chubby lock service.

{{< mermaid >}}
sequenceDiagram
  participant Old as Old Primary
  participant Q as Quorum Store
  participant New as Replica
  Old->>Q: Renew lease (t=0, ttl=10)
  Note over Old: Partition starts (t=3)
  Old->>Q: Renew (t=6) — fails
  Note over Old: Step down (t=6)
  New->>Q: Lease expired? (t=12)
  Q-->>New: Yes, free since t=10
  New->>Q: Acquire lease (t=12)
  Note over New: Activates as primary
{{< /mermaid >}}

## Fencing: Making the Old Primary Harmless

Leases assume the old primary cooperates by stepping down. A hung process, a paused VM, or a long GC pause can break that assumption — the node resumes after the lease expired, still thinking it is primary. **Fencing** removes the ability of a zombie primary to do damage even if it misbehaves.

### Fencing Tokens

Each time leadership changes, the quorum store issues a monotonically increasing **fencing token**. Every write the primary issues to shared storage carries its token. The storage layer rejects any write whose token is lower than the highest it has seen.

```text
Primary A acquires lease -> token 33
A pauses (long GC)
Primary B acquires lease -> token 34
A wakes, sends write with token 33
Storage: 33 < 34 -> REJECTED
B sends write with token 34 -> ACCEPTED
```

The zombie cannot corrupt anything because its stale token is refused at the resource itself. This requires the storage backend to be token-aware, which is why fencing tokens are common in object stores and lock managers.

### STONITH

When the resource cannot validate tokens, the blunt instrument is **STONITH** — "Shoot The Other Node In The Head." The cluster manager forcibly powers off or network-isolates the old primary (via IPMI, a managed PDU, or a cloud API) before promoting the replica. It is ugly but unambiguous: a powered-off node writes nothing.

## Detection Without Over-Reacting

Aggressive failover causes more outages than it prevents. A primary that pauses for 800 ms during a GC cycle should not trigger a promotion. Tune detection with:

- **Multiple independent observers.** Require agreement from several monitors before declaring death, defeating single-observer network blips.
- **Phi-accrual failure detection** rather than a fixed timeout. It outputs a continuous suspicion level adapted to observed latency variance instead of a binary up/down.
- **Hysteresis.** Demand sustained failure across several intervals before acting, and rate-limit how often automatic failover may fire.

```python
def should_failover(observers, threshold=0.7):
    votes = [o.suspects_primary_dead() for o in observers]
    confidence = sum(votes) / len(votes)
    return confidence >= threshold and quorum_reachable()
```

## Client-Side Reconfiguration

Even a perfect failover fails if clients keep hammering the old address. Approaches:

| Mechanism | How clients find the primary | Trade-off |
|-----------|------------------------------|-----------|
| Virtual IP | VIP moves to new primary | Risk of two nodes claiming the VIP |
| DNS update | Hostname re-points | TTL caching causes slow propagation |
| Service discovery | Client queries registry | Adds a runtime dependency |
| Smart driver | Driver tracks topology directly | Logic pushed into every client |

Modern drivers (the MongoDB and PostgreSQL multi-host connection strings, for example) embed topology awareness so they discover the new primary quickly and refuse to send writes to a demoted node.

## A Concrete Checklist

To run failover safely in production:

1. Use an **odd** number of voting members; add a witness if you only have two data nodes.
2. Require **quorum** for both election and continued write authority.
3. Give the primary a **renewable lease** and make it self-fence on renewal failure.
4. Wait out the old lease **plus clock-skew margin** before promoting.
5. Enforce **fencing tokens** at the storage layer, or fall back to **STONITH**.
6. Make **detection conservative** with multiple observers and hysteresis.
7. Use **topology-aware clients** so traffic follows the real primary.
8. Decide explicitly whether you prefer to **reject writes** (CP) or risk divergence (AP) — and test that path.

## Closing Thought

Split-brain is not an exotic failure; it is the default outcome of a naive failover plus a network partition. Every safe system converges on the same handful of ideas: a majority must agree before anyone leads, leadership is time-bounded, and a deposed leader is rendered physically incapable of writing. Get those three right and failover becomes boring — which, for a database, is exactly what you want.
