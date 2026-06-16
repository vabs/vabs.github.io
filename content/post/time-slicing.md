---
title: "Time slicing"
date: 2026-02-05T13:40:00-05:00
draft: false
tags: [frontend, react, time-slicing, scheduling, performance]
---

## Mental model: share the main thread with the user

Time slicing is the renderer's ability to split render work into smaller chunks so the browser can handle input, paint, and higher-priority tasks between chunks. It does not make JavaScript run in parallel. It makes long rendering work cooperative instead of monopolizing the main thread.

The main thread has many customers: event handlers, style recalculation, layout, painting, timers, network callbacks, and framework rendering. A render that takes 80 milliseconds blocks all of them. Time slicing aims to turn that into several smaller units so a click, keypress, or animation frame can be serviced before the user perceives the page as frozen.

{{< mermaid >}}
sequenceDiagram
    participant B as Browser
    participant R as Renderer
    participant U as User input
    R->>R: render chunk
    R-->>B: yield
    U->>B: keypress
    B->>R: urgent update
    R->>R: render urgent work
    R-->>B: yield for paint
    R->>R: resume lower-priority work
{{< /mermaid >}}

## Internals

Time slicing depends on work being represented as resumable units. React Fiber provides those units. The scheduler can perform work on a fiber, check whether the current time budget is exhausted, then yield back to the host. Later it resumes from the next fiber.

Priority is what makes yielding useful. If all work had the same importance, React would simply continue where it left off. With lanes, an urgent input update can interrupt a transition render. The old in-progress render may be paused, continued, or discarded if a newer render supersedes it.

Rendering can be interruptible because it is not supposed to mutate the visible host environment. Commit remains synchronous. Time slicing can reduce long render tasks, but it cannot split a large DOM mutation commit or a layout effect that runs for 50 milliseconds.

The browser event loop is still the outer constraint. React schedules tasks using host mechanisms and checks deadlines, but synchronous JavaScript you write inside render, reducers, effects, and event handlers still blocks until it returns.

## Practical patterns

Use transitions for non-urgent visual updates. Typing into a search box should update the input immediately; recalculating and rendering a large result list can be marked as transition work. This tells the renderer that maintaining direct input feedback matters more than completing the list update immediately.

Virtualize large lists. Time slicing can make rendering interruptible, but rendering 20,000 rows is still wasteful. Virtualization reduces the amount of work so scheduling has less to rescue.

Break expensive calculations away from render. Use memoization for deterministic derived data, move heavy CPU work to a Web Worker, or precompute on the server. Time slicing helps component traversal; it does not make a single blocking sort or parser interruptible unless you split that work yourself.

Prefer progressive disclosure for heavy panels. Tabs, accordions, routes, and Suspense boundaries can keep non-visible work out of the urgent path. Scheduling works best when the application exposes what matters now.

Chunk your own non-render work when it cannot move to a worker. A huge client-side migration, syntax highlighter, or export builder can process batches and yield between them with scheduler APIs, `setTimeout`, or `requestIdleCallback` depending on urgency. The important part is to create interruption points; the browser cannot preempt one long JavaScript function.

Design transitions with user-visible pending states. A deferred result list should not silently lag behind the input. Show a subtle pending affordance, preserve the previous results if that is less disruptive, and avoid disabling the text field just because lower-priority rendering is still in progress.

## Failure modes

The first failure is expecting time slicing to fix synchronous event handlers. If a click handler parses a giant JSON blob, the browser cannot process anything else until that handler returns. Move that work out of the handler or chunk it explicitly.

The second is hiding commit cost. A render may be sliced nicely, then commit a huge DOM update that blocks the frame. If the profiler shows a short render but long commit, focus on DOM count, layout effects, CSS containment, and third-party imperative code.

The third is starvation by continuous urgent updates. If the user keeps typing and every keypress schedules urgent work across a large subtree, lower-priority work may be repeatedly restarted. Keep urgent state local and debounce network or list updates where product behavior allows.

Visual tearing can happen outside React's managed consistency if external stores are read unsafely. Use subscription APIs designed for concurrent rendering so a render observes a consistent snapshot.

Memory pressure is an overlooked failure mode. If every interrupted render allocates large derived arrays or component-local objects, repeated cancellation can create garbage collection churn. Memoize expensive derived structures at the right boundary, and avoid building large temporary data in components that may render during every keystroke.

## Debugging and diagnostics

Use Chrome Performance to look for long tasks over 50 milliseconds. Then correlate them with React Profiler commits. If the long task is render-heavy, inspect component cost and invalidation breadth. If it is commit-heavy, inspect DOM mutation and layout effects.

Test with CPU throttling. Time slicing issues often hide on fast machines. A mid-tier mobile profile will reveal whether input stays responsive while expensive updates are pending.

Instrument transition duration and cancellation. If a transition repeatedly starts but rarely finishes, the lower-priority work may be too broad or constantly invalidated by urgent state.

## Checklist

- Mark non-urgent UI updates as transitions.
- Keep direct input state local and urgent.
- Virtualize large collections.
- Move large CPU tasks out of render or into workers.
- Profile render and commit separately.
- Test responsiveness under CPU throttling.
- Remember that commit and synchronous handlers are not time-sliced.
