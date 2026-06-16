---
title: "Streaming fetch response handling"
date: 2026-03-03T09:55:00-05:00
draft: false
tags: [frontend, fetch, streams, networking, performance]
---

Streaming fetch response handling lets a page process bytes as they arrive instead of waiting for the entire response body. That changes the user experience for large payloads, AI responses, logs, exports, media metadata, and progressive data formats. It also changes failure handling: once you process partial data, you need explicit rules for incomplete messages, cancellation, decoding, and backpressure.

The mental model is that `fetch()` resolves when response headers are available, not when the body is fully downloaded. The `Response.body` is a `ReadableStream<Uint8Array>`. You consume chunks from that stream, decode bytes into text if needed, parse message boundaries, and update UI incrementally.

{{< mermaid >}}
flowchart TD
  A[fetch request] --> B[Headers received]
  B --> C[ReadableStream body]
  C --> D[Uint8Array chunks]
  D --> E[TextDecoderStream]
  E --> F[Message parser]
  F --> G[Incremental UI update]
{{< /mermaid >}}

## Basic stream consumption

The lowest-level pattern uses a reader:

```js
const response = await fetch("/api/logs");
if (!response.ok || !response.body) {
  throw new Error(`Request failed: ${response.status}`);
}

const reader = response.body.getReader();
try {
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    handleBytes(value);
  }
} finally {
  reader.releaseLock();
}
```

For text, use streaming decoding. Do not call `new TextDecoder().decode(chunk)` without `{ stream: true }` unless you are sure characters never span chunks. UTF-8 characters can be split across network chunks.

```js
const decoder = new TextDecoder();
let text = "";

while (true) {
  const { value, done } = await reader.read();
  if (done) break;
  text += decoder.decode(value, { stream: true });
}
text += decoder.decode();
```

Where supported, `TextDecoderStream` makes this cleaner:

```js
const stream = response.body.pipeThrough(new TextDecoderStream());
for await (const chunk of stream) {
  appendText(chunk);
}
```

## Parsing message boundaries

Chunks are transport boundaries, not application messages. A JSON object, line, or server-sent event can be split across chunks or multiple messages can arrive in one chunk. Always buffer until your application delimiter is complete.

```js
let buffer = "";

for await (const chunk of response.body.pipeThrough(new TextDecoderStream())) {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (line.trim()) handleMessage(JSON.parse(line));
  }
}

if (buffer.trim()) {
  throw new Error("Stream ended with incomplete JSON line");
}
```

Newline-delimited JSON is easier to stream than a giant JSON array because each line is independently parseable. If you control the API, choose a streaming-friendly format.

## Updating the UI

Incremental data can create too many renders. If every chunk calls `setState`, the main thread can spend more time rendering than reading. Buffer UI updates and flush them on animation frames or small intervals.

```js
let pending = [];
let scheduled = false;

function enqueueRows(rows) {
  pending.push(...rows);
  if (!scheduled) {
    scheduled = true;
    requestAnimationFrame(() => {
      scheduled = false;
      commitRows(pending);
      pending = [];
    });
  }
}
```

For very large streams, combine incremental rendering with virtualization. Streaming data into a non-virtualized table still creates a DOM scalability problem.

## Cancellation

Users navigate away, change filters, close dialogs, and retry. Streaming code must be cancellable. Use `AbortController` with `fetch`, and handle abort as a normal outcome rather than an error alert.

```js
const controller = new AbortController();
const response = await fetch("/api/search", { signal: controller.signal });

// later
controller.abort();
```

Also cancel any reader loop when the owning component unmounts. If you pipe through transform streams, propagate cancellation and close resources in `finally`.

## Failure modes

A response can fail before headers, after headers, or mid-body. HTTP status is only available after headers. Mid-stream failures appear as read errors or premature termination. Your UI should represent partial data honestly: "loaded 230 rows before the connection dropped" is different from success.

Compression can affect streaming. Some intermediaries buffer compressed responses, and some server frameworks buffer output unless explicitly configured to flush. If chunks arrive all at once in production, inspect response headers, proxy buffering, server flush behavior, and CDN settings.

The browser may not expose a body stream for opaque responses, older environments, or certain request modes. Feature-detect `response.body`.

## Diagnostics

Use the Network panel to verify chunk timing. A waterfall that completes only at the end may indicate server buffering. Add server-side timestamps inside the stream to distinguish network buffering from slow generation.

Log parser state during development: buffer length, messages parsed, and last successful offset. Most streaming bugs are boundary bugs, not fetch bugs.

## Security and resource limits

Streaming does not remove the need for limits. A malicious or broken endpoint can send an endless stream, one gigantic line, or many small messages that keep the page busy forever. Put caps on buffered text, message size, total processed records, and stream duration. Abort when a limit is exceeded and show a recoverable error.

```js
const maxBuffer = 1024 * 1024;

buffer += chunk;
if (buffer.length > maxBuffer) {
  controller.abort(new Error("stream buffer limit exceeded"));
  throw new Error("Response stream exceeded parser buffer limit");
}
```

If streamed content is rendered as HTML, sanitize at the message boundary before committing it to the DOM. Incremental rendering can otherwise turn one parsing bug into many small injection points.

## Backpressure and transforms

Streams are useful because they can express backpressure, but only if each layer respects it. A parser that reads as fast as possible and pushes every message into an array can still outrun the UI. Prefer transform streams or async generators that process one message at a time, await downstream work when necessary, and stop reading when the user cancels.

For CPU-heavy parsing, move work off the main thread or batch it carefully. A streaming response that parses 50,000 records on the main thread can still freeze the page even though bytes arrive incrementally. The network is no longer the bottleneck; parsing and rendering are.

## Protocol design

If you own the server, include message types and sequence numbers. Types let the client distinguish data, progress, warnings, and final summaries. Sequence numbers make it easier to detect missing or duplicated messages after reconnects. A final completion message is often better than treating end-of-stream as success because it lets the server report counts and checksums before closing.

Design reconnection deliberately. Some streams are one-shot exports where retry starts over. Others are event feeds where the client can resume from the last event id. The UI should know which model it is using so it does not accidentally duplicate rows or hide partial failure.

## Checklist

- Remember that `fetch()` resolves at headers, not full body completion.
- Decode text with streaming semantics.
- Parse application message boundaries separately from network chunks.
- Batch UI updates to avoid render storms.
- Use streaming-friendly formats such as NDJSON for incremental data.
- Wire `AbortController` into every user-cancellable stream.
- Distinguish header failures, mid-stream failures, and incomplete final messages.
- Check server, proxy, CDN, and compression buffering when streaming appears delayed.
