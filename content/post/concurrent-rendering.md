---
title: "Concurrent rendering"
date: 2026-02-19T11:30:00-05:00
draft: false
tags: [frontend, react, concurrent-rendering, scheduling, ui-state]
---

## Mental model: multiple possible futures

Concurrent rendering lets React prepare a future UI without immediately committing it. The current screen remains visible while React works on another version of the tree. If a more important update arrives, React can pause or abandon the older work and prepare a better future.

This is a rendering model, not a data-race model with multiple JavaScript threads. Your component code still runs on the main thread. The concurrency is about scheduling, interruption, prioritization, and choosing which completed tree becomes visible.

{{< mermaid >}}
flowchart TD
    Current[Committed UI] --> UpdateA[Transition update starts]
    UpdateA --> WIP1[Work-in-progress tree A]
    Input[Urgent input update] --> WIP2[Work-in-progress tree B]
    WIP1 -. paused or discarded .-> Drop[No visible change]
    WIP2 --> Commit[Commit latest consistent tree]
    Commit --> Current2[New committed UI]
{{< /mermaid >}}

## Internals

Concurrent rendering relies on the split between render and commit. During render, React calls components and builds a work-in-progress fiber tree. That work may be interrupted. During commit, React applies the chosen result synchronously so the user never sees a half-finished tree.

Lanes track priority and update grouping. Urgent updates such as controlled input changes should complete quickly. Transition updates can wait while urgent work is handled. Suspense boundaries can keep old content visible while new content prepares, then reveal when ready.

The renderer maintains consistency for the committed React tree. It will not commit a parent from one render and a child from an unrelated render. But code that reads external mutable sources can break that model unless it uses a subscription API that provides consistent snapshots.

Strict Mode in development intentionally stresses concurrent assumptions. It may double-invoke render paths and effects to expose impure rendering, missing cleanup, and assumptions that a render always commits.

## Practical patterns

Separate urgent and non-urgent state. For search, update the input value immediately, then use a transition for filtered results. For navigation, show the selected tab or route affordance quickly while data-heavy content resolves behind Suspense.

Make render pure. Do not write to globals, mutate caches, start subscriptions, or send analytics during render. Render may be restarted or thrown away. Effects and event handlers are the correct places for imperative work, with cleanup for anything persistent.

Use `useSyncExternalStore` or framework-provided adapters for external stores. Directly reading a mutable singleton during render can produce tearing when a store changes between interrupted renders.

Design loading states around continuity. Concurrent rendering is most valuable when users can keep seeing and using the current screen while a future screen loads. Use pending indicators, disabled affordances only where necessary, and boundary-level fallbacks that preserve orientation.

Model navigations as state transitions, not page erasures. When moving from one filtered view to another, keep the old committed content visible if it remains truthful enough, then mark the new view as pending. This is especially useful for dashboards and search pages where blanking the content destroys context.

Keep reducers deterministic and cheap. Reducers can run as part of update processing, and expensive reducers make urgent work harder to complete. If a reducer needs to derive a large projection, store the minimal state change and derive the projection with memoization or a worker-backed cache.

## Failure modes

Impure render is the most dangerous failure. If render increments a metric, writes to a cache, or consumes a generator, interrupted work changes the world even though it never commits. The symptom is duplicate events, missing data, or state that changes without visible UI.

Async race conditions remain your responsibility. A slow response for an old query can arrive after a fast response for a new query. Concurrent rendering does not cancel your fetch unless the framework or your code wires cancellation. Use abort signals, request IDs, or cache keys that ignore stale responses.

Tearing appears when different parts of the UI observe different versions of external state. It often shows up as a header count disagreeing with a list. The fix is not "turn off concurrency"; the fix is a consistent snapshot subscription.

Overusing transitions can make the UI feel laggy. If an update directly reflects a user's action, such as typing in an input or opening a menu, do not demote it. Demote expensive derived views, not the user's immediate feedback.

Another trap is assuming effects from abandoned renders ran. Effects run after commit, so any setup required for correctness must be tied to committed state. If you need to start work from an event, start it in the event handler or a committed effect, not during speculative rendering.

## Debugging and diagnostics

Reproduce with CPU throttling and artificial network delay. Concurrent issues are timing-sensitive, so fast local machines often hide them. Watch whether input remains responsive and whether pending UI communicates that work is happening.

Use the React DevTools Profiler (including its Timeline view) to see which updates are urgent or transition work. If a small input update renders a whole page, move state down or split providers. If a transition never settles, look for constantly changing dependencies.

Add cleanup assertions to effects. In development, confirm subscriptions are unsubscribed, timers are cleared, and async results are ignored after unmount or key changes.

## State placement

Concurrent rendering rewards narrow state ownership. If a keystroke updates a provider at the top of the app, React may need to consider a huge subtree before the input feels settled. Move transient state closer to the control that owns it, and pass derived results outward only when necessary. This is ordinary component design, but concurrent scheduling makes the cost of broad invalidation more visible.

Context needs the same discipline. A single context object containing user, theme, feature flags, draft form state, and notifications will invalidate consumers that only need one field. Split contexts by update frequency and consumption pattern. Stable structural sharing inside context values helps, but consumers still rerender when the provider value reference changes.

## Testing concurrent assumptions

Good tests do not assert every intermediate render. They assert committed behavior: the input stays responsive, stale results do not overwrite current results, cleanup runs, and pending indicators appear when non-urgent work is delayed. Avoid tests that depend on a specific number of renders; those become brittle as scheduling changes.

Use controlled promises to simulate out-of-order completion. Start request A, start request B, resolve B, then resolve A. The final UI should still represent B. This test catches the async races that concurrent rendering makes easier to notice but does not solve automatically.

## Checklist

- Keep render pure and restartable.
- Split urgent feedback from expensive derived updates.
- Use transitions for non-urgent rendering work.
- Pair async work with cancellation or stale-response guards.
- Use safe external-store subscriptions.
- Test with throttled CPU and delayed network.
- Treat Strict Mode warnings as concurrency preparation, not noise.
