---
title: "Fiber architecture"
date: 2026-01-08T09:20:00-05:00
draft: false
tags: [frontend, react, fiber, rendering, scheduling]
---

## Mental model: rendering as interruptible work

Fiber is React's internal representation of a component tree and the unit of work used by the renderer. The old stack reconciler behaved like a recursive function call: once rendering started, it ran until the call stack unwound. Fiber turns that stack into a linked data structure that React can pause, resume, discard, and prioritize.

Think of a fiber node as a work record for one component or host element. It stores the component type, props, state, pending updates, child and sibling links, effects, lanes, and a pointer to the previous committed version. Rendering is not simply "call all components"; it is building a work-in-progress tree that can later be committed if it still represents the best answer.

{{< mermaid >}}
flowchart TD
    Root[Root fiber] --> A[App fiber]
    A --> B[Header fiber]
    A --> C[List fiber]
    C --> D[Row fiber]
    Current[Current tree] -. alternate .- WIP[Work-in-progress tree]
    Updates[Update queues and lanes] --> WIP
    WIP --> Commit[Commit effects to host tree]
{{< /mermaid >}}

## Internals

Every mounted element has a current fiber. During an update, React creates or reuses an alternate fiber as the work-in-progress copy. The current tree represents what the user sees. The work-in-progress tree represents a possible future. This double-buffering is the reason React can abandon partial work without corrupting the visible UI.

Traversal is explicit. A fiber points to `child`, `sibling`, and `return`, which lets React walk the tree without relying on the JavaScript call stack. The render phase begins at the root, performs work for a fiber, moves to the child, then siblings, then completes the parent. During completion React accumulates host mutations and effects that may be applied later.

Fiber also separates render from commit. The render phase is pure calculation: call components, compare children, prepare mutations, and decide effects. The commit phase is synchronous and visible: mutate the DOM, run layout effects, attach refs, and publish the new current tree. Interrupting commit would leave the UI half-mutated, so React keeps it short and non-interruptible.

Priority is represented through lanes. A keystroke, transition, idle refresh, and hydration event can occupy different lanes. Fibers record which lanes have pending work, and React uses those bits to decide whether a subtree can be skipped or must be revisited.

## Practical patterns

Design components so rendering is cheap and repeatable. In concurrent React, render-phase work may start and be thrown away. Expensive parsing, random ID generation, imperative subscriptions, or analytics calls inside render become bugs or performance cliffs. Keep side effects in effects, event handlers, or framework-specific server boundaries.

Use memoization to reduce repeated work, but apply it at stable boundaries. `memo`, `useMemo`, and `useCallback` help only when inputs are stable and the skipped work is meaningful. A tree with constantly recreated objects will still force child fibers to receive new props.

Keep state close to the interaction that changes it. A high-level state update marks a wide subtree as potentially needing work. Moving text input state into a small component lets React schedule and complete urgent work without re-rendering unrelated panels.

Treat keys as identity, not ordering hints. Fiber reuses child nodes by key and type. Stable keys let local state and DOM nodes survive reordering. Index keys make insertion and sorting look like many replacements, which corrupts local state and increases commit work.

When introducing shared context, treat the provider value as part of the scheduling surface. A provider that creates a fresh object on every render marks every consumer as potentially stale. Split contexts by change rate: theme, auth identity, viewport state, and active draft data should not necessarily travel through the same provider.

For browser integrations, prefer a small imperative adapter component. Let most of the tree remain declarative, then isolate the map, editor, chart, or media player behind one fiber boundary with explicit props. This keeps unpredictable DOM mutation and cleanup work from spreading through ordinary render paths.

## Failure modes

The classic failure is assuming render runs exactly once. Strict Mode intentionally stresses this by double-invoking render paths in development. If rendering triggers network calls, mutates globals, or consumes one-time iterators, Fiber's ability to retry exposes the bug.

Another failure is commit bloat. Concurrent rendering can spread calculation over time, but a giant commit still blocks the main thread. Thousands of DOM insertions, layout effects that read and write layout, or synchronous third-party widgets will produce jank even when render scheduling is healthy.

Stale closure bugs also become more visible. Work can be prepared with one set of props while newer updates are pending. React protects committed UI consistency, but your async callbacks still need functional updates, refs, or cancellation when they depend on changing values.

Context overuse can look like a Fiber problem while being an application architecture problem. If a single provider carries frequently changing state, every consumer fiber becomes part of the update's potential blast radius. The scheduler can prioritize work, but it cannot infer that a consumer does not semantically care about a field hidden inside a changing object.

## Debugging and diagnostics

Use the React Profiler to separate render time from commit time. A slow render suggests expensive component calculation, broad invalidation, or missing memo boundaries. A slow commit suggests DOM volume, layout effects, ref work, or browser layout cost.

Look for repeated renders with identical props. Add focused logging at component boundaries or use "why did this render" tooling. If many fibers re-render after one local action, inspect where state lives and whether context providers are changing identity every render.

When debugging identity bugs, log keys beside business IDs. If a row's key changes while the item is conceptually the same, React will remount it. Remounts reset state, rerun effects, and can hide as "random" focus loss or animation restarts.

## Checklist

- Keep render-phase code pure, deterministic, and restartable.
- Move state down when an update should affect only a small region.
- Use stable keys derived from domain identity.
- Profile render and commit separately.
- Keep layout effects small because commit is synchronous.
- Stabilize provider values and callback props where they fan out.
- Assume work-in-progress renders can be abandoned before commit.
