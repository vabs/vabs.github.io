---
title: "Browser memory leak detection"
date: 2026-02-14T11:10:00-05:00
draft: false
tags: [frontend, memory-leaks, diagnostics, devtools, performance]
---

Browser memory leak detection is less about finding one magic number and more about proving that memory grows after repeated workflows when it should return to a stable baseline. JavaScript garbage collection is nondeterministic, browser processes share memory across systems, and DevTools changes runtime behavior. A good leak investigation controls the workflow, repeats it, forces diagnostic collections only when appropriate, and follows retaining paths to the owner.

The core distinction is retained memory versus allocated memory. Allocated memory is what your code creates over time. Retained memory is what remains reachable after the workflow finishes and garbage collection has had a chance to run. Leaks are retained memory problems. Jank from allocation churn may have stable retained memory but frequent GC.

{{< mermaid >}}
flowchart TD
  A[Choose workflow] --> B[Take baseline]
  B --> C[Repeat workflow many times]
  C --> D[Force diagnostic GC]
  D --> E[Take comparison snapshot]
  E --> F{Retained size grows?}
  F -->|yes| G[Inspect retaining paths]
  F -->|no| H[Investigate allocation churn]
{{< /mermaid >}}

## Start with a hypothesis

Do not begin by clicking randomly through the app with the Memory panel open. Pick a suspected workflow: open and close a modal, switch between routes, load search results, start and stop screen sharing, mount and unmount a chart, or import and discard a large file. The workflow should have an expected cleanup point.

Good hypotheses sound like: "closing the report builder should release chart DOM nodes and series data" or "leaving the video room should release peer connections and media tracks." This makes the retaining path meaningful because you know what should no longer exist.

## Heap snapshots

Heap snapshots answer "what is still reachable?" Take a baseline, repeat the workflow, trigger GC from DevTools, take another snapshot, and compare. Sort by retained size and inspect objects that increased. For DOM leaks, search for detached nodes. For application leaks, search by constructor names, store slice names, route models, or third-party class names.

The retaining path is the important artifact. It might show:

- A module-level array holding route data.
- A closure from a timer capturing a component model.
- A `Map` using DOM nodes as keys.
- A global event listener holding a callback.
- A framework root that was never unmounted.
- A third-party widget registry.

Fix the owner, not the symptom. Setting random variables to `null` rarely helps if the actual owner is a listener registry or cache.

## Allocation timeline

Allocation instrumentation answers "what is being created and surviving?" It is useful when memory grows gradually or when snapshots are too coarse. Record while repeating the workflow. Stop, force GC, and inspect allocations that remain. This is especially helpful for lists, canvases, editors, and dashboards where many objects share generic constructors like `Object` or `Array`.

Allocation sampling has lower overhead and can identify hot allocation sites. Use it when performance is already fragile and full allocation instrumentation is too heavy.

## Measuring from application code

The browser exposes limited memory APIs. Chromium-based browsers have `performance.memory` in some contexts and `performance.measureUserAgentSpecificMemory()` in newer environments. Treat these as diagnostic signals with feature detection, not portable application logic.

```js
async function sampleMemory(label) {
  if ("measureUserAgentSpecificMemory" in performance) {
    const result = await performance.measureUserAgentSpecificMemory();
    console.log(label, result.bytes);
  } else if (performance.memory) {
    console.log(label, performance.memory.usedJSHeapSize);
  }
}
```

These numbers are useful for automated smoke tests that catch large regressions, but they are not a replacement for heap snapshots. A higher heap number does not identify the retaining path.

## Automation strategy

For critical workflows, build a browser test that repeats the workflow and records coarse memory. The exact threshold should be generous because CI machines vary. The goal is to catch obvious linear growth, not a 2 MB fluctuation.

```js
for (let i = 0; i < 30; i++) {
  await page.getByRole("button", { name: "Open report" }).click();
  await page.getByRole("button", { name: "Close" }).click();
}
```

In Chromium automation, you can request garbage collection through the DevTools protocol in test-only code. Use that to reduce noise, but remember that production users do not get forced GC at convenient times.

## Common frontend leak sources

Single-page apps leak through long-lived roots. Stores retain old route data. Query caches keep large responses forever. WebSocket handlers keep callbacks after unmount. Observers keep targets alive. Object URLs created with `URL.createObjectURL()` are not revoked. Web Workers continue running after the route leaves. Media streams keep devices and buffers active until tracks are stopped.

DOM-heavy libraries add their own lifecycle. Maps, charts, editors, and video SDKs often need explicit `destroy()`, `dispose()`, or `disconnect()` calls. Removing the container node usually cleans up only the DOM, not global listeners or internal registries.

## Failure modes

The most common diagnostic mistake is using the operating system process memory as proof. Browser processes pool memory, share resources, and may not return freed memory to the OS immediately. Use heap snapshots and retaining paths instead.

Another mistake is trusting a single run. Garbage collection timing and JIT behavior make one run noisy. Repeat the workflow enough times that a leak becomes obvious.

DevTools console references can retain objects. If you log a large object or inspect a DOM node, the console may keep it alive. Clear the console and avoid storing inspected objects during tests.

## Checklist

- Define one workflow with a clear cleanup point.
- Compare heap snapshots before and after repeated execution.
- Force GC only as a diagnostic step to reduce noise.
- Inspect retaining paths before changing code.
- Use allocation instrumentation for gradual growth.
- Add coarse automated memory checks for critical workflows.
- Clean up listeners, observers, workers, object URLs, media tracks, and third-party instances.
- Do not use OS process memory as the primary leak signal.
