---
title: "Scheduler priorities"
date: 2026-05-12T16:25:00-04:00
draft: false
tags: [frontend, scheduler, concurrency, rendering, performance]
---

## Mental model: not all UI work deserves the same lane

Scheduler priorities let a renderer decide which work should run now, which work can wait, and which work should be interrupted. The browser has one main thread for JavaScript, style, layout, paint coordination, and input handling. If a large render monopolizes that thread, a keystroke waits behind work the user may no longer care about.

Concurrent UI systems treat rendering as interruptible work. Typing, clicking, and focus updates should outrank background list filtering, tab preloads, or offscreen rendering. The goal is not to make total work disappear; it is to keep the user-facing work responsive.

{{< mermaid >}}
flowchart TD
    Input[Keyboard input] --> High[High priority lane]
    Click[Click] --> High
    Transition[Route/list transition] --> Medium[Transition lane]
    Prefetch[Hidden prefetch render] --> Low[Idle/background lane]
    High --> Commit1[Commit urgent update]
    Medium --> Commit2[Commit when ready]
    Low --> Commit3[Run when main thread is free]
{{< /mermaid >}}

## Internals

A scheduler breaks rendering into units and assigns them priority. If a higher-priority update arrives while lower-priority work is in progress, the renderer can pause, throw away partial work, or resume later depending on the architecture.

Priorities usually map to categories rather than exact milliseconds: synchronous or discrete input, continuous input, default updates, transitions, retries, and idle work. The names vary by framework, but the principle is stable: user input is urgent; visual transitions are important but interruptible; speculative work is optional.

The commit phase is different from the render phase. Rendering can often be interrupted because it computes a future tree. Committing changes to the DOM is typically not interruptible in the same way because the visible UI must stay consistent.

## Practical patterns

Mark expensive non-urgent updates as transitions. Filtering a 5,000-row table after typing should keep the input value urgent while the filtered result updates at transition priority. The user sees typing remain responsive even if the derived list lags slightly.

Defer derived values that are expensive and not required for the next keystroke. Do not debounce everything by default; debouncing changes semantics. Priority scheduling lets the app respond immediately while allowing heavy rendering to trail.

Chunk custom work. A framework scheduler cannot interrupt a synchronous loop that sorts, parses, and formats data for 300 ms. Move heavy computation to a worker, precompute indexes, virtualize lists, or split work into yielding chunks.

Separate urgent state from expensive derived state. A search box should update its text state immediately, then schedule filtering and result rendering separately. If both live in one synchronous update, the scheduler cannot keep typing responsive because every keystroke demands the full result tree.

```tsx
function SearchView({ rows }) {
  const [query, setQuery] = useState("");
  const deferredQuery = useDeferredValue(query);
  const results = useMemo(
    () => filterRows(rows, deferredQuery),
    [rows, deferredQuery],
  );

  return <SearchResults query={query} results={results} />;
}
```

The exact API varies by framework, but the pattern is stable: commit the input now, derive expensive content on a lower-priority path, and render a pending state when the two differ. For route changes, keep navigation intent urgent while data loading and below-the-fold rendering can be interruptible.

When writing your own scheduler-adjacent code, yield deliberately. A batch processor can process a chunk, check elapsed time, then schedule continuation with `scheduler.postTask`, `requestIdleCallback`, `MessageChannel`, or a framework-specific cooperative API. The important point is to return control to the browser often enough for input, style, layout, and paint.

```js
async function processItems(items) {
  for (let i = 0; i < items.length; i += 100) {
    processChunk(items.slice(i, i + 100));
    await (globalThis.scheduler?.yield?.() ?? new Promise(requestAnimationFrame));
  }
}
```

Treat that snippet as a shape, not a universal utility. `requestIdleCallback` can starve under constant activity, `requestAnimationFrame` runs before paint, and `scheduler.postTask` support varies. Pick the primitive based on whether the work is visual, background, or latency-sensitive.

## Failure modes

The common failure is assuming the scheduler fixes CPU-bound JavaScript. It cannot preempt a long function already running on the main thread. If a chart library blocks for half a second, priority labels around it will not rescue input.

Another failure is showing inconsistent pending states. If urgent state updates immediately but transition state lags, the UI should communicate that derived content is updating. Otherwise users may think their input was ignored or results are wrong.

Priority inversion can happen when low-priority work holds a shared resource. For example, a background render warms a cache with a global lock or saturates the network, delaying urgent data. Keep background work cancellable and bounded.

Effect work is another blind spot. A render may be interruptible, but an effect that parses a megabyte response, measures hundreds of nodes, or synchronously writes to storage can still block the main thread after commit. Profile effects separately from render. If the flame chart shows long tasks after commit, priority annotations around state updates are not addressing the bottleneck.

Be careful with memoization as a reflex. `useMemo` or equivalent caching can reduce repeated computation, but it can also move a large calculation into the render path and make invalidation harder to understand. If the work is genuinely heavy and not needed for immediate visual feedback, scheduling, virtualization, indexing, or workers may be a better fit.

Suspense-like loading boundaries can also create priority surprises. If an urgent update suspends on data that is not ready, the framework may show a fallback or keep previous content depending on configuration. Design fallbacks so they do not cause layout jumps for ordinary input, and avoid turning every keystroke into a network-dependent render.

## Debugging and diagnostics

Use performance traces to find long tasks over 50 ms. Then determine whether they are render work, commit work, effects, or third-party code. Framework profiler lanes can show which updates were transitions and which were urgent.

Add interaction marks around input start, urgent commit, transition start, and transition commit. Measure the gap users feel, not just total render duration. Test while CPU-throttled and while background work is active.

A useful trace has labels that match user intent, not implementation trivia:

```js
performance.mark("search:input");
startTransition(() => {
  performance.mark("search:transition-start");
  setFilter(query);
});
```

Pair marks with `PerformanceObserver` for long tasks in development. If every search interaction produces a 120 ms long task, inspect what runs inside that task before changing priority levels. The scheduler is a traffic controller; it cannot make oversized trucks smaller.

Run diagnostics with realistic data volume. Priority issues often disappear on a 20-row fixture and reappear with production-sized lists, slow devices, browser extensions, and background tabs. CPU throttling is not perfect, but it quickly reveals whether the UI still accepts input while lower-priority work is pending.

## Checklist

- Classify updates by user urgency.
- Mark expensive navigations or filters as transitions.
- Keep input state separate from heavy derived state.
- Move long CPU tasks off the main thread or chunk them.
- Make pending transition states visible.
- Keep background work cancellable.
- Profile long tasks and commit time separately.
