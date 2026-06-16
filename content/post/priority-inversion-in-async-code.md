---
title: "Priority inversion in async code"
date: 2026-02-25T15:10:00-05:00
draft: false
tags: [frontend, async, performance, scheduling, javascript]
---

Priority inversion happens when high-priority work waits behind low-priority work. In frontend code, it shows up when a click waits behind analytics, a keystroke waits behind JSON parsing, a route transition waits behind image processing, or an urgent state update is blocked by a long microtask chain. The main thread is a shared CPU, and JavaScript's cooperative model means priority is only real if your code yields.

The mental model: async does not automatically mean non-blocking. A promise callback still runs on the main thread. `await` splits work into continuations, but each continuation can monopolize the event loop. Browser rendering, input handling, timers, network callbacks, and your framework scheduler all compete for turns.

{{< mermaid >}}
flowchart TD
  A[Low-priority task starts] --> B[Long JS or microtask chain]
  B --> C[Input event arrives]
  C --> D[Input waits for main thread]
  D --> E[Delayed render and feedback]
{{< /mermaid >}}

## Where inversion appears

Microtasks are a common culprit. Promise callbacks run before the browser returns to rendering and many other task sources. A recursive promise chain can starve input and paint even though it "looks async." Large `then` pipelines, state-library notification cascades, and query cache fan-out can create the same effect.

Long tasks are the visible symptom. Any main-thread task above roughly 50 ms can delay input processing. But smaller tasks can still hurt Interaction to Next Paint when they cluster around an interaction. The question is not only "how long is this task?" but "what user-visible work is waiting behind it?"

Framework concurrency helps only if you use the priority boundaries correctly. In React, urgent input state and low-priority derived rendering should not be bundled into one synchronous update. Use transitions for non-urgent visual work, defer expensive derived values, and keep controlled input updates immediate.

## Practical scheduling patterns

Split CPU-heavy work into chunks and yield between chunks. For browser work, `scheduler.postTask` with priorities is increasingly useful where supported. Fallbacks include `setTimeout(0)`, `MessageChannel`, `requestIdleCallback` for truly optional work, and web workers for CPU-heavy tasks that do not need DOM access.

```js
async function processItems(items, applyChunk) {
  const chunkSize = 250;
  for (let i = 0; i < items.length; i += chunkSize) {
    applyChunk(items.slice(i, i + chunkSize));
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}
```

This is not about making total work faster. It is about allowing input, paint, and cancellation to interleave with low-priority processing.

Use abort signals. If a low-priority search, parse, or preload becomes irrelevant, cancel it instead of letting it finish and compete with newer work.

```js
const controller = new AbortController();
const result = await fetch(url, { signal: controller.signal });
```

For CPU loops, check `signal.aborted` between chunks. For network requests, abort prevents stale callbacks and frees browser resources.

## Data and rendering

Normalize data ingestion. Parsing a multi-megabyte JSON response on the main thread can block input even if the network request was asynchronous. Consider streaming formats, pagination, workers, or server-side shaping. Avoid doing expensive sorting, grouping, and formatting inside render for every keystroke.

Memoization can reduce repeated work, but it can also hide priority problems. A cache miss during an urgent update still blocks. Prefer moving expensive derivation to lower-priority updates or workers when data size is unbounded.

## Failure modes

The first failure is fire-and-forget background work that is not actually background. Analytics serialization, localStorage writes, and compression run on the main thread unless moved elsewhere. `localStorage` is synchronous; writing large payloads during a click can directly delay feedback.

The second is unbounded microtask scheduling. `queueMicrotask` and resolved promises are useful for ordering, but they are bad yielding mechanisms because they run before paint. Use a task boundary when the browser needs a chance to handle input or render.

The third is priority collapse: one event handler performs urgent state, slow validation, analytics, cache writes, and navigation in sequence. Separate the minimum immediate feedback from everything that can happen later.

## Designing priority boundaries

Start every interaction by naming the urgent feedback. For a text field, it is the character appearing and the caret staying responsive. For a drag, it is the visual object tracking the pointer. For a navigation, it may be disabling the clicked item and showing that the route is changing. Everything else should justify why it belongs on the urgent path.

Then classify work as blocking, deferrable, cancellable, or movable. Blocking work is the small amount required to preserve correctness before feedback. Deferrable work can run after paint. Cancellable work should be tied to an `AbortSignal` or sequence token. Movable work belongs in a worker, on the server, or in a precomputed cache. This classification is more useful than arguing whether code is "async" because the user only experiences what blocks the next paint.

For framework code, keep derived state out of urgent updates when it can be recomputed later. A search box can update its controlled value immediately, then schedule filtering as a transition or worker request. A table sort can show a pending affordance before regrouping thousands of rows. The best result is not always the fewest renders; it is the fastest credible feedback followed by correct completion.

## Production debugging

Record performance marks with interaction ids. Mark `input.received`, `urgent-state-applied`, `low-priority-start`, `low-priority-yield`, `paint-ready`, and `mutation-confirmed` where applicable. In traces, correlate those marks with long tasks and microtask chains. If all marks sit inside one task, your "background" work is not yielding.

Test on slower hardware and under CPU throttling. Priority inversion often hides on developer machines because the low-priority task finishes before anyone notices. Also test with realistic cache states: a cold cache may parse large JSON, while a warm cache may fan out thousands of synchronous subscriber notifications.

## Diagnostics

Use the Performance panel to find long tasks and inspect what was waiting. Chrome's Interaction to Next Paint breakdown helps connect an interaction to input delay, processing time, and presentation delay. Add performance marks around low-priority jobs. Log queue length and cancellation counts for background processors. If a user says "typing feels sticky," profile with CPU throttling and real typing, not synthetic function benchmarks.

Checklist:

- Treat promises as main-thread continuations, not free parallelism.
- Keep urgent input updates small.
- Chunk CPU work and yield with task boundaries.
- Cancel stale async work.
- Move heavy parsing or computation to workers where practical.
- Measure interactions, not just isolated function duration.
