---
title: "Structural sharing"
date: 2026-04-18T10:15:00-04:00
draft: false
tags: [frontend, data-structures, immutability, performance, state-management]
---

Structural sharing is the technique of creating a new version of a data structure by copying only the parts that changed and reusing the rest. It is the performance backbone of practical immutability. Without structural sharing, immutable updates would require copying entire trees, arrays, or maps for every small change.

{{< mermaid >}}
flowchart TD
  A[Old root] --> B[Old left branch]
  A --> C[Old right branch]
  C --> F[Old leaf]
  D[New root] --> B
  D --> E[New right branch]
  E --> G[New changed leaf]
{{< /mermaid >}}

## Mental model

Imagine state as a graph of references. An update creates a new path from the root to the changed leaf. Nodes outside that path are reused. Consumers comparing references can quickly know whether their branch changed. Old versions remain usable because reused nodes are not mutated.

In everyday JavaScript, object spread and array methods can implement structural sharing manually. Libraries such as Immer automate the copying. Persistent data structure libraries use trees optimized for sharing, so updates to large maps and vectors copy a small number of internal nodes instead of full collections.

## Practical example

For a normalized entity store:

```js
const nextState = {
  ...state,
  usersById: {
    ...state.usersById,
    [id]: {
      ...state.usersById[id],
      name,
    },
  },
};
```

The root changes. `usersById` changes. The edited user changes. Other users, other entity maps, and unrelated UI state keep the same reference. That is structural sharing.

## Why it matters

Rendering systems benefit because shallow comparison becomes meaningful. Undo stacks benefit because old states can share most memory with new states. Selectors benefit because caches keyed by branch references can skip recomputation. Debugging benefits because historical snapshots are stable.

The memory story is counterintuitive: immutable updates allocate new objects, but structural sharing prevents full duplication. The real cost is the changed path and any derived data you recreate unnecessarily.

## Failure modes

Deep cloning defeats sharing:

```js
const next = structuredClone(state);
next.usersById[id].name = name;
```

This is immutable from the outside, but every reference changes. Memoized components and selectors see the whole world as new. It also copies data that did not need to move.

In-place mutation corrupts sharing:

```js
const next = { ...state };
next.usersById[id].name = name;
```

The root reference changes, but `usersById` and the user object are shared and mutated. Old snapshots now reflect new data. Consumers of the user object may not update because the reference did not change.

A subtler failure is sharing mutable values. If a shared branch contains a `Map` and code mutates it, both old and new states observe the mutation. Treat mutable containers as leaves that must be replaced on update.

## Diagnostics

Reducer tests should assert both value changes and reference behavior:

```js
expect(next).not.toBe(prev);
expect(next.usersById).not.toBe(prev.usersById);
expect(next.usersById[id]).not.toBe(prev.usersById[id]);
expect(next.settings).toBe(prev.settings);
```

These tests catch deep cloning and accidental mutation. In performance profiling, watch for large subtrees rerendering after small updates. That usually means references are changing too broadly or state is not split along consumption boundaries.

## Practical patterns

Normalize collections by ID when updates target individual entities. Keep ordered ID arrays separate from entity maps. Copy the ID array only when order or membership changes; copy the entity map only when entity content changes.

Use Immer when manual copying obscures intent, but understand what it produces. Draft mutation is syntax; the output should still preserve references for unchanged branches.

## Implementation details

Structural sharing is easiest when state has clear ownership boundaries. A route cache, a form draft, and a selection model should not all mutate the same nested object graph. If they need the same entity data, share immutable entity references and store local annotations separately.

Selectors should align with shared branches. A selector that takes `state.usersById[userId]` can skip work when that user reference is stable. A selector that takes the entire root state will be invalidated by unrelated changes unless it has additional memoization layers. Pass the narrowest branch that contains the data needed.

For arrays, remember that the array reference and item references carry different signals. Filtering creates a new array even if all item objects are reused. Updating one item should create a new array and one new item object. Re-sorting creates a new order and may require downstream components to distinguish moved identity from changed content.

Persistent data structure libraries can improve asymptotic behavior for very large collections, but they introduce their own APIs and conversion costs. For many frontend apps, normalized plain objects plus careful copying are enough. Reach for specialized structures when profiling shows update cost or memory retention is a real issue.

## Debugging reference churn

When a small edit rerenders a large surface, inspect both the write path and the read path. In the write path, log which branches receive new references. In the read path, check whether selectors and components subscribe to a narrow branch or to a broad parent object. A reducer can preserve `state.settings`, but a component that receives `{ user, settings }` as a newly created object still sees a changed prop every render.

Browser and framework profilers usually show the symptom, not the cause. If a table rerenders after editing one row, ask these questions in order: did the array reference change, did every row object change, did the row component receive unstable props, and did the selector rebuild derived row view models for every item? The fix might be in the reducer, selector, or component boundary.

Also watch for serialization boundaries. Persisting state through JSON, receiving it from a worker, or reading it from IndexedDB recreates references even if the values are equal. That is not wrong, but it means caches based on object identity should be rebuilt at that boundary or keyed by stable IDs and versions instead.

## Operational rules

For shared application state, document which layer owns mutation. A query cache, reducer, and form library should not all write to the same entity object. Either each layer owns its own copy, or updates flow through one owner that returns a structurally shared next value.

Use version fields when identity alone is not enough. Large immutable records can keep the same nested references for efficiency while exposing `version` or `updatedAt` fields for systems that need a cheap invalidation signal. This is useful when crossing into non-React consumers, web workers, or custom rendering engines.

## Checklist

- Copy the path from root to changed leaf.
- Reuse unchanged branches intentionally.
- Avoid full deep clones for routine updates.
- Replace mutable leaves instead of mutating them.
- Test reference preservation in reducers.
- Align state boundaries with UI consumption patterns.

Structural sharing is what makes immutable state practical at application scale. It turns reference identity into a compact change map.
