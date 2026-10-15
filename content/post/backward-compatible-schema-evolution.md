---
title: "Backward-Compatible Schema Evolution"
date: 2026-04-23T17:08:55-04:00
draft: false
featured: false
tags: [backend, databases, schema, migrations, data-modeling]
---

## Why Schema Change Is the Hard Part of Backend Work

Writing the first version of a schema is easy. Changing it after millions of rows exist, multiple service versions are deployed, and downtime is unacceptable — that is where backend engineering earns its keep. A careless `ALTER TABLE` can lock a table for minutes, an incompatible column rename can crash every running instance of the old code, and a dropped field can silently corrupt a consumer three services away.

The core constraint is **deployment is not atomic**. During any rollout, old and new code run simultaneously against the same data. Schema changes must therefore be compatible with *both* versions at once. This post covers the compatibility taxonomy, the expand-contract pattern that makes zero-downtime changes possible, and the specifics for both relational databases and serialized message formats.

## The Compatibility Taxonomy

Three terms get used loosely; they are worth pinning down precisely.

| Term | Definition | Who must tolerate what |
|------|-----------|------------------------|
| Backward compatible | New code can read data written by old code | New readers, old data |
| Forward compatible | Old code can read data written by new code | Old readers, new data |
| Full compatible | Both directions hold | Everyone reads everything |

The combination you actually need depends on your rollout. In a rolling deploy, new instances come up while old ones still run, so for the duration you need *both* directions — **full compatibility** is the safe default for anything touched during a live deploy.

The single most important rule follows directly: **adding optional fields is safe; removing or renaming fields is dangerous.** Old code ignores unknown new fields (forward compat) and new code tolerates those fields being missing from old data (backward compat) — but only if those fields are genuinely optional.

## The Expand-Contract Pattern

The pattern that underlies all safe schema evolution is **expand-contract** (also called parallel change). Never transform a schema in one step. Instead, split every breaking change into a sequence of individually-safe steps, each compatible with the code versions running around it.

The canonical example is renaming a column from `email` to `email_address`:

{{< mermaid >}}
graph TD
  A["Start: column 'email'"] --> B["EXPAND: add 'email_address'<br/>(nullable, no constraint)"]
  B --> C["Backfill: copy email -> email_address"]
  C --> D["Dual-write: app writes BOTH columns"]
  D --> E["Migrate readers to email_address"]
  E --> F["Stop writing 'email'"]
  F --> G["CONTRACT: drop 'email'"]
{{< /mermaid >}}

Each arrow is a separate, reversible deployment. At no point does any running code version see a schema it cannot handle. Walk through the phases:

1. **Expand.** Add the new column as nullable. Old code ignores it; new code can use it. This step alone is safe.
2. **Backfill.** Populate the new column from the old, in batches to avoid long locks.
3. **Dual-write.** Deploy code that writes both columns on every update, keeping them in sync while readers transition.
4. **Migrate reads.** Deploy code that reads from the new column. Now nothing depends on the old one.
5. **Stop dual-writing.** Deploy code that only touches the new column.
6. **Contract.** Drop the old column, now provably unused.

This is more steps than a naive rename, but each is independently deployable and rollback-safe. That is the entire point: you trade a single risky operation for several boring ones.

## Relational Databases: The Locking Trap

The hidden danger in SQL migrations is **locking**. Many DDL operations acquire a lock that blocks reads, writes, or both — and on a large table, "briefly" can mean minutes of an effective outage.

### Operations and Their Costs

| Operation | Typical cost | Safe approach |
|-----------|-------------|---------------|
| `ADD COLUMN` (nullable, no default) | Cheap (metadata-only on modern engines) | Generally safe |
| `ADD COLUMN` with volatile default | Rewrites whole table | Add nullable, backfill, then set default |
| `ADD INDEX` | Locks writes (or long) | Use `CREATE INDEX CONCURRENTLY` |
| `DROP COLUMN` | Cheap metadata change | Safe once unused |
| `ALTER COLUMN TYPE` | Often full rewrite | Expand-contract via new column |
| `ADD NOT NULL` | Full scan to validate | Add as `NOT VALID`, then `VALIDATE` |

The classic foot-gun is adding a `NOT NULL` column with a non-constant default to a huge table — the engine rewrites every row under a lock (older engines, such as PostgreSQL before 11, did so even for constant defaults). The safe sequence:

