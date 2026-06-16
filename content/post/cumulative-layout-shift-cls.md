---
title: "Cumulative Layout Shift (CLS)"
date: 2026-03-28T12:25:00-04:00
draft: false
tags: [frontend, performance, core-web-vitals, cls, layout]
---

Cumulative Layout Shift measures unexpected visual movement. It is not a general animation metric. It penalizes layout shifts that occur without recent user input and that move visible content. CLS is frustrating because it breaks spatial memory: the user reaches for a button, content jumps, and the click lands somewhere else.

The mental model is reservation. Any content that will appear later needs space before it arrives, or it needs to appear in a layer that does not push existing content. Images, ads, embeds, banners, fonts, client-rendered widgets, and personalized modules are the usual sources.

{{< mermaid >}}
flowchart TD
  A[Initial layout] --> B[Late content arrives]
  B --> C{Space reserved?}
  C -->|yes| D[No shift]
  C -->|no| E[Visible elements move]
  E --> F[CLS increases]
{{< /mermaid >}}

## How CLS is calculated

A layout shift entry has an impact fraction and distance fraction. The score is roughly how much viewport area moved multiplied by how far it moved. The page's CLS is based on session windows of shifts, not a simple sum over the entire page lifetime. Recent user input can exempt expected shifts, but only for a short window and not for all input types.

That means delayed UI after a click can still count if it happens too late. If expanding a panel requires data, reserve the expanded area or show an immediate placeholder inside the user-input window.

Use `PerformanceObserver` to inspect shifts and sources:

```js
new PerformanceObserver((list) => {
  for (const entry of list.getEntries()) {
    if (!entry.hadRecentInput) {
      console.log(entry.value, entry.sources);
    }
  }
}).observe({ type: "layout-shift", buffered: true });
```

## Reserve dimensions

Images and videos should have `width` and `height` attributes or CSS `aspect-ratio`. Responsive images still need an intrinsic ratio so the browser can allocate space before bytes arrive.

```html
<img
  src="/chart.png"
  width="1200"
  height="675"
  alt="Revenue chart">
```

For cards with async content, reserve stable slots. A loading skeleton should match the final component's dimensions. If the final content can vary widely, use `min-height`, aspect ratio, or container queries to bound the change.

Ads and embeds are harder because inventory size may vary. Reserve the largest acceptable slot or use fixed-size containers with internal centering. Collapsing an empty ad slot after load can create a shift; consider leaving the reserved space or collapsing before the slot enters the viewport.

Reservation should happen in the first render path. Adding a min-height after JavaScript loads is too late if the first layout already happened. Server templates, static HTML, or critical CSS should define the space for above-the-fold media and modules. For client-rendered apps, the shell should include stable placeholders with the same block size as the eventual content. A spinner centered in an auto-height container does not reserve anything useful.

Use aspect ratios when one dimension is fluid. A responsive video can be `width: 100%` with `aspect-ratio: 16 / 9`. A product tile can reserve the image area even before the image URL is known. For variable-height text, reserve line count with predictable typography: fixed font stack, stable line-height, and a minimum area for titles or excerpts. Do not reserve impossible amounts of blank space, but make the expected layout stable enough that late content fills slots instead of pushing siblings.

## Hydration and personalization

CLS often appears during hydration because the server and client render different geometry. A server renders "Sign in" and the client replaces it with a user menu. A feature flag changes the hero copy. A price component adds a discount badge after a client fetch. Each difference may be logical, but the layout moves after the user has started reading.

The fix is to make both states occupy compatible space or resolve the state earlier. Auth-dependent nav can reserve the account control width. Feature flags that affect first-viewport layout should be evaluated on the server or edge. Personalization modules should have fixed slots and internal loading states. If a module is optional, decide whether to reserve a blank slot, replace it with fallback content, or place it lower on the page where movement is less harmful.

Fonts are another hydration-like mismatch. The fallback font lays out text, then the web font changes metrics. Use `size-adjust`, `ascent-override`, `descent-override`, and `line-gap-override` when available to make fallback metrics closer to the final font. If brand typography is not critical for first paint, `font-display: optional` can avoid late swaps on slow connections.

## Fonts and dynamic UI

Web font swaps can shift text when fallback and final metrics differ. Use `font-display` deliberately, preload critical fonts, and choose fallback fonts with similar metrics. CSS font metric overrides can reduce movement when supported.

Banners inserted at the top of the page are classic CLS bugs. Cookie notices, install prompts, flash messages, and experiment headers should either reserve space from the first render or overlay without pushing content. For overlays, ensure they do not cover critical controls.

Client-side personalization can also shift content. If the server renders a generic nav and the client inserts account controls later, reserve the account area. Avoid rendering nothing and then adding a wide menu after hydration.

## Failure modes

Animating layout properties such as `height`, `top`, `left`, and `margin` can cause shifts and expensive layout. Prefer transforms for visual movement when the surrounding layout should not change. If layout truly changes, tie it directly to user input and complete it promptly.

Infinite scroll can shift if content above the viewport changes size after images decode. Reserve media dimensions in every feed item. Prepending new items is especially risky; preserve scroll position and avoid inserting above the user's reading position unless explicitly requested.

Error messages in forms can shift fields during typing. Reserve validation message space or place messages in a predictable block. For submit-time summaries, focus management may matter more than avoiding every small shift, but the movement should still be intentional.

## Diagnostics

Chrome DevTools can highlight layout shift regions and show source nodes. Field attribution is essential because real CLS often comes from ads, consent tools, A/B testing scripts, or slow fonts that lab runs miss. Track CLS by template and viewport. Mobile often suffers more because small vertical shifts represent larger viewport fractions.

Checklist:

- Add dimensions or aspect ratios for media.
- Reserve slots for async cards, ads, embeds, and personalized UI.
- Avoid inserting banners above content after first paint.
- Tune font loading and fallback metrics.
- Use transforms for visual motion that should not affect layout.
- Inspect layout-shift sources in field data and DevTools.
