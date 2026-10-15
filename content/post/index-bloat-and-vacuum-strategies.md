---
title: "Index Bloat and Vacuum Strategies"
date: 2026-03-23T15:52:00-04:00
draft: false
tags: [backend, postgresql, databases, maintenance, performance]
---

## Why bloat exists at all

To understand index bloat you first have to understand a design decision at the heart of PostgreSQL: **MVCC**, multi-version concurrency control. PostgreSQL never updates a row in place. An `UPDATE` writes a *new* version of the row and marks the old version as obsolete but does not remove it. A `DELETE` just marks the row dead. The old versions — **dead tuples** — stick around so that transactions which started before the change can still see the version they're entitled to. This is what lets readers never block writers.

The consequence is that tables and indexes accumulate dead tuples. The space they occupy is **bloat**: pages that are physically present, consuming disk and memory, but logically empty. Left unchecked, a table that holds 1 GB of live data can balloon to 5 GB of mostly-dead pages, and every sequential scan, every index range scan, every cache fill drags that dead weight along.

```text
Live data:   ████░░░░████░░░░████   (░ = dead tuples)
On disk:     ←——————— 1 GB ———————→  logical
             ←———————— 3 GB ————————→ physical (bloat)
```

`VACUUM` is the process that reclaims dead tuples. The strategy around when and how it runs is one of the defining operational skills of running PostgreSQL well.

## What VACUUM actually does

A plain `VACUUM` does not return disk to the operating system. It scans the table, finds dead tuples whose versions are no longer visible to any running transaction, and marks that space as **reusable** — recorded in the free space map so future inserts and updates can fill it. The file stays the same size; the holes inside become available.

This is the crucial and frequently-misunderstood point. `VACUUM` controls bloat by *recycling* space, keeping the table at a steady size. It is not a shrink operation. If your steady-state working set genuinely needs that space, recycling is exactly right and the file size plateaus.

Beyond reclaiming tuples, `VACUUM` does several other essential jobs:

- Updates the **free space map** and **visibility map** (the latter enables index-only scans and lets future vacuums skip all-visible pages).
- Freezes old row versions to prevent **transaction ID wraparound** — a catastrophic failure mode discussed below.

`VACUUM ANALYZE` additionally refreshes the planner statistics that drive query plans.

{{< mermaid >}}
graph TD
    A["UPDATE / DELETE creates dead tuples"] --> B["Dead tuples accumulate (bloat)"]
    B --> C{"VACUUM runs"}
    C --> D["Dead tuples marked reusable in FSM"]
    D --> E["Space recycled by future inserts"]
    C --> F["Visibility map updated"]
    C --> G["Old XIDs frozen (wraparound defense)"]
    E --> H["Table size stabilizes"]
    B -->|VACUUM never runs| I["Unbounded bloat + wraparound risk"]
{{< /mermaid >}}

## Autovacuum: the background workhorse

You rarely run `VACUUM` by hand. The **autovacuum** daemon launches workers that vacuum tables automatically when they've changed enough. The trigger for a table is governed by a threshold formula:

```text
vacuum threshold = autovacuum_vacuum_threshold
                 + autovacuum_vacuum_scale_factor × reltuples
```

With the default `scale_factor` of 0.2, autovacuum fires when roughly 20% of the table's rows have become dead. That default is fine for small tables and **terrible for large ones**: a 500-million-row table must accumulate 100 million dead tuples before autovacuum touches it. By then bloat is severe and the vacuum itself is a huge, IO-heavy operation.

The standard fix for large hot tables is to lower the scale factor per-table so vacuum runs more often on a smaller delta:

```sql
ALTER TABLE events SET (
    autovacuum_vacuum_scale_factor = 0.02,   -- vacuum at 2% dead, not 20%
    autovacuum_vacuum_threshold    = 1000
);
```

Autovacuum is also deliberately throttled by `autovacuum_vacuum_cost_delay` and `cost_limit` so it doesn't saturate IO. On modern hardware these defaults are often too conservative, leaving autovacuum unable to keep pace with a high-churn table. Loosening the cost limits lets it actually keep up.

## Index bloat specifically

Indexes bloat for the same MVCC reason, plus a wrinkle. When a row is updated, by default a new index entry must be created pointing to the new tuple, and the old index entry becomes dead. Over time, B-tree pages fill with dead pointers and become sparse — half-empty pages that still must be read and cached.

