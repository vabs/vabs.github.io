---
title: "Event loop (macro vs microtasks)"
date: 2026-02-24T09:30:00-05:00
draft: false
tags: [frontend, javascript, event-loop, microtasks, scheduling]
---

The distinction between macrotasks and microtasks explains many frontend timing bugs. A task, often called a macrotask, is work such as a timer callback, input event, network callback, or script execution. A microtask is work scheduled to run immediately after the current JavaScript stack finishes and before the browser moves on to rendering or the next task. Promise callbacks, `queueMicrotask`, and mutation observer callbacks use this queue.

{{< mermaid >}}
flowchart TD
  A[Pick next task] --> B[Run JS stack]
  B --> C[Drain all microtasks]
  C --> D{Microtasks added?}
  D -->|yes| C
  D -->|no| E[Render opportunity]
  E --> A
{{< /mermaid >}}

## Mental model

Tasks are turns. Microtasks are cleanup at the end of the current turn. The browser drains the microtask queue completely before it considers painting or handling another task. That makes microtasks useful for preserving invariants: finish a state flush, notify subscribers, or resolve promise continuations before external events observe a half-updated state.

The tradeoff is starvation. A chain of microtasks can delay rendering just like synchronous code because the browser cannot paint until the queue is empty.

## Ordering examples

This code logs in an order that surprises people only once:

```js
console.log("script");

setTimeout(() => console.log("timeout"), 0);

Promise.resolve().then(() => console.log("promise"));

queueMicrotask(() => console.log("microtask"));

console.log("end");
```

The output is `script`, `end`, `promise`, `microtask`, `timeout`. The initial script is the current task. Promise and `queueMicrotask` callbacks run after the stack clears. The timer runs in a later task.

## Practical patterns

Use microtasks when you need to batch synchronous changes before any external task observes them. A store can queue one notification after many writes:

```js
let queued = false;
const listeners = new Set();

function notifySoon() {
  if (queued) return;
  queued = true;
  queueMicrotask(() => {
    queued = false;
    listeners.forEach((listener) => listener());
  });
}
```

Use tasks when you want to yield to rendering or input. `setTimeout(0)` is not precise, but it does let the current turn finish and gives the browser more room than another microtask. Use `requestAnimationFrame` for DOM writes that should happen before paint, and use idle callbacks for optional work that can wait.

## Failure modes

The most common bug is assuming `await` always yields to the browser. If the awaited value is already resolved, the continuation is a microtask. A loop that repeatedly awaits resolved promises can still block paint:

```js
for (const item of items) {
  await Promise.resolve();
  process(item);
}
```

This yields to other microtasks, not to a frame. For visible responsiveness, occasionally yield to a task or frame.

Another failure is mixing timer and promise ordering in tests. Test code that advances timers without flushing promises can assert before microtask-driven state updates complete. Robust tests explicitly flush the right queue for the abstraction under test.

## Framework implications

Frameworks use microtasks for batching because it keeps state consistent within one browser turn. That is usually good. But if your update triggers heavy computation, the batch can become a long task. The framework's scheduler may defer rendering, but your synchronous reducer, selector, or derived-data function still runs on the main thread unless you move or split it.

Event handlers are tasks. State updates inside them may flush in microtasks. Effects may run later depending on the framework. Avoid relying on incidental ordering across framework versions; use documented lifecycle boundaries.

## Diagnostics

In DevTools traces, promise callbacks appear as dense async continuation work inside a task. If paint is delayed, inspect whether the task is followed by a large microtask drain. Add marks before and after scheduled work to make ordering visible:

```js
performance.mark("before-schedule");
queueMicrotask(() => performance.mark("inside-microtask"));
setTimeout(() => performance.mark("inside-task"), 0);
```

## Implementation details

Pick scheduling primitives by the boundary you need. Use `queueMicrotask` when callers should observe a completed synchronous update before the next event. Use `requestAnimationFrame` when the work prepares visual state for the next frame. Use a task boundary when you want input and rendering to have a chance before continuing. Use idle time only for work that can be delayed indefinitely without breaking the user flow.

Testing should mirror those boundaries. A helper named `flushPromises` should not be expected to run timers. A fake timer advance should not be expected to flush framework microtasks unless the test runner documents that behavior. Many flaky UI tests come from asserting after the wrong queue has advanced.

Error handling also differs. Exceptions in promise microtasks become promise rejections. Exceptions in timer tasks are reported as task errors. A scheduling abstraction should preserve error visibility, or bugs can disappear into unhandled rejection handling that behaves differently across environments.

Finally, remember that browser rendering is not guaranteed after every task. The browser may skip a frame if nothing visual changed or if the tab is hidden. The event loop model gives ordering constraints, not a promise that every yield paints.

## Choosing a yield

For CPU-heavy loops, choose the yield based on what must happen next. If the user should see progress, yield to `requestAnimationFrame` and update visible state before continuing. If input should be processed, yield to a task boundary. If only promise continuations need to run, a microtask is enough. These are different contracts, even though all can appear as "async" code in review.

One useful pattern is a scheduler helper with names that encode intent:

```js
const nextTask = () => new Promise((resolve) => setTimeout(resolve, 0));
const nextFrame = () => new Promise((resolve) => requestAnimationFrame(resolve));
```

Calling `await nextFrame()` communicates a visual boundary better than `await new Promise(...)` scattered through code. It also gives you one place to change behavior in tests or older environments.

## Production edge cases

Background tabs change timing. Timers can be clamped, animation frames may pause, and idle callbacks may run rarely. Do not rely on a background tab making steady progress through a queue. On visibility changes, check whether queued work is still relevant before resuming.

Node.js and browser runtimes also differ in event-loop details. If shared code uses `process.nextTick`, promises, timers, or stream callbacks, test ordering in the runtime where it actually runs. A server-side rendering bug caused by Node task ordering may not reproduce in a browser demo.

## Checklist

- Use microtasks for invariant-preserving cleanup.
- Use tasks or animation frames to give rendering a chance.
- Do not treat `await` as a guaranteed paint boundary.
- Flush promises and timers deliberately in tests.
- Watch for recursive microtask scheduling.
- Profile ordering bugs with marks and traces.

The event loop is not just trivia. It is the contract that decides when users can see, click, type, and observe your application state.
