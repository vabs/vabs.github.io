---
title: "HTTP/2 Multiplexing and HPACK"
date: 2026-01-05T11:25:00-04:00
draft: false
featured: false
tags: [backend, http2, networking, performance, protocols]
---

## The problem HTTP/2 set out to solve

HTTP/1.1 has a structural flaw: a single TCP connection can carry only one request-response exchange at a time. The connection processes requests strictly in order. If the first response is slow, everything behind it waits. This is head-of-line blocking at the application layer, and it is brutal for modern pages that pull dozens or hundreds of resources.

Browsers worked around it by opening six or more parallel connections per origin. That helps, but each connection has its own TCP slow start, its own congestion window, and its own setup cost, and the browser still runs out of connections long before it runs out of resources to fetch. Sharding assets across multiple domains to get more connections was a common, ugly hack.

HTTP/2 replaces all of that with one connection that carries many concurrent streams. It does this by introducing a binary framing layer underneath HTTP semantics. The methods, headers, and status codes you know stay the same; how they travel on the wire changes completely.

## The binary framing layer

Everything in HTTP/2 is a frame. A frame has a fixed 9-byte header followed by a payload.

```text
+-----------------------------------------------+
| Length (24 bits)                              |
+---------------+---------------+---------------+
| Type (8)      | Flags (8)     |
+-+-------------+---------------+-------------------------------+
|R| Stream Identifier (31 bits)                                |
+=+=============================================================+
| Frame Payload (Length bytes)                                 |
+--------------------------------------------------------------+
```

The most important frame types:

| Frame | Purpose |
|-------|---------|
| HEADERS | Carries an HTTP header block (request or response headers) |
| DATA | Carries the message body |
| SETTINGS | Connection-level configuration exchange |
| WINDOW_UPDATE | Flow control credit |
| RST_STREAM | Abruptly terminate one stream |
| PRIORITY | Express dependency and weight for a stream |
| PUSH_PROMISE | Server announces a resource it will push |
| GOAWAY | Graceful connection shutdown |
| PING | Liveness and RTT measurement |

The crucial field is the **stream identifier**. Every frame belongs to a stream, identified by an integer. The client uses odd-numbered stream IDs, the server uses even-numbered ones, and IDs only increase.

## How multiplexing actually works

A stream is an independent, bidirectional sequence of frames within the connection. Because every frame is tagged with its stream ID, the sender can interleave frames from many streams arbitrarily, and the receiver can demultiplex them back into separate logical messages.

{{< mermaid >}}
sequenceDiagram
    participant C as Client
    participant S as Server
    C->>S: HEADERS (stream 1) GET /index.html
    C->>S: HEADERS (stream 3) GET /style.css
    C->>S: HEADERS (stream 5) GET /app.js
    S->>C: HEADERS (stream 1) 200 OK
    S->>C: HEADERS (stream 5) 200 OK
    S->>C: DATA (stream 5) chunk
    S->>C: DATA (stream 1) chunk
    S->>C: HEADERS (stream 3) 200 OK
    S->>C: DATA (stream 3) chunk
    S->>C: DATA (stream 1) chunk
{{< /mermaid >}}

Notice that the server interleaves DATA frames from streams 1, 3, and 5 in whatever order it likes. A slow response on stream 1 no longer blocks streams 3 and 5, because their frames can be sent in the gaps. This eliminates application-layer head-of-line blocking, which is the entire point.

Each stream moves through a lifecycle:

{{< mermaid >}}
stateDiagram-v2
    [*] --> idle
    idle --> open: send/recv HEADERS
    open --> half_closed_local: send END_STREAM
    open --> half_closed_remote: recv END_STREAM
    half_closed_local --> closed: recv END_STREAM
    half_closed_remote --> closed: send END_STREAM
    open --> closed: RST_STREAM
    closed --> [*]
{{< /mermaid >}}

### Flow control

With many streams sharing one connection, a single fast producer could overwhelm a slow consumer. HTTP/2 adds credit-based flow control at two levels: per-stream and per-connection. The receiver advertises an initial window via SETTINGS, and every DATA frame consumes window. The receiver issues WINDOW_UPDATE frames to grant more credit as it processes data. A sender that exhausts the window must stop sending DATA on that stream until credited again. Tuning these windows is one of the more impactful HTTP/2 server tuning knobs; default windows are often too small for high-BDP links.

### Prioritization

