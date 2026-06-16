---
title: "Task starvation"
date: 2026-02-12T11:00:00-05:00
draft: false
tags: [frontend, performance, event-loop, scheduling, responsiveness]
---

Task starvation is what happens when important browser work cannot get a turn on the main thread. The page may not be frozen in the crash sense: JavaScript is running, promises are resolving, and state is changing. But input, rendering, timers, or lower-priority work are delayed because one source keeps scheduling more work ahead of them.

{{< mermaid >}}
flowchart TD
  A[Task starts] --> B[Run JS]
  B --> C[Drain microtasks]
  C --> D{More microtasks queued?}
  D -->|yes| C
  D -->|no| E[Browser may render]
  E --> F[Next task]
{{< /mermaid >}}

## Mental model

The event loop processes a task, drains the microtask queue, gives the browser a chance to render, then moves to the next task. Starvation appears when one phase keeps refilling itself. A long synchronous loop starves everything until it exits. An unbounded promise chain can starve rendering because microtasks must drain before the browser advances. A flood of high-priority app work can starve user-visible updates even if each unit is individually short.

This matters because responsiveness is about fairness, not only total work. Ten thousand 1 ms chunks can still feel broken if none of them yields to paint or input at the right time.

## Common sources

The simplest source is CPU-heavy JavaScript: parsing a large payload, diffing a huge tree, syntax highlighting, sorting in a hot path, or running validation over thousands of fields. Another source is recursive microtask scheduling:

```js
function spin() {
  queueMicrotask(spin);
}
spin();
```

Real bugs are usually less obvious. A state subscription schedules a promise callback. The callback updates state. The update schedules another subscription notification. The loop eventually settles, but not before delaying paint for hundreds of milliseconds.

## Practical scheduling

Break work into bounded chunks and yield using a mechanism that lets the browser make progress. `await Promise.resolve()` yields to microtasks only, so it does not necessarily allow rendering. `setTimeout(0)` posts a new task. `requestAnimationFrame` aligns visual work with frames. `requestIdleCallback` is useful for optional work but should not be required for correctness.

```js
async function runQueue(queue) {
  while (queue.length) {
    const deadline = performance.now() + 8;
    while (queue.length && performance.now() < deadline) {
      queue.shift()();
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}
```

Where available, `scheduler.postTask` lets you express priority. Use user-blocking priority for immediate interaction results, user-visible for updates the user is waiting to see, and background for indexing, prefetch bookkeeping, and analytics.

## Failure modes

Starvation often hides behind "async" code. Async functions can still monopolize the event loop if they repeatedly await already-resolved promises. Microtasks are not a rendering boundary. Treat promise chains as synchronous for responsiveness analysis until they actually yield to a task or frame.

Another failure is starvation by retries. A failed request schedules immediate retry, the retry updates UI state, the UI state triggers observers, and many tabs do this at once. Add backoff, jitter, and cancellation. User navigation should cancel work for old routes.

Framework schedulers can also be overwhelmed. If every keystroke schedules a full-table recomputation, concurrent rendering cannot save the experience indefinitely. Reduce the work, memoize correctly, virtualize, or move computation to a Worker.

## Diagnostics

Use the Long Tasks API to detect blocked intervals in production. In DevTools, look for long tasks and dense chains of promise callbacks. Enable CPU throttling because starvation that is invisible on a development laptop is often obvious on mid-range phones.

Instrument queues with length, age, and dropped-work counters. A queue length that only grows during interaction is a starvation signal. Mark work with `performance.mark` so traces show whether old route work is still running after navigation.

## Implementation details

Prioritize by user intent, not by implementation source. A keystroke that updates visible search results is more important than finishing a cache warmup that started earlier. A route transition is more important than analytics enrichment for the previous route. Make this visible in code by tagging work items with priority, owner, and cancellation scope.

Cancellation is as important as yielding. Chunking stale work still wastes CPU. Use `AbortController` for fetches and long-running async workflows. For pure CPU queues, store a generation token and check it between chunks. If the route, query, or selected entity changed, drop the old work rather than politely finishing it.

Backpressure prevents starvation from recurring. If user input arrives faster than expensive derived data can be produced, coalesce updates. For example, keep only the latest search query for background indexing, or skip intermediate resize states while preserving the final state. Correct coalescing reduces work without losing the user's final intent.

Be careful with background tabs. Timer clamping and reduced rendering opportunities change scheduling behavior. Work that seems smooth in an active tab may pile up and run in a burst when the tab becomes visible. Listen to visibility changes and discard obsolete work.

## Queue design

A practical work queue should record more than the callback. Store enqueue time, priority, owner, cancellation token, and an optional coalescing key. The enqueue time tells you whether work is aging. The owner tells you what to cancel on navigation. The coalescing key lets a new resize calculation replace an older resize calculation instead of waiting behind it.

Fair queues also need a budget. A loop that processes "until empty" can starve the page whenever producers are faster than consumers. A loop that processes for 6-10 ms, then yields, gives the browser a chance to paint on a 60 Hz display while still making progress. On slower devices, time budgets are safer than item budgets because one item may be unexpectedly expensive.

## User-facing symptoms

Starvation rarely arrives as a neat error. It looks like text input dropping characters, hover states appearing late, spinners freezing, progress bars jumping in chunks, or clicks landing after the user has changed their mind. Treat those as scheduling bugs, not just "slow code."

When triaging, separate latency from throughput. Throughput asks how long the entire job takes. Latency asks how long before the user sees the next meaningful response. A job can have acceptable throughput and terrible latency if it refuses to yield.

## Checklist

- Know whether a yield goes to microtasks, tasks, frames, or idle time.
- Bound work by time, not only by item count.
- Cancel stale route and interaction work.
- Add backoff to retries and background loops.
- Move CPU-heavy independent work to Workers.
- Track queue age and long tasks in production.

Task starvation is a fairness bug. The fix is to make scheduling explicit enough that input, rendering, and urgent app work all get timely turns.
