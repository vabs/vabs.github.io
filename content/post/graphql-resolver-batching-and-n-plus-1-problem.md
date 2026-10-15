---
title: "GraphQL Resolver Batching and the N+1 Problem"
date: 2026-02-15T14:05:00-04:00
draft: false
tags: [backend, graphql, dataloader, performance, databases]
---

## Mental model

GraphQL's execution model is a tree walk. The server resolves the root fields, then for each returned object it resolves that object's selected fields, recursively. Each field has a *resolver* — a function that produces the value for that field given its parent object. This per-field resolution is what makes GraphQL flexible, and it is also exactly what creates the N+1 problem.

Consider a query for a list of posts and each post's author:

```graphql
query {
  posts(first: 50) {
    id
    title
    author { id name }
  }
}
```

The `posts` resolver runs once and returns 50 posts. Then the `author` resolver runs *once per post* — 50 times. If each invocation issues `SELECT * FROM users WHERE id = ?`, you have 1 query for the posts plus 50 queries for the authors. That is the N+1 problem: 1 + N database round trips where 2 would suffice.

{{< mermaid >}}
graph TD
    A["posts resolver"] --> B["1 query: SELECT posts"]
    B --> C["author resolver x50"]
    C --> D["50 queries: SELECT user WHERE id=?"]
    D --> E["Total: 51 round trips"]
{{< /mermaid >}}

The fix is *batching*: collect all the author IDs requested during one tick of execution and resolve them with a single `SELECT * FROM users WHERE id IN (...)`. The canonical tool for this is the DataLoader pattern.

## Why naive resolvers fall into the trap

The trap is seductive because each resolver looks correct in isolation. The `author` resolver does exactly one thing: fetch one user. There is no bug in any single resolver. The problem is emergent — it only appears when the resolver is invoked many times within a single request, which is invisible from inside the resolver.

```javascript
// Looks fine. Is a disaster at scale.
const resolvers = {
  Post: {
    author: (post) => db.user.findById(post.authorId),
  },
};
```

This also compounds with depth. If each author has `posts` and each of those has an `author`, you get multiplicative explosion. A query three levels deep can issue thousands of queries from what looks like a tidy schema.

## DataLoader: batching plus caching

DataLoader solves this with two mechanisms working together:

1. **Batching** — instead of dispatching each load immediately, DataLoader collects all keys requested within a single tick of the event loop and calls a *batch function* once with the full list of keys.
2. **Per-request caching** — within one request, loading the same key twice returns the same promise, so duplicate IDs collapse to one fetch.

```javascript
const DataLoader = require("dataloader");

function createUserLoader() {
  return new DataLoader(async (ids) => {
    const rows = await db.query(
      "SELECT * FROM users WHERE id = ANY($1)", [ids]
    );
    // CRITICAL: return results in the SAME ORDER as `ids`
    const byId = new Map(rows.map((r) => [r.id, r]));
    return ids.map((id) => byId.get(id) ?? null);
  });
}
```

The resolver now uses the loader instead of querying directly:

```javascript
const resolvers = {
  Post: {
    author: (post, _args, ctx) => ctx.userLoader.load(post.authorId),
  },
};
```

All 50 `author` resolvers call `load(id)` synchronously during the same tick. DataLoader coalesces them and issues exactly one batch query.

{{< mermaid >}}
sequenceDiagram
    participant R as 50 author resolvers
    participant L as DataLoader
    participant DB as Database
    R->>L: load(1) ... load(50)
    Note over L: Collect keys this tick
    L->>DB: SELECT * FROM users WHERE id IN (1..50)
    DB-->>L: 50 rows
    L-->>R: Resolve each promise by key
{{< /mermaid >}}

## The two contracts you must not break

DataLoader's batch function has two non-negotiable rules. Violate them and you get silent data corruption or failed batches.

**Rule 1: the output array must be the same length and order as the input keys.** DataLoader maps `result[i]` back to `keys[i]`. If your `SELECT ... IN` returns rows in arbitrary order (databases give no ordering guarantee without `ORDER BY`), and you return them as-is, user A gets user B's data. Always reindex by key, as the `Map` above does.

