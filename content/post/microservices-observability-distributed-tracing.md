---
title: "Microservices Observability: Distributed Tracing"
date: 2026-04-28T15:42:11-04:00
draft: false
featured: false
tags: [backend, observability, microservices, tracing, opentelemetry]
---

## The Problem With Logs in a Microservice World

In a monolith, a single request executes inside one process. When something goes wrong you grep one log file, follow the stack trace, and you are done. Decompose that monolith into thirty services and a single user click might fan out across a dozen processes, three message queues, and two databases. The log lines for that one request are now scattered across a dozen machines, interleaved with thousands of other requests, with no thread of continuity between them.

**Distributed tracing** restores that thread. It reconstructs the full causal path of a single request as it travels across service boundaries, giving you a timeline of every operation, how long each took, and where it failed. This post covers the data model behind tracing, how context propagation actually works, sampling strategies, and how OpenTelemetry ties it together.

## The Trace Data Model: Traces and Spans

The two core primitives are the **trace** and the **span**.

- A **span** represents a single unit of work — an HTTP handler, a database query, a queue publish. It has a name, a start time, a duration, a set of attributes (key-value tags), and a status.
- A **trace** is a tree of spans that share a common `trace_id`, representing one end-to-end request.

Spans form a parent-child hierarchy via `parent_span_id`. The first span in a trace — the one with no parent — is the **root span**.

```json
{
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "parent_span_id": "0000000000000000",
  "name": "GET /checkout",
  "start_time": "2026-04-28T15:42:11.001Z",
  "duration_ms": 412,
  "attributes": {
    "http.method": "GET",
    "http.status_code": 200,
    "service.name": "api-gateway"
  },
  "status": "OK"
}
```

A downstream call inside that request produces a child span sharing the same `trace_id` but a fresh `span_id`, with `parent_span_id` pointing at the caller.

{{< mermaid >}}
graph TD
  A["span: GET /checkout<br/>(api-gateway) 412ms"] --> B["span: validate-cart<br/>(cart-svc) 38ms"]
  A --> C["span: charge-card<br/>(payment-svc) 290ms"]
  C --> D["span: POST /authorize<br/>(stripe-client) 270ms"]
  A --> E["span: reserve-stock<br/>(inventory-svc) 51ms"]
  E --> F["span: UPDATE inventory<br/>(postgres) 22ms"]
{{< /mermaid >}}

That tree immediately tells you the request spent most of its 412 ms inside the payment service's external call. No log grep required.

## Context Propagation: The Hard Part

The magic question is: how does `payment-svc` know it belongs to the same trace as `api-gateway`? The answer is **context propagation** — passing the trace identifiers across the network with every call.

The industry standard is the W3C **Trace Context** specification, which defines the `traceparent` HTTP header:

```text
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ^  ^                                ^                ^
          version  trace-id (16 bytes)        parent span-id  trace-flags
```

The flow on every hop is:

