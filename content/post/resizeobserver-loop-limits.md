---
title: "ResizeObserver loop limits"
date: 2026-02-19T11:20:00-05:00
draft: false
tags: [frontend, resizeobserver, layout, performance, browser-internals]
---

## ResizeObserver closes a feedback loop

`ResizeObserver` reports element size changes. That sounds simple until the callback changes styles that change sizes again. The browser therefore runs ResizeObserver delivery in a guarded loop with a limit. When your callback keeps causing new resize notifications, the browser stops and reports a loop limit warning.

{{< mermaid >}}
flowchart TD
  Layout["style and layout"] --> Gather["gather active resize observations"]
  Gather --> Callback["run ResizeObserver callbacks"]
  Callback --> Writes["callback writes size-affecting styles"]
  Writes --> Layout
  Callback --> Paint["paint when stable"]
  Gather --> Limit["loop limit exceeded"] --> Paint
{{< /mermaid >}}

The warning is not random. It means the browser protected rendering from an unstable measurement-write cycle.

## Delivery timing

ResizeObserver callbacks run after layout has calculated element sizes and before paint. Entries contain box sizes such as `contentBoxSize`, `borderBoxSize`, and `devicePixelContentBoxSize` where supported. This timing makes the API excellent for component-level responsiveness, but dangerous for direct layout mutation.

```js
const ro = new ResizeObserver((entries) => {
  for (const entry of entries) {
    const width = entry.contentRect.width;
    entry.target.style.fontSize = `${Math.max(12, width / 20)}px`;
  }
});
```

This may be fine if font size changes do not affect the observed element's width or height. If they do, each callback can produce another resize.

## Why loop limits happen

A loop can be direct: observe a box, callback sets its width, width changes, observer fires again.

It can also be indirect: observe a child, callback changes parent layout, parent changes child size. Grid, flexbox, aspect-ratio, web fonts, scrollbars, and container queries can all participate.

The browser attempts to deliver observations in depth order so that deeper elements do not repeatedly invalidate ancestors forever. If undelivered notifications remain after the guard conditions, it emits messages like "ResizeObserver loop limit exceeded" or "ResizeObserver loop completed with undelivered notifications."

Many monitoring tools capture this as an error even when users see no broken UI. Do not ignore it blindly, but classify it correctly: it is usually a rendering stability warning, not an exception thrown by your application code.

## Practical patterns

Prefer CSS first. Container queries, flexbox, grid, `min()`, `max()`, and `clamp()` remove whole classes of JavaScript resize feedback.

Use ResizeObserver to update non-layout state or to schedule work, not to synchronously mutate the observed box. If you must write styles, move writes to `requestAnimationFrame` and guard against no-op updates.

```js
let nextWidth = null;
let raf = 0;

const ro = new ResizeObserver(([entry]) => {
  nextWidth = Math.round(entry.contentRect.width);
  if (!raf) {
    raf = requestAnimationFrame(() => {
      raf = 0;
      const columns = Math.max(1, Math.floor(nextWidth / 240));
      if (grid.dataset.columns !== String(columns)) {
        grid.dataset.columns = String(columns);
      }
    });
  }
});
```

This does not make loops impossible, but it separates measurement delivery from mutation and avoids repeated writes with the same value.

Observe stable boundaries. If your callback changes children, observe the parent. If it changes the parent, observe a wrapper whose size is not affected by the callback.

Make the observer callback boring. It should read sizes, normalize them, compare against previous values, and schedule a minimal update. Avoid fetching data, recalculating large layouts, mounting framework subtrees, or writing multiple style properties directly from the callback. ResizeObserver delivery happens in a sensitive part of the rendering pipeline; heavy callback work delays paint even when it does not create a loop.

Prefer coarse breakpoints over continuous formulas when possible. A grid that changes between 1, 2, 3, and 4 columns creates fewer updates than one that writes a new pixel-derived value for every small width change. Round measured values before comparing them. Device pixel rounding, scrollbars, zoom, and fractional layout can otherwise produce tiny differences that keep your equality check from working.

## Framework integration

In component frameworks, avoid setting state on every raw resize entry. State updates can trigger a render, which changes layout, which triggers another observer entry. Use a ref for the last measured size, derive a stable semantic value, and only commit state when that semantic value changes. For example, store `columns = 3`, not `width = 713.421875`.

```js
function columnsFor(width) {
  if (width >= 960) return 4;
  if (width >= 720) return 3;
  if (width >= 420) return 2;
  return 1;
}
```

If the measurement affects only styling, CSS custom properties can be useful, but they are still layout-affecting if used in layout properties. Guard writes and choose a stable target. If a chart needs the measured width, update the chart's drawing surface rather than the container's CSS size. If a component needs to know whether it is compact, container queries may remove the JavaScript state entirely.

React layout effects are a common trap. Measuring in `useLayoutEffect`, setting state, then observing the resulting resize can create a pre-paint loop across React and the browser. Prefer `useEffect` for non-critical reactions, `requestAnimationFrame` for drawing work, and cleanup that disconnects the observer on unmount.

## Failure modes

Canvas resizing is a common trap. Observing a canvas container and then setting both CSS size and backing store size can trigger repeated measurements. Keep CSS layout size stable and update only `canvas.width` and `canvas.height` for backing resolution when possible.

Scrollbars can create off-by-one loops. A callback that changes content height may add a scrollbar, which reduces width, which changes wrapping, which changes height. Use `overflow: auto` intentionally and avoid threshold logic that flips around a boundary.

Text fitting algorithms are especially risky. Reducing font size until text fits inside the same observed element creates repeated layout. Use CSS `clamp()` or a bounded binary search scheduled outside the observer.

## Diagnostics

First, identify the observed element and the style writes in the callback. Add logging for old and new sizes, and log whether your callback wrote any size-affecting styles. If the warning appears without visible impact, check third-party widgets; chart libraries and virtualized grids often use ResizeObserver internally.

In Chrome Performance recordings, look for repeated layout and ResizeObserver callback stacks before paint. In production telemetry, group these messages separately from application exceptions so they do not obscure real crashes.

## Checklist

- Use CSS container queries when the response is purely visual.
- Do not synchronously write dimensions back to the observed element.
- Guard every write with an equality check.
- Schedule expensive work with `requestAnimationFrame`.
- Observe a stable wrapper when possible.
- Treat loop limit warnings as performance signals, not generic JS errors.

ResizeObserver is a measurement primitive. Keep measurement and mutation loosely coupled, and the loop limit becomes a rare diagnostic instead of a recurring production alert.
