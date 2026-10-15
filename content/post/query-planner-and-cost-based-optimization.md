---
title: "Query Planner and Cost-Based Optimization"
date: 2026-01-22T11:05:00-04:00
draft: false
tags: [backend, databases, query-optimization, sql, performance]
---

## From declarative to executable

SQL is declarative: you state *what* you want, not *how* to get it. Between your query and the disk sits one of the most sophisticated pieces of software in a database — the query optimizer — whose job is to transform a logical request into an efficient physical execution plan. For any non-trivial query there are thousands of equivalent plans that differ in cost by orders of magnitude. Choosing well is the difference between a 5ms response and a 5-minute table scan.

Modern relational engines (PostgreSQL, SQL Server, Oracle) use **cost-based optimization (CBO)**: they estimate the cost of candidate plans using statistics about the data and pick the cheapest. Understanding how that estimate is built — and how it goes wrong — is the single most valuable skill in database performance work.

## The pipeline

A query passes through distinct stages before a single row is read.

{{< mermaid >}}
graph LR
    A["SQL text"] --> B["Parser: syntax tree"]
    B --> C["Binder: resolve tables, columns, types"]
    C --> D["Rewriter: logical transforms"]
    D --> E["Optimizer: enumerate plans + cost"]
    E --> F["Chosen physical plan"]
    F --> G["Executor: pull rows"]
{{< /mermaid >}}

The **rewriter** applies algebraic transformations that are always beneficial or that expand the search space: predicate pushdown (apply filters as early as possible), subquery flattening (turn correlated subqueries into joins), constant folding, and view expansion. The **optimizer** then explores physical alternatives for each logical operation and assigns each a cost.

## The three estimation problems

Cost-based optimization rests on three estimates, each a potential failure point.

### 1. Cardinality estimation

How many rows will an operator produce? This is the most important and most error-prone estimate, because errors compound multiplicatively up the plan tree. The optimizer relies on **statistics** collected by `ANALYZE`:

- **Row counts** per table.
- **Histograms** describing the distribution of values in a column (equi-depth or equi-width buckets).
- **Number of distinct values (NDV)** per column.
- **Most common values (MCVs)** and their frequencies, for skewed data.
- **Correlation** between physical row order and logical value order, which informs index scan cost.

For a predicate `WHERE status = 'active'`, the optimizer looks up the selectivity of `'active'` in the MCV list or histogram and multiplies by the row count.

```sql
-- selectivity = fraction of rows expected to match
-- estimated_rows = total_rows * selectivity
EXPLAIN SELECT * FROM orders WHERE status = 'active' AND region = 'US';
-- The optimizer estimates each predicate's selectivity, then combines them.
```

The classic trap is the **independence assumption**: the optimizer combines `status = 'active'` and `region = 'US'` by multiplying their selectivities, assuming they are independent. If the columns are correlated (say, all active orders happen to be in the US), the estimate can be off by 100x. PostgreSQL addresses this with **extended statistics** (`CREATE STATISTICS`) that capture multi-column dependencies.

### 2. Cost modeling

Once cardinalities are estimated, the optimizer assigns a cost to each physical operator using a model of the hardware. PostgreSQL exposes these as tunable constants:

| Parameter | Meaning | Default |
|---|---|---|
| seq_page_cost | Cost of a sequential page read | 1.0 |
| random_page_cost | Cost of a random page read | 4.0 |
| cpu_tuple_cost | Cost to process one row | 0.01 |
| cpu_index_tuple_cost | Cost to process one index entry | 0.005 |
| cpu_operator_cost | Cost of one operator/function call | 0.0025 |

The `random_page_cost / seq_page_cost` ratio of 4:1 reflects spinning-disk assumptions. On SSDs, random reads are much closer to sequential, so lowering `random_page_cost` to ~1.1 often makes the optimizer correctly prefer index scans it was wrongly avoiding.

### 3. Plan enumeration

