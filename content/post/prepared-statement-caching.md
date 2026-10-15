---
title: "Prepared Statement Caching"
date: 2026-03-20T10:14:00-04:00
draft: false
tags: [backend, databases, performance, postgresql, query-optimization]
---

## What a prepared statement actually buys you

Every SQL query the database receives goes through a pipeline before a single row is touched: it is parsed into a syntax tree, analyzed and rewritten (resolving table and column names, expanding views), and then planned — the optimizer enumerates join orders, index choices, and scan strategies and picks the cheapest. Only then does execution begin.

For a trivial point lookup, this planning overhead can rival or exceed the execution itself. If you run the same query shape thousands of times per second, re-parsing and re-planning each time is pure waste.

A **prepared statement** lets you pay the parse-and-plan cost once and reuse the result. You send the query text with placeholders, the database prepares it, and subsequent executions just supply parameter values:

```sql
PREPARE get_user (int) AS
    SELECT id, name, email FROM users WHERE id = $1;

EXECUTE get_user(42);
EXECUTE get_user(99);   -- reuses the parse + (often) the plan
```

There's a second, equally important benefit: prepared statements with bound parameters are immune to SQL injection. The parameter values can never be interpreted as SQL, because the statement structure is fixed before any value is supplied. This is why parameterized queries are the default safe way to talk to a database, independent of any performance concern.

## Where the caching happens

"Prepared statement caching" is ambiguous because there are two distinct caches at two layers, and confusing them causes most of the trouble people hit.

{{< mermaid >}}
graph TD
    A["Application code: pool.query(sql, params)"] --> B["Driver / pool statement cache"]
    B -->|cache miss| C["Send PREPARE to server"]
    B -->|cache hit| D["Send EXECUTE only"]
    C --> E["Server-side prepared statement (per session)"]
    D --> E
    E --> F["Parse + plan stored on the connection"]
{{< /mermaid >}}

### Server-side prepared statements

The database stores the parsed statement and an execution plan, scoped to a **single connection/session**. When the session ends, the prepared statement is gone. This is the cache that saves parse and plan work.

The session-scoping has a sharp consequence in pooled environments: a prepared statement created on connection A does not exist on connection B. If your pool hands the next request a different connection, the prepare is wasted. Drivers handle this by maintaining a per-connection cache and re-preparing on each physical connection as needed.

### Driver/client-side statement cache

The database driver keeps a map of `SQL text -> prepared statement handle` per connection. The first time it sees a query string on a connection, it issues `PREPARE` and stores the handle; afterwards it issues only `EXECUTE`. This is what turns "use prepared statements" from a manual ceremony into something automatic.

```java
// JDBC with a statement cache: identical SQL text is auto-prepared once per connection
String sql = "SELECT id, name FROM users WHERE id = ?";
try (PreparedStatement ps = conn.prepareStatement(sql)) {
    ps.setInt(1, userId);
    ResultSet rs = ps.executeQuery();
}
```

The cache is keyed on the **exact SQL string**. This is the most important practical fact about statement caching: string-identical queries share a cached statement; string-different ones do not, even if they're logically equivalent.

## The string-identity trap

Because the cache key is the literal SQL text, anything that varies the text defeats it.

The most common way to defeat it accidentally is **inlining values instead of using parameters**:

```python
# Defeats the cache: every distinct id produces a unique SQL string
db.execute(f"SELECT * FROM users WHERE id = {user_id}")

# Uses the cache: one SQL string, values bound separately
# (with a server-side-binding driver such as psycopg 3; psycopg2 interpolates client-side)
db.execute("SELECT * FROM users WHERE id = %s", (user_id,))
```

The first form generates a brand-new statement for every id — millions of one-shot prepares, the cache never hitting, and as a bonus a SQL injection vulnerability. The second form is a single cached statement reused forever.

Other text-variance traps:

- Whitespace and comment differences (`WHERE id=$1` vs `WHERE id = $1`) are different keys.
- Dynamically built `IN` clauses with varying element counts (`IN ($1,$2)` vs `IN ($1,$2,$3)`) produce a different statement per cardinality. Prefer `= ANY($1)` with an array parameter, which is one stable statement for any number of values.

| Pattern | Cache behavior | Fix |
|---------|---------------|-----|
| f-string / concatenated values | New key every value; never hits | Bind parameters |
| Varying `IN (...)` length | New key per element count | Use `= ANY($1::int[])` |
| Inconsistent formatting | Separate cache entries | Centralize query strings |
| Identical parameterized SQL | Hits after first prepare | This is the goal |

## The generic plan problem

