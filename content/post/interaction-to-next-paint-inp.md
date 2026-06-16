---
title: "Interaction to Next Paint (INP)"
date: 2026-04-09T16:00:00-04:00
draft: false
tags: [frontend, performance, core-web-vitals, inp, responsiveness]
---

Interaction to Next Paint measures page responsiveness across real user interactions. It observes clicks, taps, and keyboard interactions, then reports a high-percentile interaction latency for the page. Unlike older first-input metrics, INP cares about the whole session. A page can load quickly and still fail INP if later interactions are blocked by JavaScript, rendering, or main-thread contention.

The useful mental model splits one interaction into input delay, processing duration, and presentation delay.

{{< mermaid >}}
flowchart TD
  A[User input] --> B[Input waits for main thread]
  B --> C[Event handlers run]
  C --> D[Style layout paint]
  D --> E[Next frame visible]
{{< /mermaid >}}

## What INP rewards

INP rewards immediate feedback. The browser starts timing when the user interacts and stops when the next paint reflects the result. If your handler performs validation, data transformation, analytics, state updates, and navigation before allowing paint, the user waits for all of it. If you update visible pressed/open/selected state first and defer secondary work, INP improves and the UI feels more direct.

Not every interaction needs final data before feedback. A menu can open before its remote recommendations finish. A button can show pending state before the mutation returns. A text field can update its value before expensive filtering completes.

## Main-thread pressure

Most bad INP comes from main-thread congestion. Long tasks before the event cause input delay. Heavy event handlers cause processing duration. Expensive style recalculation, layout, rendering, or compositing cause presentation delay.

The fixes differ by phase. If input delay dominates, find unrelated work occupying the main thread when users interact: hydration, large script evaluation, JSON parsing, third-party tags, or background cache updates. If processing dominates, slim the handler. If presentation dominates, inspect DOM size, layout dependencies, CSS selectors, synchronous measurements, and expensive rendering.

```js
button.addEventListener("click", () => {
  button.setAttribute("aria-busy", "true");
  button.textContent = "Saving";

  setTimeout(() => {
    saveLargePayload();
  }, 0);
});
```

This example is intentionally simple: commit the visual response first, move non-urgent work to a later task, and let the browser paint.

## Framework patterns

In React-like systems, keep urgent state separate from expensive derived views. A controlled input's value update is urgent. Filtering a ten-thousand-row table is not. Use transitions, deferred values, memoized row rendering, virtualization, or workers. But virtualization is not a free win; if it adds measurement work during every keypress, it can still hurt presentation delay.

Hydration is a common INP trap. A server-rendered page may look ready while JavaScript is still hydrating. If the user taps during hydration, the interaction can wait behind framework work. Use islands, partial hydration, code splitting, and smaller client bundles so interactive regions become ready sooner and do less work.

The implementation pattern is to make the event boundary explicit. Inside the handler, do the minimum state write that changes visible affordance, then schedule everything that is not needed for the next frame. In React this often means a synchronous update for the focused control and a transition for the expensive list, chart, or route body. In plain JavaScript it means toggling the class or text first, then using `scheduler.postTask`, `requestIdleCallback`, a worker, or a later task for the heavier work. Be careful with `requestAnimationFrame`: work inside the frame callback still runs before paint, so it is useful for coordinated DOM writes but not for deferring CPU-heavy processing until after feedback.

State shape matters too. If a click on one row updates a global object that every row subscribes to, the browser pays for a large render even though the user's mental model changed one row. Prefer narrow subscriptions, stable props, keyed memoization, and derived data caches that invalidate by entity or query rather than by whole-page state. When a component owns both urgent interaction state and expensive computed output, split them. A pressed state should not wait for sorting, syntax highlighting, markdown rendering, or chart layout.

## Attribution workflow

Debug INP by assigning the slow interaction to a phase before changing code. First inspect whether the event was delayed before the handler started. If so, the problem is probably unrelated startup or background work: hydration, bundle evaluation, polling, analytics, or a large promise continuation. Next inspect handler duration. Long handlers usually contain synchronous validation, reducers over large collections, logging payload construction, local database reads, or framework renders. Finally inspect the gap between handler completion and the next paint. Presentation delay points toward layout, style recalculation, rasterization, layer churn, or a framework commit that mutated too much DOM.

For production telemetry, record interaction name, target role, route, elapsed time, and a few coarse phase hints from the Event Timing API where available. Avoid logging raw text or sensitive form values. A useful report says "filter input on reports page has high processing duration on mid-tier Android," not just "INP bad." That level of attribution lets you choose between bundle splitting, handler slimming, virtualization, containment, or rendering fixes.

## Failure modes

The first failure is measuring only page load. INP issues often occur after filters, modals, editors, route transitions, or dashboards have been used for a while. Memory growth and cache fan-out can make the fiftieth interaction slower than the first.

The second is hiding work in microtasks. Moving heavy code into `Promise.resolve().then(...)` does not give the browser a paint opportunity. Use a real task boundary or a scheduler when paint must happen first.

The third is over-rendering. A single state change causes the whole application shell to re-render, which causes layout and paint across unrelated regions. Use state colocation, selectors, memoization, and component boundaries to reduce invalidation.

Third-party scripts also matter. Tag managers can run during clicks, mutate DOM, or attach expensive listeners. Audit them with the same rigor as first-party code.

## Diagnostics

Use field INP data because lab interactions rarely cover the worst real flows. In Chrome DevTools, record a slow interaction and inspect the interaction track. Look at input delay, handler cost, layout, paint, and long tasks. Add custom performance marks around event handlers and expensive updates. Test on mid-tier mobile hardware or CPU throttling; desktop machines hide scheduler mistakes.

Checklist:

- Give visual feedback before secondary work.
- Split urgent and non-urgent state updates.
- Break long tasks and avoid microtask starvation.
- Reduce hydration and script evaluation near interactive regions.
- Profile real flows, not only initial load.
- Attribute INP by phase before choosing a fix.
