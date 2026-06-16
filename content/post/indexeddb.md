---
title: "IndexedDB"
date: 2026-01-22T09:30:00-05:00
draft: false
tags: [frontend, indexeddb, storage, offline-first, browser-internals]
---

## IndexedDB is a transactional object store

IndexedDB is the browser's built-in durable database for structured client data. It is not localStorage with promises. It is closer to a small transactional database with object stores, indexes, versioned schema upgrades, structured cloning, and browser-managed quota. The API looks unusual because it predates promises and because transactions are tied to the event loop.

{{< mermaid >}}
graph TD
  App["application code"] --> DB["IDBDatabase connection"]
  DB --> Tx["transaction: readonly/readwrite"]
  Tx --> Store["object store"]
  Store --> Record["structured cloned records"]
  Store --> Index["secondary indexes"]
  Index --> Cursor["range scans and cursors"]
{{< /mermaid >}}

The core mental model: open a database at a numeric version, create stores and indexes only during upgrade, then do all reads and writes inside transactions. Transactions auto-commit when their request queue drains and the current task finishes.

## Schema and upgrades

Schema changes happen in `onupgradeneeded`. That event is the only place you can call `createObjectStore`, `deleteObjectStore`, `createIndex`, or `deleteIndex`.

```js
const request = indexedDB.open("notes", 3);

request.onupgradeneeded = () => {
  const db = request.result;
  if (!db.objectStoreNames.contains("notes")) {
    const store = db.createObjectStore("notes", { keyPath: "id" });
    store.createIndex("by_updated_at", "updatedAt");
  }
};
```

The subtle part is blocking. If one tab holds an old connection open, another tab trying to upgrade waits. The old tab receives `versionchange`; if it does not close its connection, the new version is blocked.

Always handle it:

```js
db.onversionchange = () => {
  db.close();
  location.reload();
};
```

Without this, migrations appear to hang only for users with long-lived tabs.

## Transactions and the event loop trap

An IndexedDB transaction remains active while you enqueue requests synchronously or from request callbacks. It does not stay alive across arbitrary `await`s. This is the classic failure mode:

```js
const tx = db.transaction("notes", "readwrite");
const store = tx.objectStore("notes");
await fetch("/something"); // transaction may become inactive
store.put(note);           // TransactionInactiveError
```

Do network work before opening the transaction, or collect data first and then perform a tight set of IDB operations. If using a wrapper like `idb`, the same underlying transaction lifetime rules still apply.

## Data modeling patterns

Use object stores for aggregate roots, not for every tiny relational table you would create server-side. For an offline notes app, `notes`, `outbox`, and `metadata` are often enough. Keep server IDs, local IDs, sync status, and update timestamps explicit.

Indexes are materialized lookup structures. They speed reads but add write cost and migration complexity. Add indexes for real query paths: by account, by updated time, by sync status. Do not create indexes for every field "just in case."

Cursor scans are useful when you need ordered pagination or batched processing:

```js
const range = IDBKeyRange.lowerBound(lastSeenUpdatedAt, true);
const req = store.index("by_updated_at").openCursor(range);
```

Avoid reading a large store into memory with `getAll()` unless the result set is bounded. It structured-clones every record into JS heap.

Design keys around the queries you actually run. A store with `keyPath: "id"` is fine for direct lookup, but sync engines often need compound keys such as `[accountId, updatedAt]` or `[syncStatus, updatedAt]`. IndexedDB supports compound indexes, and they are usually cleaner than encoding multiple fields into strings. Use `IDBKeyRange.bound()` for page windows and store the last key from the cursor for stable pagination.

Keep records plain and versionable. Structured clone preserves objects, arrays, dates, blobs, and typed arrays, but class methods and prototypes are not a durable schema. Store data in a format you can migrate. Add a `schemaVersion` or domain version inside important records when the shape may evolve independently of the database version. Database upgrades migrate stores; record versions let you lazily migrate old records as they are read.

## Offline sync pattern

Most serious IndexedDB apps eventually need an outbox. The user changes local state in one transaction and appends a sync operation in the same transaction. A background sync loop later reads pending operations, sends them to the server with idempotency keys, and marks them committed or conflicted. This keeps the UI responsive and makes reloads safe.

```js
const tx = db.transaction(["notes", "outbox"], "readwrite");
tx.objectStore("notes").put({ ...note, syncStatus: "pending" });
tx.objectStore("outbox").add({
  id: crypto.randomUUID(),
  type: "note.update",
  noteId: note.id,
  payload: note,
  createdAt: Date.now()
});
```

The server response should reconcile versions, not merely clear the flag. If the server canonicalizes content or rejects a stale update, update the local aggregate and outbox state together. If sync fails due to network, keep the operation pending. If it fails due to validation or conflict, expose that state to the user instead of retrying forever.

Multi-tab coordination matters. Two tabs can open the same database, read the same pending work, and try to sync it. Use operation ids, server idempotency, and a lightweight local lease if duplicate sends are costly. BroadcastChannel can notify other tabs after commits, but it is not a locking primitive by itself.

## Durability and quota

Browsers can evict origin storage under pressure, especially for non-persistent storage. Use `navigator.storage.persist()` for serious offline apps, but treat it as a request, not a guarantee. Monitor `navigator.storage.estimate()` for rough usage.

Large blobs can be stored, but that does not make IndexedDB a CDN. Blob-heavy stores increase backup, cloning, and eviction pain. For generated media, consider the Cache API for response-like assets and IndexedDB for metadata.

## Failure modes

`Blocked` upgrades mean old tabs still hold connections. Add `versionchange` handlers and visible reload prompts.

`DataCloneError` means the value cannot be structured-cloned. Functions, DOM nodes, and some class instances are not valid records. Store plain data.

`QuotaExceededError` means the origin crossed browser storage limits or device pressure. Provide cleanup policies before the error becomes unrecoverable.

Slow UI after reads often means you are cloning too much. Add indexes, page cursor results, or move heavy processing to a worker.

## Diagnostics

Chrome DevTools Application -> IndexedDB shows stores and records, but it is not a substitute for logging transaction boundaries. Instrument open version, upgrade old/new versions, transaction mode, store names, and request errors. Every request can fail independently; always attach error handling at the transaction boundary.

## Checklist

- Keep migrations deterministic and incremental by version.
- Close old connections on `versionchange`.
- Do not `await` unrelated async work inside active transactions.
- Add indexes only for known query paths.
- Bound `getAll()` calls.
- Plan quota cleanup and export/recovery for valuable local data.

IndexedDB rewards database thinking. Model the few local aggregates you actually need, keep transactions short, and design upgrades as a multi-tab protocol.
