---
title: "Priority hints"
date: 2026-03-09T15:05:00-04:00
draft: false
tags: [frontend, performance, priority-hints, lcp, browser]
---

## Mental model

Priority Hints let developers nudge the browser's internal fetch priority using `fetchpriority`. They are useful when the browser's default guess is wrong: a hero image should load sooner, or a below-the-fold image should stop competing with critical CSS and JavaScript.

This is a hint, not a command. The browser still considers resource type, render blocking, viewport, connection state, and its own scheduler.

{{< mermaid >}}
graph TD
    A["HTML parser discovers resources"] --> B["Browser assigns default priority"]
    B --> C{"fetchpriority present?"}
    C -->|high| D["Boost relative priority"]
    C -->|low| E["Deprioritize relative priority"]
    C -->|auto| F["Keep browser default"]
    D --> G["Network scheduler"]
    E --> G
    F --> G
{{< /mermaid >}}

## Internals that matter

Browsers already prioritize resources. CSS and blocking scripts are high. Images often start lower until layout reveals whether they matter. That can delay the Largest Contentful Paint image, especially when it appears in the initial viewport but is discovered among many other images.

Use:

```html
<img
  src="/hero.jpg"
  width="1280"
  height="720"
  alt=""
  fetchpriority="high">
```

For non-critical images:

```html
<img src="/gallery-12.jpg" loading="lazy" fetchpriority="low" alt="">
```

Priority Hints also exist for `link` and `script` in supporting browsers, but image LCP is the most common high-value case.

Priority is relative inside the browser's scheduler. It does not bypass connection limits, congestion control, server response time, or parser discovery. If the browser has not discovered the resource, there is nothing to prioritize. If the server is slow to respond, priority only changes where the request sits relative to other queued work.

The browser may revise priority after layout. An image can start low and move higher when layout proves it is in the viewport. DevTools exposes this as initial and final priority. `fetchpriority="high"` is most valuable when that automatic promotion would happen too late, such as a hero image discovered early but competing with many thumbnails.

`fetchpriority` interacts with preload because preload creates an early request and priority hints influence that request. For responsive images, the preload must match the eventual candidate selection. A mismatched preload can fetch a desktop image on mobile or fetch a URL that the `<img>` never reuses.

## Practical patterns

Add `fetchpriority="high"` to exactly one or very few LCP candidates. It works best with explicit dimensions and early HTML discovery. If the hero image is injected by late JavaScript, priority hints cannot recover all the lost time; fix discovery first.

Combine carefully with `preload`. If you preload the hero image, set matching attributes so the browser does not fetch twice:

```html
<link rel="preload" as="image" href="/hero.jpg" fetchpriority="high">
<img src="/hero.jpg" fetchpriority="high" width="1280" height="720" alt="">
```

Use `fetchpriority="low"` for images above the fold only when they are decorative or less important than the main content. Do not lower priority on resources required for layout stability or product comprehension.

A good implementation starts with LCP attribution. Identify the actual LCP element for the template across desktop and mobile. If the LCP candidate is a background image in CSS, consider whether it should become an HTML image or be preloaded with `as="image"` and the right responsive attributes. CSS background discovery is often late because the browser must parse CSS and apply selectors before it knows the image is needed.

For product grids, keep the first product image at default or high only if it frequently becomes LCP. Set lower priority on later images that are technically in the initial HTML but not necessary for the first visual impression. Pair this with explicit `width` and `height` so layout does not shift while lower-priority images arrive.

For frameworks that generate image tags, expose priority as a template-level decision rather than a component default. A reusable `Image` component should not always mark itself high. Pass a prop such as `priority="lcp"` from the route that knows page context.

## Failure modes

The common failure is priority inflation. If every product thumbnail, avatar, and banner is `high`, the scheduler has no meaningful signal and critical resources compete again. Another failure is treating priority as a substitute for compression, right sizing, caching, or server latency.

Priority can also conflict with lazy loading. A lazy image outside the viewport with `fetchpriority="high"` is still gated by lazy loading discovery behavior. Decide first whether the image should load now; then decide its relative priority.

Another trap is optimizing the wrong viewport. A wide desktop hero may be LCP, while mobile LCP may be a headline, product card, or smaller image. A high-priority desktop-only image can steal bandwidth on mobile if markup or media conditions are wrong. Use `media`, `imagesrcset`, and template logic carefully.

Priority hints can hide deeper problems in reviews. A faster LCP after adding `fetchpriority="high"` may still leave an oversized image, poor CDN cache hit rate, or delayed server-rendered HTML. Keep the hint, but fix the structural issue if the resource is too large or discovered late because of client-only rendering.

Some third-party widgets add their own high-priority requests. You may not control their attributes, but you can control when they are inserted. Delaying the widget until after the main content is painted often has more impact than trying to out-prioritize it.

## Diagnostics

Chrome DevTools shows initial and final priority columns in the Network panel. Compare before and after. For LCP, use the Performance panel to identify the LCP element, then confirm the request starts early and finishes sooner.

Use field data where possible. Lab improvements can disappear if real users have different viewport sizes and the hinted image is not actually their LCP candidate. Track LCP by template and device class.

Debug in three passes. First, verify discovery: when does the request appear relative to the initial HTML, CSS, and main script? Second, verify priority: did initial priority change, and did it stay meaningful after layout? Third, verify outcome: did LCP improve without delaying CSS, fonts, or other critical resources?

In WebPageTest or Chrome traces, look for queueing time. If the image request starts earlier but spends most of its life waiting on the server, the bottleneck may be origin latency or CDN miss. If it starts early and downloads slowly, image byte size or connection bandwidth is the constraint. If it downloads early but LCP is still late, decoding, rendering, layout, or main-thread work may be blocking presentation.

## Implementation guidance

Create a small policy for each template. Article pages can prioritize the lead image if present; product pages can prioritize the main product image; category pages should not prioritize every tile, only the first visible candidate after field data confirms it. Encode that in templates or image helpers so the decision is repeatable.

When combining preload and priority, keep attributes identical between the `<link>` and the eventual consumer. That includes `href` or `imagesrcset`, `imagesizes`, `type`, `crossorigin`, and `media`. A duplicate request is worse than no hint because it spends bandwidth on the same asset twice.

Review hints during design changes. A hero redesign, carousel introduction, or new A/B test can invalidate the old priority decision. Treat hints as performance code with owners, not as markup decoration.

## Checklist

- The hinted resource is a confirmed LCP or critical candidate.
- Only a small number of resources use `fetchpriority="high"`.
- Hero images are discoverable in initial HTML when possible.
- Preload and image attributes match to avoid duplicate fetches.
- Low priority is used for non-critical competing resources.
- DevTools priority and LCP timings verify the change.
- Mobile and desktop LCP candidates are checked separately.
- Third-party requests are delayed when they compete with first paint.
- Priority hints are revisited when templates or experiments change.
