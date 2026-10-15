---
title: "Offline conflict resolution"
date: 2026-05-02T12:45:00-04:00
draft: false
tags: [frontend, offline-first, conflict-resolution, sync, web-apps]
---

Offline conflict resolution is the set of rules that decides what happens when users make changes without a live connection and those changes meet other changes later. The hard part is not detecting that two writes happened. The hard part is choosing domain-correct semantics: should edits merge, should one win, should the user decide, or should the system create a new version?

The mental model is that offline-first applications have at least two logs: local intent and remote truth. While offline, the app records local operations. On reconnect, it exchanges state with the server, rebases or merges local operations, resolves conflicts, and updates the UI without pretending that every conflict is an error.

{{< mermaid >}}
flowchart TD
  A[User edits offline] --> B[Local operation log]
  C[Remote changes by others] --> D[Server state]
  B --> E[Reconnect sync]
  D --> E
  E --> F{Conflict?}
  F -->|no| G[Apply automatically]
  F -->|yes| H[Resolve by policy]
  H --> I[Persist merged result]
{{< /mermaid >}}

## Choose the unit of conflict

A common mistake is resolving conflicts at the record level when the domain needs field-level or operation-level resolution. If two users edit different fields of the same profile offline, record-level last-write-wins loses data. Field-level merge preserves both changes.

For ordered collections, the unit may be an operation: move card, insert paragraph, delete item, rename title. Operation-level sync can express intent better than overwriting an entire array.

```json
{ "op": "move_card", "cardId": "c7", "afterId": "c3", "clientId": "u1", "seq": 42 }
```

This operation survives many concurrent changes better than sending the whole column order as a replacement value.

## Resolution strategies

Last-write-wins is simple and sometimes correct for disposable preferences, read markers, or "last viewed at." It is risky for user-authored content because it silently discards concurrent work. If you use it, make the timestamp source explicit. Server timestamps avoid client clock skew but do not represent offline intent time. Hybrid logical clocks can help when ordering matters across replicas.

Field-level merge works well for independent fields. It fails when fields are coupled, such as `startDate` and `endDate`, or `subtotal`, `tax`, and `total`.

Operational transformation (OT) and CRDTs work for collaborative structures such as text and ordered lists, but they add metadata and algorithmic complexity.

Manual resolution is appropriate when the domain has no safe automatic rule. The UI should show both versions, explain the conflicting fields, and let the user choose or combine. Do not dump raw JSON on users unless the product is for developers.

## Local operation log

Store local operations durably before applying optimistic UI. IndexedDB is the usual browser storage choice. Each operation needs a stable id, client id, sequence number, base version or dependency information, payload, and status.

```js
const op = {
  id: crypto.randomUUID(),
  clientId,
  seq: nextSequence(),
  type: "rename_document",
  baseVersion: currentVersion,
  payload: { documentId, title },
  createdAt: Date.now(),
};
```

The server should process operations idempotently. If the client retries after a timeout, the same operation id must not apply twice.

## Sync flow

A robust sync loop pulls remote changes, pushes pending local operations, handles accepted/rejected/conflicted responses, and then pulls again if the push caused derived changes. Keep the loop resumable. A tab can close halfway through sync.

Use exponential backoff for network failures, but do not block local editing. Surface sync state clearly: saved, saving, offline, conflict, or failed. Users should know whether closing the tab risks unsynced work.

## UI patterns

For automatic merges, show subtle confirmation only when useful. For conflicts, be specific: "The title changed on another device while you were offline" is better than "sync failed."

Let users keep their local version, accept remote, or merge when the domain allows it. For destructive conflicts, preserve both versions. A duplicated note is better than silent data loss.

## Failure modes

Client clocks are unreliable. Do not let clock skew decide important conflicts without safeguards.

Deletes need special handling. If one user deletes a record while another edits it offline, you need a policy: resurrect, discard edit, create copy, or ask. Tombstones help clients learn that an item was deleted instead of assuming it never existed.

Schema migrations can break pending offline operations. Version operation payloads and write migration code for queued operations, or force sync before applying breaking migrations.

Multiple tabs can create duplicate client sequences. Coordinate through IndexedDB transactions, BroadcastChannel, or a single shared worker if sequence ordering matters.

## Diagnostics

Build a sync debug view for developers and support. It should show client id, last pulled version, pending operation count, failed operations, retry time, and conflict details. Log operation ids on both client and server so a user report can be traced end to end.

Test with deterministic scenarios: edit same field offline, edit different fields offline, delete versus edit, reorder same list concurrently, retry after server timeout, and reconnect with duplicate operations.

## Server contracts

The server API should make conflict outcomes explicit. A vague `409 Conflict` with no machine-readable body pushes too much logic into guesswork. Return the current server version, the rejected operation id, the conflicting fields or operations, and the resolution options the client is allowed to offer.

For accepted operations, return the committed version and any canonicalized data. The client can then replace optimistic placeholders, clear pending operations, and advance its local checkpoint. This makes sync auditable and keeps the UI from inventing state the server did not accept.

## Checklist

- Define conflict units: record, field, operation, or document structure.
- Avoid last-write-wins for valuable user-authored content unless explicitly acceptable.
- Store local operations durably with stable ids and client sequence.
- Make server operation handling idempotent.
- Treat deletes as tombstones or explicit conflict cases.
- Version offline operation payloads for migrations.
- Surface sync state and conflicts in user language.
- Test duplicate delivery, retries, reconnects, multi-tab editing, and clock skew.
