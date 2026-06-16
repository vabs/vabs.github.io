---
title: "Largest Contentful Paint (LCP)"
date: 2026-03-18T14:40:00-04:00
draft: false
tags: [frontend, performance, core-web-vitals, lcp, images]
---

Largest Contentful Paint measures when the largest visible content element in the viewport is painted. It is a user-centric proxy for "the main thing loaded." The LCP candidate is often a hero image, poster image, heading, large paragraph, or background image discovered through CSS. Optimizing it requires working backward from the actual winning element, not applying generic performance tricks.

Think of LCP as four segments: time to first byte, resource load delay, resource load duration, and element render delay. The slowest segment determines the practical fix.

{{< mermaid >}}
flowchart TD
  A[Navigation starts] --> B[TTFB]
  B --> C[Discover LCP resource]
  C --> D[Download resource]
  D --> E[Decode and render element]
  E --> F[LCP recorded]
{{< /mermaid >}}

## Find the real element

Use field data first when available because lab tests may pick different candidates than real devices. In the browser, `PerformanceObserver` can report LCP entries and their element. DevTools' Performance panel and Lighthouse identify the candidate and phase breakdown. Do not assume the hero image is LCP; a cookie banner, large text block, or skeleton can win.

```js
new PerformanceObserver((list) => {
  const entries = list.getEntries();
  const lcp = entries[entries.length - 1];
  console.log(lcp.startTime, lcp.element);
}).observe({ type: "largest-contentful-paint", buffered: true });
```

LCP finalizes when the user interacts or the page is hidden. Late-loading content can replace earlier candidates, so optimize the final candidate, not the first candidate.

## Resource discovery

If the LCP element is an image, the browser must discover it early. Plain `<img src>` in the initial HTML is ideal. CSS background images are discovered only after CSS downloads and parses. Client-rendered images may wait for JavaScript, hydration, data fetching, and component rendering. Each dependency adds resource load delay.

Use `fetchpriority="high"` on the actual LCP image when there are competing images. Preload it when discovery is otherwise late, but keep preload URLs, `imagesrcset`, and media conditions aligned with the real image or you will download the wrong asset.

```html
<img
  src="/hero-1280.avif"
  srcset="/hero-640.avif 640w, /hero-1280.avif 1280w"
  sizes="100vw"
  width="1280"
  height="720"
  fetchpriority="high"
  alt="Product dashboard overview">
```

Do not lazy-load the LCP image. Native lazy loading is useful below the fold, but it intentionally delays discovery and scheduling.

## Server and render delay

TTFB includes DNS, connection, TLS, redirects, server processing, and CDN behavior. Redirect chains are pure waste for LCP. Server rendering can help by sending the LCP markup before JavaScript, but slow server data dependencies can erase that benefit. Stream the shell and critical content where possible.

Element render delay occurs after the resource is ready but before it paints. Causes include render-blocking CSS, long JavaScript tasks, font blocking, hidden ancestors, client hydration, and image decode delays. If the image is downloaded early but LCP is still late, look for main-thread work and CSS dependencies.

For text LCP, web fonts matter. `font-display: swap` or carefully preloaded critical fonts can avoid invisible text delays. For image LCP, provide dimensions to avoid layout work and use modern formats sized to the rendered viewport.

The most useful optimization habit is to keep the LCP chain short. The browser should not need to wait for JavaScript to fetch JSON, render a component, discover an image URL, then start downloading the image. Put the winning element, or at least the winning resource reference, in the initial HTML whenever possible. If the resource depends on responsive conditions, use `srcset`, `sizes`, and media-aware preload rather than a single unconditional preload that fights the actual image selection algorithm.

Priority should be deliberate. `fetchpriority="high"` helps when the browser has several plausible important images, but overusing it destroys the signal. Do not mark logos, avatars, below-the-fold gallery images, and carousel alternates as high priority. The first viewport has limited network and decode capacity. The LCP resource should win that competition, and non-critical scripts should not be able to crowd it out.

## Implementation patterns

For server-rendered pages, include the LCP element in the first chunk and avoid wrapping it in a client-only component. If personalization is required, render a stable generic version and patch details later. For app shells, route-level code splitting should not hide the first meaningful heading or hero behind a bundle that loads after the shell. If the route's first screen is image-led, the image URL must be known before the route component finishes a long hydration path.

For CSS background LCPs, consider whether they should be real images. A semantic `<img>` is easier for the preload scanner, easier to prioritize, easier to size, and easier to observe. If a background is necessary, preload the exact URL with the right media condition and keep the CSS file itself early. Background images inside late-loaded CSS are a common resource load delay source.

For image generation pipelines, set budgets by rendered size, not original asset size. A 2400 px image in a 390 px mobile viewport wastes download, decode, and memory. Use CDN transforms or build-time variants, cache them aggressively, and verify that `sizes` matches the layout at each breakpoint. Incorrect `sizes="100vw"` on a half-width desktop hero can silently double the resource cost.

## Failure modes

Skeleton screens can hurt LCP if the skeleton is large and then replaced late by real content. They may improve perceived progress, but the metric rewards the final large content paint. Prefer rendering meaningful content early.

Carousels are frequent offenders. If the first slide's image is hidden behind JS initialization or all slides compete for priority, LCP suffers. Server-render the first slide, prioritize only its image, and lazy-load the rest.

Cookie banners and app install prompts can become LCP candidates if they are large. Keep overlays compact and avoid letting non-primary UI dominate the viewport before content appears.

## Diagnostics

Break the LCP timeline into phases. If TTFB is high, inspect CDN, redirects, server traces, and cache headers. If resource load delay is high, improve discovery and priority. If load duration is high, resize, compress, and cache the asset. If render delay is high, profile CSS, fonts, hydration, and long tasks.

Checklist:

- Identify the real LCP element in field and lab data.
- Put LCP markup and resources in the earliest possible path.
- Do not lazy-load the LCP image.
- Use correct dimensions, responsive images, and modern formats.
- Reduce redirects, TTFB, render-blocking CSS, and long tasks.
- Re-measure by LCP phase after every change.
