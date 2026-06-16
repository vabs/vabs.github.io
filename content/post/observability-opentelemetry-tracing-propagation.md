---
title: "Observability: OpenTelemetry Tracing Propagation"
date: 2026-02-24T13:50:00-04:00
draft: false
tags: [backend, observability, opentelemetry, tracing, distributed-systems]
---

## Mental model

In a monolith, a stack trace tells you the whole story of a request. In a distributed system, one user action might touch a gateway, three services, a queue, and two databases — across different processes, machines, and languages. A stack trace in any one of them shows only a fragment. Distributed tracing reassembles the fragments into a single coherent picture of the request's journey.

The unit of that picture is the **trace**: a tree of **spans**, where each span represents one operation (an HTTP handler, a DB query, a queue publish) with a start time, duration, attributes, and a link to its parent. The magic that lets spans created in five different processes belong to one tree is **context propagation** — passing the trace identity across every process boundary the request crosses.

OpenTelemetry (OTel) is the vendor-neutral standard for producing this telemetry: an API, an SDK, and a wire format. Get propagation right and you get end-to-end traces for free; get it wrong and you get a pile of disconnected single-process spans that tell you almost nothing.

{{< mermaid >}}
graph TD
    T["Trace (one request)"] --> S1["Span: API gateway"]
    S1 --> S2["Span: orders service"]
    S2 --> S3["Span: DB query"]
    S2 --> S4["Span: publish to queue"]
    S4 --> S5["Span: worker (different process)"]
    S5 --> S6["Span: payment service"]
{{< /mermaid >}}

## Spans and the trace tree

Every span carries a **SpanContext**, the minimal identity that must travel between processes:

- **trace_id** — 16 bytes, identical for every span in the whole trace.
- **span_id** — 8 bytes, unique to this span.
- **trace_flags** — 1 byte; the low bit is the *sampled* flag.
- **trace_state** — vendor-specific key/values.

A child span records its parent's `span_id` as `parent_span_id` and copies the `trace_id`. That parent/child linkage is the entire structure of the tree. When a span is created in a *new process*, it learns its parent's `trace_id` and `span_id` not from memory but from the **incoming request's headers** — that is propagation.

```python
from opentelemetry import trace

tracer = trace.get_tracer("orders")

def handle_order(req):
    with tracer.start_as_current_span("handle_order") as span:
        span.set_attribute("order.id", req.id)
        span.set_attribute("order.total", req.total)
        validate(req)          # child spans auto-parent to this one
        charge(req)
```

## In-process propagation: the Context

