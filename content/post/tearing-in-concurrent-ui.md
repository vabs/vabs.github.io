---
title: "Tearing in concurrent UI"
date: 2026-06-05T09:15:00-04:00
draft: false
tags: [frontend, concurrent-ui, tearing, state-management, react]
---

## Mental model: one screen, two snapshots

Tearing happens when different parts of the UI render from different versions of shared state at the same time. In a concurrent renderer, rendering can be paused, resumed, and interleaved. If an external store changes during that process and components read it unsafely, the committed screen can show an impossible combination.

Imagine a header shows cart count `3` while the checkout panel, rendered from a newer store snapshot, shows four items. Neither component is individually wrong, but the screen is inconsistent.

{{< mermaid >}}
sequenceDiagram
    participant Renderer
    participant Store
    participant Header
    participant Panel
    Renderer->>Store: read snapshot v1
    Renderer->>Header: render count 3
    Store-->>Store: update to snapshot v2
    Renderer->>Store: read snapshot v2
    Renderer->>Panel: render 4 items
    Renderer-->>Renderer: commit mixed UI
{{< /mermaid >}}

The bug is not that state changed. State is allowed to change while rendering. The bug is that one committed UI represents more than one logical moment. Users notice this as counts that do not match lists, totals that disagree with line items, enabled buttons for unavailable resources, or security-sensitive controls appearing under the wrong permission snapshot.

## Internals

Concurrent rendering separates render from commit. During render, components compute what the UI should look like. That work can be interrupted. External mutable stores are dangerous because reads are not automatically tied to a single render snapshot.

Framework-owned state is usually protected because the renderer controls when updates become visible. External stores, browser globals, mutable modules, and hand-rolled caches need an explicit subscription and snapshot protocol. In React, this is the reason for APIs shaped like `useSyncExternalStore`: read a snapshot, subscribe to changes, and let the renderer verify consistency before commit.

The key invariant is simple: every component participating in one render should observe the same logical snapshot of shared state.

A concurrent renderer may start rendering an update, pause for higher-priority work, then resume later. If a component calls `store.getState()` directly during render, it reads whatever the store contains at that exact time. Another component in the same render pass may read later and see a newer value. Without a snapshot protocol, the renderer cannot know that the render became inconsistent.

The subscription protocol solves two problems. First, it tells the renderer how to subscribe to external changes. Second, it gives the renderer a repeatable snapshot read. If the snapshot changes between render and commit, the renderer can retry so the committed screen uses one version.

Referential stability matters. A snapshot function that returns `{ ...state }` on every call says "the state changed" even when it did not. A snapshot function that returns a mutable object reused across updates says "the state did not change" even when fields changed. Both break the contract in different ways.

## Practical patterns

Use framework-approved external store adapters. A store hook should expose a stable `getSnapshot` and `subscribe`. The snapshot should be immutable or at least referentially stable when data has not changed. Returning a freshly allocated object on every read can cause infinite render loops or unnecessary retries.

Prefer selectors that derive from one snapshot rather than reading multiple mutable sources. If a component needs user and permissions, derive both from the same store version or combine them behind a single snapshot boundary.

For server-synchronized data, use caches that integrate with the renderer's subscription model. Avoid components directly reading mutable singleton objects that are updated by websockets.

A minimal store shape should include a version:

```js
let snapshot = Object.freeze({ version: 0, items: [] });
const listeners = new Set();

export function getSnapshot() {
  return snapshot;
}

export function subscribe(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function replaceItems(items) {
  snapshot = Object.freeze({ version: snapshot.version + 1, items });
  listeners.forEach((listener) => listener());
}
```

Selectors should run against `snapshot`, not against a live mutable backing object. If the store needs efficient updates, use structural sharing so unchanged subtrees keep identity while the root snapshot changes.

For websocket updates, buffer and publish complete snapshots. Do not mutate `ordersById` for each message while components might be rendering. Accumulate changes, create a new snapshot, then notify subscribers. If multiple stores must update together, coordinate them behind one transaction or expose a combined snapshot to the UI.

For browser APIs such as `matchMedia`, `localStorage`, or `BroadcastChannel`, wrap them the same way. A component reading `window.innerWidth` during render can tear relative to another component that subscribes to a media query. The source does not need to be a formal state library to cause the problem.

## Failure modes

The obvious symptom is inconsistent UI, but the root cause is often hidden. A custom store may mutate an object in place and notify subscribers later. A component that already holds a reference sees the new value during an old render. Immutability is not style here; it is a snapshot guarantee.

Another failure is mixing state systems without boundaries. A component reads Redux, a module-level cache, and `localStorage` during render. Each source has different update timing, so one render can observe multiple moments in time.

Hydration can expose tearing-like bugs too. If the server snapshot differs from the first client snapshot, the UI may mismatch or immediately change before the user can interact. Provide a consistent initial snapshot.

Another failure is selector impurity. A selector that reads time, random values, a global cache, or another store can return different results for the same snapshot. Keep selectors pure and push nondeterministic values into the snapshot at update time.

Local derived state can also drift. A component reads a store value, copies it into local state, and later renders both. During concurrent updates, the copied value may lag behind the store. Prefer derived values during render or explicit synchronization with clear ownership.

Transitions can make tearing easier to see. A low-priority transition renders an older snapshot while urgent input updates a store. If unsafe reads are involved, the final screen can combine transition-era data with urgent-era data. Test under transitions, not only synchronous updates.

External caches are often overlooked. A module-level `Map` filled by data fetching, a feature flag singleton, or an analytics consent object can all change outside the renderer. If render reads them, they need the same snapshot discipline.

## Debugging and diagnostics

Add store version numbers. Include the version in development selectors and log when one committed screen renders multiple versions. Freeze snapshots in development to catch in-place mutation. Use strict and concurrent rendering modes during tests because synchronous rendering can hide tearing.

Write a stress test that updates the external store while a slow component renders. Artificially yield or delay part of the tree, then assert that all visible components show the same version.

Add a small development helper that records versions observed during one render:

```js
function useStoreVersionDebug(name, version) {
  if (process.env.NODE_ENV !== "production") {
    window.__seenVersions ??= new Map();
    window.__seenVersions.set(name, version);
  }
}
```

This is not a production solution, but it helps find components that read a different source or bypass the store adapter.

To reproduce tearing, make rendering slow on purpose. Add a test-only component that burns a few milliseconds or suspends, then update the external store while the render is in progress. If the UI can commit mixed versions, the store adapter is unsafe.

Memory tooling can help with mutation bugs. Freeze snapshots or use proxies in development so accidental writes throw immediately. In-place mutation that "works" in synchronous rendering is exactly the kind of behavior concurrent rendering exposes.

For hydration, log the server snapshot version into the HTML and compare it to the first client snapshot. If they differ before hydration finishes, decide whether the client should use the server snapshot first and revalidate after hydration.

## Checklist

- Do not read mutable external stores directly during render.
- Use a subscription plus snapshot API designed for concurrency.
- Make snapshots immutable or versioned.
- Derive multiple fields from one logical snapshot.
- Avoid in-place mutation before subscriber notification.
- Match server and first client snapshots during hydration.
- Test with interrupted renders and rapid external updates.
- Keep selectors pure and tied to one snapshot.
- Version snapshots and log mixed-version commits in development.
- Coordinate multi-store updates through transactions or combined snapshots.
