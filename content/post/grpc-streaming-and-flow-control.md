---
title: "gRPC Streaming and Flow Control"
date: 2026-02-13T09:20:00-04:00
draft: false
tags: [backend, grpc, http2, streaming, flow-control]
---

## Mental model

gRPC is RPC semantics layered on top of HTTP/2. Every gRPC call is an HTTP/2 stream, and every message you send is a length-prefixed frame written into that stream. Once you internalize that mapping, streaming and flow control stop being magic: they are just HTTP/2 features that gRPC exposes through a friendlier API.

gRPC offers four call shapes. Unary is the classic request/response. Server streaming keeps the request single but lets the server push many messages. Client streaming reverses that. Bidirectional streaming opens both directions independently, which is the most powerful and the easiest to misuse.

The critical thing to understand is that a stream is not a queue with infinite buffer. HTTP/2 gives each stream and each connection a *flow-control window*, and gRPC sits on top of that window. If you ignore it, you get memory blowups, head-of-line stalls, and deadlocks that only show up under load.

{{< mermaid >}}
graph TD
    A["gRPC call"] --> B["HTTP/2 stream"]
    B --> C["Length-prefixed messages"]
    C --> D["HTTP/2 DATA frames"]
    D --> E["Per-stream flow window"]
    D --> F["Per-connection flow window"]
    E --> G["Backpressure to sender"]
    F --> G
{{< /mermaid >}}

## The four call types

| Type | Request | Response | Typical use |
|------|---------|----------|-------------|
| Unary | one | one | CRUD, lookups |
| Server streaming | one | many | feeds, large result sets, change notifications |
| Client streaming | many | one | uploads, telemetry batches |
| Bidirectional | many | many | chat, real-time sync, RPC tunnels |

A subtle point: in bidi streaming, the two directions are *not* synchronized. The client can send 100 messages before the server sends its first. There is no implicit request/response pairing. Any pairing you want is application-level protocol that you design yourself.

```protobuf
service Telemetry {
  // server streaming
  rpc Watch(WatchRequest) returns (stream Event);
  // client streaming
  rpc Upload(stream Sample) returns (UploadSummary);
  // bidirectional
  rpc Sync(stream ClientMsg) returns (stream ServerMsg);
}
```

## How a message becomes bytes

Each gRPC message is framed with a 5-byte prefix before the serialized protobuf payload: one byte for the compression flag and four bytes for the message length (big-endian uint32).

```
+--------+----------------+----------------------+
| 1 byte | 4 bytes        | N bytes              |
| compr. | message length | serialized protobuf  |
+--------+----------------+----------------------+
```

These framed bytes are written into HTTP/2 DATA frames. A single gRPC message can span multiple DATA frames, and a single DATA frame can carry parts of multiple small messages. The receiver reassembles using the length prefix. This is why a corrupt or truncated stream surfaces as a framing error rather than a protobuf parse error.

## Flow control: the part everyone skips

HTTP/2 flow control is credit-based. The receiver advertises a window size. The sender may transmit DATA bytes only up to the remaining window. As the receiver consumes data and is ready for more, it sends `WINDOW_UPDATE` frames to replenish credit. There are two windows that both apply simultaneously: a per-stream window and a per-connection window. The effective allowance is the minimum of the two.

{{< mermaid >}}
sequenceDiagram
    participant S as Sender (server stream)
    participant R as Receiver (client)
    R->>S: Initial window = 64KB
    S->>R: DATA 32KB (window now 32KB)
    S->>R: DATA 32KB (window now 0KB)
    Note over S: Blocked - no credit
    R->>R: App reads buffered data
    R->>S: WINDOW_UPDATE +64KB
    S->>R: DATA resumes
{{< /mermaid >}}

The headline consequence: **if the receiving application stops reading, the window drains to zero and the sender blocks.** That blocking is backpressure. It is a feature, not a bug. A well-behaved producer naturally slows to match the consumer.

The failure mode is when you defeat backpressure. If your server-streaming handler enqueues every message into an unbounded in-memory channel and a background goroutine drains it onto the wire, you have hidden the backpressure signal from your producer. The wire blocks, your channel grows, and you OOM.

### Default windows are small

The HTTP/2 spec default initial window is 65,535 bytes per stream. For high-throughput streaming over high-latency links this is far too small: the bandwidth-delay product can exceed the window, so the sender is forced to stall waiting for `WINDOW_UPDATE` round trips. Most gRPC implementations raise the defaults and many support a *BDP estimator* (dynamic window scaling) that grows the window automatically based on observed throughput and RTT.