**Rule 2: missing keys must produce a value (usually `null`), not a gap.** If you query 50 IDs and only 48 exist, the database returns 48 rows. You must still return a 50-element array with `null` (or an `Error`) in the two missing slots. The `ids.map(...)` reindexing handles this automatically.

| Mistake | Symptom |
|---------|---------|
| Return rows in DB order | Fields attached to wrong parents |
| Drop missing keys | Length mismatch; DataLoader rejects every load in the batch |
| Reuse loader across requests | Stale data, cross-user cache leaks |
| Create loader inside resolver | No batching (new loader per call) |

## Loader lifecycle: per request, not per process

The single most common DataLoader bug is sharing a loader across requests. DataLoader caches by key for its lifetime. If the loader lives for the whole process, user data gets cached globally and never invalidated — request B sees request A's stale or, worse, *another user's* data.

The correct lifecycle is **one set of loaders per request**, created in the GraphQL context factory:

```javascript
const server = new ApolloServer({ schema });

const { url } = await startStandaloneServer(server, {
  context: async () => ({
    userLoader: createUserLoader(),
    postsByAuthorLoader: createPostsByAuthorLoader(),
  }),
});
```

Per-request loaders give you request-scoped caching (great — duplicate IDs in one query collapse) without cross-request leakage. They are cheap to create; do not optimize this away.

## Batching one-to-many relationships

Loading a single parent by ID is the easy case. The trickier case is loading a *collection* per key — for example, all comments for each post. The keys are post IDs; the result for each key is an array of comments.

```javascript
function createCommentsByPostLoader() {
  return new DataLoader(async (postIds) => {
    const rows = await db.query(
      "SELECT * FROM comments WHERE post_id = ANY($1)", [postIds]
    );
    const byPost = new Map(postIds.map((id) => [id, []]));
    for (const row of rows) byPost.get(row.post_id).push(row);
    // one array per postId, in order
    return postIds.map((id) => byPost.get(id));
  });
}
```

The same ordering contract applies: one bucket per input key, in input order. Pre-seed the map with empty arrays so posts with zero comments return `[]` rather than `undefined`.

## Beyond DataLoader

DataLoader fixes per-field N+1 but it is not the only lever.

- **Query-time joins / lookahead.** If you can inspect the GraphQL AST (via `info.fieldNodes`) you can detect that `author` is requested and JOIN it in the root `posts` query, eliminating the second batch entirely. Libraries like join-monster do this. It is faster but couples your resolvers to query planning and is harder to maintain.
- **Pagination limits.** Batching turns N queries into one, but that one query can still pull thousands of rows. Always bound list fields with pagination (`first`/`after`) and enforce a max.
- **Query cost analysis / depth limiting.** Even with perfect batching, a maliciously deep or wide query can be expensive. Reject queries past a complexity budget before execution.
- **Persisted queries.** Restrict the server to a known allowlist of queries so you can pre-optimize their data access.

| Technique | Eliminates round trips | Eliminates over-fetching rows | Complexity |
|-----------|-----------------------|-------------------------------|------------|
| DataLoader | Yes (batches to 1) | No | Low |
| AST-aware JOINs | Yes (folds into parent) | Yes | High |
| Pagination | No | Yes | Low |
| Complexity limits | Defensive only | Defensive only | Medium |

## Verifying you actually batched

Do not trust that batching works — measure it. Log every SQL statement with the request ID and assert the count. A healthy resolution of the posts+authors query should show exactly two statements regardless of page size. If you see counts that scale with the number of results, batching is broken — usually because a loader was created in the wrong place or a resolver bypassed the loader.

```javascript
// test assertion sketch
const queries = captureSql(() => execute(POSTS_WITH_AUTHORS_QUERY));
expect(queries.length).toBe(2); // posts + users, not 51
```

## Takeaways

The N+1 problem is structural to GraphQL's per-field resolution, not a bug in any one resolver. DataLoader fixes it by deferring loads to the end of a tick and issuing one batched query, with request-scoped caching as a bonus. The discipline that makes it safe is small but absolute: return results in input-key order, fill missing keys with `null`, and create one loader set per request. Add pagination and complexity limits so that even a perfectly batched query cannot become a perfectly batched denial of service. Then measure the SQL count in tests so regressions surface immediately.
