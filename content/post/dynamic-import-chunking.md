---
title: "Dynamic import chunking"
date: 2026-04-14T09:00:00-04:00
draft: false
tags: [frontend, dynamic-import, chunking, bundling, performance]
---

Dynamic `import()` is both a language feature and a bundler signal. In application code it means "load this module asynchronously." In a bundled frontend it usually means "create a separate chunk boundary here." Used well, it keeps initial JavaScript small and delays rarely used code. Used casually, it creates a waterfall of tiny chunks that slow down real navigation.

{{< mermaid >}}
flowchart TD
  Entry[entry chunk] --> Router[router]
  Router -->|import()| Admin[admin chunk]
  Router -->|import()| Editor[editor chunk]
  Editor -->|import()| Markdown[markdown parser chunk]
  Editor -->|import()| Syntax[syntax highlighter chunk]
{{< /mermaid >}}

## Internals that matter

Bundlers build a module graph. Static imports become part of the synchronous graph for an entry point. Dynamic imports become async edges. The bundler emits a runtime loader that fetches the referenced chunk when execution reaches that import.

The browser still pays network latency, parse time, compile time, and execution time. A chunk is not free because it is deferred. The win appears when many users never request it, or when it can be prefetched before interaction.

Chunk names and grouping depend on the bundler. Webpack, Vite/Rollup, and esbuild expose different controls. The important concept is stable ownership: know why a boundary exists and which user action needs it.

The runtime also needs a manifest of chunk relationships. When execution reaches `import("./routes/EditorPage")`, the loader resolves the chunk URL, fetches it, evaluates its dependencies, and fulfills the promise with the module namespace. If that imported module depends on CSS or additional chunks, the runtime may issue more requests before the UI can render.

Dynamic import does not make parse and compile cost disappear. It moves that cost to a later moment. That is good when the later moment is rare, idle, or predictable enough to prefetch. It is bad when the user clicks a common navigation item and then waits for JavaScript that could have loaded during idle time.

Bundlers can only split at module boundaries they understand. Computed import paths may cause broad context chunks. For example, `import("./pages/" + name)` can force the bundler to include every matching page in a generated map. That is sometimes useful, but it should be intentional and visible in bundle analysis.

## Practical boundaries

Route-level imports are the safest first split. Admin pages, settings pages, dashboards, editors, and onboarding flows often have distinct audiences and dependencies. Component-level imports are useful for heavy widgets such as rich text editors, maps, charts, video tools, and code highlighters.

Avoid splitting every component. If a page needs ten components immediately, ten dynamic imports can become a request waterfall. Group code by interaction phase: initial route, above-the-fold interaction, advanced panel, export flow.

```js
const EditorPage = lazy(() => import("./routes/EditorPage"));

async function openExportDialog() {
  const { ExportDialog } = await import("./features/export-dialog");
  showDialog(ExportDialog);
}
```

For hover or intent-driven flows, prefetch before click. When a user hovers a navigation item or focuses a command, start loading the likely chunk. Keep prefetch conservative on slow connections and data-saver modes.

Group by user journey, not by file count. A settings route may need profile, billing, and notification panels immediately; splitting those into separate chunks can create a waterfall. A charting library behind an "Analytics" tab is a better boundary because many users never open it.

Use explicit loading states at the boundary. A lazy route should have a stable shell, not a blank page. If dynamic import is paired with data fetching, start both as early as possible. A common pattern is to trigger code prefetch and data prefetch on link intent so the eventual click has less work to do.

For admin-only or role-specific code, dynamic import can reduce both bytes and accidental exposure of implementation details. It is not an access-control mechanism, because users can still request chunks by URL, but it keeps irrelevant code out of the main path.

## Failure modes

The classic failure is chunk load error after deploy. The user has old HTML and runtime code, but the server no longer has the old chunk filename. Immutable asset retention fixes this: keep old hashed chunks available long enough for active sessions to finish.

Another failure is moving shared dependencies into async chunks accidentally. If a small dialog import pulls in a second copy or a large vendor chunk, the split may hurt more than it helps. Inspect bundle analyzer output and the actual network waterfall.

Dynamic import can also hide errors until a user reaches a path. A syntax error or missing dependency in an admin chunk may pass initial smoke tests. Exercise lazy routes in CI or production canaries.

Chunk naming instability can hurt long-term caching. If a small change in one route changes chunk names for unrelated routes, users lose cache value and stale references become more likely. Prefer deterministic content-hashed filenames and review bundler settings that affect chunk IDs.

Service workers can make chunk errors harder. An old worker may serve old HTML, a new runtime, or cached route chunks in combinations you did not test. Version app-shell caches, avoid caching chunk manifests with stale policies, and provide a reload path when a chunk load fails after deploy.

Another failure is splitting shared vendor code into a chunk required by nearly every route. The first route then pays entry chunk plus vendor chunk plus route chunk, and later routes still wait on route chunks. Bundle analyzer output should show whether the split actually reduces critical bytes for real users.

## Diagnostics

Use coverage tools to identify unused initial JavaScript. Then inspect bundle graphs to find heavy modules that are not needed on first interaction. Measure route transition time with cold cache and warm cache. A split that improves first load but makes common navigation feel broken needs prefetching or regrouping.

Log chunk load failures with chunk URL, app version, route, and service-worker state. Many "random white screen" reports are stale chunk problems.

Measure both first load and route transition. A split that saves 80 KB on initial load but adds 900 ms to the most common second page may be a poor trade. Use cold-cache tests for first visit, warm-cache tests for navigation, and throttled CPU tests for parse cost.

Inspect the waterfall for sequential chunk loading. If `EditorPage` loads, then discovers `markdown`, then discovers `syntax`, the user waits for multiple round trips. Import related heavy dependencies together or prefetch known children. Some frameworks expose route-level loaders or module preload hints to flatten this graph.

## Implementation guidance

Start with a bundle report and a route map. Mark which routes are public, authenticated, admin-only, rarely used, or heavy because of a specific library. Create boundaries around those facts. Avoid splitting a component just because it has a large file; split it because it is not needed for the current user task.

Wrap lazy imports in retry and fallback behavior. A chunk load failure after a deploy often succeeds after a hard reload because the new HTML points at the new chunk graph. Show a scoped recovery UI instead of leaving a blank screen. Log enough metadata to tell stale asset failures from network failures.

Keep old hashed chunks on the CDN for at least the longest realistic session plus cache lifetime. Removing them immediately after deploy is the fastest way to turn dynamic import into production-only white screens.

## Checklist

- Split around routes and heavy interaction phases.
- Avoid tiny chunks that are always needed together.
- Prefetch likely next chunks based on user intent.
- Retain old hashed chunks after deploy.
- Test lazy routes in CI.
- Measure initial load and navigation latency together.
- Avoid computed imports unless the generated context is understood.
- Flatten waterfalls for common lazy routes.
- Log lazy-load failures with app and service-worker version.