`VACUUM` removes dead index entries but, like with tables, it does not compact the B-tree or return pages. A bloated index has more levels and more pages than it needs, so every lookup reads more pages and the index occupies more cache. You can check index size and usage directly (the `pgstattuple` extension's `pgstatindex()` reports actual leaf density):

```sql
SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size,
       idx_scan
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;
```

An index that is large, bloated, and has `idx_scan = 0` is a double problem: it's wasting space *and* it's unused, so the maintenance cost of vacuuming and updating it buys nothing. Drop unused indexes.

### HOT updates: avoiding index bloat in the first place

PostgreSQL has a powerful optimization called **Heap-Only Tuple (HOT)** updates. If an update does *not* change any indexed column, and there's room on the same page, the new tuple is written to the same page and chained to the old one — and **no new index entry is created**. The index keeps pointing at the page; the chain leads to the live version.

HOT updates avoid index bloat entirely for the updated columns. The lever you control is `fillfactor` — leaving free space on each page so updates have room to stay HOT:

```sql
ALTER TABLE sessions SET (fillfactor = 80);   -- leave 20% per page for HOT updates
```

For a high-update table where the changing columns aren't indexed, tuning fillfactor and ensuring those columns stay un-indexed can dramatically cut both table and index bloat. The trade-off is lower storage density and slightly worse scan locality, so reserve it for genuinely update-heavy tables.

## Reclaiming space when bloat is already bad

`VACUUM` recycles but doesn't shrink. When a table has already bloated badly — say after a one-time mass delete — you have to actively compact it. Two tools, very different profiles.

### VACUUM FULL

`VACUUM FULL` rewrites the entire table and its indexes into fresh, compact files and returns the freed space to the OS. It produces a perfectly packed table. The catch is fatal for availability: it takes an **ACCESS EXCLUSIVE lock** for the whole duration, blocking all reads and writes. On a large table that's minutes to hours of total downtime. It also needs disk space for a full second copy during the rewrite.

### pg_repack

`pg_repack` achieves the same compaction **online**, without a long exclusive lock. It builds a new copy of the table in the background, tracks changes made during the copy via triggers, applies the delta, and swaps the tables with only a brief lock at the very end. For production systems that can't take downtime, this is the standard tool. It costs extra disk and IO during the operation and a bit of complexity, but keeps the table available throughout.

`REINDEX` is the index-specific equivalent for rebuilding a bloated index, and `REINDEX ... CONCURRENTLY` does it without blocking writes.

| Tool | Locks | Returns space to OS | Online | When to use |
|------|-------|--------------------|--------|-------------|
| `VACUUM` | Light, non-blocking | No (recycles) | Yes | Routine, continuous |
| `VACUUM FULL` | ACCESS EXCLUSIVE | Yes | No | Maintenance window only |
| `pg_repack` | Brief at swap | Yes | Yes | Production compaction |
| `REINDEX CONCURRENTLY` | Brief | Yes (index) | Yes | Bloated/corrupt index |

## Transaction ID wraparound: the reason vacuum is non-negotiable

Bloat is a performance problem. Wraparound is an existential one. PostgreSQL stamps every row with a 32-bit transaction id (XID). With only ~4 billion XIDs, the space wraps around. To keep old rows visible forever, `VACUUM` **freezes** old tuples, marking them as permanently visible regardless of XID comparison.

If vacuum falls too far behind, the database approaches wraparound. It first screams in the logs, then refuses new writes entirely, going into a protective read-only-ish state until an emergency vacuum runs. This has taken down major production systems. The defense is simply: never let autovacuum starve. Monitor the age of the oldest unfrozen XID:

```sql
SELECT relname, age(relfrozenxid) AS xid_age
FROM pg_class
WHERE relkind = 'r'
ORDER BY xid_age DESC
LIMIT 10;
```

When `xid_age` on any table climbs toward `autovacuum_freeze_max_age` (default 200 million), aggressive anti-wraparound autovacuums kick in automatically — but if they can't keep up because cost limits are too tight or a long transaction is pinning XIDs, you have a brewing emergency.

{{< mermaid >}}
stateDiagram-v2
    [*] --> Healthy: autovacuum keeps XID age low
    Healthy --> Aging: high write rate, vacuum lagging
    Aging --> Healthy: vacuum catches up, tuples frozen
    Aging --> Warning: xid_age nears freeze_max_age
    Warning --> AntiWraparound: aggressive autovacuum forced
    AntiWraparound --> Healthy: freezing completes
    Warning --> ReadOnly: vacuum blocked, XIDs exhausted
    ReadOnly --> [*]: emergency single-user vacuum
{{< /mermaid >}}

## The enemy of vacuum: long-running transactions

One thing silently sabotages every vacuum strategy: a long-running transaction (or an idle-in-transaction connection, or a stale replication slot). Vacuum can only remove dead tuples that are invisible to *all* running transactions. A single transaction open for hours pins the visibility horizon — dead tuples created after it began cannot be cleaned, on *every* table in that database (a stale replication slot pins it across the whole cluster). Bloat grows and XID age climbs even though autovacuum is running flat out.

This ties index bloat back to operational hygiene from other corners of the system: an abandoned `idle in transaction` connection from a leaking pool, or a forgotten analyst session, can be the root cause of cluster-wide bloat and wraparound risk. Monitor `pg_stat_activity` for old transactions and set `idle_in_transaction_session_timeout`.

## A practical strategy

- **Tune autovacuum per table.** Lower `scale_factor` on large, high-churn tables so vacuum runs on small deltas, and loosen cost limits so it keeps pace.
- **Use fillfactor and avoid indexing volatile columns** to maximize HOT updates and prevent index bloat at the source.
- **Monitor three things:** dead tuple ratio (`n_dead_tup` / `n_live_tup`), index size and usage, and oldest XID age.
- **Reclaim badly bloated objects online** with `pg_repack` and `REINDEX CONCURRENTLY`; reserve `VACUUM FULL` for maintenance windows.
- **Hunt down long-running transactions** — they neutralize everything else.
- **Drop unused indexes** so you're not vacuuming dead weight.

## Summary

Bloat is the natural byproduct of MVCC: updates and deletes leave dead tuples in both tables and indexes. `VACUUM` controls it by recycling that space rather than shrinking files, while also maintaining the visibility map and freezing old transaction ids to prevent wraparound. Autovacuum's default 20% threshold is wrong for large tables — tune it per table and loosen cost limits so it keeps up. Index bloat is best prevented at the source via HOT updates (fillfactor plus not indexing volatile columns), and cured online with `pg_repack` and `REINDEX CONCURRENTLY` rather than the downtime-inducing `VACUUM FULL`. Above all, watch XID age to stay clear of wraparound, and hunt long-running transactions, which quietly defeat every vacuum strategy at once.
