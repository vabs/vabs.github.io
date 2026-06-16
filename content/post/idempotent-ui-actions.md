---
title: "Idempotent UI actions"
date: 2026-02-03T09:45:00-05:00
draft: false
tags: [frontend, state-management, reliability, ux, distributed-systems]
---

An idempotent UI action can be invoked more than once and still leave the application in the same intended state. Users double-click, mobile browsers retry taps after jank, network clients retry requests, tabs restore after crashes, and optimistic interfaces replay local mutations. If the UI action is not idempotent, those ordinary behaviors become duplicate orders, double votes, repeated messages, or corrupted client state.

The frontend mental model should mirror distributed systems: every meaningful mutation has an identity, a target state, and a reconciliation path. "Add one more" is fragile. "Set this item to selected for action id X" is much easier to retry safely.

{{< mermaid >}}
flowchart TD
  A[User intent] --> B[Create action id]
  B --> C[Optimistic state transition]
  C --> D[Send mutation]
  D --> E{Server result}
  E -->|success| F[Confirm canonical state]
  E -->|retryable failure| D
  E -->|rejected| G[Rollback or repair]
{{< /mermaid >}}

## Design actions around intent

The first pattern is to model actions as target-state transitions. A toggle should send `subscribed: true` or `subscribed: false`, not "toggle". A quantity stepper should eventually send the chosen quantity, not a stack of "increment" operations, unless the business domain truly cares about each increment.

The second pattern is to assign client mutation IDs. When creating a comment, generate a stable `clientId` before optimistic insertion. If the request retries, the server can deduplicate by idempotency key, and the client can merge the confirmed record into the existing optimistic row instead of appending a second row.

```js
async function submitComment(body) {
  const clientId = crypto.randomUUID();
  store.addOptimisticComment({ clientId, body, status: "pending" });

  try {
    const saved = await api.createComment({
      body,
      idempotencyKey: clientId
    });
    store.confirmComment(clientId, saved);
  } catch (error) {
    store.markCommentFailed(clientId, error.message);
  }
}
```

Disable-on-click is useful feedback, but it is not idempotency. It fails across tabs, refreshes, slow event loops, browser autofill submission, and network retries. Keep it as a UX affordance, not the correctness boundary.

## State machines over booleans

Represent action lifecycle explicitly: `idle`, `pending`, `succeeded`, `failed`, `retrying`, `conflicted`. A single `isLoading` boolean loses information. For example, after failure you need to know whether an optimistic change remains visible, whether retry is safe, and whether the user can edit the payload before retrying.

Use per-entity pending state rather than global pending state. A table with row actions should not freeze every row because one row is saving. Key pending state by entity id and action type. For create flows where the entity does not yet have a server id, key by client id.

## Reconciliation

Optimistic UI becomes reliable when reconciliation is boring. The server response should replace local guesses with canonical data: ids, timestamps, computed totals, permissions, and version numbers. If the server returns a conflict, do not blindly keep the optimistic state. Show the repaired state and explain the conflict at the point of action.

Versioning helps. Send `If-Match` headers, row versions, or updated-at tokens for edits where stale writes are dangerous. If the version fails, the UI can present "This changed since you opened it" rather than overwriting newer data.

For actions that are naturally additive, such as payment capture or sending email, idempotency keys are mandatory. The frontend should generate the key once per user intent and persist it until the operation reaches a terminal state. If the page reloads mid-flight, local storage or IndexedDB can preserve the pending key and query status instead of starting a second operation.

## Failure modes

The classic failure is binding mutation to both `onClick` and form `onSubmit`. Pressing Enter and clicking the button can create two submissions. Put the mutation in the submit handler, make the button `type="submit"`, and guard by action id.

Another failure is treating retries as new intents. A "Try again" button should reuse the same idempotency key when retrying the same payload. If the user edits the payload, that is a new intent and should receive a new key.

Optimistic list ordering is also subtle. If you sort by server timestamp, optimistic items may jump after confirmation. Use a temporary created-at value for display, then animate or quietly reconcile when the server timestamp arrives.

## Server contract

Frontend idempotency only works if the server participates. For dangerous mutations, send an idempotency key in a header or field and define the deduplication window. The server should store the key with the request fingerprint and final response. If the same key arrives with the same payload, return the original result. If the same key arrives with a different payload, reject it as a client bug instead of guessing.

For edits, pair idempotency with concurrency control. A repeated "set title to X" is safe, but a stale "set title to X" may still overwrite someone else's newer change. Use entity versions, ETags, or revision numbers so the server can distinguish duplicate delivery from stale intent. The UI can then offer retry, reload, or merge instead of pretending all failures are network failures.

## Client implementation details

Persist pending operations when the consequence matters. A payment, booking, invite, or message send should survive reload long enough for the app to ask the server what happened. Store the action id, payload hash, entity target, created time, and current lifecycle state. On startup, reconcile pending operations before allowing the user to issue the same intent again.

Keep optimistic reducers deterministic. Applying the same pending action twice should not append two temporary rows or increment a counter twice. Use maps keyed by action id or client id. For derived counts, compute from the deduplicated collection rather than maintaining a separate optimistic counter that can drift.

## Debugging

Add action ids to client logs, request headers, server logs, and analytics events. During QA, intentionally double-submit with the browser devtools network throttled. Refresh while a request is pending. Replay a failed request from the network panel. Open two tabs and perform the same action. The expected result is boring: one user intent, one durable effect, clear reconciliation in both tabs.

## Diagnostics

Instrument action ids in logs, analytics, and request headers. In development, deliberately double-click buttons, throttle the network, abort requests, refresh during pending actions, and open two tabs. Server logs should show duplicate attempts collapsing into one effect. Client logs should show one optimistic entity being confirmed, not two entities being appended.

Checklist:

- Model target state, not ambiguous toggles.
- Generate one stable idempotency key per user intent.
- Use lifecycle states instead of one loading boolean.
- Reconcile optimistic state with canonical server responses.
- Reuse keys for retries of the same payload.
- Test double-clicks, refreshes, offline retries, and multi-tab behavior.