```sql
-- Step 1: add nullable, no default (instant metadata change)
ALTER TABLE users ADD COLUMN status text;

-- Step 2: backfill in batches to avoid one giant transaction
UPDATE users SET status = 'active'
WHERE status IS NULL AND id BETWEEN 1 AND 10000;
-- ...repeat across id ranges...

-- Step 3: now enforce the constraint without a full lock
ALTER TABLE users ADD CONSTRAINT users_status_nn
  CHECK (status IS NOT NULL) NOT VALID;
ALTER TABLE users VALIDATE CONSTRAINT users_status_nn;  -- non-blocking scan
```

For indexes, always reach for the concurrent variant on a live system:

```sql
CREATE INDEX CONCURRENTLY idx_users_status ON users (status);
```

It is slower and cannot run inside a transaction, but it does not block writes — which on a production table is the difference between a routine change and an incident.

## Serialized Formats: Schema in the Wire

When data crosses a network or sits in a queue, the schema lives in the *serialization format*, and the same compatibility rules apply with format-specific mechanics.

### Protobuf

Protocol Buffers were designed for evolution. Compatibility hinges on **field numbers, never names**. The wire format identifies fields by their tag number; names exist only in the `.proto` source.

```protobuf
message User {
  int64 id = 1;
  string email = 2;
  // Added in v2 — old readers skip unknown field 3 (forward compat).
  // New readers see it absent in old data and use the default (backward compat).
  string display_name = 3;
}
```

Protobuf rules for safe evolution:

- **Adding a field** with a new number is fully compatible — old readers skip it, new readers default it.
- **Never reuse a field number.** Reserve dropped numbers with `reserved 4;` so no future field accidentally reuses the tag and misinterprets old bytes.
- **Renaming a field is free** since names are not on the wire.
- **Changing a field's type is dangerous** unless the types are wire-compatible (e.g. `int32`/`int64` for small values).

### Avro

Avro takes a different approach: the **reader uses its own schema and resolves against the writer's schema** at read time. Compatibility depends entirely on **default values**.

```json
{
  "type": "record",
  "name": "User",
  "fields": [
    { "name": "id", "type": "long" },
    { "name": "email", "type": "string" },
    { "name": "displayName", "type": "string", "default": "" }
  ]
}
```

- To stay **backward compatible**, a new field *must* have a default — so a new reader can fill it in when reading old data lacking the field.
- To stay **forward compatible**, you may add a field with a default and old readers (using the old schema) simply ignore it.
- This is why Avro pairs naturally with a **Schema Registry** that enforces a compatibility policy on every schema submission, rejecting incompatible changes before they ship.

| Format | Field identity | Compatibility mechanism |
|--------|---------------|------------------------|
| Protobuf | Field number | Skip unknown / default missing |
| Avro | Field name + reader/writer resolution | Default values |
| JSON | Field name | Convention + tolerant readers |

## The Tolerant Reader Principle

Across all of these runs one design principle: **be conservative in what you send, liberal in what you accept** (Postel's Law). Concretely:

- Readers must **ignore unknown fields** rather than reject the whole payload. A strict JSON parser that fails on an unexpected key breaks forward compatibility the moment producers add anything.
- Readers must **tolerate missing optional fields** by supplying sensible defaults.
- Producers should **not remove fields** that any consumer might still read — coordinate removals through the expand-contract sequence.

A tolerant reader turns "the producer added a field" from a deployment crisis into a non-event.

## Event Streams and the Outbox

Schema evolution gets subtler with persisted events (Kafka, event sourcing) because **old events are immutable and live forever**. You cannot migrate them in place. Strategies:

- **Versioned schemas with a registry** enforcing compatibility per topic.
- **Upcasting**: a transformation layer that reads an old event version and converts it to the current shape on the fly when consumed.
- **Never delete required fields** from event schemas; an event written in 2024 must still deserialize in 2030.

## A Practical Checklist

1. Default to **full compatibility** for anything live during a deploy.
2. Decompose every breaking change into **expand-contract** steps.
3. For SQL, know which operations **lock**; add columns nullable, backfill in batches, index concurrently, validate constraints separately.
4. For Protobuf, evolve by **field number**, reserve dropped numbers, never reuse them.
5. For Avro/JSON, give new fields **defaults** and run a **schema registry** with an enforced policy.
6. Write **tolerant readers** that ignore unknown and default missing fields.
7. Treat **events as immutable**; upcast rather than rewrite.

## Closing Thought

Schema evolution is fundamentally a coordination problem across time and across running code versions. The discipline that solves it is always the same: never make a change that any concurrently-running version cannot tolerate. Expand before you contract, add before you remove, default everything optional, and accept more than you require. Follow those rules and the scariest operation in backend work — changing the shape of data that production depends on — becomes a routine, reversible, zero-downtime sequence.