Server-side prepared statements introduce a subtlety that can make a query *slower*, not faster. When the optimizer plans a prepared statement, it can choose a **custom plan** (re-planned each execution using the actual parameter values) or a **generic plan** (planned once, parameter-blind, reused for all values).

PostgreSQL uses an adaptive heuristic: the first several executions get custom plans, and if their average cost is not better than the generic plan, it switches to the generic plan permanently (controllable via `plan_cache_mode`).

The generic plan wins when data is uniform — it skips re-planning entirely. It loses badly when the data is **skewed**. Imagine `WHERE status = $1` where 99% of rows have `status = 'archived'` and 0.1% have `status = 'pending'`:

- For `'pending'`, an index scan is ideal — it touches a handful of rows.
- For `'archived'`, a sequential scan is ideal — the index would be slower than just reading the table.

A generic plan must commit to one strategy for both. If it picks the index scan, the `'archived'` query becomes catastrophically slow. This is the prepared-statement performance regression that surprises people: they "optimized" by preparing statements and a subset of queries got 100x slower because they lost the per-value custom plan.

{{< mermaid >}}
stateDiagram-v2
    [*] --> CustomPlanning: first executions
    CustomPlanning --> CustomPlanning: cost varies by value
    CustomPlanning --> GenericPlan: avg custom cost not better than generic
    GenericPlan --> GenericPlan: reused, no re-planning
    GenericPlan --> Regression: skewed data hits wrong plan
    Regression --> ForceCustom: SET plan_cache_mode = force_custom_plan
    ForceCustom --> [*]
{{< /mermaid >}}

The remedy when you hit this: force custom plans for the affected query (`plan_cache_mode = force_custom_plan`), or avoid server-side preparation for queries over skewed columns and accept the re-plan cost as the price of a correct plan per value.

## Prepared statements through a connection pooler

PgBouncer in **transaction pooling** mode breaks naive server-side prepared statements. In transaction mode, a client gets a real server connection only for the duration of a transaction, then it's returned to the pool and may be handed to a different client. A prepared statement created in one transaction won't exist on the connection a later transaction receives — you get `prepared statement "S_1" does not exist` errors.

There are three ways out:

1. **Session pooling** instead of transaction pooling — each client keeps its server connection, so prepared statements persist. This sacrifices the multiplexing that makes the pooler valuable.
2. **Disable server-side prepared statements** in the driver and let it send full query text each time (still parameterized for safety, just re-parsed). You lose the plan-caching benefit but keep transaction pooling.
3. **Use a pooler/driver that supports protocol-level prepared statement tracking** — newer PgBouncer versions can track and re-prepare statements across the pool transparently.

The right choice depends on whether your bottleneck is parse/plan CPU on the database (favor session pooling or transparent tracking) or connection count (favor transaction pooling with prepared statements disabled).

## Measuring the impact

Don't guess whether statement caching is helping. Measure parse and plan time. In PostgreSQL, `EXPLAIN (ANALYZE, BUFFERS)` reports planning time and execution time separately:

```text
Planning Time: 0.412 ms
Execution Time: 0.087 ms
```

When planning time dwarfs execution time and the query runs at high frequency, prepared statements are a clear win. When execution dominates, the parse/plan saving is noise and you should focus elsewhere. The `pg_stat_statements` extension (with `pg_stat_statements.track_planning` enabled, which is off by default) aggregates planning vs execution time across all calls, making it easy to find the high-frequency, plan-heavy queries that benefit most.

## Practical guidance

- **Always parameterize.** It's the safe default and the prerequisite for any statement caching to work.
- **Centralize query strings** so identical queries share a cache entry and formatting drift doesn't fragment the cache.
- **Use array parameters** (`= ANY($1)`) instead of variable-length `IN` lists.
- **Watch for generic-plan regressions** on skewed columns; force custom plans where a single plan can't serve all values.
- **Match pooling mode to your prepared-statement strategy** — transaction pooling and naive server-side prepares don't mix.
- **Measure planning vs execution time** to know whether caching is even worth it for a given query.

## Summary

Prepared statement caching reuses the parse and plan work for repeated query shapes, and parameterization additionally closes off SQL injection. The cache lives at two layers — a per-connection driver cache keyed on exact SQL text, and a per-session server-side statement that stores the plan. The text-identity key means inlined values silently defeat the cache, while parameters and array arguments keep it effective. The main hazard is the generic plan: parameter-blind plan reuse that regresses badly on skewed data, fixable by forcing custom plans. In pooled deployments, server-side prepares fight transaction-mode poolers, so match your pooling mode to your strategy. Measure planning versus execution time to spend the effort where it pays.