1. **Extract** the `traceparent` from the incoming request headers.
2. If present, the incoming `span-id` becomes the new span's parent. If absent, start a new trace (this caller is the root).
3. Create a new span for the local work.
4. **Inject** the updated `traceparent` (carrying *this* span's id) into the headers of any outbound calls.

```python
def handle_request(incoming_headers):
    ctx = extract(incoming_headers)          # read traceparent
    with tracer.start_span("charge-card", parent=ctx) as span:
        span.set_attribute("amount", 49.99)
        outbound = {}
        inject(outbound, span.context())     # write traceparent
        resp = http.post("https://stripe/authorize", headers=outbound)
        span.set_attribute("http.status_code", resp.status)
```

The same extract/inject dance applies to non-HTTP transports. For Kafka or RabbitMQ, the context rides in message headers; for gRPC, in metadata. The propagation is **out-of-band** from your business payload — your application data never carries trace IDs, the transport layer does.

A subtle but important case is **queue-based async work**. When a producer publishes a message and a consumer processes it later, you preserve causality with a *span link* rather than a strict parent-child edge, because the consumer span may start long after the producer span ended.

## Sampling: You Cannot Trace Everything

A high-traffic system generates millions of spans per second. Storing all of them is prohibitively expensive and rarely useful. **Sampling** decides which traces to keep. There are two fundamental strategies.

### Head-Based Sampling

The decision is made at the **root span**, before the request executes, and propagated downstream via the `trace-flags` bit in `traceparent`. Every service honors the root's decision, so a trace is either fully kept or fully dropped — no broken traces.

```python
def should_sample(trace_id, rate=0.01):
    # Deterministic: same trace_id always yields same decision,
    # so all services agree without coordination.
    return (int(trace_id[-8:], 16) / 0xFFFFFFFF) < rate
```

The downside: the decision is made *before* you know whether the request was interesting. A 1% sample rate will discard 99% of your rare, slow, error-producing requests.

### Tail-Based Sampling

The decision is deferred until the **entire trace is complete**, made by a collector that buffers all spans for a trace and then decides. This lets you keep traces based on outcome — every error, every request over 500 ms, a small random baseline of the rest.

| Strategy | Decision point | Pros | Cons |
|----------|---------------|------|------|
| Head-based | Root span start | Cheap, stateless, no broken traces | Blind to outcomes; misses rare errors |
| Tail-based | After trace completes | Captures errors & slow traces | Needs buffering, more memory & infra |

Most mature setups run **head-based with a low rate plus tail-based for errors and latency outliers**, getting cheap baseline coverage and guaranteed capture of the traces that matter.

{{< mermaid >}}
graph TD
  A["Request arrives"] --> B{"Head sampler:<br/>keep?"}
  B -- "Yes" --> C["Emit all spans"]
  B -- "No" --> D["Still emit if<br/>error/slow"]
  C --> E["Collector buffers trace"]
  D --> E
  E --> F{"Tail policy:<br/>error or >500ms?"}
  F -- "Yes" --> G["Store trace"]
  F -- "No, baseline" --> H["Store 1% sample"]
  F -- "No" --> I["Drop"]
{{< /mermaid >}}

## OpenTelemetry: The Unifying Standard

Before OpenTelemetry (OTel), every vendor had its own SDK and wire format, locking you in. OTel is a vendor-neutral specification and set of SDKs that emit traces, metrics, and logs in a common format (OTLP). The architecture has three layers:

1. **SDK / Instrumentation** — libraries in your service that create spans. Auto-instrumentation hooks common frameworks (HTTP servers, DB drivers) so you get spans with minimal code; manual instrumentation adds business-specific spans.
2. **Collector** — a standalone process that receives spans, processes them (batching, tail sampling, attribute scrubbing), and exports them. Decoupling export from your app means you can swap backends without touching service code.
3. **Backend** — Jaeger, Tempo, Honeycomb, or any OTLP-compatible store and UI.

```yaml
# otel-collector minimal pipeline
receivers:
  otlp:
    protocols:
      grpc:
processors:
  batch:
  tail_sampling:
    policies:
      - name: errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow
        type: latency
        latency: { threshold_ms: 500 }
exporters:
  otlp/tempo:
    endpoint: tempo:4317
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [tail_sampling, batch]
      exporters: [otlp/tempo]
```

## The Three Pillars, Correlated

Tracing is most powerful when correlated with the other two observability signals. The trick is shared identifiers.

| Signal | Question it answers | Correlation key |
|--------|--------------------|-----------------|
| Metrics | Is something wrong? (aggregate) | service + time |
| Traces | Where is it slow / failing? | `trace_id` |
| Logs | What exactly happened? | `trace_id` in log line |

If every log line your services emit includes the active `trace_id`, then from a single slow trace in Jaeger you can pivot directly to the exact log lines emitted during that request — across all services. Exemplars take this further by linking spikes in a latency histogram metric to representative traces.

## Practical Pitfalls

- **Cardinality explosions.** Putting unbounded values (user IDs, full URLs with query strings) into span attributes can overwhelm your backend's index. Use bounded, low-cardinality attribute *keys*; high-cardinality values are fine in traces but disastrous in metric labels.
- **Missing propagation.** A single service that forgets to forward `traceparent` breaks the trace tree downstream of it. Auto-instrumentation prevents most of these gaps.
- **Clock skew.** Span timings come from each host's clock; skew across machines can make a child span appear to start before its parent. Rely on durations and causal ordering, not absolute cross-host timestamps.
- **Over-instrumentation.** A span per loop iteration produces thousands of useless spans. Trace meaningful boundaries — service calls, DB queries, external APIs.

## Closing Thought

Distributed tracing is not a luxury once you cross a handful of services; it is the only way to reason about latency and failure in a system where no single process sees the whole request. Get three things right — propagate context on every hop, sample intelligently so you keep the traces that matter, and correlate traces with logs via a shared `trace_id` — and a system that was previously a black box becomes a request you can read top to bottom.