The optimizer must search the space of equivalent plans, which is dominated by **join ordering**. The number of possible orderings of an n-table join grows factorially. For up to a dozen or so tables, PostgreSQL uses **dynamic programming** (the System R bottom-up approach): compute the best plan for every subset of tables, building up from pairs. Beyond a threshold (`geqo_threshold`, default 12), it switches to a **genetic algorithm** to avoid combinatorial explosion.

## Physical operator choices

For each logical operation, the optimizer picks among physical implementations.

### Access methods

- **Sequential scan** — read every page. Best when most rows match; sequential I/O is cheap.
- **Index scan** — walk the index, then fetch each matching row (random I/O). Best for high selectivity (few matching rows).
- **Index-only scan** — answer entirely from the index without touching the table. Possible when all needed columns are in the index and the visibility map says the page is all-visible.
- **Bitmap heap scan** — build a bitmap of matching page locations from one or more indexes, sort it, then read pages in physical order. Bridges the gap when an index returns a medium number of rows.

### Join algorithms

{{< mermaid >}}
graph TD
    A["Join request"] --> B{"Estimated sizes?"}
    B -->|"small inner, indexed"| C["Nested loop join"]
    B -->|"both large, sortable"| D["Merge join"]
    B -->|"one fits in memory"| E["Hash join"]
    C --> F["O(n*m) but cheap if inner indexed"]
    D --> G["O(n log n + m log m), needs sorted input"]
    E --> H["O(n+m), needs hash table in RAM"]
{{< /mermaid >}}

| Join | Best when | Cost driver |
|---|---|---|
| Nested loop | Inner side small or indexed, outer side tiny | Outer rows x inner lookup |
| Hash join | One side fits in work_mem, equality join | Build + probe; spills to disk if too big |
| Merge join | Both inputs already sorted on join key | Sort cost if not pre-sorted |

## Reading EXPLAIN ANALYZE

The optimizer's estimates are only as good as the statistics. `EXPLAIN ANALYZE` runs the query and shows estimated vs. actual rows side by side — the single most useful diagnostic.

```text
EXPLAIN ANALYZE SELECT * FROM orders o JOIN customers c
  ON o.cust_id = c.id WHERE c.country = 'JP';

Hash Join  (cost=12.4..210.6 rows=50 width=84)
           (actual time=0.3..18.2 rows=4800 loops=1)
  ->  Seq Scan on orders o ...
  ->  Hash
        ->  Seq Scan on customers c
              (cost=0..8.1 rows=5 width=4)
              (actual rows=480 ...)   <-- estimated 5, got 480!
```

When `rows` (estimate) and `actual rows` diverge by a large factor, the optimizer is flying blind. The cascade is the danger: an underestimate at a leaf node makes the optimizer pick a nested loop expecting 5 iterations, but it runs 480 — a plan that is catastrophically wrong because the *input* estimate was wrong, not the cost model.

## When the optimizer gets it wrong, and what to do

Most "the database is slow" incidents trace to estimation failures:

- **Stale statistics.** A bulk load happened but `ANALYZE` did not run. The optimizer thinks the table is empty. Fix: ensure autovacuum/auto-analyze is keeping up, or analyze manually after big changes.
- **Correlated predicates.** Independence assumption misfires. Fix: extended/multi-column statistics.
- **Skewed data.** A value appears far more often than the histogram suggests. Fix: increase the statistics target (`ALTER TABLE ... SET STATISTICS 1000`) so MCV lists are richer.
- **Parameter sniffing / generic plans.** A prepared statement caches a plan optimized for the first parameter value, which is terrible for later values. Fix: force a re-plan or use a custom plan.
- **Bad cost constants.** SSD hardware with disk-era `random_page_cost`. Fix: tune the constants to the hardware.

The deepest lesson: the optimizer is not magic, it is arithmetic on statistics. It will confidently choose a disastrous plan if its inputs are wrong, and it cannot know they are wrong. Your job is less about hinting it toward a plan and more about *feeding it accurate statistics* so its arithmetic lands on the right answer. When you must override it, use `EXPLAIN ANALYZE` to find exactly which estimate diverged from reality, because that divergence — not the chosen operator — is almost always the true cause.
