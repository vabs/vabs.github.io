---
title: "Pointer events"
date: 2026-01-08T09:15:00-05:00
draft: false
tags: [frontend, browser-events, input, accessibility, performance]
---

Pointer Events are the browser's unification layer for mouse, touch, pen, and trackpad-like pointing input. They are not just "mouse events with a different name." They expose a stream model that carries device identity, pressure, contact geometry, capture state, cancellation, and compatibility behavior. If you build draggable surfaces, drawing tools, sliders, resizers, maps, or gesture-heavy components, Pointer Events are usually the right primitive.

The mental model is simple: a pointer is a single active contact. A mouse usually has one persistent pointer. A touchscreen can have many simultaneous pointers. A stylus has one pointer with richer metadata. Your code should track pointer state by `pointerId`, not by global booleans such as `isDragging`.

{{< mermaid >}}
flowchart TD
  A[pointerdown] --> B[Track pointerId]
  B --> C[pointermove stream]
  C --> D{End condition}
  D -->|pointerup| E[Commit gesture]
  D -->|pointercancel| F[Abort gesture]
{{< /mermaid >}}

## Event internals

The core events are `pointerdown`, `pointermove`, `pointerup`, `pointercancel`, `pointerenter`, `pointerleave`, `pointerover`, and `pointerout`. Like mouse events, some bubble and some do not. Unlike mouse events, each event includes `pointerId`, `pointerType`, `isPrimary`, `pressure`, `width`, `height`, and sometimes tilt/twist fields.

`pointercancel` matters. It fires when the browser takes over the interaction, the device disappears, orientation changes, palm rejection kicks in, or touch scrolling wins. Treat cancellation as a rollback path. Do not submit, reorder, or save a gesture from `pointercancel`.

Compatibility mouse events are another internal detail. Browsers often synthesize `mousedown`, `mousemove`, `mouseup`, and `click` after pointer events for old code. Calling `preventDefault()` on `pointerdown` can suppress some compatibility events, but the exact interaction depends on passive listeners, target type, and browser behavior. Prefer making one input path authoritative instead of wiring both pointer and mouse handlers to the same mutation.

## Practical pattern

For drag-like interactions, use pointer capture. When an element receives `pointerdown`, call `event.currentTarget.setPointerCapture(event.pointerId)`. Future pointer events for that pointer are retargeted to the element until release, even if the pointer leaves its bounds. This avoids document-level listeners and fixes the classic bug where fast movement drops a drag outside the handle.

```js
const active = new Map();

handle.addEventListener("pointerdown", (event) => {
  if (event.button !== 0) return;
  handle.setPointerCapture(event.pointerId);
  active.set(event.pointerId, {
    startX: event.clientX,
    startY: event.clientY,
    lastX: event.clientX,
    lastY: event.clientY
  });
});

handle.addEventListener("pointermove", (event) => {
  const state = active.get(event.pointerId);
  if (!state) return;
  state.lastX = event.clientX;
  state.lastY = event.clientY;
  updatePreview(state);
});

handle.addEventListener("pointerup", (event) => {
  const state = active.get(event.pointerId);
  if (!state) return;
  active.delete(event.pointerId);
  commitDrag(state);
});

handle.addEventListener("pointercancel", (event) => {
  active.delete(event.pointerId);
  resetPreview();
});
```

For high-frequency drawing, use `getCoalescedEvents()` inside `pointermove`. The browser may combine multiple hardware samples into one dispatched event. Coalesced events let you draw smoother strokes without increasing main-thread dispatch overhead. For predicted stylus movement, some browsers expose `getPredictedEvents()`, but use predictions only for previews that can be corrected by later real samples.

## CSS controls the stream

`touch-action` is the most important CSS property for Pointer Events. It tells the browser which gestures it may handle natively. Without it, touch input may be delayed, cancelled, or diverted into scrolling/zooming. Use the narrowest value that matches the component:

```css
.drawing-canvas { touch-action: none; }
.horizontal-slider { touch-action: pan-y; }
.map { touch-action: none; }
```

Do not default every interactive surface to `touch-action: none`. That blocks expected page scrolling and zooming. For a horizontal carousel, `pan-y` usually gives the browser vertical scrolling while your component handles horizontal dragging.

## Failure modes

The most common bug is storing one global drag state. Multi-touch then corrupts state because the second contact overwrites the first. Store per-pointer state keyed by `pointerId`.

The second bug is ignoring `lostpointercapture`. Capture can be lost if the element is removed, the browser cancels the stream, or another element captures the pointer. Use `lostpointercapture` as cleanup insurance.

The third bug is reading layout on every move and then writing style. That creates forced reflow under a high-frequency input stream. Cache geometry on `pointerdown`, update transforms during movement, and batch DOM writes with `requestAnimationFrame`.

Accessibility is also easy to miss. Pointer support does not replace keyboard support. A slider, splitter, or drag handle needs focus behavior, ARIA semantics where applicable, and keyboard equivalents for users who cannot operate pointer gestures precisely.

## Gesture architecture

Split gesture handling into recognition, preview, and commit. Recognition decides whether a pointer stream has become a drag, resize, draw, or tap. Preview updates the visual state during movement. Commit performs the durable mutation on `pointerup`. This separation prevents accidental saves during cancelled gestures and makes it easier to support keyboard paths that call the same commit logic.

Use thresholds deliberately. A pointer that moves two pixels during a tap should not start a drag. Store the down position, compare squared distance to a small threshold, and only begin the gesture once intent is clear. For touch, thresholds may need to be larger than for mouse because contact geometry is less precise.

For multi-pointer gestures, track each pointer independently and then derive the gesture from the active set. Pinch zoom, rotation, and two-finger pan should not be built on a single `lastX` variable. Also decide what happens when a third pointer appears or one pointer cancels. The simplest reliable rule is often to cancel the current compound gesture and let the user start again.

## Performance details

Pointer streams can arrive faster than the display refresh rate. Do not perform expensive DOM work for every event. Store the latest event state and schedule one visual update with `requestAnimationFrame`. For drawing, process coalesced samples into an offscreen buffer or canvas path, then present once per frame.

Avoid synchronous hit testing during every move. If a drag needs drop targets, compute target rectangles at gesture start and invalidate them only when layout changes. For large boards, spatial indexes or row/column math are better than calling `elementFromPoint` and layout reads on every move.

## Diagnostics

Log `event.type`, `pointerId`, `pointerType`, `buttons`, `isPrimary`, and capture status when debugging. Chrome DevTools can emulate touch, but real devices reveal palm rejection, pressure, and cancellation behavior that desktop emulation misses. When a drag stops mysteriously, search for missing `touch-action`, lost capture, element removal, or a passive listener that prevents your cancellation strategy from working.

Checklist:

- Track state by `pointerId`.
- Use pointer capture for drags and resizes.
- Implement `pointercancel` and `lostpointercapture`.
- Set `touch-action` deliberately.
- Keep move handlers layout-read-light and write-batched.
- Provide keyboard and semantic alternatives for pointer-only controls.
