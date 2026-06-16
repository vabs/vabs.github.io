---
title: "Prometheus Metric Cardinality Explosion"
date: 2026-02-28T10:42:00-04:00
draft: false
tags: [backend, prometheus, observability, monitoring, time-series]
---

## What cardinality actually means

In Prometheus, a single metric name is not one thing. Every unique combination of label values produces a distinct time series, and each series is stored, indexed, and queried independently. The *cardinality* of a metric is the number of distinct label-value combinations it produces. A cardinality explosion happens when that number grows far beyond what the operator anticipated, usually because a label was attached to a value that has high or unbounded variety.

The danger is that cardinality is multiplicative. If you have a metric with three labels and each label has 10, 20, and 5 possible values, the worst-case series count is `10 * 20 * 5 = 1000`. Add one more label with even modest variety and the count balloons. The classic failure is putting an identifier such as `user_id`, `request_id`, `email`, or a full URL path into a label.

Consider this innocent-looking instrumentation:

```go
httpRequests := prometheus.NewCounterVec(
    prometheus.CounterOpts{
        Name: "http_requests_total",
        Help: "Total HTTP requests",
    },
    []string{"method", "status", "path"},
)

// Somewhere in a handler
httpRequests.WithLabelValues(r.Method, status, r.URL.Path).Inc()
```

The `path` label is the problem. If the application serves `/users/12345/profile`, every distinct user ID becomes a new path, and therefore a new time series. A site with a million users can generate millions of series from this one counter.

## How a single metric multiplies into millions

The series count for a metric is the product of the unique value counts of all its labels, bounded by the actual combinations observed. The table below shows how quickly things grow as you add labels with realistic variety.

| Labels | Distinct values each | Worst-case series |
|--------|----------------------|-------------------|
| method | 5 | 5 |
| method, status | 5, 8 | 40 |
| method, status, endpoint | 5, 8, 30 | 1,200 |
| method, status, endpoint, user_id | 5, 8, 30, 100k | 120,000,000 |

The first three rows are perfectly healthy. The fourth row, which differs only by adding one identifier label, produces 120 million potential series. In practice you will not hit the full Cartesian product because not every combination occurs, but the *active* series count still tracks the number of distinct users who made requests, which is more than enough to take down a Prometheus instance.

{{< mermaid >}}
graph TD
    A["Metric: http_requests_total"] --> B["Label set 1: method=GET, status=200, path=/home"]
    A --> C["Label set 2: method=GET, status=200, path=/users/1"]
    A --> D["Label set 3: method=GET, status=200, path=/users/2"]
    A --> E["Label set N: method=GET, status=200, path=/users/N"]
    B --> F["Stored as independent time series"]
    C --> F
    D --> F
    E --> F
    F --> G["Head block memory grows linearly with active series"]
{{< /mermaid >}}

## Why it hurts so much

Prometheus keeps an in-memory index and an in-memory representation of every *active* series in the head block. Each series carries a chunk buffer that holds recent samples before they are flushed to disk. As a rough rule of thumb, every active series costs somewhere between 1 and 4 KB of resident memory once you account for the inverted index, label strings, and chunk overhead.

The consequences compound:

- **Memory.** A million series can easily consume several gigabytes of RAM. Ten million can OOM-kill the process.
- **Ingestion slowdown.** Each scrape must look up or create series in the index. With a bloated index, scrapes take longer and may exceed the scrape timeout, producing gaps.
- **Query latency.** A query like `sum(rate(http_requests_total[5m]))` must touch every matching series. PromQL evaluation time scales with the number of series selected, so dashboards crawl.
- **WAL and compaction pressure.** The write-ahead log and the block compaction process both do more work, increasing disk I/O and recovery time after a restart.
- **Restart pain.** On startup Prometheus replays the WAL and rebuilds the head. A high-cardinality instance can take many minutes to become ready, during which you are blind.

The cruel part is that the cost is paid even for series that receive only a single sample. A user who hits an endpoint once, never to return, still creates a series that lingers until it goes stale (roughly five minutes after the last sample) and is eventually marked for removal. Churn — series that appear and disappear constantly — is in some ways worse than a stable high count, because it thrashes the index.

## Finding the offending metric

Prometheus exposes meta-metrics that let it watch itself. The first stop is `prometheus_tsdb_head_series`, which reports the total number of active series in the head block. Watch its trend over time.

To attribute cardinality to specific metric names, the TSDB status page at `/tsdb-status` (or the API `/api/v1/status/tsdb`) lists the top series by metric name and the labels with the most distinct values. This is the single most useful diagnostic tool.

You can also query directly. To see how many series exist per metric name:

```promql
topk(10, count by (__name__)({__name__=~".+"}))
```

To find which label on a specific metric is the culprit, count distinct values of each candidate label:

```promql
count(count by (path) (http_requests_total))
```

If that returns a number in the tens of thousands, `path` is your problem. A healthy label usually has a handful to a few dozen distinct values.

