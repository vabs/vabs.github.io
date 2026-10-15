---
title: "Read Replicas Lag Monitoring"
date: 2026-03-16T11:05:00-04:00
draft: false
tags: [backend, replication, databases, monitoring, postgresql]
---

## The promise and the catch

Read replicas are the standard first move for scaling reads. You point writes at a primary, stream its changes to one or more replicas, and fan out read traffic across them. Storage stays in sync automatically, and you get more read capacity by adding nodes.

The catch is that replication is asynchronous by default. A replica is always some amount of time *behind* the primary. That gap is **replication lag**, and it is the single most important thing to monitor about a replicated system. Lag is invisible when small and catastrophic when large: a user updates their profile, the read hits a lagging replica, and they see their old data. Worse, an order is written and a downstream job reads from a replica that hasn't caught up, so the order "doesn't exist" yet.

You cannot eliminate lag without giving up the performance that replicas exist to provide. So you measure it, alert on it, and design your application to tolerate it.

## How replication actually works

To monitor lag meaningfully you have to know what is being delayed. In PostgreSQL the pipeline looks like this:

{{< mermaid >}}
graph TD
    A["Primary commits transaction"] --> B["Write to WAL"]
    B --> C["WAL sender streams to replica"]
    C --> D["Replica receives WAL (write lag)"]
    D --> E["Replica flushes WAL to disk (flush lag)"]
    E --> F["Replica replays WAL (replay lag)"]
    F --> G["Data visible to read queries"]
{{< /mermaid >}}

There are three distinct lags, and they are not the same number:

- **Write lag**: time for the primary's WAL to *reach* the replica's receiver.
- **Flush lag**: additional time to *persist* that WAL to the replica's disk.
- **Replay lag**: additional time to *apply* the WAL so the changes become visible to queries.

The one that matters for read correctness is **replay lag** — until WAL is replayed, the data is not queryable. A replica can have received and flushed everything (zero write/flush lag) but still be far behind on replay because a single long-running query on the replica is blocking WAL application.

## Measuring lag: time versus bytes

There are two units of lag, and you need both.

### Byte lag

How many bytes of WAL the replica is behind the primary's current write position. On the primary:

```sql
SELECT
    client_addr,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
```

Byte lag is cheap to compute and great for spotting the replica falling behind in throughput terms. Its weakness: 50 MB of lag means nothing to a human. Is that one second or five minutes? Depends entirely on write rate.

### Time lag

How many seconds of wall-clock the replica is behind. On the replica:

```sql
SELECT
    CASE
        WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
        ELSE EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())
    END AS replay_lag_seconds;
```

Time lag is what you alert on because it maps to user experience: "reads may be up to 8 seconds stale." The subtlety is the guard clause. `pg_last_xact_replay_timestamp()` is the commit time of the last replayed transaction. On an **idle** primary, that timestamp keeps aging even though the replica is perfectly caught up — there are simply no new transactions. Without the `receive_lsn = replay_lsn` check you would report growing lag on a healthy idle system and page someone at 3 a.m. for nothing.

| Metric | Where to query | Best for | Pitfall |
|--------|----------------|----------|---------|
| Replay lag (bytes) | Primary, `pg_stat_replication` | Throughput / capacity | Not human-readable |
| Replay lag (seconds) | Replica, `pg_last_xact_replay_timestamp` | Alerting on staleness | False positive when idle |
| Replication slot retained WAL | Primary, `pg_replication_slots` | Disk-fill risk | Easy to forget |

## The replication slot trap

PostgreSQL replication slots guarantee the primary retains WAL until the replica has consumed it. This prevents the replica from falling off a cliff if it disconnects briefly. But it has a dangerous edge: if a replica goes away and never comes back, its slot keeps the primary from recycling WAL **forever**. WAL piles up, the primary's disk fills, and the primary goes read-only or crashes. A dead replica can take down your primary.

Monitor `pg_replication_slots` for slots that are inactive or retaining excessive WAL:

```sql
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
```

Alert when an inactive slot retains more WAL than you can afford, and have a runbook to drop abandoned slots.

## Common causes of lag spikes

Lag is usually flat and small, then suddenly spikes. The causes cluster into a few categories:

