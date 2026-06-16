---
title: "B-tree vs LSM-tree Index Internals"
date: 2026-01-19T15:18:00-04:00
draft: false
tags: [backend, databases, indexing, storage-engines, performance]
---

## Two answers to the same question

Every storage engine has to answer one question: given a key, how do I find its value on disk quickly, and how do I keep that structure efficient as data changes? For decades the answer was the B-tree, the structure beneath PostgreSQL, MySQL's InnoDB, and nearly every relational database. Then the write-heavy era — logging, time series, event streams — made a different answer attractive: the Log-Structured Merge-tree (LSM-tree), which powers RocksDB, Cassandra, LevelDB, and ScyllaDB.

The two structures make opposite bets. B-trees optimize for read efficiency and update in place. LSM-trees optimize for write throughput and never modify data in place. Understanding *why* each bet pays off — and what it costs — is the key to picking a storage engine instead of cargo-culting one.

## B-tree internals

A B-tree (specifically a B+tree in practice) is a balanced, wide, shallow tree. Internal nodes hold keys and child pointers; leaf nodes hold the actual key-value pairs and are linked into a sorted sequence for range scans. Each node is exactly one page — typically 4KB, 8KB, or 16KB — chosen to match the disk and OS page size so that one node read is one I/O.

{{< mermaid >}}
graph TD
    A["Root: keys 30, 60"] --> B["Internal: 10, 20"]
    A --> C["Internal: 40, 50"]
    A --> D["Internal: 70, 80"]
    B --> E["Leaf: 1..9"]
    B --> F["Leaf: 10..19"]
    C --> G["Leaf: 30..39"]
    D --> H["Leaf: 70..79"]
    E -.->|"linked list"| F
    F -.-> G
    G -.-> H
{{< /mermaid >}}

A high branching factor keeps the tree shallow. With a 16KB page holding several hundred keys, a billion rows fit in a tree of depth 3 or 4. A point lookup is therefore a handful of page reads, the top levels of which usually live in the buffer cache.

**The defining property is in-place update.** To change a value, the engine finds the leaf page, modifies it, and writes the whole page back. This creates three problems:

1. **Write amplification.** Changing one row rewrites an entire page. Updating 16 bytes can cost a 16KB write.
2. **The torn-write problem.** A crash mid-write can leave a page half-old, half-new. B-trees solve this with a **write-ahead log (WAL)**: every change is appended to the log before the page is modified, so recovery can replay or undo.
3. **Page splits and fragmentation.** When a leaf fills up, it splits in two, propagating up the tree. Over time, pages end up partially full and physically scattered, degrading range-scan locality.

```text
Insert into a full leaf:
[10|20|30|40]  <- full (fanout 4)
insert 25
-> split:
[10|20]  [25|30|40]
-> push 25 up to parent, which may itself split
```

The B-tree's reward for this complexity: a key is stored in exactly one place, so reads are predictable and a point lookup touches `O(log n)` pages with no merging.

## LSM-tree internals

An LSM-tree refuses to update in place. Writes go to an in-memory sorted structure (the **memtable**, usually a skip list or balanced tree) and to an append-only WAL for durability. When the memtable fills, it is flushed to disk as an immutable **Sorted String Table (SSTable)** — a file of sorted key-value pairs that is never modified again.

{{< mermaid >}}
graph TD
    A["Write arrives"] --> B["Append to WAL"]
    A --> C["Insert into memtable - in RAM"]
    C -->|"memtable full"| D["Flush to immutable SSTable L0"]
    D --> E["Background compaction merges SSTables"]
    E --> F["L1 SSTables - sorted, non-overlapping"]
    F --> G["L2, L3 ... larger levels"]
{{< /mermaid >}}

Because writes are sequential appends, ingest throughput is enormous — disks and SSDs love sequential writes. But this creates the opposite problem of the B-tree: **the same key can exist in many SSTables across many levels**, each version newer than the last. A read must check the memtable, then each level, newest to oldest, and the first hit wins. Deletes are not deletes — they write a **tombstone** marker that suppresses older versions until compaction removes them.

### Compaction: the heart of the LSM-tree

Left alone, SSTables would accumulate forever and reads would slow to a crawl. **Compaction** is the background process that merges SSTables, discarding overwritten values and tombstones, and reorganizing data into levels. Two strategies dominate:

| Strategy | How it works | Optimizes | Penalty |
|---|---|---|---|
| Leveled (RocksDB default) | Each level is one sorted run, ~10x the previous; merges overlapping ranges into next level | Read & space | High write amplification |
| Size-tiered (Cassandra default) | Group SSTables of similar size, merge into one bigger one | Write throughput | High space & read amplification |

Leveled compaction guarantees a key appears at most once per level, so a read checks at most one SSTable per level after the top. Size-tiered allows multiple overlapping SSTables, trading read cost for cheaper writes.

### Making reads fast: Bloom filters and block cache

A naive LSM read could touch every SSTable. Two tricks save it:

- **Bloom filters.** Each SSTable carries a probabilistic filter that answers "is this key *definitely not* here?" with no false negatives. A read skips any SSTable whose filter says no, turning a multi-file scan into one or two real lookups.
- **Sparse block index + block cache.** SSTables are divided into blocks with an in-memory index of block boundaries, so a lookup reads one block, not the whole file.

```python
def lsm_get(key):
    if (v := memtable.get(key)) is not None:
        return None if v is TOMBSTONE else v
    for sstable in sstables_newest_first():
        if not sstable.bloom.might_contain(key):
            continue                      # cheap skip
        if (v := sstable.lookup(key)) is not None:
            return None if v is TOMBSTONE else v
    return None
```

## The amplification trade-offs

Storage engines are judged by three amplifications, and you cannot minimize all three at once — this is the **RUM conjecture** (Read, Update, Memory: optimize two, pay for the third).

| Amplification | B-tree | LSM-tree |
|---|---|---|
| Read | Low and predictable (one path) | Higher (multiple SSTables, mitigated by Bloom filters) |
| Write | Moderate (page rewrites + WAL) | Low at ingest, high over time (compaction rewrites data repeatedly) |
| Space | Fragmentation, half-empty pages | Stale versions until compaction; tombstones linger |

A subtle point about LSM write amplification: although the *initial* write is cheap, compaction may rewrite a given piece of data many times as it migrates down the levels. With leveled compaction and a 10x level ratio, total write amplification can reach 10x or more. The win is that this work is sequential and deferred, off the critical path, whereas a B-tree pays its (smaller) amplification synchronously with random I/O.

## When to choose which

Choose a **B-tree** engine when:

- Reads dominate or read latency must be low and predictable (p99 matters).
- You need strong transactional support — B-trees pair naturally with in-place locking and MVCC.
- Range scans over the primary key are frequent and locality matters.

Choose an **LSM-tree** engine when:

- Writes dominate: ingestion pipelines, time-series, event logs, metrics.
- You can tolerate slightly higher and more variable read latency.
- Sequential write throughput and write endurance (fewer SSD program-erase cycles) matter.

A useful way to internalize it: a B-tree does its housekeeping *now*, synchronously, in small random pieces; an LSM-tree does it *later*, in big sequential batches, accepting temporary disorder. The B-tree gives you a tidy desk at the cost of constant filing; the LSM-tree lets the inbox pile up and sorts it during off-hours. Neither is universally better — they are answers to different workload questions, and the modern split between OLTP relational stores and write-optimized NoSQL engines is largely this single architectural choice playing out at scale.
