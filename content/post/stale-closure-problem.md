---
title: "Stale closure problem"
date: 2026-03-04T10:05:00-05:00
draft: false
tags: [frontend, javascript, react, state, closures]
---

The stale closure problem occurs when a function keeps references to values from an old render, old state transition, or old lexical scope and then runs later as if those values were current. In frontend code it appears in timers, event listeners, promises, subscriptions, memoized callbacks, and effects. The bug is not that closures are broken. The bug is that the callback's lifetime is longer than the state snapshot it captured.

{{< mermaid >}}
flowchart TD
  A[Render 1: count = 0] --> B[Create callback]
  B --> C[Timer stores callback]
  A --> D[Render 2: count = 1]
  C --> E[Timer fires]
  E --> F[Callback still sees count = 0]
{{< /mermaid >}}

## Mental model

Every render of a component creates a new set of local variables. A callback created during that render closes over those variables. If the callback is invoked after later renders, it still sees the old variables unless it was recreated or reads current data through a mutable reference or functional update.

This is especially visible in React because render state is immutable per render. That is a feature: it makes rendering predictable. But long-lived callbacks need a deliberate strategy.

## Common example

```js
function Counter() {
  const [count, setCount] = useState(0);

  useEffect(() => {
    const id = setInterval(() => {
      setCount(count + 1);
    }, 1000);
    return () => clearInterval(id);
  }, []);
}
```

The interval callback captures `count` from the first render. It keeps setting `1`. The fix is to use a functional update because the next value depends on the previous value:

```js
setCount((current) => current + 1);
```

Now the callback does not need the captured `count`.

## Practical patterns

Use dependency arrays honestly. If an effect reads `userId`, include `userId`. If that causes unwanted resubscription, the design probably needs separation between subscription setup and current value access.

For event listeners that must stay stable while reading current state, store the current value in a ref:

```js
function useLatest(value) {
  const ref = useRef(value);
  useEffect(() => {
    ref.current = value;
  });
  return ref;
}
```

Then the long-lived callback reads `latest.current`. Use this pattern sparingly. Refs bypass the render snapshot model, so they are best for imperative boundaries: DOM listeners, sockets, timers, and third-party APIs.

Use functional state updates for state derived from previous state. Use reducers when updates depend on multiple fields that must change together. A reducer centralizes transition logic and avoids callbacks stitching together stale fragments.

## Failure modes

Missing effect dependencies are the obvious failure. The subtle failure is over-memoization. A `useCallback` with an empty dependency array can freeze business logic. It may be stable for child rendering, but wrong for behavior.

Async code creates another trap:

```js
async function save() {
  const draft = formState;
  await api.save(draft);
  if (formState.dirty) markSaved();
}
```

The `formState` after `await` is still from the render that created `save`. If the user edited while the request was in flight, the callback may mark the wrong state as saved. Track request IDs, compare versions, or move the state machine into a reducer.

## Diagnostics

Log render versions. Increment a ref on each render and include it in callbacks:

```js
const version = useRef(0);
version.current += 1;
```

When a delayed callback fires, log the captured values and the current ref values. If they differ, decide whether the callback should use the snapshot or the latest value. Both can be correct in different workflows.

React's exhaustive-deps lint rule is valuable because it makes stale closures visible during review. Do not silence it without leaving a design reason.

## Implementation details

Classify callbacks by lifetime. Render-only callbacks can safely use render values because they run during the same render pass. Event handlers usually use the values from the render that produced the visible UI, which is often exactly what you want. Long-lived callbacks such as intervals, socket handlers, observers, and third-party listeners need a current-value strategy.

For async workflows, model the operation explicitly. A save button might capture the draft at submit time, send that exact snapshot, and then only mark the form saved if the saved version still matches the current draft version. That is different from reading the latest draft after the request resolves. Both choices are valid, but mixing them creates stale closure bugs.

Reducers help because they move "what should happen next" into a transition function. Instead of an old callback reading old state and computing a new value, it dispatches an event. The reducer receives the current state at dispatch time. This is especially useful for websocket events, timers, and multi-step workflows.

Refs are an imperative escape hatch. They should be named to show intent, such as `latestUserRef` or `isMountedRef`, and they should be updated consistently. If many refs are needed to keep logic fresh, the component probably wants a reducer or a smaller state machine.

## Choosing snapshot or latest

Not every stale-looking closure is wrong. A submit handler should often send the exact draft the user submitted, even if the user keeps editing while the request is in flight. A telemetry event should describe the UI state at the time of the click, not whatever state exists when batching finishes. Those callbacks intentionally use a snapshot.

Latest-value reads are appropriate when the callback is an ongoing subscription to the outside world. A websocket message handler usually wants the current selected conversation. A resize observer wants the current layout configuration. A retry timer wants to know whether the route is still active. In those cases, use a ref, reducer dispatch, or cancellation scope.

Make this decision explicit in names. `submittedDraft` signals snapshot semantics. `latestDraftRef` signals current-value semantics. Ambiguous names such as `data` or `state` make stale closure reviews much harder because the intended lifetime is hidden.

## Review and linting guidance

Treat exhaustive-deps warnings as design prompts. If adding a dependency causes resubscription, first ask whether resubscription is correct. If it is too expensive, split the effect: one effect owns the subscription, another updates a ref or dispatches state. Silencing the rule should be rare and accompanied by a comment that states the lifetime contract.

Tests should cover time. Use fake timers for intervals, delayed promises for async saves, and explicit rerenders between scheduling and resolution. The important sequence is schedule with value A, render value B, then fire the callback. That is the moment stale closure bugs appear.

## Checklist

- Treat each render as a snapshot.
- Include dependencies unless the callback intentionally reads through a ref.
- Use functional updates for previous-state transitions.
- Use reducers for multi-field transitions.
- Add cancellation or version checks to async workflows.
- Avoid empty dependency arrays as a performance reflex.

Stale closures are lifetime mismatches. Fix them by deciding whether a callback should operate on a snapshot, the latest state, or an explicit state transition.
