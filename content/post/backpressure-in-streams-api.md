---
title: "Backpressure in streams API"
date: 2026-03-23T10:05:00-04:00
draft: false
tags: [frontend, streams, backpressure, browser-api, performance]
---

Backpressure is the mechanism that prevents a fast producer from overwhelming a slow consumer. In the browser Streams API, it is the difference between a pipeline that stays bounded and a pipeline that quietly buffers unbounded data until memory, latency, or responsiveness collapses. If you stream fetch responses, generate client-side exports, transform large files, or bridge WebSockets into streams, you need to understand where pressure is applied.

The mental model is a queue with a desired size. A `ReadableStream` has an internal queue. A consumer reads from it. A producer enqueues into it. When the queue reaches its high water mark, `controller.desiredSize` becomes zero or negative, and a well-behaved producer slows down.

{{< mermaid >}}
flowchart TD
  A[Producer] --> B{desiredSize > 0?}
  B -->|yes| C[enqueue chunk]
  B -->|no| D[pause or await pull]
  C --> E[Internal queue]
  E --> F[Consumer read]
  F --> G[Queue drains]
  G --> B
{{< /mermaid >}}

## Readable stream pressure

When you construct a `ReadableStream`, the `pull` callback is called when the stream wants more data. This is the easiest way to respect backpressure because the stream asks only when its queue has capacity.

```js
const stream = new ReadableStream({
  async pull(controller) {
    const chunk = await source.read();
    if (chunk.done) {
      controller.close();
    } else {
      controller.enqueue(chunk.value);
    }
  },
});
```

By contrast, a producer that loops and enqueues without checking pressure can fill memory:

```js
// Risky for large sources.
for (const chunk of hugeSource) {
  controller.enqueue(chunk);
}
```

If your source is push-based, such as a WebSocket, you may need an adapter that pauses the source, drops messages by policy, or closes the connection when the consumer cannot keep up. The Streams API cannot magically slow every external producer.

## Writable stream pressure

For `WritableStream`, the writer exposes `writer.ready`. Await it before writing more when you are producing chunks manually.

```js
const writer = writable.getWriter();
try {
  for await (const chunk of input) {
    await writer.ready;
    await writer.write(chunk);
  }
  await writer.close();
} finally {
  writer.releaseLock();
}
```

`writer.write()` itself returns a promise that reflects the sink's progress. Awaiting it is often the simplest conservative approach. Awaiting `ready` lets you know when the queue is below the high water mark.

## Transform streams

`TransformStream` sits between readable and writable sides. Backpressure propagates through `pipeThrough()` and `pipeTo()` when the pipeline is built from standard streams.

```js
await response.body
  .pipeThrough(new DecompressionStream("gzip"))
  .pipeThrough(parseRecords())
  .pipeTo(renderSink(), { signal });
```

If a transform expands data, such as parsing one compressed chunk into thousands of rows, it must be careful not to enqueue too much synchronously. Chunk output and yield when needed.

## Queuing strategies

The high water mark defines how much data can queue before pressure is applied. The `size()` function defines how a chunk contributes to queue size.

```js
const stream = new ReadableStream(source, {
  highWaterMark: 64 * 1024,
  size(chunk) {
    return chunk.byteLength;
  },
});
```

For byte streams, size by bytes. For object streams, size by item count or estimated cost. A queue of 100 tiny status messages is not the same as a queue of 100 image frames.

## UI as a slow consumer

Rendering is often the slowest sink. Streaming 10,000 rows into state as quickly as they arrive can create a backlog on the main thread even if the network stream is well-behaved. Use batching, virtualization, and frame-based flushing.

```js
function renderSink() {
  let batch = [];
  return new WritableStream({
    write(row) {
      batch.push(row);
      if (batch.length >= 100) {
        const rows = batch;
        batch = [];
        return new Promise((resolve) => {
          requestAnimationFrame(() => {
            appendRows(rows);
            resolve();
          });
        });
      }
    },
    close() {
      if (batch.length) appendRows(batch);
    },
  });
}
```

Returning a promise from `write` is how the sink communicates that it is busy.

## Failure modes

The biggest failure mode is bridging push APIs without a policy. WebSocket messages, `postMessage` events, and sensor callbacks may continue arriving after the stream queue is full. Decide whether to buffer, drop oldest, drop newest, aggregate, or close.

Another mistake is ignoring cancellation. If downstream cancels, upstream should stop reading, close files, abort fetches, or unsubscribe from events. Implement `cancel()` in custom readable streams and `abort()` in writable streams.

Finally, do not set huge high water marks to hide pressure. That converts a flow-control problem into a memory problem and increases latency because old chunks sit in queues.

## Diagnostics

Log queue depth proxies: `desiredSize`, pending batch length, time spent in `write`, and memory growth during long streams. If latency grows over time, the consumer is slower than the producer. If memory grows while `desiredSize` is negative, a producer is ignoring pressure.

Use DevTools Performance traces to see whether the sink is CPU-bound. Network backpressure will not fix a render loop that blocks the main thread.

## Browser integrations

Fetch response bodies already participate in stream backpressure. If your code stops reading, the browser can stop pulling from lower layers or buffer less aggressively. The exact network behavior depends on protocol and implementation, but your JavaScript should still express demand correctly by reading only when ready.

Compression, decoding, and parsing transforms can hide pressure if they buffer internally. When adding a custom transform, test with a slow sink and a large input. Memory should remain bounded, and cancellation should stop upstream work quickly. A transform that reads the entire input before emitting output is not streaming, even if it returns a `ReadableStream`.

## Checklist

- Prefer `pull()`-driven readable streams for sources you control.
- Await `writer.write()` or `writer.ready` when manually writing.
- Size queues by bytes or realistic object cost.
- Return promises from slow `WritableStream.write` methods.
- Define a policy for push sources that cannot be paused.
- Propagate cancellation upstream.
- Avoid large high water marks as a substitute for flow control.
- Monitor latency and memory during long-running streams.
