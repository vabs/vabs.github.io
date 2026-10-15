---
title: "Optimistic UI rollback strategy"
date: 2026-01-08T10:15:00-05:00
draft: false
tags: [frontend, optimistic-ui, rollback, state-management, latency]
---

## Mental model: speculative state with an audit trail

Optimistic UI is not "update the screen before the server responds." That is only the visible part. The useful mental model is speculative execution: the client applies a predicted mutation, records enough context to undo or reconcile it, and later commits, patches, or rolls it back when the authoritative response arrives.

The mistake is treating optimistic state as a boolean flag. A real rollback strategy needs an operation log. Each optimistic operation should have an id, target entity, before snapshot or inverse patch, predicted after state, request status, and conflict policy. Without that metadata, failures turn into hand-written edge cases scattered across components.

{{< mermaid >}}
sequenceDiagram
    participant UI
    participant Store
    participant API
    UI->>Store: apply optimistic op 42
    Store-->>UI: render predicted state
    Store->>API: send mutation with op id
    alt success with canonical payload
        API-->>Store: committed entity
        Store->>Store: replace prediction
    else validation/conflict/error
        API-->>Store: failure details
        Store->>Store: rollback or reconcile op 42
    end
{{< /mermaid >}}

## Internals that matter

The store needs to distinguish base state from pending overlays. The simplest implementation mutates local state immediately and stores an inverse patch. A more robust implementation keeps `baseState` plus a queue of pending operations, then derives the visible state by replaying pending operations over base state. Replay costs more CPU, but it makes out-of-order responses tractable.

Consider a todo title changed twice while both requests are in flight:

```ts
type OptimisticOp = {
  id: string;
  entityKey: string;
  apply: (state: State) => State;
  invert: (state: State) => State;
  status: "pending" | "committed" | "failed";
};
```

If response #1 fails after response #2 succeeds, a naive inverse patch may restore the title to the value before #1 and erase #2. Queue replay avoids that. Remove the failed op from the pending queue, update base state with committed server data, then replay the remaining pending ops in creation order.

## Practical patterns

Use client-generated operation ids and send them with the mutation. They make retries idempotent and let the server return a response that the client can match to the pending operation. For creates, also use a temporary client id and maintain a `tempId -> serverId` map after commit. Every relationship that references the temp id must be rewritten when the real id arrives.

Prefer inverse patches for small local edits and overlay replay for collaborative or high-frequency domains. A like button can store `delta: -1`. A kanban board with drag-and-drop, filters, and live updates should use an operation queue because many operations interact.

Validation failures should not always snap back. If a user edits a field and the server rejects it because a slug is taken, preserve the user's input, mark the field invalid, and roll back only the committed entity value. Destructive actions need stronger UX: hide immediately, keep an undo affordance, and delay irreversible server work when possible.

Keep optimistic metadata out of random component state. A central mutation layer, cache adapter, or domain store should own operation ids, inverse patches, retries, and reconciliation. Components should render state such as `pending`, `failed`, `queued`, or `conflicted`, but they should not each invent rollback behavior. Consistency matters because optimistic bugs usually appear when the same entity is visible in multiple places.

For normalized caches, write the optimistic change to the canonical entity record and let selectors update projections. For denormalized caches, list every projection the mutation touches: detail page, list row, search result, count badge, notification preview. If you cannot enumerate them, optimistic updates will drift. In that case, prefer a local overlay that is applied at read time or narrow the optimistic UI to the control that initiated the action.

## Reconciliation strategies

On success, do not assume the server returns exactly the predicted state. The server may add timestamps, normalize text, enforce permissions, recalculate counts, merge duplicates, or return a different entity version. Replace predictions with canonical payloads, then replay any still-pending operations that were based on the old view.

On failure, choose the smallest rollback that preserves user trust. For a toggle, revert the toggle and show a quiet error. For a text edit, keep the user's draft and mark it unsaved. For a create, keep the temporary item in a failed state with retry and delete actions rather than making it disappear. For a reorder, either replay the last confirmed order or show the failed item position with an explicit retry. The more effort the user invested, the less acceptable a silent snapback becomes.

Conflicts need a separate path from transport errors. A timeout says "we do not know whether the command succeeded." A 409 says "the command did not apply to the current server version." A 422 says "the command was understood but invalid." Treating all three as rollback loses information. Timeouts may need reconciliation polling or idempotent retry; conflicts may need a merge UI; validation errors need field-level feedback.

## Failure modes

The common failure is rollback that is correct for one mutation but wrong for multiple pending mutations. Another is optimistic cache writes that update one query result but not another. If a post title appears in a detail view, search result, and sidebar, either normalize the cache or write every affected projection deliberately.

Offline and retry behavior also changes the contract. If the request may be retried later, the operation is not failed; it is pending-durable. Show a queued state, persist the operation log, and design for app restart. If retries are automatic, avoid duplicate toasts and duplicate optimistic inserts by deduping on operation id.

## Debugging and diagnostics

Add a dev-only operation inspector. It should show pending op ids, entity keys, age, retries, and current derived state. Log transitions as `optimistic.apply`, `optimistic.commit`, `optimistic.rollback`, and `optimistic.replay`. In production metrics, track rollback rate by mutation name. A high rollback rate often means the UI is predicting business rules it does not actually know.

When testing, force responses to arrive out of order. Also simulate partial success, 409 conflicts, 422 validation failures, and network timeouts. The rollback path is rarely exercised manually, so make it deterministic in integration tests.

## Checklist

- Give every optimistic mutation a stable operation id.
- Store either an inverse patch or a replayable operation.
- Treat base state and pending overlays as separate concepts.
- Handle out-of-order success and failure responses.
- Reconcile temporary ids across every reference.
- Measure rollback rate and retry age.
- Test conflicts, validation errors, timeouts, and app reloads.
