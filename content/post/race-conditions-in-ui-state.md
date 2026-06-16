---
title: "Race conditions in UI state"
date: 2026-01-08T09:30:00-05:00
draft: false
tags: [frontend, state-management, react, async, concurrency]
---

## Mental model

A UI race condition happens when two or more state transitions are valid in isolation but arrive in an order the user, product, or component did not intend. The browser is single-threaded for most JavaScript, but it is not single-causal. User input, network responses, timers, animation frames, workers, and framework schedulers all enqueue work. The bug is rarely "two lines ran at the same time"; it is "an old result committed after the UI had already moved on."

Typical frontend examples:

- Search results for `rea` overwrite results for `react` because the earlier request finished later.
- A double click submits two mutations and the slower response wins.
- An optimistic update is rolled back by a stale refetch.
- A component commits async state after it has unmounted or after its props changed.

{{< mermaid >}}
sequenceDiagram
    participant U as User
    participant C as Component
    participant A as Request A
    participant B as Request B
    U->>C: type "rea"
    C->>A: fetch /search?q=rea
    U->>C: type "react"
    C->>B: fetch /search?q=react
    B-->>C: newer result
    C->>C: render react results
    A-->>C: older result
    C->>C: bug: render rea results
{{< /mermaid >}}

## Internals that matter

JavaScript promises resume in the microtask queue. DOM events, timers, and network progress callbacks are tasks. React, Vue, Svelte, and Solid add another layer: they batch, schedule, interrupt, or defer updates. That means the line that starts an operation and the line that commits its result may be separated by many user-visible state changes.

The important distinction is between **operation identity** and **data identity**. If the component says "show results for the latest query," then the latest query is part of the operation identity. A response carrying correct data for an older query is still invalid for the current operation. Treating all successful responses as equivalent is the root cause.

## Practical patterns

Use request tokens for read races. Increment a sequence number whenever a new operation starts and only commit the response if it still matches.

```js
let searchSeq = 0;

async function runSearch(query) {
  const seq = ++searchSeq;
  setState({ status: "loading", query });

  const results = await fetchJson(`/api/search?q=${encodeURIComponent(query)}`);
  if (seq !== searchSeq) return;

  setState({ status: "ready", query, results });
}
```

Use `AbortController` when cancellation is useful for both correctness and resource usage. Aborting prevents wasted server work in some stacks and makes stale completions explicit.

```js
let currentController;

function loadProfile(id) {
  currentController?.abort();
  currentController = new AbortController();
  return fetch(`/api/profile/${id}`, { signal: currentController.signal });
}
```

For mutations, prefer idempotency keys and server-side conflict handling. A disabled button prevents many accidental duplicates, but it is not a correctness boundary. The backend should understand whether two submits represent the same command.

Model async UI as a small state machine instead of a loose collection of booleans. A search box is not just `{ loading, data, error }`; it is "idle for query A," "loading operation 13 for query B," "showing results for query B," or "showing stale results while operation 14 refreshes query C." Naming those states makes invalid commits obvious. If a response does not match the active operation, it cannot transition the machine.

```ts
type SearchState =
  | { tag: "idle"; query: string }
  | { tag: "loading"; query: string; opId: number }
  | { tag: "ready"; query: string; results: Result[] }
  | { tag: "error"; query: string; message: string };
```

For server state libraries, learn the cache's race semantics instead of assuming they match your product. Query cancellation, stale time, deduping, invalidation, refetch-on-focus, and optimistic cache writes all affect ordering. A refetch triggered by window focus can overwrite a local optimistic view if it returns an older server snapshot. A mutation success handler can invalidate a query whose refetch completes after the user has navigated to a different filter. Include the route params, filters, account id, and feature flags in query keys so unrelated results cannot share a cache slot.

## Conflict policies

Not every race should be solved with "latest wins." Text search usually wants latest query wins. A money transfer wants exactly-once command handling. A collaborative document wants merge or conflict resolution. A form save might want last writer wins for drafts but server validation for published records. Make the policy explicit per operation type.

Read races are often safe to drop. Mutation races usually need durable semantics. Use idempotency keys for create and submit actions, entity versions or ETags for updates, and server-side conflict responses for stale writes. On the client, keep the failed command visible enough for the user to understand what happened. Silent rollback is acceptable for toggling a heart icon; it is not acceptable for losing a paragraph of edited text.

Unmount is another policy choice. If a component unmounts because the user navigated away, the operation may still matter. A save should complete and update shared cache; a typeahead request can be cancelled. Tie cancellation to operation intent, not only component lifecycle.

## Failure modes

The most dangerous failure mode is stale success. Teams often handle stale errors because they are noisy, but stale success looks legitimate and can silently show wrong data. Another common issue is optimistic UI rollback: a failed old mutation reverts a newer optimistic state. Store enough metadata with optimistic entries to roll back only the change that failed.

Framework-specific traps include stale closures in hooks, effect cleanup that does not cancel async work, and derived state copied from props. In React, an effect should either return cleanup or guard its commit path. In Vue, watchers that fetch data should invalidate previous work with cleanup callbacks. In any framework, avoid committing by "the component is still mounted" alone; mounted does not mean the operation is still current.

## Diagnostics

Make races visible by logging operation ids:

```text
search start seq=12 query=rea
search start seq=13 query=react
search commit seq=13
search drop stale seq=12 current=13
```

Throttle the network in DevTools, add artificial jitter in development, and test rapid user input. Race bugs rarely reproduce under a fast localhost API. For automated tests, use controllable promises: start two operations, resolve the second first, then resolve the first and assert the UI does not move backwards.

## Checklist

- Every async read has an operation identity: query, route params, filters, or sequence.
- Stale results are dropped before state commit.
- Cleanup cancels work where possible.
- Mutations are protected by idempotency or conflict checks, not only disabled buttons.
- Optimistic updates can roll back one operation without overwriting newer state.
- Tests cover out-of-order completion, duplicate submit, and unmount during pending work.
