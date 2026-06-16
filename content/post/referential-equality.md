---
title: "Referential equality"
date: 2026-03-25T08:55:00-05:00
draft: false
tags: [frontend, javascript, react, state, equality]
---

Referential equality means two values are considered equal because they point to the same object, array, or function instance. In JavaScript, objects compare by reference with `===`. Two objects with identical fields are not equal unless they are the same allocation. Frontend frameworks lean on this rule because it makes change detection cheap: if a reference did not change, many systems assume the value did not change.

{{< mermaid >}}
flowchart TD
  A[Previous prop object] --> C{Same reference?}
  B[Next prop object] --> C
  C -->|yes| D[Can skip shallow update]
  C -->|no| E[Inspect or rerender]
{{< /mermaid >}}

## Mental model

Referential equality is a signal. A new reference usually means "something may have changed." The same reference usually means "nothing changed." The signal works when data is immutable and updates create new objects along changed paths. It fails when code mutates objects in place or recreates objects unnecessarily.

Shallow comparison depends on referential equality. `React.memo`, dependency arrays, selector caches, and many store subscriptions compare top-level references. They do not deeply inspect every nested field because deep comparison is expensive and can still be semantically ambiguous.

## Practical patterns

Preserve references for unchanged values. If only one item changes in a list, reuse the other item objects:

```js
const nextItems = items.map((item) =>
  item.id === changed.id ? { ...item, label: changed.label } : item
);
```

Now components receiving unchanged items can skip work if they compare props shallowly. This is the core benefit of immutable updates: the reference graph tells consumers where changes occurred.

Avoid recreating stable config objects in render when they are passed to memoized children:

```js
const tableOptions = useMemo(() => ({ density, columns }), [density, columns]);
```

Use this when the child is expensive or the options object is a dependency for effects. Do not wrap every object reflexively.

## Failure modes

Mutation breaks the signal:

```js
user.name = "Asha";
setUser(user);
```

The reference is the same, so subscribers may skip updates. Even when the UI rerenders for another reason, memoized selectors may return stale derived data because their key did not change.

Unnecessary allocation creates noise:

```js
const filters = { status: "open" };
```

If this object is created on every render and passed to a memoized child, the child sees a change every time. The reference signal says "changed" even though the semantic value is stable.

Functions are objects too. Inline callbacks are new references each render. That is fine until a child or effect depends on callback identity. Use `useCallback` when identity stability matters for a measured reason.

## Debugging

When a component rerenders unexpectedly, log which props changed by reference:

```js
function diffRefs(prev, next) {
  for (const key of Object.keys(next)) {
    if (prev[key] !== next[key]) console.log("changed", key);
  }
}
```

When a component fails to update, look for mutation. Freeze state in development, use Immer's draft model, or add tests that assert new references along changed paths.

Dependency-array bugs are also referential-equality bugs. An effect depending on `{ page, pageSize }` will run on every render if that object is recreated. Depend on primitives or memoize the object.

## Implementation details

Design APIs with reference stability in mind. A hook that returns a new object on every call can cause every consumer effect to rerun. If the hook exposes multiple values, consider returning primitives, memoizing the result object, or exposing separate hooks for high-frequency and low-frequency values.

Context providers are a common pressure point. A provider value like `{ user, theme, notifications, updateTheme }` changes whenever any field changes, so every consumer may rerender. Split contexts by update pattern, or memoize provider values while ensuring callbacks do not capture stale state.

Version numbers can be useful when values are large or mutable at the boundary. For example, a canvas model might keep imperative internals but expose a `version` that increments on semantic changes. Consumers compare the version rather than walking the model. This is a compromise, but it makes the change signal explicit.

Avoid using `JSON.stringify` as an equality strategy in render. It is order-sensitive for some structures, expensive for large objects, and unable to represent functions, symbols, cycles, and many browser objects. If semantic equality is required, write a domain-specific comparison or redesign the data flow.

## Selector and cache design

Selectors should return stable references when their semantic result has not changed. A selector that filters an array and returns a new array every time defeats shallow comparison even if the contents are identical. Memoize by the inputs that actually affect the result, and be careful with parameterized selectors shared across many component instances. A global one-entry cache works for one consumer and fails when two rows ask different questions.

For normalized stores, derive small values close to the consumer. Returning a whole reconstructed graph from a selector can allocate many objects and hide which entity actually changed. Returning ids, primitive counts, or a stable entity reference often gives the component enough information with less reference noise.

Context values deserve special attention because every provider update can broadcast to many consumers. Split contexts by update frequency: authentication identity, theme, feature flags, and high-frequency editor state should not necessarily share one object. A stable callback also matters; if a provider memoizes `{ value, update }` but `update` is recreated every render, the memoized object still changes.

## When equality should be semantic

Referential equality is a performance signal, not a complete model of meaning. Some domains need semantic equality: two date ranges may be equivalent even if represented by different objects, and two search filters may be equivalent after default values are applied. Put that comparison at the domain boundary rather than sprinkling deep comparisons through render paths.

For effects, prefer depending on the primitive fields that drive the effect. If an API request depends on `page`, `pageSize`, and `sort`, list those values directly. If the effect truly depends on a complex object, memoize that object at the point where the object is built, not inside the effect as a workaround.

## Checklist

- Treat object identity as part of the state contract.
- Use immutable updates so changed paths get new references.
- Preserve references for unchanged branches.
- Avoid inline objects for expensive memoized children.
- Do not use deep comparison as a default escape hatch.
- Debug both noisy new references and hidden in-place mutation.

Referential equality is powerful because it is cheap. It becomes reliable only when the codebase consistently treats references as change signals.
