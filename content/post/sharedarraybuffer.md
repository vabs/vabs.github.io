---
title: "SharedArrayBuffer"
date: 2026-02-09T09:00:00-04:00
draft: false
tags: [frontend, sharedarraybuffer, workers, concurrency, atomics]
---

`SharedArrayBuffer` gives multiple JavaScript agents access to the same memory. Unlike transferable `ArrayBuffer`, ownership does not move. The main thread and Workers can observe and modify shared bytes concurrently. That makes it powerful for low-latency coordination and dangerous when treated like ordinary JavaScript state.

The mental model is shared memory plus explicit synchronization. Reads and writes through typed arrays are not a message protocol. If one thread writes data and another reads it, you need a way to define when the data is ready. In browser JavaScript, that synchronization is the `Atomics` API over integer typed arrays.

{{< mermaid >}}
flowchart TD
  SAB[SharedArrayBuffer]
  Main[Main thread] -->|Int32Array view| SAB
  W1[Worker A] -->|Uint8Array view| SAB
  W2[Worker B] -->|Int32Array view| SAB
  W1 -->|Atomics.store/notify| SAB
  W2 -->|Atomics.wait/load| SAB
{{< /mermaid >}}

## Security prerequisites

Modern browsers require cross-origin isolation before enabling `SharedArrayBuffer` in normal web pages. That means serving with headers such as `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` or an equivalent credentialless strategy. Every subresource must also cooperate. A single third-party script, image, or iframe without compatible headers can break isolation.

This requirement is not incidental. Shared memory made high-resolution timing attacks easier, so browsers gate it behind an isolation boundary. Before designing around SAB, verify `crossOriginIsolated === true` in the deployed environment, not only locally.

## Practical patterns

The best use cases are narrow: audio processing, WebAssembly threads, low-latency data feeds, shared ring buffers, and compute pipelines where copying is too expensive. A common structure is a data region plus a small control region:

- `Int32Array` control slots for write index, read index, state, and sequence.
- `Uint8Array` or domain-specific views for payload bytes.
- `Atomics.store` to publish state.
- `Atomics.load`, `Atomics.wait`, or polling to consume state.

Use a ring buffer when producer and consumer run at different rates. The producer writes bytes, advances a write index with `Atomics.store`, and notifies. The consumer reads until it catches up, then waits. Keep indexes monotonic and apply modulo only when addressing the backing array; this makes overflow and lag easier to reason about.

Separate payload memory from synchronization memory. A typical design uses one `SharedArrayBuffer` for bytes and a small `SharedArrayBuffer` or reserved prefix for `Int32Array` control slots. Only integer typed arrays can be used with the main `Atomics` operations, so the control plane should be `Int32Array` or `BigInt64Array` where supported.

```js
const control = new Int32Array(new SharedArrayBuffer(4 * 4));
const WRITE_INDEX = 0;
const READ_INDEX = 1;
const STATE = 2;
const SEQUENCE = 3;
```

Publish data in two steps: write payload bytes first, then publish the new state with `Atomics.store` and `Atomics.notify`. Consumers read the state with `Atomics.load` before reading payload. The atomic control write creates the synchronization point; the payload writes become meaningful because the protocol says they are complete before the state changes.

Backpressure must be explicit. If the producer catches the consumer, choose a policy: block in a Worker, drop oldest data, drop newest data, grow a separate queue, or signal overflow. Audio may prefer dropping data to blocking. Financial or editing data may require lossless backpressure. Do not let the producer silently overwrite unread bytes unless the domain can tolerate it.

Shutdown is part of the protocol. Add a state such as `CLOSED` or `ERROR`, store an error code or sequence, and notify waiters. Without this, Workers can wait forever after a page navigates, a stream fails, or a producer is terminated.

## Failure modes

The first failure mode is assuming normal writes are enough. Without Atomics, another agent may observe stale or partially published state. Use Atomics for coordination variables even if the payload itself is written with normal typed-array operations.

The second is blocking the wrong agent. `Atomics.wait` is not allowed on the main thread in browsers. Workers can block; the UI thread should use messages, polling, or `Atomics.waitAsync` where supported.

The third is cross-origin isolation breaking after a product change. Adding analytics, an embedded widget, or an unheadered CDN asset can silently disable SAB. Put an automated check in your diagnostics page or smoke tests.

Data races are harder to debug than message bugs because there is no event log by default. Add sequence numbers, state transitions, and invariant checks. For example, assert that the consumer never reads beyond the published write index and that the producer never overwrites unread data.

False sharing can hurt performance. If multiple hot control variables sit next to each other, different agents may invalidate the same cache line repeatedly. JavaScript does not expose cache-line control directly, but you can pad control regions by leaving unused slots between heavily contended indexes when profiling shows contention.

Do not use SAB as a general application store. Shared mutable state across UI and Workers is harder to reason about than messages, and most frontend state does not need nanosecond-level coordination. Keep shared memory behind a small module with domain-specific operations. The rest of the app should not know which byte offset represents which concept.

Security headers can fail in non-obvious ways. `COEP: require-corp` means cross-origin resources must opt in with CORS or CORP. Fonts, images, scripts, iframes, and analytics tags can break isolation. `COEP: credentialless` can help for some no-credentials subresources, but it changes request credential behavior. Test the exact deployment topology.

## Debugging and diagnostics

Start with a single-producer, single-consumer design. Log control slots in a compact table: read index, write index, capacity, available bytes, and sequence. If the numbers make no sense, fix the protocol before tuning performance.

Use small buffers in tests to force wraparound. Large buffers hide boundary bugs. Add stress tests that vary producer and consumer speed. If a ring buffer works only when both sides run at the same rate, it is not correct.

When using WebAssembly threads, separate toolchain issues from isolation issues. Confirm headers, `crossOriginIsolated`, browser support, and Wasm thread flags before investigating application code.

Add invariant checks that can be compiled out or disabled in production:

```js
function assertRing(read, write, capacity) {
  if (write < read) throw new Error("write index moved backwards");
  if (write - read > capacity) throw new Error("producer overran consumer");
}
```

Use deterministic stress tests. Start Workers with seeded delays, small capacities, forced wraparound, and repeated open/close cycles. Race bugs often appear only when the buffer is nearly full, the consumer wakes late, or shutdown happens while data is in flight.

For header diagnostics, log a single startup line with `crossOriginIsolated`, `self.SharedArrayBuffer` availability, worker creation success, and the selected fallback. That prevents vague bug reports like "threads are slow" when the page actually fell back to copying because isolation was unavailable.

## Checklist

- Confirm cross-origin isolation in the deployed page.
- Use SAB only when copying or message latency is a proven bottleneck.
- Coordinate with `Atomics`; do not rely on ordinary shared writes.
- Never block the main thread with `Atomics.wait`.
- Model shared memory as a protocol with explicit states.
- Test wraparound, backpressure, and shutdown paths.
