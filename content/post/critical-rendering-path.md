---
title: "Critical rendering path"
date: 2026-01-21T10:20:00-05:00
draft: false
tags: [frontend, performance, rendering, browser-internals, web-vitals]
---

The critical rendering path is the sequence of browser work required to turn bytes into pixels. It starts with the network response and ends with a frame on screen. The useful part of the model is that each stage can block or invalidate later stages: HTML creates the DOM, CSS creates the CSSOM, both combine into a render tree, layout computes geometry, paint records drawing commands, and compositing places layers on screen.

{{< mermaid >}}
flowchart LR
  A[HTML bytes] --> B[DOM]
  C[CSS bytes] --> D[CSSOM]
  B --> E[Render tree]
  D --> E
  E --> F[Layout]
  F --> G[Paint]
  G --> H[Composite]
  H --> I[Frame]
{{< /mermaid >}}

## Mental model

The rendering pipeline is incremental, but not magic. The parser can build the DOM while bytes stream in. The preload scanner can discover resources before the parser reaches them. The browser can paint partial content once it has enough DOM and CSS. But JavaScript can pause parsing, CSS can block paint, and layout reads can force the browser to flush pending style changes earlier than it wanted.

When performance work gets vague, map the symptom to a pipeline stage. Slow first contentful paint usually points at network, blocking CSS, or parser-blocking JavaScript. Slow largest contentful paint often involves image discovery, server response time, client hydration, or delayed rendering of the LCP node. Interaction delay usually points at long main-thread tasks after the page is visible.

## Internals that matter

DOM construction is tolerant of malformed HTML, but it is still ordered. A synchronous script in the head stops parsing because it may call `document.write` or inspect elements that have been parsed so far. Stylesheet loading also interacts with script execution: a script that might query style cannot safely run until earlier blocking stylesheets are ready.

Layout computes boxes. It needs DOM structure, computed styles, viewport constraints, font metrics, and intrinsic sizes. Paint converts boxes into drawing commands. Compositing moves painted layers, often on a compositor thread. Transform and opacity animations can often stay in compositing; width, height, top, and font changes usually return to layout or paint.

## Practical patterns

Design the first screen as a small dependency graph. The HTML shell should contain the primary content or enough server-rendered structure to avoid waiting for a large bundle. Critical CSS should cover the shell. The LCP image should be discoverable in HTML, have explicit dimensions, and use `fetchpriority="high"` only when it is truly the primary candidate.

```html
<img
  src="/hero.webp"
  width="1200"
  height="640"
  fetchpriority="high"
  alt="Product dashboard"
>
```

Hydration should not monopolize the main thread. Split islands by interaction priority. Navigation, search, and purchase controls hydrate before below-the-fold decoration. If the framework supports streaming or selective hydration, use it to match the user journey rather than the component tree shape.

## Failure modes

The critical path often grows accidentally. A marketing tag is added in the head. A design system stylesheet imports fonts from another origin. A client-only route waits for JavaScript before showing content that the server could have rendered. No single change looks catastrophic, but the dependency graph gets wider and deeper.

Another failure is optimizing the wrong metric. Removing a render-blocking stylesheet may improve FCP while causing a flash and worse CLS. Lazy-loading the LCP image may reduce initial network pressure while making the most important element arrive late. Performance work must preserve visual correctness.

## Debugging

Use a DevTools Performance trace and mark FCP, LCP, layout, paint, and long tasks. Then open the Network panel and identify whether critical resources were discovered early. If an important image is found only after JavaScript runs, move discovery into HTML. If CSS arrives late from a third-party origin, consider self-hosting or reducing font/style dependencies.

Add targeted `performance.mark` calls around hydration and route rendering. Compare those marks to Web Vitals attribution. If LCP happens after hydration completes, rendering may be delayed by app code. If LCP waits on an image response, the network path is the bottleneck.

## Implementation details

The highest-leverage optimization is usually early discovery. Browsers are good at fetching resources once they know about them. They are much worse at fetching a resource that is hidden behind a client bundle, a CSS background image, or a late JSON response. Put the main document, critical CSS, and LCP candidate on a short, visible path.

Server rendering changes the shape of the path but does not remove it. HTML can arrive earlier, yet hydration can still delay interaction or replace server-rendered content if client state disagrees. Make server and client data sources deterministic for the first render. Avoid reading local-only values during initial render unless you have a deliberate fallback and can tolerate the visual transition.

The path also differs by navigation type. A cold entry load pays DNS, TLS, cache misses, and parser startup. A same-origin client transition may pay JavaScript execution, route data, and rendering but not document parsing. Measure both. Optimizing only the initial page can leave the app feeling slow after the first click.

Use performance budgets at the stage level: maximum blocking script bytes, maximum critical CSS bytes, maximum LCP image size, and maximum hydration task duration. Stage budgets are more actionable than a single Lighthouse score because they tell the owning team what to change.

## Checklist

- Keep the first-screen dependency graph small and explicit.
- Make critical images discoverable in HTML.
- Use dimensions to reserve layout space.
- Defer non-critical scripts.
- Avoid CSS imports and late font discovery.
- Measure cold and warm navigations separately.
- Debug with traces, not only aggregate scores.

The critical rendering path is a coordination problem. Fast pages reduce the amount of work before the first useful frame and schedule the remaining work so it does not invalidate what the user already sees.