The `promtool tsdb analyze` command, run against a block directory, gives an offline report including the highest-cardinality label pairs and the label names with the most unique values, without putting query load on a live server.

## Strategies to control cardinality

### Drop or rewrite labels at scrape time with relabeling

The most powerful lever is `metric_relabel_configs`, which runs after a scrape but before ingestion. You can drop entire metrics, drop specific labels, or rewrite high-cardinality values into bounded buckets.

```yaml
scrape_configs:
  - job_name: "api"
    static_configs:
      - targets: ["api:8080"]
    metric_relabel_configs:
      # Remove the raw path label entirely
      - regex: "path"
        action: labeldrop
      # Or normalize numeric IDs in a path before it ever lands
      - source_labels: [path]
        regex: "/users/[0-9]+/(.*)"
        target_label: path
        replacement: "/users/:id/${1}"
```

The second rule collapses `/users/1/profile`, `/users/2/profile`, and so on into a single `/users/:id/profile` series. This preserves the analytical value (you can still see traffic to the profile endpoint) while bounding cardinality to the number of route templates rather than the number of users.

### Use route templates in the application

Relabeling is a safety net. The real fix is to never emit unbounded labels in the first place. Most web frameworks expose the matched route pattern rather than the raw URL. Instrument with the template.

```go
// Instead of r.URL.Path use the matched route
route := mux.CurrentRoute(r)
template, _ := route.GetPathTemplate() // "/users/{id}/profile"
httpRequests.WithLabelValues(r.Method, status, template).Inc()
```

Now the `endpoint` label has a value count equal to the number of routes in your application — a stable, small number.

### Push high-variety dimensions to logs or traces

Not every dimension belongs in a metric. If you genuinely need per-user or per-request granularity, that is what structured logs and distributed traces are for. Metrics answer "how many" and "how fast" across populations; logs and traces answer "what happened to this specific request." Keep `user_id` in your trace spans and log lines, where the storage model is built for high cardinality, and out of your Prometheus labels.

### Set guardrails with sample and label limits

Prometheus can refuse to ingest a target that exceeds a configured number of samples, protecting the whole server from one misbehaving service.

```yaml
scrape_configs:
  - job_name: "risky-service"
    sample_limit: 10000        # reject the scrape if it exceeds this
    label_limit: 30            # max number of labels per series
    label_value_length_limit: 200
    static_configs:
      - targets: ["risky:9090"]
```

When a scrape exceeds `sample_limit`, the entire scrape is dropped and an `up` value of 0 is recorded, which is loud and visible. That is far better than silently letting a bad deploy double your memory footprint.

### Alert on cardinality itself

Treat cardinality as a first-class SLI. A simple alert catches regressions before they cause an outage:

```yaml
groups:
  - name: cardinality
    rules:
      - alert: HeadSeriesHigh
        expr: prometheus_tsdb_head_series > 2000000
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Prometheus head series above 2M"
```

You can also alert on the rate of growth, which catches a slow leak from a newly deployed metric long before it crosses an absolute ceiling.

## A decision flow for new metrics

Before adding any label, walk through a quick mental checklist. The flow below captures it.

{{< mermaid >}}
graph TD
    A["Want to add a label"] --> B{"Is the value bounded?"}
    B -- "No" --> C{"Do I need per-item detail?"}
    B -- "Yes, small set" --> D["Add the label"]
    C -- "Yes" --> E["Use logs or traces instead"]
    C -- "No" --> F["Bucket or template the value"]
    F --> D
    D --> G["Add a cardinality alert on the metric"]
    E --> G
{{< /mermaid >}}

## Recovering from an active explosion

If you are already in an outage, the order of operations matters because the server may be too loaded to query.

1. **Stop the bleeding at the source.** If a recent deploy introduced the bad label, roll it back. The series will go stale and be reclaimed.
2. **Add a `labeldrop` or `drop` relabel rule** for the offending metric and reload the config. New scrapes stop creating the bad series immediately.
3. **Reduce memory pressure.** If the head is too large to hold, you may need to delete series via the admin TSDB delete API (requires `--web.enable-admin-api`), then run a clean tombstone, but use this carefully — it is destructive.
4. **Restart only as a last resort.** A restart forces a WAL replay that, on a bloated instance, can take a long time and may OOM again before it finishes. Fix the config first so the replayed series do not simply rebuild.

The lasting fix is always upstream: bound the labels, and put a guardrail in place so the next person who adds `email` to a counter gets a rejected scrape instead of a 3 a.m. page.

## Summary

Cardinality explosion is the most common way to break Prometheus, and it almost always traces back to a single high-variety label such as an ID, path, or email landing in a metric. The cost is multiplicative across labels and is paid in memory, ingestion lag, and query latency. Defend against it on three fronts: instrument with bounded route templates in the application, normalize or drop dangerous labels with relabeling at scrape time, and enforce hard limits plus alerts so a bad deploy fails loudly instead of quietly eating your RAM. High-cardinality data is not bad data — it simply belongs in logs and traces, not in the Prometheus label set.
