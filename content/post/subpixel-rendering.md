---
title: "Subpixel rendering"
date: 2026-03-18T13:40:00-04:00
draft: false
tags: [frontend, css, rendering, pixels, browser-internals]
---

## CSS pixels are not device pixels

Modern layout is full of fractions. CSS pixels are an abstract unit; device pixels are physical display samples. Device pixel ratio, zoom, transforms, percentage layouts, font metrics, and flex/grid distribution all create subpixel values. The browser does not simply round every box to an integer at layout time. It carries fractional geometry forward and resolves it during painting and compositing.

{{< mermaid >}}
flowchart LR
  CSS["CSS values: %, rem, vw"] --> Layout["fractional layout boxes"]
  Layout --> Paint["paint commands with floats"]
  Paint --> Raster["rasterize to device pixels"]
  Raster --> Composite["composite transformed layers"]
  Composite --> Display["physical pixels"]
{{< /mermaid >}}

Subpixel rendering is why a three-column layout can divide 1000px into thirds without leaving a giant gap. It is also why borders blur, hairlines disappear, and screenshots differ across zoom levels.

## Where fractions come from

Percentages are the obvious source: `width: 33.333%` rarely maps to an integer number of CSS pixels. Flexbox and grid distribute free space and gaps using algorithms that preserve fairness across items. `rem` and `em` values inherit fractional font sizes. Browser zoom changes the mapping between CSS and device pixels. Transforms like `translateX(0.5px)` deliberately position content between pixel boundaries.

Text adds another layer. Font shaping produces glyph positions with fractional advances. The engine may use grayscale antialiasing or platform-specific subpixel antialiasing. That means two strings with the same CSS can look slightly different between macOS, Windows, Linux, and high-DPI screens.

## Layout rounding vs paint snapping

Browsers generally keep fractional layout boxes internally. During paint, edges may be antialiased or snapped depending on primitive type, transform, and device scale. A 1 CSS pixel border on a DPR 2 display maps to 2 device pixels and looks crisp. A 1 CSS pixel border translated by 0.25 CSS pixels maps to half-device-pixel positions and becomes antialiased.

This is why "just round everything" is not a serious solution. Rounding each child independently can accumulate error. If seven columns each compute to `142.857px`, rounding all to `143px` overflows. Layout engines distribute rounding so the total still matches the container.

## Practical patterns

For hairlines, use the device pixel ratio intentionally. A common pattern is to draw a pseudo-element scaled down:

```css
.hairline::after {
  content: "";
  position: absolute;
  inset-inline: 0;
  bottom: 0;
  height: 1px;
  background: currentColor;
  transform: scaleY(0.5);
  transform-origin: bottom;
}
```

This is useful on DPR 2 displays, but test on DPR 1 and fractional zoom. Sometimes a normal border is more robust.

For icons and pixel art, align the asset and viewport. SVG icons should use an even viewBox and stroke widths that land cleanly at common sizes. Pixel art should use `image-rendering: pixelated` and integer CSS scaling.

For layout, prefer letting grid and flex distribute space instead of manual JavaScript rounding. If you must compute sizes, assign the remainder deliberately to one track or use CSS `fr` units.

## Failure modes

Blurry fixed elements often come from transforms. `translateZ(0)` or animated transforms can move text onto a composited layer and change antialiasing. Avoid forcing layers on text-heavy UI unless you measured a benefit.

One-pixel gaps between tiles appear when transformed or percentage-sized items are painted independently. Slight overlap, shared backgrounds, or CSS grid gaps can hide the issue better than trying to micromanage decimals.

Canvas blurriness happens when CSS size and backing store size differ. Set the canvas backing dimensions to CSS size multiplied by DPR, then scale the drawing context.

```js
const dpr = window.devicePixelRatio || 1;
canvas.width = Math.round(cssWidth * dpr);
canvas.height = Math.round(cssHeight * dpr);
ctx.scale(dpr, dpr);
```

## Debugging

Test at multiple zoom levels: 90%, 100%, 110%, and 125%. Test DPR 1 and DPR 2 if possible. Inspect computed layout values in DevTools; they often show decimals even when the box overlay rounds visually.

Use screenshots for visual regression, but allow small antialiasing thresholds. Pixel-perfect assertions across operating systems are brittle unless you control fonts, rendering backend, DPR, and zoom.

For transform blur, temporarily remove transforms and `will-change`. If text sharpens, the issue is compositing or fractional transform placement.

## Implementation patterns

Design components so fractional space is handled by one layout system, not by several competing calculations. A grid should let CSS distribute tracks and gaps. JavaScript should not independently compute each column width unless it also owns the remainder strategy. When JS and CSS both round, the last item in a row often becomes the victim: it wraps, overflows, or leaves a visible seam.

For draggable and animated surfaces, keep the logical value separate from the rendered transform. A slider can store the value as a high-precision number but snap the thumb's displayed position only where it improves clarity. Rounding the state on every pointer move introduces cumulative error; rounding the presentation is reversible.

For canvas and WebGL overlays, recalculate backing size when DPR, zoom, or container size changes. A common production bug is sizing correctly on initial load and then becoming blurry after a window moves between monitors. Use `ResizeObserver` for CSS size changes and listen for resolution changes when your app supports multi-monitor workflows.

## Failure analysis

Thin-line defects are easiest to debug by forcing high contrast. Temporarily set borders to red and backgrounds to white, then test zoom levels. If gaps move as you zoom, the issue is fractional distribution. If gaps follow transform animation, the issue is independent compositing or texture sampling. If gaps appear only in screenshots, the issue may be test environment DPR or font rasterization rather than the product code.

Text blur after animation often persists because the element ends at a fractional transform value. Inspect the computed transform matrix, not just the declared CSS. Layout calculations, spring animation libraries, and percentage translations can produce values like `translate3d(100.5px, 0, 0)`. Snap only the final resting position if continuous movement still needs subpixel smoothness.

## Checklist

- Assume layout values can be fractional.
- Avoid JavaScript rounding unless you own the full distribution algorithm.
- Align canvas backing store to DPR.
- Test thin lines at DPR 1, DPR 2, and browser zoom.
- Be cautious with transforms on text.
- Use visual regression thresholds for antialiasing differences.

Subpixel rendering is not a browser bug. It is the mechanism that lets fluid layouts, high-DPI screens, and shaped text work. The engineering task is to know where fractions matter and where the renderer should be allowed to handle them.
