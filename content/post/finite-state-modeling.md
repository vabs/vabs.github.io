---
title: "Finite state modeling"
date: 2026-02-03T11:45:00-05:00
draft: false
tags: [frontend, state-machines, finite-state, ui-architecture, forms]
---

## Mental model: make impossible states unrepresentable

Finite-state modeling is the practice of describing UI behavior as a set of named states and allowed transitions. The point is not academic purity. The point is to stop representing contradictory UI conditions with independent booleans such as `isLoading`, `hasError`, `isDirty`, `isSaving`, and `isSuccess`.

If a form can be both `isSaving: true` and `hasError: true`, every render branch must guess what that means. A state machine makes the mode explicit: `editing`, `submitting`, `submitFailed`, or `submitted`.

{{< mermaid >}}
stateDiagram-v2
    [*] --> editing
    editing --> submitting: SUBMIT
    submitting --> submitted: RESOLVE
    submitting --> submitFailed: REJECT
    submitFailed --> editing: CHANGE
    submitFailed --> submitting: RETRY
    submitted --> editing: EDIT_AGAIN
{{< /mermaid >}}

## Internals

A finite state machine has three important parts: the current state, events, and transition rules. Extended data, often called context, holds values that do not define the mode by themselves: form fields, validation messages, request ids, or selected entity ids.

```ts
type State =
  | { value: "editing"; fields: Fields }
  | { value: "submitting"; fields: Fields; requestId: string }
  | { value: "submitFailed"; fields: Fields; error: string }
  | { value: "submitted"; receiptId: string };

type Event =
  | { type: "CHANGE"; field: string; value: string }
  | { type: "SUBMIT" }
  | { type: "RESOLVE"; requestId: string; receiptId: string }
  | { type: "REJECT"; requestId: string; error: string };
```

Notice that `submitted` does not contain editable fields unless the UX needs them. That forces code to handle the mode rather than accidentally rendering stale input.

## Practical patterns

Start with the states a designer or support engineer would name. Avoid modeling every microscopic condition as a state. `editing` with context `{ dirty: true }` is often better than separate `cleanEditing` and `dirtyEditing` states unless the transition rules differ materially.

Use guards for business conditions: `SUBMIT` from `editing` is allowed only when the form is valid. Use actions for side effects: when entering `submitting`, start the request. Do not start requests from random click handlers and then try to keep the machine in sync afterward.

For async work, store a request id in the submitting state. When a response arrives, ignore it unless it matches the current state's request id. This prevents stale responses from overwriting newer user intent.

State machines are especially useful for flows with cancellation: upload widgets, checkout, authentication, wizards, media players, and permission prompts. They also document edge cases because every transition needs a source and destination.

Keep the transition function pure. It should accept state and event, then return the next state plus a description of effects to run. That separation prevents click handlers, effects, and reducers from racing each other.

```ts
type Effect =
  | { type: "submit"; requestId: string; fields: Fields }
  | { type: "cancel"; requestId: string };

function transition(state: State, event: Event): [State, Effect[]] {
  switch (state.value) {
    case "editing":
      if (event.type === "SUBMIT") {
        const requestId = crypto.randomUUID();
        return [
          { value: "submitting", fields: state.fields, requestId },
          [{ type: "submit", requestId, fields: state.fields }],
        ];
      }
      return [state, []];
    default:
      return [state, []];
  }
}
```

This pattern is especially useful in React, where render can re-run and effects can be replayed in development. The reducer decides what should happen; a single effect runner observes the returned effect and performs the network call. Tests can assert transitions without mocking `fetch`.

For hierarchical flows, split machines by ownership. A checkout page might have a page-level machine for `cart`, `shipping`, `payment`, and `review`, while the payment form has its own nested machine for `idle`, `validating`, `tokenizing`, and `failed`. Do not put every child widget into one giant graph unless the parent truly coordinates every transition.

## Implementation patterns in UI code

A practical machine usually needs three boundaries: event creation, transition, and effects. Components should create domain events such as `SUBMIT`, `CHANGE_EMAIL`, or `TOKENIZE_RESOLVED`, not mutate raw state. The transition layer should be the only place where mode changes. The effect layer should translate commands into actual I/O and feed results back as events.

When integrating with framework state, avoid deriving the current state from multiple stores. If `submitting` lives in one hook and `error` lives in another, the machine has already been split apart. Store the machine state as one value. Select small render-friendly pieces from it, but write through dispatch.

Use exhaustive checks. In TypeScript, a `never` check at the bottom of a switch makes newly added events or states visible at compile time:

```ts
function assertNever(value: never): never {
  throw new Error(`Unhandled case: ${JSON.stringify(value)}`);
}
```

This is not just neatness. It prevents a new `cancelled` state from silently falling through to behavior intended for `editing`.

## Failure modes

The common failure is creating a state machine wrapper while still letting components mutate state outside the machine. That gives you the ceremony without the guarantees. Make transitions the only write path.

Another failure is exploding the state graph. If the machine has 60 states for a single modal, context probably belongs in data rather than state names. State names should represent qualitatively different behavior, not every combination of properties.

Machines can also be too rigid for server-driven UI if the backend owns the workflow. In that case, model the frontend shell states, and treat server step identifiers as data returned by the workflow API.

## Debugging and diagnostics

Log transitions as `previousState`, `event`, `nextState`, and selected context diff. A transition log is more useful than a pile of component-level logs because it explains why the UI moved.

Write tests against the transition function directly. It is faster and clearer than clicking through every screen. Add model tests for invalid events: `RESOLVE` should not move `editing` to `submitted`; stale request ids should be ignored.

For production diagnostics, count unexpected events by current state. If users frequently send `SUBMIT` while already `submitting`, the button may not be disabled, or keyboard submit may bypass the visual lock.

Visualize the live machine during development. Even a simple panel that shows current state, last event, pending request id, and allowed next events can shorten debugging. If a designer reports "the retry button disappears," the machine view tells you whether the UI is in `submitFailed`, whether the transition to `editing` happened early, or whether rendering is hiding a valid state.

For async bugs, log request ids at the transport boundary. A stale response should be boring: `ignored RESOLVE req-1 while current req-2`. If it is hard to tell which request won, the state probably lacks enough identity to be reliable.

## Checklist

- Replace conflicting booleans with named states.
- Keep mode in state names and mutable values in context.
- Route all writes through transitions.
- Guard invalid transitions explicitly.
- Store request ids for async states.
- Test transition tables directly.
- Log state transitions, not just button clicks.
