---
title: "Event sourcing in frontend"
date: 2026-01-19T09:30:00-05:00
draft: false
tags: [frontend, event-sourcing, state-management, undo-redo, architecture]
---

## Mental model: state is a projection

Event sourcing on the frontend means the primary record of change is an append-only event stream, and the UI state is a projection derived from that stream. Instead of storing only `currentCart`, you store facts such as `ItemAdded`, `QuantityChanged`, and `CouponRemoved`, then fold them into the current view model.

This is not the right default for every app. It earns its complexity when you need undo/redo, auditability, collaborative reconciliation, offline replay, or deterministic debugging. If the app is mostly forms submitted once, a normal normalized store is easier.

{{< mermaid >}}
flowchart LR
    UI[User intent] --> CMD[Command]
    CMD --> VAL[Validate]
    VAL --> EVT[(Event log)]
    EVT --> PROJ[Projection reducer]
    PROJ --> VM[View model]
    VM --> UI
{{< /mermaid >}}

## Internals

Separate commands from events. A command is a request: `ChangeQuantity(itemId, 3)`. An event is a fact: `QuantityChanged(itemId, from: 1, to: 3)`. Commands can fail validation. Events should be valid, append-only, and replayable.

```ts
type Event =
  | { type: "ItemAdded"; version: number; id: string; sku: string; qty: number; at: number }
  | { type: "QuantityChanged"; version: number; id: string; from: number; to: number; at: number }
  | { type: "ItemRemoved"; version: number; id: string; at: number };

function project(events: Event[]): CartView {
  return events.reduce(cartReducer, emptyCart());
}
```

The reducer must be deterministic. Do not read `Date.now()`, random ids, browser size, or global caches during projection. Put those values in the event at creation time. Determinism is what makes replay, time travel, and bug reproduction useful.

## Practical patterns

Keep the event log small enough for the client. Snapshot projections after a known event index if replay becomes expensive. A snapshot is not a replacement for the log; it is a checkpoint: load snapshot, replay events after snapshot.

Use event versions. Frontend events live across deployments if they are persisted in IndexedDB, local storage, or a server sync queue. Add `version` and write migration functions from old event shapes to the current shape. Avoid deleting fields casually.

For undo, do not simply pop the last event if events can come from multiple actors or background sync. Append compensating events such as `QuantityChanged` back to the previous value. The log remains a faithful history, and projections stay monotonic.

For server sync, include stream id, event id, client id, and sequence number. The server can acknowledge accepted events and reject conflicting ones. The client then marks local events as accepted, appends server events it did not know about, and reprojects.

Use command handlers as the only place where intent becomes facts. A component can dispatch `ChangeQuantity`, but the handler checks inventory rules, clamps limits, assigns event ids, records timestamps, and appends `QuantityChanged`. That keeps invariants out of buttons and reducers.

```ts
function handle(command: Command, state: CartView): Event[] {
  switch (command.type) {
    case "ChangeQuantity": {
      const item = state.items[command.id];
      if (!item) return [];
      const next = Math.max(1, Math.min(command.qty, item.maxQty));
      if (next === item.qty) return [];
      return [{
        type: "QuantityChanged",
        version: 1,
        id: command.id,
        from: item.qty,
        to: next,
        at: command.at,
      }];
    }
  }
}
```

Store metadata consistently: event id, stream id, schema version, actor id, client id, timestamp, and causation/correlation ids when useful. The domain payload says what changed; metadata says where the event came from and how it relates to other work. This makes sync, auditing, and debugging much easier.

Persist carefully. IndexedDB is usually a better client-side log store than local storage because it handles larger data and async writes. Append events transactionally with any local acknowledgement state. If the UI updates optimistically before persistence succeeds, define what happens on failure: rollback with compensating events, show a retry state, or keep the change in memory and block navigation.

## Projection design

A projection should be a pure fold from events to a read model. It can build normalized maps, sorted lists, validation summaries, or route-specific view models. Multiple projections can consume the same log: one for rendering, one for undo labels, one for sync status. Keep them deterministic and cheap enough to recompute during development.

For large streams, project incrementally. Keep the last processed event index and apply only new events. When the schema changes, invalidate or migrate the snapshot. Never let a projection become the hidden source of truth; if it cannot be rebuilt from events plus migrations, the architecture has drifted back to mutable state with extra ceremony.

Event granularity is a product decision. `TextInserted` and `TextDeleted` may be right for collaborative editing. `ProfileUpdated` may be enough for an account settings screen. Too coarse, and undo/audit is vague. Too fine, and replay becomes noisy and hard to reason about. Choose events around meaningful domain facts, not around every UI callback.

## Failure modes

The biggest failure is putting side effects inside projection. If replaying events triggers analytics, network calls, or persistence writes, every debug session becomes dangerous. Projection should be pure; side effects belong in command handlers or effect subscribers that are guarded by event ids.

Another trap is over-modeling UI trivia. Events like `ModalOpened` and `TooltipHovered` usually do not belong in the durable domain log. Keep ephemeral UI state separate unless it matters for replay or collaboration.

Event logs can also hide invalid transitions if every component appends events directly. Use command handlers as the boundary that enforces invariants. A cart item should not reach negative quantity because a component emitted a clever event.

Schema migration is a long-term failure mode. A persisted event from six months ago may not match today's TypeScript union. Do not parse old logs with `as CurrentEvent[]` and hope. Add explicit upcasters from old versions to new versions and test them with fixtures. If an event cannot be migrated, quarantine it and show a recovery path rather than crashing the entire app.

Conflict handling also needs a policy. In offline-first apps, two clients may append valid events that conflict when synchronized. Last-write-wins is simple but can erase user intent. Domain-specific merges, conflict events, or server-side rejection with client rebase are more work but more honest. The frontend projection should be able to represent pending, accepted, rejected, and conflicted events.

Privacy and retention matter. An append-only log can preserve data the user thought they removed. If events contain personal data, define compaction, redaction, or crypto-erasure strategies. For example, `EmailChanged` events might store hashes for audit and keep the current email in a separate encrypted profile record.

## Debugging and diagnostics

An event-sourced frontend should ship with a log viewer in development. Show event id, type, version, timestamp, actor, and projection diff. Add an export button that serializes the event stream. Many "cannot reproduce" UI bugs become easy when QA can attach the exact stream that produced the broken state.

Measure projection time and event count. If rendering a route requires replaying thousands of events, introduce snapshots or narrower streams. Use property tests for reducers: replaying the same events twice should produce equal state, and migration should preserve important invariants.

Add replay tests for real bug reports. When a user hits a broken state, reduce the exported stream to the smallest sequence that reproduces it and commit that as a fixture. This is the frontend equivalent of a database regression test: the bug was not "the UI looked wrong," it was "this event history projected into an invalid view model."

Track event rates and log sizes in development. If a mouse move appends hundreds of durable events, the boundary is wrong. If a single command appends events from several unrelated domains, the command handler may be doing too much. The log should explain the product history at a level humans can inspect.

## Checklist

- Model commands as requests and events as facts.
- Keep projection pure and deterministic.
- Version persisted event schemas.
- Use snapshots when replay cost becomes visible.
- Prefer compensating events over destructive history edits.
- Keep ephemeral UI state out of the domain log.
- Build a dev event viewer before the first production incident.
