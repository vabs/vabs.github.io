---
title: "Immutable data patterns"
date: 2026-04-07T09:40:00-04:00
draft: false
tags: [frontend, state-management, immutability, javascript, patterns]
---

Immutable data patterns update state by creating new values instead of modifying existing values in place. The goal is not aesthetic purity. The goal is reliable change detection, predictable debugging, safe undo/redo, and fewer hidden side effects between components that share references.

{{< mermaid >}}
flowchart TD
  A[Previous state] --> B[Update action]
  B --> C[Copy changed path]
  C --> D[Reuse unchanged branches]
  D --> E[Next state]
  A --> F[History/debug snapshot remains valid]
{{< /mermaid >}}

## Mental model

State is a value, not a bag of objects to mutate from anywhere. An update receives the previous value and returns the next value. Consumers can compare references to know which branches changed. Old snapshots remain meaningful because later updates do not rewrite them.

This model is especially useful in UI because rendering is snapshot-based. A component renders from one version of state. Events and effects schedule transitions to later versions. Immutability keeps those versions from bleeding into each other.

## Core patterns

For shallow objects, spread is enough:

```js
const nextUser = {
  ...user,
  name: "Mira",
};
```

For arrays, use `map`, `filter`, `slice`, and spread instead of mutating methods:

```js
const nextTodos = todos.map((todo) =>
  todo.id === id ? { ...todo, done: true } : todo
);
```

For nested data, copy every changed level and reuse unchanged branches:

```js
const nextState = {
  ...state,
  projects: {
    ...state.projects,
    [projectId]: {
      ...state.projects[projectId],
      title,
    },
  },
};
```

If this becomes noisy, use Immer or normalize the state shape. Immer lets you write draft mutations while producing immutable output. Normalization reduces deep copying by storing entities by ID.

## Practical architecture

Keep server cache, form draft state, and UI state separate. Server data often wants normalized entities and cache invalidation. Form drafts may intentionally diverge from saved entities. UI state such as expanded rows or selected tabs should not be embedded inside shared entities unless it is truly domain data.

Use reducers for complex transitions. Reducers make updates explicit and testable:

```js
function reducer(state, action) {
  switch (action.type) {
    case "todo.completed":
      return {
        ...state,
        todos: state.todos.map((todo) =>
          todo.id === action.id ? { ...todo, done: true } : todo
        ),
      };
    default:
      return state;
  }
}
```

## Failure modes

The biggest failure is partial immutability. A top-level object is copied, but a nested object is mutated. The top-level reference changes, so some subscribers update, but memoized children receiving the nested object do not. This creates inconsistent UI that is hard to reason about.

Another failure is excessive copying. Deep cloning the whole state on every update destroys referential benefits because every branch looks changed. It also increases garbage collection pressure. Copy changed paths, not the entire tree.

Mutable browser objects need care. `Date`, `Map`, `Set`, `URLSearchParams`, and class instances can mutate internally while keeping the same reference. Either wrap updates by creating new instances or keep them out of state values that rely on shallow comparison.

## Diagnostics

Use development freezes to catch mutation:

```js
function deepFreeze(value) {
  Object.freeze(value);
  for (const child of Object.values(value)) {
    if (child && typeof child === "object" && !Object.isFrozen(child)) {
      deepFreeze(child);
    }
  }
  return value;
}
```

Use this in tests or development, not hot production paths. Add reducer tests that assert changed and unchanged references.

## Implementation details

Choose the state shape before choosing helper libraries. If updates frequently target individual records, normalize first. If updates are mostly document-like and localized, nested objects with Immer may be fine. If the data is append-only history, arrays of immutable events may be simpler than mutable entity snapshots.

Keep transient UI state separate from persisted domain state. A row hover, open popover, or current drag position should not force domain entities to receive new references. Separating transient state reduces accidental rerenders and keeps persistence logic cleaner.

When integrating with APIs, normalize at the boundary. Server responses often arrive as nested documents optimized for transfer or human readability. UI updates often need random access by ID. Convert once in the data layer instead of scattering nested update logic throughout components.

Be explicit about ownership. If a child receives an object prop, it should not mutate it unless the prop is documented as a mutable handle. Most UI props should be treated as read-only values. TypeScript `readonly` types and lint rules can reinforce this contract, but tests and code review still matter.

## Failure analysis in real apps

When an immutable update appears correct but the UI is stale, inspect the exact reference path from the store root to the component prop. A common bug is copying `state.projects` and `state.projects[id]` but mutating `state.projects[id].tasks` in place. The parent rerenders, but a memoized task list receives the same array reference and skips. Write reducer tests that assert both sides: changed paths should be new references, and untouched siblings should be the same references.

When the UI rerenders too much, look for accidental all-tree replacement. API normalization code sometimes rebuilds every entity object after every fetch. That makes every row, selector, and memoized child believe everything changed. Merge by id and reuse the previous entity object when the meaningful fields are equal. This is especially important for live polling, collaborative documents, and tables with hundreds of rows.

Undo and redo make mutation bugs obvious. If history entries are just references to objects that later mutate, undo will restore corrupted snapshots. Store immutable snapshots, patches, or event logs. Patches are often the best compromise: they are smaller than whole snapshots and easier to invert than arbitrary object mutation.

## Boundary guidance

Do not force immutability onto every low-level structure. A parser, physics engine, or canvas renderer may use internal mutation for performance. The boundary should still expose immutable snapshots, patches, or versioned reads to the UI. That keeps hot internals fast without leaking mutable references into components.

For TypeScript code, use `Readonly<T>`, readonly arrays, and lint rules as guardrails, but avoid assuming types enforce runtime behavior. External libraries can still mutate objects, and type assertions can bypass protection. Clone or normalize untrusted inputs at the boundary where ownership changes.

## Checklist

- Return new values for changed state.
- Reuse unchanged branches.
- Avoid deep cloning whole state trees.
- Normalize deeply nested collections.
- Be careful with mutable built-ins.
- Test reducer transitions and reference preservation.

Immutable data patterns are about making change visible. Once references accurately represent change, rendering, memoization, debugging, and undo become much simpler.
