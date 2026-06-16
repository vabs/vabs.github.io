---
title: "OffscreenCanvas"
date: 2026-01-18T09:00:00-04:00
draft: false
tags: [frontend, canvas, workers, rendering, performance]
---

`OffscreenCanvas` moves canvas rendering away from the main thread. That matters when canvas work competes with input handling, layout, style recalculation, framework updates, and accessibility tree changes. The goal is not automatically higher frame rates; the goal is isolating expensive drawing so the main thread can stay responsive. A canvas can still be slow in a Worker, but its slowness no longer blocks a text input or a route transition as directly.

The mental model is a split renderer. The DOM still owns the visible `<canvas>` element, but drawing commands can run in a Worker after the main thread transfers control. The Worker receives data, updates render state, and paints frames without blocking pointer events or React reconciliation.

{{< mermaid >}}
sequenceDiagram
  participant Main
  participant Worker
  participant Canvas
  Main->>Canvas: transferControlToOffscreen()
  Main->>Worker: postMessage({ canvas }, [canvas])
  Main->>Worker: input/state messages
  loop animation
    Worker->>Worker: simulate/update scene
    Worker->>Canvas: draw via 2d/webgl context
  end
{{< /mermaid >}}

## Internals that matter

An `OffscreenCanvas` can be created directly with `new OffscreenCanvas(width, height)` or obtained from a DOM canvas with `transferControlToOffscreen()`. Once transferred, the main thread cannot draw into that canvas. The object becomes a transferable resource owned by the Worker.

The rendering context can be `2d`, `webgl`, or `webgl2` depending on browser support. For a transferred visible canvas, the Worker drawing updates the presentation surface. For a standalone `OffscreenCanvas`, you can render to an image bitmap and send that to the main thread.

Sizing is still your responsibility. CSS size and backing-store size are different. The main thread knows layout dimensions; the Worker does not observe CSS automatically. Send resize messages containing CSS pixels and `devicePixelRatio`, then set `canvas.width` and `canvas.height` in backing pixels.

The transfer is one-way for the drawing surface. The DOM element remains in the document for layout, focus, accessibility labeling, and sizing, but rendering commands must go through the transferred canvas. That means lifecycle ownership has to be explicit: initialize once, resize many times, dispose once.

Workers communicate by message passing. Small objects are cloned, while transferable objects move ownership. For large binary data, prefer `ArrayBuffer` transfer or `SharedArrayBuffer` when the deployment can satisfy the required cross-origin isolation headers. Sending a huge JavaScript object every frame can erase the benefit of worker rendering through serialization cost.

Context loss still exists. WebGL contexts can be lost, resources can need recreation, and a Worker can throw. Build the renderer so it can rebuild GPU resources from retained scene state rather than assuming initialization happens exactly once.

## Practical patterns

Use a small protocol between main and Worker. Avoid sending high-level UI objects. Send messages like `resize`, `pointer`, `setData`, and `dispose`. Keep a monotonically increasing version on data updates so late messages can be ignored.

```js
const canvas = document.querySelector("canvas");
const worker = new Worker(new URL("./renderer.worker.js", import.meta.url), {
  type: "module",
});

const offscreen = canvas.transferControlToOffscreen();
worker.postMessage({ type: "init", canvas: offscreen }, [offscreen]);
```

Inside the Worker, run the animation loop with `requestAnimationFrame` where available in workers, or fall back to a timed loop if the target browser requires it. Keep simulation and drawing separate so diagnostics can time them independently.

For charts and maps, push normalized render data into the Worker and let it own viewport transforms, hit testing, and cached paths. For games or visualizations, keep authoritative UI state on the main thread only when it must coordinate with DOM controls.

A resize handler should coalesce layout changes:

```js
const observer = new ResizeObserver(([entry]) => {
  const { width, height } = entry.contentRect;
  worker.postMessage({
    type: "resize",
    width,
    height,
    dpr: window.devicePixelRatio,
  });
});
observer.observe(canvas);
```

In the Worker:

```js
function resize({ width, height, dpr }) {
  canvas.width = Math.max(1, Math.round(width * dpr));
  canvas.height = Math.max(1, Math.round(height * dpr));
  state.cssWidth = width;
  state.cssHeight = height;
  state.dpr = dpr;
}
```

For high-frequency pointer input, send the latest position and let the Worker consume it once per frame. If you need full stroke fidelity for drawing apps, batch events into compact numeric arrays instead of posting one object per event. Keep timestamps so smoothing and prediction can run in render time.

Accessibility remains on the main thread. A canvas visualization still needs DOM labels, fallback text, keyboard controls, and sometimes an alternate table or summary. Offloading pixels does not offload semantics.

For server-rendered apps, delay transfer until the client component is mounted and the canvas element exists. If a framework may remount the canvas, ensure the old Worker is terminated and the new canvas is transferred only once.

## Failure modes and diagnostics

The first failure mode is unsupported APIs. Feature-detect `HTMLCanvasElement.prototype.transferControlToOffscreen` and provide a main-thread renderer fallback. Do not assume all mobile browsers behave the same.

The second is message pressure. If the main thread posts a pointer event for every movement and the Worker cannot keep up, latency grows. Coalesce events: keep only the latest pointer position or batch samples per frame.

The third is blurry output after resize. Log CSS size, backing size, and DPR. A canvas that is 600 CSS pixels wide on a DPR 2 display should usually have a width of 1200 backing pixels.

For debugging, add counters for message queue rate, draw time, simulation time, and dropped frames. Use Chrome Performance traces to confirm the main thread is actually quieter. If the main thread still janks, the bottleneck is probably layout, JavaScript work outside canvas, or oversized message serialization.

Another failure is hidden synchronization. If the Worker waits for a main-thread response every frame, the design is no longer off-thread in practice. Avoid request-response loops for layout, theme, or data that can be pushed ahead of time. Send snapshots, not questions.

Memory pressure is easy to miss. Large canvases at high DPR create large backing stores. A 1600 by 900 CSS pixel canvas at DPR 3 is 4800 by 2700 backing pixels, before intermediate textures or buffers. On integrated GPUs and mobile devices, this can cause dropped frames or context loss. Cap DPR for complex scenes when visual quality allows it.

Bundler configuration can fail too. Worker modules often need `new URL("./worker.js", import.meta.url)` or framework-specific syntax. Verify the production build emits the Worker as a separate asset and serves it with the right headers.

Use a debug overlay rendered by the Worker with frame time, update time, draw time, data version, canvas size, and DPR. Pair it with main-thread marks around input handling. If input events arrive promptly but visual response lags, inspect Worker load. If input itself is delayed, OffscreenCanvas is not addressing the dominant bottleneck.

When a bug appears only after tab backgrounding, check timing assumptions. Worker timers can be throttled. On visibility change, pause simulation or compute elapsed time carefully so the scene does not jump after resume.

## Checklist

- Transfer control once, during initialization.
- Send layout size and DPR explicitly.
- Keep the Worker protocol small and versioned.
- Coalesce high-frequency input messages.
- Provide a main-thread fallback.
- Measure responsiveness, not only frames per second.
- Avoid per-frame round trips back to the main thread.
- Cap backing resolution for large or complex scenes.
- Terminate Workers on component teardown.
- Keep accessibility and keyboard semantics in DOM.
