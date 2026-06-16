---
title: "Service Mesh Traffic Shifting"
date: 2026-04-02T15:38:47-04:00
draft: false
featured: false
tags: [backend, service-mesh, istio, canary, deployments]
---

Traffic shifting is the capability that turns a service mesh from a fancy observability layer into a genuine deployment safety net. It lets you route a controlled fraction of requests to a new version, watch the metrics, and either ramp up or roll back — all without redeploying, without DNS changes, and without touching your application code. This post covers how traffic shifting works at the sidecar level, the difference between weight-based and request-based routing, how canary analysis automates the decision, and the failure modes that silently corrupt a rollout.

## The Data Plane Does the Work

In a mesh like Istio or Linkerd, every pod runs a sidecar proxy (Envoy in Istio's case) that intercepts all inbound and outbound traffic. Traffic shifting is fundamentally a *control plane configuration* that gets compiled down to *data plane routing rules* the sidecar enforces on every request.

The control plane (istiod) takes your high-level intent — "send 10% of traffic to v2" — and pushes Envoy configuration to every sidecar that might originate calls to the target service. The actual splitting happens in the calling pod's sidecar, not at any central gateway. This is the key architectural insight: traffic shifting is **decentralized**. There is no single bottleneck doing the routing.

{{< mermaid >}}
graph LR
  A["Caller Pod + Sidecar"] -->|"90%"| B["reviews-v1"]
  A -->|"10%"| C["reviews-v2"]
  D["istiod control plane"] -.->|"push routing config"| A
  E["VirtualService + DestinationRule"] -.->|"declares intent"| D
{{< /mermaid >}}

## Subsets, DestinationRules, and VirtualServices

Istio's traffic shifting rests on two resources working together.

A **DestinationRule** defines named *subsets* of a service, usually keyed on a version label:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
spec:
  host: reviews
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

A **VirtualService** then declares how traffic is distributed across those subsets:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
    - reviews
  http:
    - route:
        - destination:
            host: reviews
            subset: v1
          weight: 90
        - destination:
            host: reviews
            subset: v2
          weight: 10
```

The weights must sum to 100. To shift traffic, you patch these numbers and istiod propagates the change in seconds. No pod restarts.

## Weight-Based vs. Request-Based Shifting

There are two fundamentally different ways to choose which requests go to the new version.

| Strategy | How it routes | Use case |
|----------|---------------|----------|
| Weight-based | Random percentage of all requests | Gradual ramp, statistical canary |
| Request-based (header/match) | Requests matching a rule (header, cookie, user ID) | Internal dogfooding, targeted cohorts |

Request-based shifting is what powers "ship to employees first." You match a header:

```yaml
http:
  - match:
      - headers:
          x-internal-user:
            exact: "true"
    route:
      - destination:
          host: reviews
          subset: v2
  - route:
      - destination:
          host: reviews
          subset: v1
```

A common pattern combines them: route internal users to v2 by header for a few days, then begin a weight-based ramp for the general population. The two strategies are not mutually exclusive — the match block is evaluated first, falling through to the weighted default.

## The Sticky Session Problem

Naive weight-based shifting routes *each request* independently. If a user makes ten requests, statistically one might hit v2 and nine hit v1. For stateless APIs that's fine. For anything with session affinity — a multi-step checkout, a stateful WebSocket upgrade, a feature that changes the UI — bouncing a single user between versions mid-session is a bug.

The fix is consistent hashing on a stable key:

```yaml
spec:
  host: reviews
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          name: session-id
          ttl: 3600s
```

This pins a given session to one backend. But beware: consistent hashing for *load balancing within a subset* is different from *which subset a request lands in*. Weight-based subset selection is still per-request random unless you push the canary decision earlier — for example, by setting a header at the edge gateway that then drives request-based routing downstream. Getting end-to-end stickiness in a canary requires deciding the version *once*, at the entry point, and propagating that decision.

## Automated Canary Analysis

Manually editing weights and squinting at dashboards does not scale. Progressive delivery controllers — Flagger, Argo Rollouts — automate the loop: bump the weight, wait, query metrics, decide.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Initializing
  Initializing --> Progressing: "canary deployed"
  Progressing --> Analyzing: "weight increment applied"
  Analyzing --> Progressing: "metrics pass, ramp up"
  Analyzing --> RollingBack: "metrics fail threshold"
  Progressing --> Promoting: "weight reached 100%"
  Promoting --> [*]: "primary updated"
  RollingBack --> [*]: "weight reset to 0%"
{{< /mermaid >}}

A Flagger canary spec encodes the analysis criteria:

```yaml
analysis:
  interval: 1m
  threshold: 5          # consecutive failures before rollback
  maxWeight: 50
  stepWeight: 10
  metrics:
    - name: request-success-rate
      thresholdRange:
        min: 99
      interval: 1m
    - name: request-duration
      thresholdRange:
        max: 500
      interval: 1m
```

Every interval, the controller raises the canary weight by `stepWeight`, then checks the success rate and p99 latency from the mesh's telemetry. If a metric breaches its threshold `threshold` times in a row, the controller resets the canary weight to zero and the rollout fails closed. This is the whole point: the rollback decision is data-driven and automatic, executing faster than a human paging through Grafana at 2 a.m.

## Metrics That Actually Matter

The mesh gives you golden signals for free because every request passes through a proxy that records it. For canary analysis, weight these:

- **Success rate** — fraction of non-5xx responses. The primary kill switch.
- **p99 latency** — tail latency catches regressions that averages hide.
- **Request volume** — ensure the canary actually received enough traffic for the statistics to mean anything. A canary at 1% weight on a low-traffic service may go an entire interval with zero requests, in which case "100% success rate" is meaningless.

That last point is the most common analysis bug. Always gate promotion on a minimum request count, not just a success ratio over a possibly empty sample.

## Failure Modes

**Asymmetric resource provisioning.** The canary pod often gets the same replica count and limits as production, but receives a fraction of the traffic. If you later flip to 100% weight, the canary may be under-provisioned for full load. Scale the canary's capacity for its eventual share, not its current share.

**Stale DestinationRule subsets.** If a VirtualService references a subset whose label selector matches no pods (because the version label was renamed), Envoy gets a route to nowhere and requests fail with `503 NR` (no route / no healthy upstream). Always apply DestinationRule changes before the VirtualService that depends on them.

**Mesh-external traffic bypass.** Traffic that enters from outside the mesh without going through a mesh gateway, or calls that bypass the sidecar (e.g., `hostNetwork` pods, or traffic on ports the sidecar doesn't intercept), is not subject to your weights. You can have a "10% canary" that an entire class of clients never participates in.

**Retries amplifying the canary.** If the mesh retries failed requests and the canary is the one failing, retries may land on the healthy primary — masking the canary's failure rate at the caller while the canary quietly burns errors. Inspect destination-side metrics, not just source-side, when judging a canary.

## Conclusion

Traffic shifting is deceptively simple at the YAML level — a couple of weight integers — but the behavior it produces depends on a stack of decisions: per-request vs. sticky routing, where the version decision is made, whether your metrics have enough volume to be trustworthy, and whether all your traffic even flows through the mesh. Get those right and you have a deployment process where a bad release affects 5% of users for sixty seconds before automatically rolling itself back. Get them wrong and you have a canary that lies to you. Treat the weights as the easy part and the analysis criteria as the hard part, because that is exactly the inversion that production will teach you.
