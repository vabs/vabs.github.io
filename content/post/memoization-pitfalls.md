---
title: "Memoization pitfalls"
date: 2026-03-13T09:50:00-05:00
draft: false
tags: [frontend, performance, memoization, react, caching]
---

Memoization caches the result of a computation for a set of inputs. In frontend code it can reduce expensive derived data, stabilize references passed to children, and avoid repeated work during render. It can also hide stale data, increase memory use, make profiling harder, and create the illusion that a render problem has been solved when the real issue is still there.

{{< mermaid >}}
flowchart TD
  A[Inputs] --> B{Same as cache key?}
  B -->|yes| C[Return cached value]
  B -->|no| D[Run computation]
  D --> E[Store result]
  E --> C
{{< /mermaid >}}

## Mental model

Memoization is a trade: pay comparison and cache complexity to avoid recomputation. It only helps when the saved computation is more expensive than the cache overhead and when input identity changes less often than renders. If the inputs are always new objects, the cache misses every time. If the computation is cheap, the memo wrapper may cost more than recalculating.

In React, `useMemo` does not guarantee semantic stability forever; it is a performance hint tied to dependencies. `React.memo` skips child rendering when props compare equal. `useCallback` memoizes function identity, not the work inside the function.

## Practical uses

Good candidates include sorting large lists, building indexes, deriving filtered views, compiling regular expressions from user settings, and stabilizing context values that would otherwise rerender a large subtree.

```js
const visibleRows = useMemo(() => {
  return rows
    .filter((row) => matchesFilter(row, filter))
    .sort(compareBy(sortKey));
}, [rows, filter, sortKey]);
```

This helps only if `rows`, `filter`, and `sortKey` are stable when the underlying data has not changed. If a parent recreates `rows` on every render, the memo misses.

## Pitfalls

The first pitfall is incorrect dependencies. Missing dependencies create stale results. Extra dependencies cause unnecessary invalidation. The dependency list should describe every value read by the computation from the render scope.

The second pitfall is memoizing unstable outputs without fixing unstable inputs. Wrapping a child in `React.memo` does little if every prop is an inline object or function:

```js
<Table options={{ dense: true }} onSelect={(row) => select(row.id)} />
```

The object and function are new each render. Stabilize them only if the child is expensive enough for the additional code to pay for itself.

The third pitfall is memory retention. A memoized result can keep large arrays, DOM-adjacent data, or parsed payloads alive longer than expected. Global memoization maps are especially risky because they may never evict. Prefer bounded caches when keys can grow with user behavior.

## Debugging

Start with profiling. In React DevTools Profiler, identify which components render often and why. Use "why did this render" tooling or targeted logs to check prop identity. Do not add memoization before finding an actual repeated cost.

Measure computation time directly:

```js
performance.mark("derive:start");
const result = deriveRows(rows);
performance.mark("derive:end");
performance.measure("deriveRows", "derive:start", "derive:end");
```

If the computation takes 0.2 ms, memoization is likely noise. If it takes 30 ms during typing, it is a real candidate.

## Failure modes

Memoization can freeze a bug. A stale `useMemo` result may pass tests until a user changes one of the missing dependency values. Memoized callbacks can capture stale closures. Memoized selectors can return old data when mutation breaks structural sharing, because the selector sees the same object identity and assumes nothing changed.

Another failure is using memoization as architecture. If every component needs `memo`, `useMemo`, and custom comparison functions, the state shape may be too broad. Move state closer to consumers, split contexts, virtualize large surfaces, and reduce prop fanout.

## Implementation details

Memoization works best at stable boundaries. A selector that derives visible rows from a normalized store is a good boundary because the inputs are explicit and the result may be expensive. A tiny calculation inside a leaf component is usually a poor boundary because the cache adds more concepts than it removes.

Prefer memoizing data over memoizing JSX unless profiling shows component creation itself is the bottleneck. Data memoization can be reused by tests, selectors, and non-visual code. JSX memoization tends to be tightly coupled to render structure and is easier to invalidate accidentally.

Custom equality functions deserve skepticism. They run during render decisions, so a deep comparison over large props can become the performance problem. They also encode semantics in a place future maintainers may not inspect. If a custom comparator is necessary, test the cases where it returns true and false, and keep it focused on stable identifiers or version numbers.

For shared caches, define eviction. A module-level `Map` keyed by arbitrary query objects can grow for the entire session. Use LRU behavior, weak references where appropriate, or clear caches on route/account changes. Memory leaks from memoization are still leaks.

## Cache keys and invalidation

The hardest part of memoization is usually not storing the value; it is defining equality. Primitive keys are simple. Object keys depend on identity, which is only meaningful if callers preserve structural sharing. A selector keyed by `filters` will miss every time if the caller creates `{ status, owner }` inline. Either stabilize the object at the boundary, key by primitive fields, or accept recomputation.

Version numbers are often cleaner than deep equality. If a dataset changes in controlled places, expose `rowsVersion` or `schemaVersion` and key expensive derived work from that. The memoized function no longer needs to inspect every row to decide whether the result is valid.

Invalidation should be tied to ownership. A route-level cache should clear on route changes. A user-specific cache should clear on account switches. A feature-flag-aware cache should include the flag version in the key. Bugs happen when a cache silently outlives the assumptions under which its result was created.

## Testing memoized code

Test both correctness and reuse. For correctness, call the function with changed inputs and assert the new output reflects every dependency. For reuse, call it with unchanged shared references and assert expensive collaborators are not called again. This catches both stale dependency bugs and ineffective cache keys.

Avoid snapshot tests that only assert rendered output after memoization. They may pass while hiding a stale branch that appears only after a dependency changes in a different order. Exercise sequences: initial render, unrelated update, relevant update, and owner teardown. Memoization bugs are temporal.

## Checklist

- Profile before memoizing.
- Keep dependency lists honest.
- Stabilize inputs before expecting cache hits.
- Avoid custom equality functions unless they are tested and cheap.
- Use bounded caches for unbounded key spaces.
- Revisit memoization after state-shape changes.

Memoization is not a general performance setting. It is a local cache with correctness constraints, invalidation rules, and real maintenance cost.
