---
title: "Reconciliation algorithm"
date: 2026-01-22T10:15:00-05:00
draft: false
tags: [frontend, react, reconciliation, virtual-dom, diffing]
---

## Mental model: preserve identity where the shape matches

Reconciliation is the process of turning a previous UI tree and a next UI tree into the minimal set of renderer operations React cares to compute. It is not a general tree-edit-distance algorithm. React uses practical heuristics: different component types produce different subtrees, and children with stable keys represent stable identity across renders.

The goal is not theoretical minimum DOM edits; the goal is predictable component identity and fast enough diffing. When type and key match, React can reuse the existing fiber and preserve state. When either changes, React treats the old node as replaced and mounts a new one.

{{< mermaid >}}
flowchart LR
    Old[Previous children] --> Match{Same type and key?}
    New[Next children] --> Match
    Match -- yes --> Reuse[Reuse fiber and state]
    Match -- no --> Replace[Unmount old and mount new]
    Reuse --> Props[Update props and reconcile children]
    Replace --> Effects[Schedule placement/deletion effects]
{{< /mermaid >}}

## Internals

At each position, React first compares element type. A `div` changing to a `section` remounts that host node and its descendants. A `ProfileCard` changing to `SettingsCard` remounts the component subtree. If the type is the same, React updates props and continues reconciling children.

For child arrays, keys dominate identity. React can scan children in order while keys and types line up. Once it detects movement, insertion, or deletion, it builds a lookup of remaining old children by key. New children then claim old fibers from that lookup. Unclaimed old fibers are deleted; new children without a match are mounted.

This algorithm is intentionally biased toward common UI updates: append an item, remove an item, reorder keyed rows, update props, or swap a conditional branch. It avoids an expensive global search. The trade-off is that React needs developers to provide correct keys and stable tree structure.

Component state belongs to a position in the rendered tree, refined by type and key. This is why toggling between two forms in the same position may preserve state unexpectedly unless you give them different keys. It is also why moving keyed rows can preserve input state inside each row.

## Practical patterns

Use keys from durable domain IDs: database IDs, slugs, generated client IDs stored with the item, or composite IDs that represent real identity. Avoid array indexes for lists that can filter, sort, prepend, insert, or delete. Index keys are tolerable only for static lists whose order and membership never change.

Use keys to intentionally reset state. A search page can render `<Results key={query} />` when each query should start with clean pagination and selection. A wizard can key a step form by step ID to avoid carrying validation state into the next step.

Keep conditional branches structurally honest. If two branches represent different concepts, make that visible through type or key. If they represent the same component with different props, keep the type and key stable so React can preserve state.

Do not create component types inside render. A nested component declaration creates a new function identity on every render, so React sees a different type and remounts the subtree. Define components at module scope or memoize factories only when there is a strong reason.

For forms and editors, decide explicitly whether identity follows the screen position or the edited entity. A reusable drawer might keep the same component instance while its `userId` prop changes, which is useful for preserving drawer chrome but dangerous for local draft fields. Put the key on the smallest component whose state must reset, not necessarily on the whole drawer.

For optimistic UI, create client-side IDs at the moment the item enters application state and keep them stable through server confirmation. Replacing a temporary key with a server key after save can remount the row and lose focus or animation state. Instead, store a stable view key or reconcile the server ID into the existing item object.

## Failure modes

State leaks are the most confusing reconciliation bug. A form switches from editing Alice to editing Bob, but the local draft still contains Alice's data because the component identity never changed. Add a key based on the edited entity or explicitly reset state when the entity changes.

State loss is the opposite bug. A row loses focus after sorting because keys were indexes. React preserved the state for "row position 2" rather than "invoice 123". Once the order changes, the wrong component owns the wrong state.

Animation glitches often come from unstable identity. If keys are regenerated with `Math.random()` or timestamps, every render becomes a full remount. Exit animations cannot run predictably, DOM nodes churn, and effects reconnect constantly.

Over-keying can also hurt. Placing a changing key too high in the tree remounts expensive providers, data caches, and layout. Use the smallest boundary that matches the reset you need.

Another subtle failure is mixing filtered and unfiltered arrays with different key schemes. A table may use domain IDs in the main view but index keys in a compact search result. Moving between modes then changes identity rules even though the rows represent the same records. Keep key strategy consistent across views that preserve state.

## Debugging and diagnostics

When a component unexpectedly resets, log mount and unmount with an empty-dependency effect. If it unmounts on ordinary prop changes, inspect type identity and keys. React DevTools can also show whether a component remounted or updated.

When state appears attached to the wrong item, print each rendered row's key and business ID. If the key is an index or changes independently from the item ID, reconciliation is doing exactly what it was told.

For conditional UI, draw the before and after tree. The bug is often obvious when you mark component type, key, and position. React does not know your business semantics; it only sees the element tree.

## Checklist

- Match keys to durable domain identity.
- Use keys deliberately to reset state at the right boundary.
- Avoid index keys for mutable lists.
- Define component types outside render.
- Debug remounts with mount/unmount logging.
- Keep conditional branches explicit about shared or separate identity.
- Do not use random keys to silence warnings.