Within a single process, OTel tracks the "current span" using a **Context** object stored in a context-local mechanism (thread-locals, async-locals, Go's `context.Context`). When you start a new span, the SDK reads the current context to find the parent automatically — that's why nested `start_as_current_span` calls form a tree without you wiring parents manually.

The classic in-process failure is losing the context across an async hop or a thread-pool boundary. If you hand work to a background thread without carrying the context, the new thread sees an empty context and starts a fresh root span — a detached subtree. In Go you must pass `ctx` explicitly; in async runtimes you must use context-propagating executors.

```go
// Go: context carries the span; pass it everywhere
ctx, span := tracer.Start(ctx, "handle_order")
defer span.End()

// WRONG: new goroutine without ctx -> orphan span
go process(req)

// RIGHT: pass ctx so the child span links correctly
go process(ctx, req)
```

## Cross-process propagation: W3C Trace Context

The hard boundary is between processes. OTel's default standard for HTTP is **W3C Trace Context**, which serializes the SpanContext into two headers.

The `traceparent` header packs version, trace_id, parent span_id, and flags:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ^  ^                                ^                ^
          version  trace_id (16 bytes hex)   span_id (8 bytes)  flags (01=sampled)
```

The optional `tracestate` carries vendor data:

```
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

A **propagator** is the component that *injects* these headers when making an outbound call and *extracts* them when receiving an inbound one. With auto-instrumentation, this happens transparently: the HTTP client instrumentation injects `traceparent` on every outbound request, and the server instrumentation extracts it and uses it as the parent of the server span.

{{< mermaid >}}
sequenceDiagram
    participant A as "Service A"
    participant B as "Service B"
    A->>A: "start span (trace_id=T, span=S1)"
    A->>B: "HTTP GET /pay\ntraceparent: 00-T-S1-01"
    B->>B: "extract -> parent = S1, trace = T"
    B->>B: "start span (trace_id=T, span=S2, parent=S1)"
    B-->>A: "response"
    A->>A: "end span S1"
{{< /mermaid >}}

Because B reads `traceparent` and uses `S1` as its parent, B's spans join A's trace. Drop the header anywhere and the chain breaks: B starts a brand-new trace and the connection between the two services is lost forever.

## Propagation across non-HTTP boundaries

HTTP is the easy case. Real systems also cross message queues, gRPC metadata, and database calls. The same principle applies — inject the context into whatever carrier the transport offers.

| Boundary | Carrier for traceparent |
|----------|-------------------------|
| HTTP | request headers |
| gRPC | metadata |
| Kafka / RabbitMQ | message headers |
| Cloud Pub/Sub | message attributes |
| Cron / batch | often a fresh root (no inbound parent) |

For asynchronous messaging the producer injects context into the message headers when publishing, and the consumer extracts it when processing. Because the consume happens later (and possibly in a different service), OTel models this with **span links** rather than strict parent/child, since the producing span may have already ended. This preserves causality even when there is no live parent.

```python
# producer: inject context into the outgoing message
from opentelemetry.propagate import inject
headers = {}
inject(headers)                       # writes traceparent into headers
queue.publish(body, headers=headers)

# consumer: extract it back into a context
from opentelemetry.propagate import extract
ctx = extract(message.headers)
with tracer.start_as_current_span("process_msg", context=ctx):
    process(message)
```

## Sampling: the flag travels too

Tracing every request is expensive at scale, so most systems **sample**. The crucial detail is that the sampling decision must be *consistent across the whole trace* — you do not want service A to record its span but service B to drop its part of the same request. That's what the sampled bit in `trace_flags` is for: the head service decides, and the decision propagates downstream via `traceparent`. Every service honors the incoming flag.

There are two broad strategies:

- **Head-based sampling.** Decide at the start of the trace (e.g. keep 5% randomly, deterministically by trace_id). Cheap and simple, but you decide before you know whether the request was interesting (errored, slow). You may sample away exactly the traces you needed.
- **Tail-based sampling.** Buffer all spans of a trace (usually in the Collector) and decide *after* it completes, keeping all errors and slow traces. Captures the interesting tails but requires holding spans in memory and is more operationally complex.

Deterministic head sampling on `trace_id` is the common default because it guarantees the whole trace agrees without any coordination.

## The architecture: SDK and Collector

OTel separates *producing* telemetry from *exporting* it. Your app uses the OTel SDK to create spans and ships them — typically via the OTLP protocol — to an **OpenTelemetry Collector**, a standalone process that receives, processes (batching, attribute scrubbing, tail sampling), and exports to one or more backends (Jaeger, Tempo, a vendor).

```
[App + SDK] --OTLP--> [Collector] --> [Tracing backend]
                          |---------> [Metrics backend]
```

This indirection matters: the Collector lets you change backends, redact PII, enrich attributes, and apply tail sampling *without redeploying every service*. Apps just speak OTLP to the local Collector.

## Common ways traces break

- **Missing propagator config.** If injection/extraction isn't wired (or two services use different propagator formats — W3C vs B3), the header isn't read and traces fragment. Standardize on W3C Trace Context everywhere.
- **Manual HTTP clients.** Hand-rolled clients that bypass instrumentation won't inject `traceparent`. Use instrumented clients or inject manually.
- **Context lost across async/threads.** The number-one in-process bug. Propagate context into every executor, goroutine, and callback.
- **A non-propagating proxy or gateway.** A middlebox that strips unknown headers silently kills traces. Allowlist `traceparent`/`tracestate`.
- **Inconsistent sampling.** If a service makes its own independent sampling decision instead of honoring the incoming flag, traces come out half-recorded.

## Takeaways

Distributed tracing turns a request's scattered, per-process fragments into one tree, and the thing that makes the tree possible is context propagation. In-process, the current span lives in a context-local that you must carry across every async and thread boundary. Across processes, the SpanContext rides in headers — `traceparent`/`tracestate` for W3C Trace Context — injected on the way out and extracted on the way in by propagators, with the same pattern applied to queues and RPC metadata. The sampled flag travels with it so the entire trace agrees on whether to be recorded. Route everything through a Collector so you can sample, scrub, and re-target backends centrally. When traces fragment, the cause is almost always a dropped header or a lost in-process context — fix those two and end-to-end visibility falls out for free.
