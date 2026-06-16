---
title: "Log Aggregation with Sampling"
date: 2026-03-06T16:18:00-04:00
draft: false
tags: [backend, logging, observability, sampling, distributed-systems]
---

## Why aggregate, and why sample

A single modern service can emit tens of thousands of log lines per second. Multiply that across a fleet of hundreds of instances and you are producing terabytes per day. Log aggregation is the practice of shipping all of that from individual machines into a central store — Loki, Elasticsearch, a cloud log service — where it can be searched, correlated, and retained. The aggregation part is well understood. The harder question is economic: do you actually need to store every line?

For most systems the answer is no. The marginal value of the ten-millionth identical "request handled successfully" line is essentially zero, yet it costs the same to ingest, index, and store as a rare stack trace that would tell you exactly why a customer's payment failed. *Sampling* is how you keep the signal while shedding the redundant bulk. Done well, it cuts ingestion cost by an order of magnitude while preserving your ability to debug. Done badly, it throws away the one log line you needed.

This post covers the aggregation pipeline, the sampling strategies that fit into it, and the trade-offs that decide which strategy you should reach for.

## The aggregation pipeline

A typical pipeline has four stages: the application emits structured logs, a local agent collects and buffers them, a forwarding layer applies processing and sampling, and a backend stores and indexes them.

{{< mermaid >}}
graph LR
    A["Application stdout / file"] --> B["Node agent: tail and buffer"]
    B --> C["Forwarder: parse, enrich, sample"]
    C --> D["Backend store and index"]
    D --> E["Query and dashboards"]
{{< /mermaid >}}

Each stage is a place where you can drop, transform, or sample data. Where you choose to sample has real consequences. Sampling at the application has the lowest cost (you never pay to serialize or ship the dropped line) but the least context. Sampling in the forwarder has full context (you can see the whole event, even correlate across lines) but you have already paid the network cost to get it there. Sampling at the backend is the most expensive of all because you have paid for everything up to ingestion.

The general principle: **sample as early as possible for volume, but as late as possible for decisions that need context.** These pull in opposite directions, which is why mature systems use more than one technique.

## Structured logs are a prerequisite

You cannot sample intelligently on unstructured text. Sampling decisions depend on fields — severity, status code, route, tenant, trace ID — and those must be machine-readable. Emit JSON or another structured format from day one.

```json
{
  "ts": "2026-03-06T16:18:04.221Z",
  "level": "info",
  "service": "checkout",
  "route": "/cart/checkout",
  "status": 200,
  "latency_ms": 34,
  "trace_id": "a1b2c3d4e5f6",
  "msg": "order placed"
}
```

With this shape, a sampler can say "keep everything where `level >= warn`, keep everything where `status >= 500`, and keep 1 percent of the `status == 200` lines." That rule is impossible against a raw string blob without fragile regex parsing.

## Sampling strategies

### Head-based (rate) sampling

The simplest strategy: decide to keep or drop a line at the moment it is created, based on a fixed probability, before you know anything about how the request turns out. Keep 1 in N lines.

```go
func shouldSample(rate int) bool {
    // rate of 100 means keep ~1%
    return rand.Intn(rate) == 0
}

if level >= WARN || shouldSample(100) {
    logger.Emit(line)
}
```

Head sampling is cheap and stateless, which makes it ideal for high-volume, low-value lines like access logs on the happy path. Its weakness is that the decision is made blind. If you sample at the head and a request later errors, you may have already discarded the earlier log lines from that same request, leaving you with a stack trace and no context leading up to it.

### Tail-based sampling

Tail sampling defers the keep/drop decision until after the request (or trace) completes, when you know the outcome. You buffer all the lines for a request, and once it finishes you apply rules: if it errored or was slow, keep everything; if it was a fast success, keep a small sample or nothing.

```python
def decide(buffered_lines, trace):
    if trace.has_error or trace.latency_ms > 1000:
        return KEEP_ALL          # keep full context for the interesting cases
    if random.random() < 0.01:
        return KEEP_ALL          # a thin baseline of healthy requests
    return DROP
```

Tail sampling gives you the best of both worlds — full context for anomalies, tiny volume for the routine — but it requires buffering and the ability to group lines by request, which costs memory and adds latency to the decision. It is typically implemented in the forwarding layer or in a dedicated collector that can hold a request's worth of lines in memory until it sees the terminating event.

### Priority and severity-based sampling

A pragmatic middle ground: never sample errors and warnings, always keep them, and sample aggressively only at the `info` and `debug` levels. This is severity-based sampling, and it covers a huge fraction of real needs with almost no machinery.

| Level | Action | Typical keep rate |
|-------|--------|-------------------|
| error | always keep | 100% |
| warn | always keep | 100% |
| info | sample | 1–10% |
| debug | sample hard or drop | 0–1% |

### Adaptive (dynamic) sampling