Not all resources are equal. CSS blocks rendering; a tracking pixel does not. HTTP/2 lets a client express a dependency tree with weights so the server knows which streams to favor when bandwidth is scarce. In practice the original priority scheme proved hard to implement well, and many servers ignored it, which is part of why HTTP/3 replaced it with a simpler model. Still, on the connection it remains the mechanism for hinting urgency.

## HPACK: compressing headers without leaking secrets

Multiplexing solves the body-transfer problem, but headers are their own problem. HTTP headers are verbose and extremely repetitive. Every request to a site repeats the same `user-agent`, `accept`, `cookie`, and host. On a page with 100 requests, you might send the same multi-kilobyte cookie 100 times. HTTP/1.1 sent all of it as plain text every time.

The obvious fix is generic compression like gzip, and HTTP/1 sometimes did that for bodies. But applying stream compression to headers across requests created the CRIME attack: by observing compressed sizes, an attacker who could inject content could infer secret header values like session cookies. HPACK (RFC 7541) is a header compression format designed specifically to be efficient while resisting this class of attack.

HPACK has three mechanisms working together.

### 1. The static table

A fixed, predefined table of 61 common header entries, shared by every connection. Entry 2 is `:method: GET`. Entry 8 is `:status: 200`. Instead of spelling out `:method: GET`, the encoder sends a single index referencing the static table.

```text
Static table (excerpt):
  2  :method        GET
  3  :method        POST
  8  :status        200
 16  accept-encoding gzip, deflate
 ...
```

### 2. The dynamic table

This is where the real savings come from. Each connection maintains a dynamic table that both endpoints update in sync. When the encoder sends a header that is not in the static table, it can instruct the decoder to insert that header into the dynamic table. On subsequent requests, that header can be referenced by index too.

So the first time you send your giant cookie, it goes on the wire literally, plus an instruction to remember it. Every request after that references it by a small index. The dynamic table is a sliding window bounded by a size limit (negotiated via SETTINGS); when it overflows, the oldest entries are evicted.

### 3. Huffman coding of literals

When a header value must be sent literally (not yet in any table), HPACK can encode the string using a static Huffman code optimized for the byte distribution of typical HTTP header characters, shrinking it further.

### How a header field is encoded

Each header field in a HEADERS frame is one of a few representations:

| Representation | Meaning |
|----------------|---------|
| Indexed | Both name and value are in a table; send just the index |
| Literal with incremental indexing | Send the value; add to dynamic table for reuse |
| Literal without indexing | Send the value; do not store (one-off) |
| Literal never indexed | Send the value; never store, never let proxies store |

The "never indexed" representation is the security-conscious one. Sensitive headers (a password in a header, certain auth tokens) can be marked so they are never placed in the dynamic table, which prevents their compressed-size from varying with attacker-controlled input. This, combined with the fact that HPACK only references entries the peer already explicitly inserted (rather than doing free-form back-references over a mixed buffer of secret and attacker data), is what closes the CRIME-style hole.

## Why HPACK forces strict ordering on the connection

There is a subtle and important consequence of the dynamic table. Because the decoder's table state depends on processing HEADERS frames in the exact order the encoder sent them, HEADERS frames cannot be reordered relative to each other. The dynamic table is shared connection state, and a reference by index only makes sense against the table as it existed at that moment.

This means that while DATA frames of different streams interleave freely, the header-compression context is a single serialized state machine. Over TCP this is fine, because TCP delivers bytes in order anyway. But it becomes a real constraint when you move to independent streams. This is precisely why HTTP/3 had to invent QPACK: it redesigns the dynamic table so that header decoding does not require strict cross-stream ordering, avoiding head-of-line blocking when each stream can arrive independently.

## Putting it together

```text
One TCP + TLS connection
  ├── Stream 1: HEADERS (HPACK-compressed) + DATA frames
  ├── Stream 3: HEADERS + DATA          interleaved by frame
  ├── Stream 5: HEADERS + DATA
  └── shared:   SETTINGS, WINDOW_UPDATE, PING, GOAWAY
```

HTTP/2's two big wins are mechanically distinct but mutually reinforcing. Multiplexing lets one connection carry many concurrent exchanges without head-of-line blocking at the message level, which removes the need for connection sharding. HPACK collapses the redundant, bulky header traffic that multiplexing would otherwise multiply, using a static plus dynamic table model that was carefully designed to avoid leaking secrets through compression side channels. The cost is that HPACK's stateful dynamic table reintroduces an ordering dependency on the connection, a tension that HTTP/3 resolves by moving transport to QUIC and header compression to QPACK.