**Long-running queries on the replica.** By default, replaying WAL can conflict with queries reading old row versions. PostgreSQL must either cancel the query or pause replay. With a large `max_standby_streaming_delay` (or `-1`) it pauses replay, which protects the query but grows replay lag for everyone. An analyst's 20-minute report on a replica can stall replay for every reader on that replica.

**Write bursts on the primary.** A bulk import, a backfill, or a schema migration generates WAL faster than the replica can apply it. Single-threaded WAL replay on the replica becomes the bottleneck. The byte lag balloons; time lag follows.

**Network saturation.** Cross-region replicas are limited by bandwidth and latency between regions. A network hiccup shows up first as write lag.

**Replica resource starvation.** A replica under-provisioned relative to the primary cannot keep up with replay even at steady state. The replica needs comparable IO and CPU to the primary for the apply phase.

{{< mermaid >}}
stateDiagram-v2
    [*] --> Healthy: lag under threshold
    Healthy --> Elevated: write burst or long query
    Elevated --> Healthy: burst clears, replay catches up
    Elevated --> Critical: lag exceeds SLA, keeps climbing
    Critical --> Degraded: route reads to primary
    Degraded --> Healthy: replica recovers, re-add to pool
    Critical --> [*]: replica removed / rebuilt
{{< /mermaid >}}

## Designing the application for lag

Monitoring tells you about lag; the application has to *tolerate* it. Three patterns, from cheapest to strongest:

### Read-your-writes via primary pinning

After a user performs a write, route their subsequent reads to the primary for a short window (a few seconds, longer than typical lag). The user always sees their own changes; everyone else's reads still scale on replicas. Implement it with a per-session timestamp or a "wrote-recently" flag.

### Lag-aware routing

The connection router knows each replica's current lag and excludes any replica above a threshold from the read pool. Reads with strict freshness requirements demand a replica under, say, 1 second; tolerant reads accept anything. When all replicas are too stale, fall back to the primary.

```python
def pick_replica(replicas, max_lag_seconds):
    fresh = [r for r in replicas if r.lag_seconds <= max_lag_seconds]
    return random.choice(fresh) if fresh else PRIMARY
```

### Causal consistency with LSN tokens

The strongest pattern. On a write, the primary returns the commit LSN. The client carries that LSN to its next read, and the router only uses a replica whose `replay_lsn >= token`. This guarantees the read reflects at least that write, without pinning everything to the primary. It is more machinery but gives precise per-request freshness guarantees.

## Alerting that does not lie

A good lag alerting setup has these properties:

- **Alert on time lag, not bytes** — it maps to user impact.
- **Tier the thresholds.** A warning at the edge of your freshness SLA, a page when lag threatens correctness or keeps climbing. A momentary 2-second spike during a nightly batch is not a page.
- **Suppress the idle false positive** with the `receive = replay` guard.
- **Alert on inactive replication slots** separately — that protects the primary's disk, a different and more urgent failure.
- **Track the rate of change.** Lag growing at a steady 1s per second means replay is fully stalled and will never recover on its own; that is more urgent than a high but stable value.

Dashboard the per-replica replay lag as a time series, overlaid with primary write rate. The correlation between write bursts and lag spikes is usually the first thing you'll want when debugging.

## Synchronous replication: trading latency for zero lag

If even seconds of lag are unacceptable for certain data, synchronous replication makes the primary wait for a replica to confirm before the commit returns. With `synchronous_commit = remote_apply`, replay lag for that path drops to zero (the default `on` only waits for the replica to flush WAL, not replay it), but every write now pays the round-trip to the replica, and if the synchronous replica is unavailable, writes block. PostgreSQL's quorum syntax in `synchronous_standby_names` (`ANY 1 (replica_a, replica_b)`) lets you require acknowledgement from any one of several replicas, balancing durability against availability. Use it surgically for the data that truly needs it, not as a blanket setting.

## Summary

Replication lag is the unavoidable tax of asynchronous read replicas, and the gap between the primary and a replica's *replayed* state is what determines whether reads are correct. Measure replay lag in both bytes (capacity) and seconds (user impact), guarding against the idle-primary false positive. Watch replication slots so a dead replica can't fill the primary's disk. Lag spikes come from long replica queries, write bursts, network limits, and under-provisioned replicas. Tolerate lag in the application with read-your-writes pinning, lag-aware routing, or LSN tokens — and reach for synchronous replication only where zero lag is worth the latency.
