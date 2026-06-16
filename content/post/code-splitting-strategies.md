---
title: "Code splitting strategies"
date: 2026-04-25T09:00:00-04:00
draft: false
tags: [frontend, code-splitting, performance, bundling, javascript]
---

Code splitting is a budgeting tool. The question is not "can this code be split?" but "which users need this code, at what moment, and what latency can they tolerate?" A good strategy reduces initial work without turning every interaction into a loading spinner. It is a distribution problem, not a bundler checkbox.

{{< mermaid >}}
flowchart LR
  App[Application code] --> Critical[critical path]
  App --> Route[route chunks]
  App --> Feature[feature chunks]
  App --> Vendor[vendor chunks]
  App --> Background[background/prefetch]
  Critical --> FCP[fast first interaction]
{{< /mermaid >}}

## Mental model

JavaScript cost has multiple parts: download, decompression, parse, compile, and execution. On modern sites, parse and execution can dominate for mid-range devices. Splitting helps when it removes work from the critical path. It does not help if the split code is immediately requested during startup.

Start from user journeys. Anonymous visitors, authenticated daily users, admins, editors, and support staff need different surfaces. The initial bundle should contain the shell and the code needed for the current journey, not the entire product.

The unit of analysis is the interaction path. A dashboard route may need charts immediately, while a settings route may only need charts after the user opens an audit panel. The same dependency can be critical in one path and wasteful in another. Good splitting decisions come from route-level and feature-level evidence, not package names alone.

Think in three budgets:

- Transfer budget: compressed bytes over the network.
- Main-thread budget: parse, compile, execute, and hydration work.
- Latency budget: extra round trips introduced by lazy discovery.

A split is useful only if the first two budgets shrink more than the third budget grows.

## Strategy layers

Route splitting is the baseline. Each major route gets its own async boundary. This maps well to routers and user intent.

Feature splitting handles expensive modules inside a route: charting, maps, rich text editing, PDF rendering, export flows, payment forms, and advanced filters. These load when the feature becomes visible or likely.

Vendor splitting separates stable third-party dependencies from frequently changing application code. Be careful: a giant vendor chunk can become a tax on every route. Split vendors by usage, not only by `node_modules`.

Capability splitting isolates code by permission or tenant configuration. If only admins can access audit tools, non-admin sessions should not parse them.

Environment splitting can also matter. Development-only diagnostics, mock tooling, locale packs, and rarely used integrations should not leak into production startup. Feature flags are not enough if both branches import heavy code at module scope.

A practical hierarchy is:

1. Keep the application shell and current route lean.
2. Split route-level surfaces by navigation.
3. Split heavy features by explicit intent or visibility.
4. Split admin, enterprise, or integration-only capabilities by entitlement.
5. Group tiny modules that always execute together.

The last point is important. A bundler can produce many small chunks, but HTTP/2 multiplexing does not erase all overhead. Every chunk still needs discovery, request scheduling, response processing, source map association in development, and runtime bookkeeping.

## Practical patterns

Define performance budgets per route. For example: initial dashboard route under a target compressed size and main-thread execution budget; editor route allowed a larger async editor chunk after intent. Budgets make tradeoffs visible during review.

Use skeletons only when the delay is meaningful and unavoidable. For tiny delays, prefer preloading or grouping. For long delays, give progressive UI and preserve user context.

Combine splitting with prefetching. After login, prefetch the most likely next route. On idle, load low-risk chunks. On hover or focus, load the target route. Respect network conditions with `navigator.connection` where available.

Make lazy boundaries match UI boundaries. A route-level boundary can show a stable page skeleton. A modal-level boundary can keep the page interactive while the modal loads. A lazy component in the middle of a button label creates a poor failure mode because the user sees a broken small piece instead of a purposeful loading state.

Use static import for code needed during startup. Use dynamic import for code needed after a decision:

```js
button.addEventListener("click", async () => {
  const { openExportDialog } = await import("./export-dialog.js");
  openExportDialog();
});
```

If a feature is highly likely after navigation, preload it:

```js
link.addEventListener("pointerenter", () => {
  import("./settings-route.js");
});
```

Do not bury dynamic imports inside functions that run after data requests unless the code and data truly depend on each other. Otherwise the route waits for data, then discovers the chunk, then waits again.

For vendors, inspect actual usage. A date library used by every route may belong in a shared chunk. A charting library used by one analytics tab should stay with that tab. A UI component package might look shared, but importing a single component can accidentally include all icons, locales, or themes if the package is not tree-shakeable.

## Failure modes

Over-splitting creates waterfalls. The route chunk loads, then imports a chart chunk, which imports a date library chunk, which imports a locale chunk. The screen appears late despite small individual files. Bundle analyzers and network waterfalls reveal this quickly.

Under-splitting keeps first load slow. Teams often accept a bloated main bundle because "users eventually need it." Many users do not. Use coverage data from real sessions to challenge assumptions.

Another failure is inconsistent loading states. If every lazy component implements its own spinner, the app feels unstable. Centralize route-level loading behavior and reserve local loading states for genuinely local work.

Chunk invalidation can also break users during deploys. A user loads HTML that references `route-a.123.js`, then you deploy and remove that file before the user navigates. The dynamic import fails with a chunk load error. Keep old assets available for at least the maximum HTML cache lifetime, or handle chunk load failures by refreshing against current HTML.

Shared chunk churn is subtle. If every commit changes a large shared chunk, returning users lose cache benefits. Stable vendor chunks help only when they are stable in practice. Watch hash churn, not just chunk size.

Security and privacy can be failure modes too. Capability splitting should prevent non-admin users from downloading admin-only code when that code reveals workflow details, internal field names, or privileged UI paths. Do not rely on code splitting for authorization, but do avoid unnecessary disclosure.

## Diagnostics

Track JavaScript bytes by route, long tasks during startup, and lazy chunk load time. Use field data when possible because device class and network quality change the answer. Lab tools are useful for regression detection, but real usage tells you which routes matter.

Run bundle analysis in CI for main chunks and major async chunks. Alert on large dependency movement into critical paths. Review source maps to identify accidental imports, such as pulling a full icon library or all locales.

Use coverage tools to identify code executed during startup. A large unused percentage in the main bundle is a strong candidate for splitting, but verify that moving it does not add a waterfall to the first interaction. Record a trace for both cold load and warm navigation.

Useful metrics include:

- Initial JavaScript bytes per route.
- Main-thread startup time before first interaction.
- Number of async chunks requested before the route becomes useful.
- Lazy chunk failure rate.
- Cache hit rate for shared chunks after deploy.
- Top dependencies by parsed size, not only compressed size.

When reviewing a proposed split, ask for the before/after waterfall. The ideal shape is fewer critical bytes with at most one purposeful async load at a clear boundary. A bad shape is a staircase of chunks discovered during render.

## Checklist

- Split by route first, then by heavy feature.
- Keep critical-path JavaScript intentionally small.
- Group modules used in the same interaction.
- Prefetch based on strong user intent.
- Retain consistent loading UX.
- Watch bundle movement in CI.
- Validate with route-level field metrics.
- Keep old hashed chunks available across deploys.
- Measure parse and execution, not just transfer size.
- Avoid lazy boundaries that create nested startup waterfalls.
