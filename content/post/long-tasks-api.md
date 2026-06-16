---
title: "Long tasks API"
date: 2026-01-08T09:15:00-05:00
draft: false
tags: [frontend, performance, long-tasks, browser-api, diagnostics]
---

The Long Tasks API is a browser performance API for answering a narrow but important question: when was the main thread unavailable long enough for users to feel it? It does not tell you every function call, every layout, or every promise continuation. It reports tasks that block the main thread for more than 50 ms, which is the threshold browsers use to identify work that can delay input handling, rendering, timers, and other user-visible activity.

The mental model is the event loop. JavaScript execution, style recalculation, layout, paint preparation, event dispatch, and many browser callbacks compete for time on the main thread. A "task" is one chunk of work pulled from the task queue. Microtasks run before the browser gets a chance to render or handle the next task, so a short task with a huge promise chain can still create a long blocked interval.

{{< mermaid >}}
flowchart TD
  A[User input or timer] --> B[Main-thread task starts]
  B --> C[JS, style, layout, callbacks]
  C --> D{Duration > 50ms?}
  D -->|yes| E[PerformanceLongTaskTiming entry]
  D -->|no| F[No long-task entry]
  E --> G[PerformanceObserver callback]
{{< /mermaid >}}

## How the API works

You observe `longtask` entries through `PerformanceObserver`:

```js
const observer = new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    console.log({
      startTime: entry.startTime,
      duration: entry.duration,
      attribution: entry.attribution,
    });
  }
});

observer.observe({ type: "longtask", buffered: true });
```

Each entry is a `PerformanceLongTaskTiming`. `startTime` is relative to the page's time origin and `duration` is the blocked interval. The useful part is not just the number; it is correlating that number with route transitions, input handlers, hydration, analytics scripts, and rendering bursts.

The `attribution` field can identify a culprit container such as a same-origin frame, cross-origin frame, script, or unknown source depending on browser support and privacy restrictions. Treat it as a clue, not a profiler. The API is designed for production telemetry, where stack traces would be too heavy and privacy-sensitive.

## Practical instrumentation

Long-task telemetry should be sampled and annotated with application context. Raw entries are hard to action because "there was a 143 ms task at 37,200 ms" does not say what the user was doing.

Useful dimensions include route name, interaction name, visibility state, device memory bucket, connection type when available, and whether the app was hydrating, rendering a virtualized list, parsing a large response, or executing a known third-party integration.

```js
let currentInteraction = "idle";

export function markInteraction(name, fn) {
  currentInteraction = name;
  try {
    return fn();
  } finally {
    queueMicrotask(() => {
      currentInteraction = "idle";
    });
  }
}

new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    sendMetric("long_task", {
      duration: Math.round(entry.duration),
      start: Math.round(entry.startTime),
      interaction: currentInteraction,
      route: location.pathname,
      hidden: document.visibilityState === "hidden",
    });
  }
}).observe({ type: "longtask", buffered: true });
```

Do not report every long task from every session. Long tasks can be frequent on low-end devices, and telemetry itself can become overhead. Sample sessions, batch sends with `navigator.sendBeacon`, and cap the number of entries per page view.

## What counts as a long task

Common sources are large JSON parsing, synchronous loops, expensive reducers, client-side syntax highlighting, hydration of too many islands at once, layout thrashing, third-party scripts, and rendering too many DOM nodes in one pass. A task does not need to be pure JavaScript. Layout forced by repeated `getBoundingClientRect()` calls can appear inside the same blocking interval.

The API does not identify idle periods, GPU work, network latency, or work running in Web Workers. If a page feels slow because data arrives late, Long Tasks will not explain it. If a page feels slow because the main thread is blocked after data arrives, it will.

## Debugging workflow

Start with field data. Find routes and interactions with frequent tasks above 100 ms or 200 ms. Then reproduce locally with CPU throttling in DevTools. Record a Performance trace around the interaction and search for long purple, yellow, or rendering blocks near the timestamps. The Long Tasks API tells you where to look; DevTools tells you why.

Add local marks to align app events with the trace:

```js
performance.mark("search:render:start");
renderResults(results);
performance.mark("search:render:end");
performance.measure("search:render", "search:render:start", "search:render:end");
```

Then compare `measure` entries with long-task entries. If the long task fully overlaps a render measure, split the render. If it starts before the measure, the source may be a synchronous parser, state update, or third-party callback.

## Fix patterns

Break work into chunks when it does not need to finish before the next frame. `scheduler.postTask` can help where supported; `setTimeout(0)` and `requestIdleCallback` are fallbacks with different scheduling semantics. For user-facing updates, prefer yielding after a bounded amount of work rather than after an arbitrary number of items.

```js
async function processItems(items) {
  const budgetMs = 8;
  let start = performance.now();

  for (const item of items) {
    process(item);
    if (performance.now() - start > budgetMs) {
      await new Promise((resolve) => setTimeout(resolve, 0));
      start = performance.now();
    }
  }
}
```

Move CPU-heavy transforms to a Worker when the result does not require synchronous DOM access. Virtualize large lists. Avoid sync storage calls during input. Precompute expensive lookup tables. Defer non-critical third-party scripts until after first interaction or after the page becomes idle.

## Failure modes

A common mistake is treating 50 ms as a pass/fail target. A single 55 ms task during app bootstrap may be acceptable; repeated 80 ms tasks during typing are not. Segment by interaction, device class, and route.

Another failure mode is blaming the visible component. The component rendering at the time of a long task may be innocent if a global store selector, analytics hook, or synchronous logging layer runs inside the same task. Use flame charts before rewriting UI code.

Finally, remember that microtasks can starve the browser. A promise loop that repeatedly queues more promises may not appear as separate tasks. It can still create a long blocked interval and delay paint.

## Checklist

- Install one sampled `PerformanceObserver` for `longtask` with `buffered: true`.
- Attach route and interaction context before sending metrics.
- Cap reports per page view and batch telemetry.
- Investigate clusters above 100 ms, especially during input and route changes.
- Reproduce with CPU throttling and correlate with DevTools traces.
- Fix by chunking, virtualizing, moving work to Workers, and deferring non-critical scripts.
- Validate fixes in field data, not only on a fast development machine.
