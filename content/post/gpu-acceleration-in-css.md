---
title: "GPU acceleration in CSS"
date: 2026-04-16T15:25:00-04:00
draft: false
tags: [frontend, css, gpu, animation, performance]
---

## The GPU is not a magic fast path

"Use GPU acceleration" usually means "make the browser animate by compositing existing layers instead of repainting pixels on the CPU." The GPU is good at moving textured rectangles, blending opacity, and applying transforms. It is not a general cure for expensive layout, slow JavaScript, huge paints, or memory pressure.

{{< mermaid >}}
flowchart LR
  DOM["DOM/CSS changes"] --> Layout["layout"]
  Layout --> Paint["paint display lists"]
  Paint --> Raster["raster tiles"]
  Raster --> Layers["GPU textures/layers"]
  Layers --> Composite["transform/opacity compositing"]
  Composite --> Screen["screen"]
{{< /mermaid >}}

The key distinction: animating `transform` or `opacity` can often skip layout and paint after the layer has been rasterized. Animating `width`, `top`, `box-shadow`, `filter`, or `background-position` may require layout or paint every frame.

The browser pipeline matters because "GPU" enters late. DOM and CSS changes can trigger style calculation, layout, paint, raster, and finally compositing. Compositor-friendly animations work by keeping earlier stages stable. If JavaScript changes layout on every frame, the GPU cannot rescue the frame budget.

## Layer promotion

Browsers decide which elements become composited layers. Reasons include transforms, opacity animations, video, canvas, position-fixed elements, 3D context, and `will-change`. A promoted layer is rasterized into a texture and then composited by the GPU.

You can hint:

```css
.drawer {
  will-change: transform;
}
```

But `will-change` is a reservation request. It can allocate memory and change rendering behavior before the animation starts. Keep it scoped and remove it after the interaction if the element is not frequently animated.

```js
drawer.addEventListener("mouseenter", () => {
  drawer.style.willChange = "transform";
});
drawer.addEventListener("transitionend", () => {
  drawer.style.willChange = "";
});
```

Layer promotion has costs. The browser must raster the layer into tiles, upload those textures, track damage, and composite them. A single drawer or modal is usually fine. Hundreds of promoted list items can increase memory and tile management enough to make scrolling worse.

Promotion is also heuristic. Browsers can promote, merge, split, or demote layers based on device, memory, and implementation details. Treat `will-change` as a hint to the browser, not a guarantee that a specific GPU path will happen.

## Good acceleration candidates

Use transforms for movement:

```css
.panel {
  transform: translateX(var(--offset));
  transition: transform 180ms ease;
}
```

Use opacity for fades. Combine transform and opacity for entrances. Keep the element's layout slot stable so surrounding content does not need recalculation.

For large scrollable surfaces, prefer compositor-friendly scrolling and avoid scroll handlers that mutate layout on every frame. For parallax, use CSS where possible and test on low-end devices.

Use transform-based patterns:

```css
.toast {
  transform: translateY(12px);
  opacity: 0;
  transition:
    transform 160ms ease,
    opacity 160ms ease;
}

.toast[data-open="true"] {
  transform: translateY(0);
  opacity: 1;
}
```

For collapsible layout, transforms are not always enough because surrounding content may need to move. In those cases, separate the interaction into a cheap animated affordance and a less frequent layout update, or accept the layout cost if the element is small and the interaction is rare. Performance rules serve the product, not the other way around.

Containment can help adjacent work. `contain: layout paint;` or `content-visibility` can limit how much of the page is affected by changes, but they are not GPU switches. Use them to reduce invalidation scope, then use transforms and opacity for motion when appropriate.

For scroll-linked effects, prefer platform features where available. JavaScript scroll handlers that read layout and write styles in one loop can force layout thrashing. If you must use JavaScript, batch reads before writes and update only compositor-friendly properties.

## Failure modes

Layer explosion is the classic GPU acceleration bug. Promoting hundreds of cards creates hundreds of textures. Memory usage rises, raster work increases, and the browser may spend more time managing layers than it saves.

Blurry text can appear when text is rendered into a texture and transformed at fractional positions or scales. Avoid long-lived transformed layers for text-heavy content. Animate a wrapper when possible and finish at whole-pixel positions.

Expensive filters are often misunderstood. `filter: blur(30px)` may run on the GPU in some cases, but it still processes many pixels. Large blurred backdrops, translucent overlays, and backdrop filters can be costly even if composited.

`translateZ(0)` as a blanket hack is outdated. It can force promotion, but it also changes stacking, antialiasing, and memory behavior. Use explicit `will-change` only around measured animations.

Another failure is animating a property that looks visual-only but triggers paint. Large `box-shadow`, `filter`, `backdrop-filter`, gradients, masks, and clipped backgrounds can repaint expensive areas. Even when accelerated, the number of pixels matters. A full-screen blurred backdrop can be costly because every frame processes a large texture.

Texture upload can cause stutter. If an element changes paint content while also being transformed, the browser may need to repaint and upload new tiles before compositing. This is common in animated carousels with images loading during movement. Preload images and avoid changing heavy paint content mid-animation.

Stacking context changes can break UI. Transform and opacity can create new stacking contexts, affecting `z-index`, fixed-position descendants, and blending. A performance hint should not accidentally change overlay ordering or tooltip positioning.

Battery and thermals matter on mobile. A 60 fps animation that keeps the GPU busy for a decorative background may look fine in a short trace and still drain battery or throttle after sustained use. Animate with purpose and stop when offscreen.

## Debugging

In Chrome DevTools, use Layers and Performance. Look for "Composite Layers" versus "Paint" and "Layout" work during the animation. A smooth compositor animation should show minimal layout and paint after startup. Use paint flashing to see whether the element repaints every frame.

Record on a throttled CPU and a real mobile device when possible. Desktop GPUs hide problems that mid-range phones expose quickly. Watch memory as well as frame rate; dropped frames can come from tile uploads or texture eviction.

If an animation stutters, ask:

- Is JavaScript blocking the main thread?
- Is layout running every frame?
- Is paint running every frame?
- Are too many layers being rasterized or uploaded?
- Is the animated area enormous?

Add a simple experiment before rewriting. Change the animation to `opacity` only. If it still stutters, the problem is probably main-thread work, layer count, or raster/upload pressure rather than layout. Then pause JavaScript with a performance profile; if frames smooth out, find the long tasks.

Use DevTools Rendering options:

- Paint flashing shows repaint areas.
- Layer borders reveal composited layer boundaries.
- FPS meter shows frame drops.
- Performance recordings show layout, paint, raster, and composite tasks.

Check the final visual state. Fractional transforms can leave text soft, and scaling from `0.98` to `1` can produce subtle blur if the element remains transformed. Clear transforms after transitions when the resting state does not need its own layer.

For lists, test worst-case counts. Ten promoted cards may be fine; two hundred may not. Virtualization, grouping, or animating only the active item is often better than promoting every repeated element.

## Practical checklist

- Animate `transform` and `opacity` when the visual design allows it.
- Avoid animating layout properties for high-frequency motion.
- Use `will-change` sparingly and remove it when idle.
- Do not promote every repeated item in a list.
- Test text sharpness after transform animations.
- Inspect real frame traces; do not rely on property folklore.
- Watch texture memory and tile uploads on mobile.
- Avoid large animated filters and blurred backdrops without measurement.
- Check stacking context and fixed-position side effects.
- Stop or simplify offscreen and decorative animations.

GPU acceleration in CSS is really compositing strategy. Use it to move already-painted pixels cheaply, and keep the number and size of those pixels under control.