```go
// Go server: enlarge windows to fixed sizes
// (note: in grpc-go, setting these disables the dynamic BDP estimator)
srv := grpc.NewServer(
    grpc.InitialWindowSize(1<<20),       // 1 MB per stream
    grpc.InitialConnWindowSize(1<<22),   // 4 MB per connection
)
```

If you set the per-stream window high but leave the connection window low, a single hot stream can starve every other stream on the same connection. Keep the connection window comfortably larger than a single stream window times your expected concurrent streams, or accept that the connection window is your global throttle.

## Reading the stream is mandatory

A recurring bug: client opens a bidi stream, sends requests, and never calls `Recv()` because it "only cares about sending." The server's responses accumulate in the transport receive buffer. Eventually the server's send window hits zero and the server-side `Send()` blocks. The server stops processing. Now neither side makes progress — a flow-control deadlock.

```go
// WRONG: send-only loop on a bidi stream
for _, m := range work {
    stream.Send(m)        // will eventually block forever
}

// RIGHT: drain responses concurrently even if you ignore them
go func() {
    for {
        if _, err := stream.Recv(); err != nil { return }
    }
}()
for _, m := range work {
    if err := stream.Send(m); err != nil { break }
}
stream.CloseSend()
```

The rule for bidi: **always have something reading each direction.** Even if you discard the messages, you must drain them so the window keeps replenishing.

## Backpressure design patterns

The cleanest streaming handlers write directly in the loop so the wire's blocking *is* your backpressure:

```go
func (s *server) Watch(req *pb.WatchRequest, stream pb.Telemetry_WatchServer) error {
    for ev := range s.source(req) {
        // Send blocks when the flow window is exhausted.
        // That blocking throttles s.source upstream. Good.
        if err := stream.Send(ev); err != nil {
            return err   // client gone or context cancelled
        }
    }
    return nil
}
```

When you must buffer (e.g. you fan in from multiple producers), use a *bounded* buffer and treat "buffer full" the same way the wire treats a closed window: block or shed load. Never use an unbounded queue between your producer and the gRPC `Send` call. The unbounded queue converts polite TCP backpressure into a memory leak.

| Pattern | Backpressure preserved? | Risk |
|---------|------------------------|------|
| Send directly in handler loop | Yes | Slow consumer slows producer (desired) |
| Bounded channel + drainer | Yes (when channel blocks) | Must size buffer for latency/throughput |
| Unbounded channel + drainer | No | OOM under slow consumer |
| Drop-on-full ring buffer | Partial (lossy) | Acceptable only for stale-tolerant data |

## Keepalive, deadlines, and half-closed streams

Long-lived streams need keepalive PINGs or intermediary proxies will silently drop idle connections. Configure both client and server keepalive, and configure the server's *enforcement policy* or it will close clients that ping too aggressively with `ENHANCE_YOUR_CALM`.

```go
// client keepalive
grpc.WithKeepaliveParams(keepalive.ClientParameters{
    Time:                30 * time.Second,
    Timeout:             10 * time.Second,
    PermitWithoutStream: true,
})
```

Deadlines propagate through context. A streaming RPC with a deadline will be cancelled mid-stream when the deadline passes; your handler sees `ctx.Done()` and `Send`/`Recv` start returning errors. Always select on `stream.Context().Done()` in long loops so you stop producing the moment the client gives up.

A stream can be *half-closed*: the client calls `CloseSend()` to signal "no more requests" while still receiving responses. This is normal in client-streaming and bidi flows. Do not treat the client's half-close as a full teardown — the server may still have responses to deliver.

## Debugging flow-control problems

When throughput is mysteriously capped or a stream hangs:

1. Check whether the application is actually reading the receiving side. A non-draining receiver is the most common cause.
2. Inspect window sizes. Small default windows over a high-RTT link cap you at `window / RTT` bytes per second regardless of bandwidth.
3. Look for an unbounded buffer between your producer and `Send`. Growing memory plus a stalled wire is the signature.
4. Verify connection-window vs stream-window sizing if one stream starves others.
5. Enable transport-level logging (`GODEBUG=http2debug=2` in Go) to watch `WINDOW_UPDATE` and DATA frames directly.

## Takeaways

gRPC streaming is HTTP/2 streaming with a serialization layer. Flow control is credit-based and operates on two windows at once; respecting it gives you free, correct backpressure. The two cardinal sins are never reading a direction of a bidi stream (deadlock) and hiding the wire's backpressure behind an unbounded buffer (OOM). Size your windows for your bandwidth-delay product, keep streams alive with keepalive, and always honor context cancellation in your loops. Do that and streaming gRPC scales cleanly to millions of concurrent long-lived calls.
