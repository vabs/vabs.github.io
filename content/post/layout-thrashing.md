---
title: "Layout thrashing"
date: 2026-02-03T08:45:00-05:00
draft: false
tags: [frontend, performance, layout, dom, diagnostics]
---

Layout thrashing happens when JavaScript repeatedly alternates between writing DOM or style changes and reading layout-dependent values. Each read asks the browser for up-to-date geometry. If there are pending writes, the browser must synchronously recalculate style and layout before returning the value. In a loop, that creates many forced layouts where one batched layout would have been enough.

{{< mermaid >}}
flowchart TD
  A[Write style] --> B[Layout marked dirty]
  B --> C[Read offsetWidth]
  C --> D[Forced style and layout]
  D --> E[Write style again]
  E --> B
{{< /mermaid >}}

## Mental model

Browsers normally batch rendering work. JavaScript mutates the DOM, then the browser waits until the task ends and prepares the next frame. Layout thrashing defeats that batching by demanding geometry in the middle of mutation work.

Layout reads include `offsetWidth`, `offsetHeight`, `clientTop`, `scrollTop` in some cases, `getBoundingClientRect()`, `getComputedStyle()` for certain properties, and focus or selection operations that require updated geometry. Writes include changing classes, inline styles, text, DOM nodes, image dimensions, and anything that can affect computed style or box geometry.

## Bad pattern

The classic bug is measuring and mutating inside the same loop:

```js
for (const item of items) {
  item.style.width = `${container.offsetWidth / 3}px`;
}
```

If `item.style.width` changes layout, the next `container.offsetWidth` can force layout again. The fix is to read once, then write many times:

```js
const width = container.offsetWidth / 3;
for (const item of items) {
  item.style.width = `${width}px`;
}
```

For more complex cases, separate reads and writes into phases. Read all geometry first, compute the next state in memory, then apply DOM writes. Libraries that schedule animation work often use this discipline internally.

## Practical patterns

Use `requestAnimationFrame` for visual writes that should land before the next paint. Use a small read/write scheduler when multiple components need measurements:

```js
const reads = [];
const writes = [];
let scheduled = false;

export function measure(fn) {
  reads.push(fn);
  schedule();
}

export function mutate(fn) {
  writes.push(fn);
  schedule();
}

function schedule() {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    const measurements = reads.splice(0).map((fn) => fn());
    writes.splice(0).forEach((fn) => fn(measurements));
  });
}
```

Prefer CSS for state-dependent layout when possible. Container queries, flexbox, grid, `aspect-ratio`, and `position: sticky` remove many measurement scripts. If JavaScript must measure, keep the measured subtree small with containment: `contain: layout paint;` can limit how far invalidation spreads.

## Failure modes

Virtualized lists can thrash when every row measures itself and updates shared scroll height synchronously. Tooltips can thrash when they measure target geometry, write position, read overflow, and write again for every mouse move. Responsive components can thrash when resize handlers directly measure and mutate dozens of nodes without throttling.

Frameworks do not eliminate the problem. A React layout effect that reads `getBoundingClientRect()` after setting state can force layout. Multiple components doing this independently during mount can serialize expensive layout work. Centralize measurement for shared surfaces such as tables, grids, and editors.

## Diagnostics

In Chrome DevTools Performance, forced layouts appear as layout events inside JavaScript tasks. The summary often shows "Forced reflow" warnings with a call stack. Record with CPU throttling and reproduce the interaction slowly enough to isolate the handler.

Add counters around suspicious reads:

```js
function rect(el, label) {
  performance.mark(`${label}:measure`);
  return el.getBoundingClientRect();
}
```

If a single drag or scroll produces hundreds of measurements, you have a scheduling problem even before optimizing the math.

## Implementation details

A useful rule is "measure at the edge, render from data." For example, a table column resizer should measure the table once at drag start, store the relevant widths, and then compute new widths from pointer deltas. It should not remeasure every cell on every pointer move. The DOM is the output surface, not the state database.

For animations, decide whether the animation is layout-driven or compositor-driven. Expanding an accordion changes layout for surrounding content, so some layout work is expected. Moving a floating panel can usually use `transform` and avoid layout. Do not force everything into transforms if the surrounding document truly needs to reflow; optimize the interaction that matters.

ResizeObserver can help, but it can also create feedback loops. If an observer reads a size and writes a style that changes that size, the browser may hit loop limits. Keep observer callbacks small, batch writes to animation frames, and avoid observing broad containers when only one child matters.

In component systems, expose measured values through a shared store or context only when necessary. If every child measures itself independently, the aggregate behavior becomes expensive even if each component looks clean in isolation.

## Scheduling architecture

Make measurement ownership explicit. A popover system can own target measurement, viewport collision detection, and placement writes in one scheduler. A data grid can own column and row measurements. If every component independently calls `getBoundingClientRect()` in its own lifecycle hook, the browser sees a pile of uncoordinated read/write cycles even though each component appears reasonable.

Use frame phases consistently. One practical pattern is: event handlers update model state, animation-frame reads collect geometry, pure computation derives positions, and animation-frame writes apply styles. Do not sneak layout reads into the write phase for convenience. If a write reveals that more information is needed, schedule another frame rather than forcing the current frame to redo layout repeatedly.

Containment can reduce blast radius but should be applied with understanding. `contain: layout` tells the browser that internal layout does not affect outside layout, which is useful for independent widgets. It can break features that depend on natural sizing or overflow visibility. `content-visibility: auto` can help large offscreen sections, but measuring skipped content may produce surprising values until it becomes relevant.

## Debugging playbook

Start with the user interaction, not the helper function. Record a trace while dragging, resizing, opening the menu, or typing. Find the first forced layout and inspect its initiator stack. Then look backward for the write that dirtied layout. The guilty read is only half the bug; the real fix is usually to move the earlier write or cache the read.

Add development-only counters for high-risk APIs. Wrap measurement helpers, not browser prototypes, and log per interaction id. A report like "drag: 480 rect reads, 120 style writes" is more actionable than a generic performance complaint. After the fix, the count should drop because scheduling changed, not because a single read became marginally faster.

## Checklist

- Batch layout reads before layout writes.
- Avoid geometry reads inside mutation loops.
- Use CSS layout features before JavaScript measurement.
- Throttle resize, scroll, and pointer handlers.
- Use containment for independent subtrees.
- Profile with DevTools and inspect forced-layout stacks.

Layout thrashing is rarely fixed by making one function faster. It is fixed by restoring the browser's ability to batch work.
