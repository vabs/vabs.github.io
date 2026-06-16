---
title: "Garbage collection timing"
date: 2026-01-27T13:20:00-05:00
draft: false
tags: [frontend, memory, garbage-collection, javascript, performance]
---

Garbage collection timing is one of the least deterministic parts of frontend performance. JavaScript gives you automatic memory management, but it does not promise when memory will be reclaimed. That uncertainty matters because collection work can happen during interactions, route transitions, animation, or hydration, and the resulting pauses can look like random jank.

The practical mental model is reachability. Objects are collectible only when the engine can prove they are no longer reachable from roots: global variables, active stack frames, closures, pending timers, DOM references, event listeners, and internal engine structures. Timing is separate from eligibility. An object can be garbage and still remain in memory until a later collection cycle.

{{< mermaid >}}
flowchart TD
  A[Object allocated] --> B{Reachable from roots?}
  B -->|yes| C[Retained]
  B -->|no| D[Eligible for GC]
  D --> E{Collector runs now?}
  E -->|no| F[Still occupies heap]
  E -->|yes| G[Memory reclaimed]
{{< /mermaid >}}

## What the browser is optimizing

Modern JavaScript engines use generational collectors because most objects die young. New objects are allocated in a young generation, collected frequently, and promoted to older space if they survive. Old-generation collections are less frequent and more expensive. Engines also split work into incremental and concurrent phases where possible, but some stop-the-world work remains.

This means allocation rate can matter as much as retained memory. A component that allocates thousands of short-lived objects every animation frame may not leak, but it can force frequent young-generation collections. A route that retains a few large graphs may increase old-space pressure and trigger longer collections later.

## Why timing feels random

The engine schedules GC based on heap pressure, allocation rate, idle time, memory limits, and heuristics. Two users can run the same code and see different collection timing because their devices have different memory, CPU speed, tab pressure, and background activity. DevTools can also perturb timing because profiling changes engine behavior.

Avoid code that assumes finalization will happen soon. For example, dropping a reference to a large `ArrayBuffer` does not immediately reduce the process memory you see in the OS. The object may be eligible, but the engine and allocator may not return pages to the operating system right away.

## Frontend patterns that affect GC

High churn is common in render code:

```js
// Allocates a new array and object set on every call.
const rows = items
  .filter((item) => item.visible)
  .map((item) => ({ id: item.id, label: format(item) }));
```

This is fine for small lists and infrequent renders. It becomes a problem inside scroll handlers, animation loops, or large tables. The fix is not to avoid allocation everywhere; it is to avoid allocation in hot paths where it competes with frames.

Better patterns include memoizing derived data by stable inputs, using virtualization, reusing typed arrays for numeric buffers, moving heavy transforms to Workers, and reducing render frequency. Object pooling is rarely the first answer in UI code because it can make lifetime bugs worse, but it can be useful for tight loops such as canvas particle systems or audio visualization.

## Observing GC indirectly

The web platform intentionally does not expose precise GC events to normal page code. You infer GC pressure from symptoms: long tasks with engine work in DevTools, sawtooth heap charts, pauses after allocation bursts, and increasing old-space size across repeated workflows.

In Chrome DevTools, use the Performance panel with memory enabled. Look for scripting blocks labeled with garbage collection work and compare them with interaction timing. In the Memory panel, take heap snapshots before and after a repeated workflow. If retained size grows after explicit cleanup and a forced collection in DevTools, you may have a leak. If retained size returns to baseline but the Performance trace shows frequent GC, you may have allocation churn instead.

## Weak references and finalizers

`WeakMap` and `WeakSet` are useful when metadata should not keep an object alive. They are a good fit for associating bookkeeping with DOM nodes or model objects owned elsewhere.

```js
const metadataByNode = new WeakMap();

export function attachMetadata(node, metadata) {
  metadataByNode.set(node, metadata);
}
```

`WeakRef` and `FinalizationRegistry` exist, but they should not be used for core application control flow. Finalizers run eventually, maybe much later, and possibly not before page termination. They are appropriate for opportunistic cleanup of secondary resources, not for closing critical handles or updating user-visible state.

## Failure modes

The biggest mistake is measuring memory immediately after cleanup and assuming the cleanup failed. You need to distinguish "still reachable" from "not collected yet." DevTools forced GC helps during diagnosis, but it is not representative of production timing.

Another mistake is optimizing retained heap while ignoring allocation rate. A page can have stable memory and still jank because it allocates aggressively during every keystroke.

Closures are a common retention source. A timer callback, promise chain, or event listener can capture a large object graph through one variable. The code may look harmless because the large object is not referenced directly at the cleanup site.

```js
function startPolling(bigModel) {
  const id = setInterval(() => {
    sendHeartbeat(bigModel.id);
  }, 5000);
  return () => clearInterval(id);
}
```

Until the interval is cleared, the callback keeps `bigModel` reachable.

## Practical guidance

Design explicit lifetimes for subscriptions, timers, observers, workers, object URLs, and caches. Keep large derived data close to the component or route that owns it. Clear caches by policy, not hope. Bound in-memory queues. Avoid storing DOM nodes in long-lived maps unless the keys are weak or the lifecycle is explicit.

For performance-sensitive code, profile with CPU throttling and realistic data sizes. A garbage collector that is invisible on a developer laptop can be visible on a mid-range phone.

## Checklist

- Separate eligibility for collection from actual collection timing.
- Profile allocation churn and retained memory as different problems.
- Use DevTools heap snapshots after repeated workflows, not single clicks.
- Treat forced GC as a diagnostic tool, not production behavior.
- Clear timers, observers, subscriptions, workers, and object URLs explicitly.
- Use `WeakMap` for metadata that should not extend object lifetime.
- Avoid `FinalizationRegistry` for correctness-critical cleanup.
- Validate fixes on lower-end devices or throttled CPU profiles.
