---
title: "PerformanceObserver API"
date: 2026-01-16T10:40:00-05:00
draft: false
tags: [frontend, performance, performanceobserver, web-vitals, browser-api]
---

`PerformanceObserver` is the browser's streaming interface for performance timeline entries. Instead of polling `performance.getEntriesByType()`, you subscribe to entry types and receive batches as the browser records them. That makes it the foundation for production measurement of navigation timing, resource timing, paint timing, layout shifts, long tasks, event timing, and custom marks.

The key mental model is that the browser maintains performance timelines. Different subsystems append entries to those timelines. `PerformanceObserver` lets your code consume those entries asynchronously without blocking the subsystem that produced them.

{{< mermaid >}}
flowchart TD
  A[Browser subsystem] --> B[Performance entry]
  B --> C[Performance timeline buffer]
  C --> D[PerformanceObserver]
  D --> E[Batch callback]
  E --> F[Normalize and sample]
  F --> G[Telemetry backend]
{{< /mermaid >}}

## Basic shape

The API has two modes. You can observe a single `type`, often with `buffered: true`, or you can observe a set of `entryTypes`. Prefer the single-type form for modern entry types because it supports buffered delivery.

```js
const observer = new PerformanceObserver((list, obs) => {
  for (const entry of list.getEntries()) {
    console.log(entry.entryType, entry.name, entry.startTime, entry.duration);
  }
});

observer.observe({ type: "resource", buffered: true });
```

`buffered: true` asks the browser to deliver matching entries that were recorded before the observer was installed. This matters because paint, navigation, and early resource entries can happen before your application bundle runs.

Browser support varies by entry type, so production instrumentation should check:

```js
function supportsEntry(type) {
  return PerformanceObserver.supportedEntryTypes?.includes(type);
}
```

## Entry types that matter

For frontend work, the most practical types are `navigation`, `resource`, `paint`, `largest-contentful-paint`, `layout-shift`, `longtask`, `event`, and `measure`. Not all browsers expose all of them, and some are gated by security or privacy rules.

`navigation` replaces the older `performance.timing` API with high-resolution timestamps. `resource` gives timing for scripts, CSS, images, fetches, and other resources, limited by cross-origin timing headers. `paint` exposes first paint and first contentful paint. `largest-contentful-paint` keeps emitting candidates until page visibility changes or input occurs. `layout-shift` entries power Cumulative Layout Shift, but you must ignore shifts that had recent user input. `measure` entries are your own application spans.

## Designing a metrics collector

A reliable collector normalizes entry types into a small schema. Avoid shipping raw browser objects. They contain fields that vary across browser versions and can be too verbose.

```js
const queue = [];

function enqueue(metric) {
  queue.push({ ...metric, path: location.pathname, ts: Date.now() });
  if (queue.length >= 20) flush();
}

function flush() {
  if (!queue.length) return;
  const body = JSON.stringify(queue.splice(0));
  navigator.sendBeacon?.("/metrics", body) || fetch("/metrics", {
    method: "POST",
    body,
    keepalive: true,
    headers: { "content-type": "application/json" },
  });
}
```

For each observer, translate entries into metrics with explicit names and units. `startTime` and `duration` are milliseconds relative to `performance.timeOrigin`. Do not mix them with `Date.now()` without converting.

## Buffer limits and dropped data

The browser has finite buffers. Resource timing is the most visible example: by default, the resource timing buffer can fill on pages that load many assets. Once full, new resource entries may be dropped unless you increase the buffer size.

```js
performance.setResourceTimingBufferSize(1000);

performance.addEventListener?.("resourcetimingbufferfull", () => {
  flushResourceMetrics();
  performance.clearResourceTimings();
});
```

Do not blindly set an enormous buffer. Resource entries can be memory-heavy on long-lived single-page apps. Periodically flush and clear entries you no longer need.

## SPA navigation

`navigation` entries describe document navigation, not every client-side route transition. In an SPA, create your own route measures:

```js
performance.mark("route:start");
await loadData();
renderRoute();
requestAnimationFrame(() => {
  performance.mark("route:paintish");
  performance.measure("route:change", "route:start", "route:paintish");
});
```

Observe `measure` entries and report route changes alongside browser-native entries. This gives you a bridge between platform timing and application timing.

## Failure modes

The first failure mode is installing observers too late. If you load analytics after hydration, you may miss early entries unless the type supports `buffered`. Place critical observers in a small early script when possible.

The second is double-counting. React Strict Mode, hot reload, or repeated app initialization can install duplicate observers. Centralize observer setup and expose a singleton metrics module.

The third is trusting unsupported fields. Cross-origin resource timing is intentionally limited unless the response includes `Timing-Allow-Origin`. If DNS, TCP, TLS, or response timing fields are zero, the browser may be protecting timing data rather than reporting a fast request.

The fourth is sending too much data. A busy page can produce thousands of resource and event entries. Sample, aggregate, or threshold before sending.

## Debugging

Start by logging supported entry types in the target browser. Then add one observer at a time and verify that entries arrive with realistic timestamps. In DevTools, compare resource timing entries with the Network panel, paint entries with the Performance panel, and custom measures with the User Timing track.

For metrics such as LCP and CLS, compare your implementation against a known reference library during development. Small mistakes, such as reporting the first LCP candidate instead of the final one, produce convincing but wrong dashboards.

## Privacy and precision

Performance APIs expose timing that can be sensitive, so browsers reduce precision in some contexts and hide cross-origin details unless servers opt in. Cross-origin isolated pages may get more precise timing for some APIs, but do not design metrics that require maximum precision to be useful. For field monitoring, bucket values and focus on percentiles.

Also watch page lifecycle. A hidden tab can delay callbacks, throttle timers, and change metric interpretation. For page-load metrics, record `document.visibilityState` and ignore or separately segment pages that became hidden before the metric was finalized. This is especially important for LCP, which is finalized when the page is hidden.

## Checklist

- Check `PerformanceObserver.supportedEntryTypes` before observing optional types.
- Use `{ type, buffered: true }` for early lifecycle metrics.
- Normalize entries into a stable schema with explicit units.
- Increase and manage the resource timing buffer on asset-heavy pages.
- Add custom `mark` and `measure` spans for SPA route transitions.
- Prevent duplicate observers during repeated initialization.
- Sample or aggregate high-volume entry types.
- Validate field metrics against DevTools and reference implementations.
