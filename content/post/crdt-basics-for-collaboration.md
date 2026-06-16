---
title: "CRDT basics for collaboration"
date: 2026-04-18T09:00:00-04:00
draft: false
tags: [frontend, crdt, collaboration, offline-first, distributed-systems]
---

CRDTs are data structures designed so replicas can accept local changes independently, exchange updates later, and converge without a central conflict resolver. In frontend collaboration, that means a user can type, move a card, toggle a checkbox, or edit metadata while disconnected, then sync with other clients without losing concurrent work. The tradeoff is that the conflict policy moves into the data type itself.

The mental model is convergence by construction. A CRDT does not avoid conflicts by preventing concurrent edits. It defines merge behavior so concurrent edits have deterministic meaning.

{{< mermaid >}}
flowchart TD
  A[Replica A local edit] --> D[Sync updates]
  B[Replica B local edit] --> D
  C[Replica C offline edit] --> D
  D --> E[CRDT merge]
  E --> F[Same logical state on all replicas]
{{< /mermaid >}}

## State-based and operation-based CRDTs

State-based CRDTs send state and merge it with a join operation that is commutative, associative, and idempotent. That means merge order and duplicate delivery do not matter.

Operation-based CRDTs send operations. They can be more bandwidth-efficient, but they require stronger delivery assumptions, usually causal delivery and deduplication depending on the design.

Frontend libraries often hide this distinction behind document updates. You still need to understand the implications: state sync can be larger, operation sync can be more sensitive to missing history, and both need metadata.

## Simple examples

A grow-only counter stores one count per replica. Each replica increments only its own slot. Merge takes the maximum count per replica. The value is the sum.

```js
function mergeCounter(a, b) {
  const out = { ...a };
  for (const [replica, value] of Object.entries(b)) {
    out[replica] = Math.max(out[replica] ?? 0, value);
  }
  return out;
}
```

A last-write-wins register is sometimes called a CRDT when timestamps are unique and ordered, but it is a dangerous default for collaboration. It converges by discarding one concurrent value. That may be fine for "last selected theme" and unacceptable for "paragraph text."

For sets, add/remove semantics are policy choices. An observed-remove set removes only the adds it has seen, so a concurrent add can survive a remove. A remove-wins set chooses the opposite. Neither is universally correct.

## Text collaboration

Text CRDTs need stable positions that survive concurrent insertion and deletion. Plain array indexes do not work because two users can insert at index 5 concurrently. CRDT text structures assign identifiers to characters or spans so ordering can be merged deterministically.

The implementation details are complex: identifier growth, tombstones, compaction, formatting marks, undo semantics, and awareness state. Most teams should use a proven library rather than inventing a text CRDT. The engineering work is integrating it with persistence, presence, permissions, and rendering.

## Frontend architecture

A practical collaborative editor has local state, a CRDT document, a transport, persistence, and derived UI state. Keep those separate. The CRDT document is the source of shared truth. UI state such as open panels, selection, hover, and unsent notifications usually should not be part of the durable document.

Presence is often not a CRDT. Cursor positions and online indicators are ephemeral awareness messages. They should expire if a client disconnects.

```js
doc.transact(() => {
  sharedMap.set("title", nextTitle);
  sharedText.insert(index, text);
});

transport.send(encodeUpdate(doc));
```

Batch related edits into transactions when the library supports it. This improves undo behavior and reduces update overhead.

## Offline and sync

Offline support requires durable local storage of document updates and a replica/client id that remains stable across reloads. If a client generates a new identity every session, metadata can grow and undo/presence semantics can become confusing.

On reconnect, sync must handle duplicates, out-of-order updates, and partial delivery. CRDT updates are designed for this, but your transport and persistence still need idempotency. Store update ids or use the library's state vector mechanisms.

## Failure modes

Metadata growth is the classic CRDT cost. Deletes often leave tombstones or version metadata so other replicas can understand what happened. Long-lived documents need compaction or snapshot strategies provided by the library.

Undo is not just "apply inverse operation." In collaborative editing, a local undo should usually undo the user's own last logical action without deleting another user's concurrent work. Use library-level undo managers where available.

Authorization is easy to overlook. If clients can submit arbitrary CRDT updates, the server must still enforce document access and possibly validate operation shape. CRDT convergence is not a security boundary.

## Debugging

Build tooling to inspect replica id, document version vector or state vector, pending local updates, last sync time, and update queue length. Many collaboration bugs are not rendering bugs; they are missing update, duplicate identity, or persistence bugs.

Create deterministic tests with two or three replicas. Apply operations in different orders and assert convergence. Include disconnect/reconnect and duplicate delivery cases.

## Persistence model

Do not persist only the rendered JSON view if the CRDT library needs its internal metadata to merge future updates. Store snapshots in the library's native format, plus incremental updates when that is the recommended model. Periodically compact incremental updates into a snapshot so startup does not replay thousands of tiny records.

On the server, treat the document update log as append-only until compaction. This makes retries and audit easier. After compaction, keep enough version information for clients that reconnect with old state to ask for either incremental updates or a fresh snapshot.

## Checklist

- Pick conflict semantics per field, not one global policy.
- Use established CRDT libraries for text and rich documents.
- Separate durable shared document state from ephemeral presence.
- Persist local updates and stable replica identity for offline use.
- Make sync idempotent and tolerant of out-of-order delivery.
- Plan for metadata growth, snapshots, and compaction.
- Use CRDT-aware undo, not naive inverse operations.
- Test convergence with multiple delivery orders and duplicate updates.
