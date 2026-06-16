---
title: "First Input Delay (FID)"
date: 2026-04-19T09:35:00-04:00
draft: false
tags: [frontend, performance, core-web-vitals, fid, javascript]
---

First Input Delay measures the delay between a user's first interaction and the browser's ability to start running the corresponding event handler. It focuses on input delay, not handler execution or paint. Even though Interaction to Next Paint is now the broader responsiveness metric, FID remains a useful concept because the first interaction is often where users discover that a page only looked ready.

The mental model: FID is main-thread availability at the moment of first input. If JavaScript parsing, execution, hydration, style work, or a third-party script owns the main thread, the browser queues the input until that task finishes.

{{< mermaid >}}
flowchart TD
  A[Page paints content] --> B[Long main-thread task]
  B --> C[User taps]
  C --> D[Input queued]
  D --> E[Task finishes]
  E --> F[Handler begins]
{{< /mermaid >}}

## Why FID happens

Modern pages often render pixels before they are interactive. Server rendering, static HTML, and CSS can make a page appear usable while large JavaScript bundles are still downloading, parsing, evaluating, and hydrating. If the user taps a menu during that window, the input waits.

Third-party tags amplify the problem. Analytics, consent managers, ads, chat widgets, heatmaps, and experiment frameworks may all run near startup. From the user's perspective, it does not matter whether the blocking task came from your code or a vendor script.

FID only measures the first discrete interaction such as click, tap, keydown, or similar input. It does not measure scrolling, and it does not include the time your handler takes after it starts. That narrowness is why a page can have acceptable FID and still feel slow later.

## Reducing startup contention

Ship less JavaScript. This is the highest-leverage FID fix and the least glamorous. Remove unused dependencies, split route bundles, avoid hydrating static islands, and prefer server-rendered HTML for content that does not need client behavior.

Defer non-critical work. Use `defer` for scripts that do not need to block parsing, lazy-load below-the-fold widgets, and schedule analytics setup after critical interaction paths are ready. Avoid doing expensive cache warmups during startup unless they directly support first interaction.

Break long tasks. If initialization must process large data, chunk it and yield between chunks. If it can run off-main-thread, move it to a worker. Parsing a large JSON blob, syntax highlighting a long article, or building a search index can all delay first input if run synchronously.

```js
async function initializeSearchIndex(records) {
  for (let i = 0; i < records.length; i += 500) {
    index.addAll(records.slice(i, i + 500));
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}
```

This allows the browser to process input between chunks.

Chunking only helps if the chunks yield to the task queue. Long promise chains can still monopolize the main thread because microtasks drain before the browser handles the next task. If a boot process does `await Promise.resolve()` between expensive chunks, it may look asynchronous in code while still blocking input in practice. Use a real task boundary, `scheduler.yield()` where available, `setTimeout(0)`, or a framework scheduler that cooperates with rendering.

Also distinguish parsing cost from execution cost. A library can be expensive before you call it because the engine must parse and compile it. Route-level dynamic import helps by keeping code out of the initial parse path. Tree shaking helps only when the bundler can prove unused code is removable, so CommonJS packages, side effects, and broad utility imports can keep surprising amounts of code in the startup bundle.

## Interaction readiness

FID exposes the gap between "painted" and "ready." Close that gap by designing the first interaction path explicitly. Identify the controls visible above the fold: navigation menu, search box, sign-in button, theme toggle, hero call to action, cookie choice. Those controls should have the smallest possible dependency chain. If opening the mobile menu requires the entire analytics stack, personalization layer, and dashboard bundle to hydrate first, the page will feel broken even if the first paint is fast.

Progressive enhancement is a practical readiness tool. Links should be real links. Forms should have a server action or a minimal submit path. Disclosure widgets can be small islands rather than waiting for the app root. On content-heavy pages, a small script that handles the table of contents or menu can load before the larger interactive features. The goal is not to avoid JavaScript; it is to avoid coupling every first interaction to all JavaScript.

Use feature ownership to enforce this. Third-party scripts should not run unbounded work before critical controls are interactive. Experiment frameworks should decide the above-the-fold variant as early and cheaply as possible, preferably at the edge or server. Consent tools should not attach heavy listeners to the whole document during startup if a smaller prompt would do.

## Hydration strategy

Hydration is a common FID source because it runs after HTML is visible and can monopolize the main thread. Hydrate the smallest necessary interactive regions first. Delay low-priority islands such as comments, recommendations, and sharing widgets. Avoid attaching expensive listeners to huge DOM subtrees during startup.

Progressive enhancement helps. A server-rendered link should navigate even before client routing hydrates. A form should have a baseline submit path. When possible, the first interaction should not depend on a full application boot.

In traces, hydration often appears as script evaluation followed by many small DOM reads, listener attachments, and framework reconciliation. If the first input lands during that work, the handler waits. Splitting hydration by island or priority reduces the maximum blocking window. So does simplifying the HTML that must hydrate: fewer nodes, fewer client components, fewer layout effects, and fewer synchronous data reads during mount.

## Failure modes

One failure is optimizing only network load. A compressed 300 KB script can still become a long parse and execute task on a low-end phone. Measure CPU, not just transfer size.

Another failure is putting startup work into microtasks. Promise chains during boot can keep control away from rendering and input. If you need to yield to user input, use task scheduling rather than an endless microtask queue.

A third failure is relying on lab FID. FID requires a real user interaction, so lab tools often use Total Blocking Time as a proxy. Field data is essential. TBT improvements often help FID, but they are not identical.

## Diagnostics

Use real user monitoring to capture first input delay by page type, device class, and script version. In lab, inspect long tasks before and around first interaction. The Performance panel shows script evaluation, parse cost, and third-party tasks. CPU throttle heavily; a startup path that feels fine on a laptop can block input for hundreds of milliseconds on budget Android devices.

Checklist:

- Reduce startup JavaScript.
- Split and defer non-critical bundles.
- Break initialization into yieldable chunks.
- Hydrate only what must be interactive early.
- Audit third-party scripts during startup.
- Use field data for FID and lab Total Blocking Time as a proxy.