Fixed rates are wrong whenever traffic changes. A 1 percent rate that yields a comfortable volume at midnight can overwhelm your backend during a flash sale. Adaptive sampling adjusts the rate to hit a target throughput — say, 5,000 lines per second per service — regardless of input volume. When traffic spikes, the keep rate automatically drops; when traffic is quiet, you keep more.

A common implementation keeps per-key counters (keyed by route or service) and computes a rate that would have produced the target volume over the last window, applying it to the next window. The effect is that rare keys are sampled lightly (you keep most of them) while firehose keys are sampled heavily, which naturally surfaces diversity.

### Consistent sampling by trace ID

In a distributed system a single request touches many services. If each service samples independently, you end up with fragments — service A kept its lines, service B dropped them, and the trace is full of holes. The fix is *consistent* sampling: every service makes the same keep/drop decision for a given request by hashing the shared trace ID.

```go
func keepByTrace(traceID string, rate uint64) bool {
    h := fnv64a(traceID)
    // Same traceID -> same result everywhere, no coordination needed
    return h % rate == 0
}
```

Because the hash of the trace ID is identical on every node, all services either keep or drop in unison, and you get complete end-to-end logs for the sampled requests instead of a scattered mess.

## A combined decision flow

Real systems layer these strategies. The flow below shows a typical decision made per log line in the forwarder.

{{< mermaid >}}
graph TD
    A["Incoming log line"] --> B{"Level >= warn?"}
    B -- "Yes" --> K["Keep"]
    B -- "No" --> C{"Part of an errored trace?"}
    C -- "Yes" --> K
    C -- "No" --> D{"Consistent trace-ID hash selected?"}
    D -- "Yes" --> K
    D -- "No" --> E{"Adaptive rate budget available?"}
    E -- "Yes" --> K
    E -- "No" --> F["Drop"]
{{< /mermaid >}}

This pipeline keeps everything that matters (warnings, errors, full context for failed traces), keeps a consistent statistical baseline of healthy traffic, and sheds the rest under a volume budget.

## Preserving statistical accuracy

The moment you sample, you have to be careful about counting. If you keep 1 percent of `status == 200` lines and then count them, your dashboard will report 1 percent of the real traffic. The fix is to record the sampling rate on each kept line and *upweight* during aggregation.

```json
{ "msg": "order placed", "status": 200, "sample_rate": 100 }
```

When you compute a count, sum `sample_rate` instead of counting rows: a line that survived 1-in-100 sampling represents roughly 100 real events. This keeps aggregate metrics accurate even though you stored a fraction of the data. Without it, every count, sum, and percentile derived from sampled logs is silently wrong.

For percentiles and latency distributions, this matters even more. Naive sampling can distort the tail. Either compute latency metrics from a separate, unsampled metrics pipeline, or use weighted estimators that account for `sample_rate` when building the distribution.

## Configuration example

Here is what severity plus adaptive sampling looks like in a forwarder pipeline (illustrative, in a generic config style):

```yaml
pipeline:
  - parse:
      format: json
  - sample:
      # never drop these
      keep_if: "level == 'error' || level == 'warn' || status >= 500"
  - sample:
      # adaptive baseline for the rest, keyed by route
      strategy: adaptive
      key: route
      target_per_second: 200
      annotate_rate_as: sample_rate
  - export:
      backend: loki
```

## Trade-offs and pitfalls

| Concern | Risk if mishandled | Mitigation |
|---------|--------------------|------------|
| Dropped context | The one error line you needed was sampled out | Tail sampling; never sample warn/error |
| Skewed metrics | Counts and rates understate reality | Record and upweight by `sample_rate` |
| Trace fragmentation | Partial logs across services | Consistent trace-ID hashing |
| Cost spikes | Fixed rate overruns budget on traffic surge | Adaptive sampling to a target volume |
| Compliance | Audit or security logs must be complete | Exempt those streams from sampling entirely |

The compliance row deserves emphasis. Audit trails, security events, and anything legally required must be routed to a separate, unsampled pipeline. Sampling is a tool for operational telemetry, not for records you are obligated to keep. Mixing the two leads to a bad day in front of an auditor.

A subtler pitfall is sampling making rare events *look* rarer than they are. If a bug affects one in ten thousand requests and you sample at one percent, you may see it once a day instead of a hundred times, which can hide a real problem under the noise floor. This is exactly why error-biased and tail-based strategies exist: keep the rare and the failed at full fidelity, and only sample the abundant and the boring.

## Summary

Log aggregation centralizes telemetry; sampling makes it affordable at scale. The strongest pipelines do not pick one sampling strategy — they combine them: always keep warnings and errors, use consistent trace-ID hashing so distributed logs stay coherent, apply tail sampling to retain full context for failed or slow requests, and use adaptive rates to hold a steady volume budget through traffic swings. Throughout, structured logs make intelligent decisions possible, and recording the sampling rate keeps your aggregate metrics honest. Sample the abundant, keep the rare, and never sample what you are legally required to retain.
