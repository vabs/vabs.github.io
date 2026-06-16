---
title: "Preload vs Prefetch vs Preconnect"
date: 2026-03-02T09:50:00-05:00
draft: false
tags: [frontend, performance, resource-hints, preload, networking]
---

## Mental model

`preload`, `prefetch`, and `preconnect` are resource hints, but they solve different timing problems. `preload` says "this resource is needed for the current navigation; start it earlier." `prefetch` says "this may be needed for a future navigation; fetch it when idle." `preconnect` says "I will need this origin soon; warm up DNS, TCP, and TLS."

Choosing the wrong hint can make performance worse by stealing bandwidth from critical resources.

{{< mermaid >}}
graph TD
    A["Need something sooner"] --> B{"What is late?"}
    B -->|"Current page resource"| C["preload"]
    B -->|"Future page resource"| D["prefetch"]
    B -->|"Connection setup to origin"| E["preconnect"]
    C --> F["High priority fetch now"]
    D --> G["Idle/low priority cache fill"]
    E --> H["DNS + TCP + TLS warmup"]
{{< /mermaid >}}

## Internals that matter

Browsers discover resources by parsing HTML, CSS, and JavaScript. If a critical font is referenced deep inside CSS, discovery is late. `preload` moves discovery into the HTML head:

```html
<link rel="preload" href="/fonts/inter.woff2" as="font" type="font/woff2" crossorigin>
```

The `as` attribute matters. It tells the browser destination, priority, CSP bucket, and cache matching behavior. Missing or wrong `as` can cause duplicate downloads or ignored hints. Fonts usually need `crossorigin` even when same-origin because font fetch mode differs from normal fetches.

`prefetch` usually lands in the HTTP cache for later use:

```html
<link rel="prefetch" href="/next-route.js" as="script">
```

`preconnect` opens the connection without fetching a resource:

```html
<link rel="preconnect" href="https://cdn.example" crossorigin>
```

The three hints operate at different layers. `preconnect` warms the origin connection. `preload` fetches a specific resource for this page and gives it an early priority. `prefetch` opportunistically fetches a likely future resource at low priority. They can complement each other, but they are not interchangeable.

Cache matching is strict. A preloaded font without the same CORS mode as the eventual CSS font request may not be reused. A preloaded script with the wrong `as` value may sit in the wrong cache bucket. A preloaded responsive image without matching candidate metadata may fetch a resource the browser never selects.

Browsers also police unused preloads. If a preloaded resource is not consumed soon after load, DevTools warns because the hint likely competed with critical work for no benefit. Treat that warning as a design review prompt: was the resource wrong, too early, or no longer needed after a template change?

## Practical patterns

Use `preload` for render-blocking or near-render-critical resources that the browser discovers too late: hero image, critical font, or an entry chunk in some server-rendered setups. Keep the list short. If everything is preloaded, nothing is special.

Use `prefetch` for likely next routes after the current page is stable. Many routers do this on link hover or when links enter the viewport. Gate it on network conditions when possible; prefetching on slow connections can hurt the page the user is actually viewing.

Use `preconnect` for high-confidence third-party origins: API, CDN, font host, payment SDK. Do not preconnect to many origins. Each warm connection costs sockets, memory, and sometimes radio energy on mobile.

For fonts, preload only the critical subset or weight used during first paint. Preloading every family, weight, and style can delay the page more than font fallback would. Combine font preloads with `font-display` choices so the browser has a clear rendering strategy.

For hero images, prefer HTML discovery first. An `<img>` in the initial document with `fetchpriority="high"` may be enough. Add preload when the image is otherwise discovered late, such as through CSS or a framework manifest. For responsive images, use `imagesrcset` and `imagesizes` on the preload so the browser chooses the same candidate as the eventual image.

For route prefetching, use intent signals. Viewport-based prefetch can work for a small number of links, but prefetching every link in a large navigation wastes bytes. Hover, focus, tap-start, or recent behavior can provide better confidence. Disable or reduce prefetch under data saver and poor network conditions.

## Failure modes

Preloading a resource that is not used soon triggers browser warnings and wastes bandwidth. Preloading an image without matching `imagesrcset` or media conditions can fetch the wrong asset. Preloading fonts without `crossorigin` can download the same font twice.

Prefetch can pollute caches with assets the user never needs. It can also expose navigation intent to third parties if used against external origins.

Preconnect can be undone by slow server think time. If the resource is not requested within a few seconds, the warmed connection may close before use.

Over-preloading is the most common self-inflicted regression. Each high-priority preload competes with parser-discovered CSS, scripts, and images. If a resource is not needed for the initial render, prefetch or normal discovery is usually better.

Another failure is hiding an architectural problem. If a critical image is late because the route renders an empty shell and waits for client JavaScript to discover content, preload may improve the symptom while preserving a fragile path. Server-rendering the image tag or moving data earlier may be the real fix.

Third-party preconnects can leak intent and consume resources before consent. For analytics, ads, or social widgets, consider privacy requirements and user consent flows before warming connections.

## Diagnostics

Use the Network panel waterfall. A successful preload appears early and is reused by the eventual consumer. If you see two rows for the same URL, inspect request mode, credentials, `as`, and CORS attributes. Lighthouse and WebPageTest can identify late-discovered critical requests, but verify manually before adding hints.

Measure LCP before and after preloading hero images. Measure font swap behavior before and after font preloads. For route prefetching, track cache hit rate and wasted bytes.

Read waterfalls from left to right. A useful preconnect reduces DNS, TCP, and TLS time on the later request. A useful preload appears early and is later consumed by the parser, CSS, or script without a duplicate row. A useful prefetch is quiet during critical loading and becomes a cache hit on the next navigation.

If a hint appears ineffective, check whether the browser ignored it. Wrong MIME type, wrong `as`, unsupported attributes, CSP restrictions, and CORS mismatch can all cause hints to be ignored or not reused. DevTools initiator and priority columns usually reveal this.

## Implementation guidance

Keep hints close to the template that owns the need. A global head partial full of stale preloads is hard to maintain. Route-level metadata should declare the few current-page critical resources, while router code can handle future-route prefetch based on user intent.

Budget hints. For example: at most one hero image preload, at most two critical font preloads, and at most two third-party preconnects on a route unless a measurement justifies more. The exact numbers can vary, but having a budget forces review.

Review resource hints after design and dependency changes. A removed font, replaced hero, or new CDN hostname can leave behind useless hints that quietly waste bandwidth for months.

## Checklist

- `preload` is limited to current-page critical resources.
- Every preload has correct `as`, `type`, and `crossorigin` where needed.
- Responsive image preloads match the actual selected image.
- `prefetch` is gated by route likelihood and network conditions.
- `preconnect` is used for few high-confidence origins.
- Waterfalls confirm hints are reused, not duplicated.
- Hints are owned by routes or components, not a stale global list.
- Unused preload warnings are investigated.
- Font and image hints cover only first-render critical resources.
