---
title: "Paint vs composite vs layout"
date: 2026-05-01T09:45:00-04:00
draft: false
tags: [frontend, rendering, layout, paint, compositing, performance]
---

## Rendering work has different prices

When a page changes, the browser does not perform one generic "render" step. It may recalculate style, run layout, paint pixels, raster tiles, and composite layers. Performance work becomes much clearer when you can identify which stage your change invalidates.

{{< mermaid >}}
flowchart TD
  JS["JS or CSS change"] --> Style["style recalculation"]
  Style --> Layout["layout: compute geometry"]
  Layout --> Paint["paint: record drawing commands"]
  Paint --> Raster["raster: pixels/tiles"]
  Raster --> Composite["composite: assemble layers"]
  Composite --> Screen["display"]
  JS --> CompositeOnly["transform/opacity change"] --> Composite
{{< /mermaid >}}

Layout determines boxes. Paint determines what those boxes look like. Compositing assembles already-rasterized layers onto the screen.

## Layout

Layout answers geometry questions: where boxes are and how large they are. Changing `width`, `height`, `font-size`, `display`, DOM structure, or content can require layout. Layout can be local or broad depending on containment, formatting context, and dependencies.

Forced synchronous layout happens when JavaScript writes to the DOM and then immediately reads geometry:

```js
el.style.width = "400px";
const h = el.offsetHeight; // browser may flush style and layout now
```

In loops, this becomes layout thrashing. Batch reads before writes, or schedule measurement and mutation in separate phases.

## Paint

Paint records drawing operations: backgrounds, borders, text, shadows, images, outlines. Changing `color` usually avoids layout but requires paint. Changing a complex `box-shadow` or large background can be paint-heavy. Paint cost depends on area and complexity, not just the property name.

Paint invalidation is the region the browser must repaint. A small color change in a contained button is cheap. A fixed translucent overlay over the whole viewport is not.

## Composite

Compositing combines layers. If an element is on its own composited layer, changes to `transform` and `opacity` can often be handled by the compositor without repainting. This is the basis of smooth CSS animations.

Composite-only is not always free. Layers consume memory. Large layers require raster tiles. Moving a huge layer can still stress bandwidth. But it is usually more predictable than layout or paint for motion.

## Property examples

`transform: translate(...)` normally affects composite. `opacity` normally affects composite. `background-color` affects paint. `box-shadow` affects paint and can be expensive. `width` affects layout and then paint. `left` on positioned elements may affect layout; `transform` is usually better for animation. `font-size` affects layout because text metrics change.

These are tendencies, not guarantees. Browser engines optimize aggressively, and context matters. The reliable answer comes from a performance trace.

The dependency graph is the important part. A style change may require selector matching. If the computed value affects geometry, layout follows. If pixels change, paint follows. If the painted output lives on a composited layer, the compositor can reuse existing raster tiles for transforms and opacity. But a layer is not magic. If the layer's contents change, it still needs paint and raster. If a transform changes the visible bounds enough to expose previously unrasterized tiles, raster work can appear during an animation.

This is why "use `will-change`" is not a blanket fix. `will-change: transform` can promote an element earlier so the first animation frame does not pay setup cost, but promoted layers consume memory and can increase upload bandwidth to the GPU. Use it shortly before an interaction and remove it afterward for transient effects. Permanent layer promotion is reasonable for stable, frequently animated surfaces such as a map viewport, video overlay, or primary drawer, but not for every card in a feed.

## Layout invalidation scope

Layout cost depends on how far geometry dependencies spread. Changing text in a flex item can affect siblings, parent height, scrollbars, and descendants. Changing a contained card with fixed grid tracks may stay local. Tables, large flex layouts, percentage sizing, intrinsic image dimensions, and web font swaps can broaden invalidation because the engine must answer "does this change alter available space elsewhere?"

Containment and stable sizing are practical boundaries. A dashboard grid with cards that declare `contain: layout paint` and a stable `min-height` gives the engine more confidence than a page where every card's size depends on its children and every parent depends on its tallest child. Virtualization helps by shrinking the number of boxes, but it can introduce measurement loops if rows are constantly measured and repositioned. The goal is not only fewer nodes; it is fewer dependencies between nodes.

When optimizing, record the exact interaction. If a trace shows repeated "Layout" tasks interleaved with JavaScript stacks, search for geometry reads such as `offsetWidth`, `scrollHeight`, `getBoundingClientRect()`, and computed style reads after DOM writes. If paint dominates, enable paint flashing and look for unexpectedly large invalidation regions. If composite dominates, inspect layer count, large textures, backdrop filters, and fixed elements that move during scroll.

## Practical patterns

For animation, reserve layout changes for state transitions that do not run every frame. Use transform for movement:

```css
.toast {
  transform: translateY(var(--offset));
  opacity: var(--alpha);
  transition: transform 160ms ease, opacity 160ms ease;
}
```

For measurement-heavy components, implement a read/write discipline:

```js
const rects = items.map((item) => item.getBoundingClientRect());
requestAnimationFrame(() => {
  for (const [i, item] of items.entries()) {
    item.style.setProperty("--top", `${rects[i].top}px`);
  }
});
```

For large UI, introduce boundaries: CSS containment, virtualization, and component-level state updates. The best rendering work is the work you do not invalidate.

## Failure modes

Animating `height: auto` causes repeated layout. Use transform reveals, grid tricks, or measure once and animate between explicit values.

Heavy shadows on scrolling cards cause paint storms. Replace with simpler shadows, static assets, or limit the shadow area.

Sticky headers with backdrop blur can repaint large areas during scroll. Test on mobile hardware before shipping.

Reading layout in scroll handlers can block smooth scrolling. Use passive listeners, IntersectionObserver, ResizeObserver, or scheduled reads where appropriate.

## Diagnostics

Chrome Performance traces label Layout, Paint, Raster, and Composite work. Paint flashing shows repainted regions. Layer borders show composited layers. Firefox and Safari have similar tools with different names.

Start with the user-visible symptom: input delay, animation stutter, scroll jank, or slow load. Then capture a trace around that interaction. Optimize the dominant stage, not the property you suspect.

## Checklist

- Know whether your change invalidates layout, paint, or composite.
- Batch geometry reads and DOM writes.
- Animate transform and opacity for frequent motion.
- Measure paint area, not only paint count.
- Avoid unbounded layer promotion.
- Verify in performance tools on realistic hardware.

Rendering performance is stage-specific. Once you can name the stage, fixes become concrete instead of superstitious.
