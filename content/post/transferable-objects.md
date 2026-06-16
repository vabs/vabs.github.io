---
title: "Transferable objects"
date: 2026-01-29T09:00:00-04:00
draft: false
tags: [frontend, workers, transferable-objects, performance, structured-clone]
---

Transferable objects are the difference between "send this data to a Worker" and "move ownership of this memory to a Worker." That distinction is critical for large binary payloads. Structured cloning copies data. Transferring detaches the object from the sender and makes the receiver the owner, avoiding a large copy on the hot path.

The mental model is move semantics for browser concurrency. After transfer, the sender's buffer is intentionally unusable. That can feel surprising in JavaScript because most values are shared by reference or copied by value, but it is exactly what makes transfer cheap.

{{< mermaid >}}
flowchart LR
  A[Main thread ArrayBuffer] -->|postMessage without transfer| B[Clone: second buffer]
  C[Main thread ArrayBuffer] -->|postMessage with transfer list| D[Worker owns same backing store]
  C -. detached .-> X[byteLength becomes 0]
{{< /mermaid >}}

## What can transfer

Common transferable objects include `ArrayBuffer`, `MessagePort`, `ImageBitmap`, `OffscreenCanvas`, and streams in modern browsers. Typed arrays themselves are not the transferable resource; their underlying `buffer` is. If you have a `Uint8Array`, transfer `view.buffer`, then reconstruct a view on the receiving side.

```js
const bytes = new Uint8Array(largePayload);
worker.postMessage(
  { type: "process", buffer: bytes.buffer, length: bytes.byteLength },
  [bytes.buffer],
);
```

After this call, `bytes.byteLength` may be zero because its buffer is detached. Code that logs, retries, or hashes the payload after posting will break unless it intentionally keeps another copy.

## Practical patterns

Use transfer when the sender no longer needs the data. Image decoding, file parsing, compression, audio analysis, and WebAssembly input pipelines are good candidates. For request/response flows, the Worker can transfer the result buffer back to the main thread.

Design functions around ownership. A name like `sendToWorker(bytes)` is ambiguous; `transferToWorker(bytes)` tells callers not to reuse the argument. In TypeScript, you can wrap this with a small domain object and invalidate it after transfer to make accidental reuse obvious during tests.

For repeated work, use a buffer pool. The main thread transfers a buffer to the Worker, the Worker fills or processes it, then transfers it back. This avoids constant allocation and garbage collection while preserving single-owner semantics.

```js
// Worker
self.onmessage = async (event) => {
  const { buffer } = event.data;
  const view = new Uint8Array(buffer);
  transformInPlace(view);
  self.postMessage({ buffer }, [buffer]);
};
```

For typed-array views, preserve offset and length. A view can start in the middle of a larger buffer. If the receiver blindly reconstructs `new Uint8Array(buffer)`, it may process bytes outside the intended range. Include `byteOffset` and `byteLength` when the view is not known to cover the entire buffer.

```js
worker.postMessage({
  buffer: view.buffer,
  byteOffset: view.byteOffset,
  byteLength: view.byteLength,
}, [view.buffer]);
```

On the receiving side:

```js
const bytes = new Uint8Array(buffer, byteOffset, byteLength);
```

If the backing buffer contains unrelated or sensitive bytes, do not transfer it. Copy the visible range into a tightly sized `ArrayBuffer` first. That copy costs time, but it enforces data minimization and avoids giving a Worker more than it needs.

Use `MessageChannel` when ownership should move between two non-parent contexts. A main thread can create ports, transfer one to a Worker, and use the other for a dedicated protocol. This keeps high-volume binary messages away from a shared global worker handler and makes cancellation or teardown easier.

For canvas and image pipelines, `ImageBitmap` and `OffscreenCanvas` can remove expensive main-thread work. Decode or draw on the appropriate side, transfer the object once, and keep the rendering contract simple. The best performance win often comes from avoiding a round trip of pixel buffers through JavaScript entirely.

## Protocol design

A transfer-based protocol should make ownership visible in the message type. Include an operation id, buffer metadata, and a response path. If the sender may cancel work, define whether cancellation returns the buffer, discards it, or lets the Worker finish and transfer a result later. Ambiguous ownership during cancellation is a common source of detached-buffer bugs.

```js
worker.postMessage({
  type: "decode",
  id,
  input: { buffer, byteLength },
}, [buffer]);
```

Pair every transfer with a lifecycle state in the caller: `available`, `transferred`, `processing`, `returned`, or `disposed`. In plain JavaScript this can be a small wrapper object. In TypeScript, a discriminated union makes it harder to accidentally read a transferred buffer in a retry path.

Retries need special handling. Once a buffer has been transferred, the original sender cannot retry with the same object. Either keep a separate source of truth, ask the Worker to transfer the buffer back on failure, or design the operation so retries happen inside the Worker while it still owns the memory.

## Failure modes

The most common bug is using the detached buffer after transfer. Symptoms include `byteLength` becoming `0`, typed-array reads returning nothing useful, or downstream code failing far away from the `postMessage` call. Add assertions immediately after transfer in development if ownership is unclear.

Another failure is accidentally copying by omitting the transfer list. `postMessage({ buffer })` and `postMessage({ buffer }, [buffer])` are not equivalent. The first clones. The second transfers. This is easy to miss in code review because the payload object looks identical.

Transferring the wrong buffer can also leak unrelated bytes. A `Uint8Array` slice may reference a larger `ArrayBuffer` than its visible range. If you transfer `view.buffer`, the receiver gets the whole backing store. When handling sensitive or user-provided data, create a tightly sized buffer or include explicit offset and length and enforce them.

Another failure is assuming transfer guarantees faster end-to-end behavior. If the Worker immediately clones the data into another library, converts it to strings, or posts a copied result back, the transfer only optimizes one boundary. Inspect the entire pipeline: input acquisition, transfer, processing, result construction, result transfer, and rendering.

Browser support and object-specific behavior also matter. `ArrayBuffer` transfer is widely supported, but newer transferable streams or platform objects may vary by browser and context. Feature-detect the exact path you intend to use and provide a fallback that copies only when the payload size makes that acceptable.

## Diagnostics

Measure before and after with realistic payloads. Use Performance marks around serialization boundaries, not only Worker compute. In Chrome DevTools, inspect main-thread long tasks and memory allocations. A successful transfer usually reduces copy time and allocation pressure, but it may not help if the Worker immediately creates multiple derived copies.

Log `buffer.byteLength` at send and receive points during development. If a buffer is expected to transfer, the sender should be detached and the receiver should see the original length. If both sides can read full data, you probably cloned.

Add protocol assertions in development:

```js
function assertDetached(buffer) {
  if (buffer.byteLength !== 0) {
    throw new Error("Expected buffer to be transferred");
  }
}
```

Use that only for paths where transfer is mandatory. Some fallbacks intentionally clone. Name the metric accordingly, such as `worker.decode.transferMode = "transfer" | "clone"`, so performance reports explain which path ran.

When tracking memory, watch for retained views. A detached view is small, but closures that keep large pre-transfer sources, file blobs, decoded images, or result copies can still create pressure. Transfer solves one copy; it does not automatically make the surrounding pipeline streaming or leak-free.

## Checklist

- Transfer only when the sender is done with the data.
- Always pass the transfer list as the second `postMessage` argument.
- Transfer `typedArray.buffer`, then reconstruct views.
- Watch for slices backed by larger buffers.
- Name APIs to communicate ownership transfer.
- Use buffer pools for repeated high-volume work.
