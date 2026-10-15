---
title: "Blue-Green vs Canary Deployments"
date: 2026-05-31T15:25:00-04:00
draft: false
tags: [backend, deployment, devops, kubernetes, release-strategy]
---

## Two answers to one question

Every deployment strategy is an answer to the same question: how do you replace running version N with version N+1 without breaking the users hitting your service right now? The naive answer — stop the old, start the new — causes downtime and an all-or-nothing blast radius. Blue-green and canary are the two dominant disciplined alternatives, and they make opposite bets about how to manage risk.

**Blue-green** keeps two full production environments and flips all traffic from one to the other atomically. **Canary** keeps one environment and shifts a small slice of traffic to the new version, watches it, and ramps up gradually. Blue-green optimizes for instant, clean rollback; canary optimizes for limiting blast radius and catching problems before they reach everyone. Neither is universally better.

## Blue-green deployments

You run two identical environments: **blue** (current, serving all production traffic) and **green** (the new version, fully deployed but receiving no live traffic). You deploy N+1 to green, smoke-test it in isolation, then flip a router — a load balancer, a DNS change, a Kubernetes Service selector — to send 100% of traffic to green. Blue stays up, untouched, as an instant rollback target.

{{< mermaid >}}
graph TD
    LB["Load balancer / router"] -->|"100% before flip"| BLUE["Blue: version N"]
    LB -.->|"0% before flip"| GREEN["Green: version N+1"]
    FLIP["Atomic switch"] --> LB2["Load balancer"]
    LB2 -.->|"0% after flip"| BLUE2["Blue: version N (warm standby)"]
    LB2 -->|"100% after flip"| GREEN2["Green: version N+1"]
{{< /mermaid >}}

The defining property is the **atomic cutover**. Every user moves from N to N+1 at the same instant. If green misbehaves, you flip back to blue just as instantly — rollback is a router change, not a redeploy, so it completes in seconds.

A Kubernetes implementation is conceptually just swapping a Service's label selector:

```yaml
# The Service routes to whichever color the selector points at
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
    color: blue        # flip this to "green" to cut over
  ports:
    - port: 80
      targetPort: 8080
```

```bash
# The cutover: one atomic patch
kubectl patch service api -p '{"spec":{"selector":{"color":"green"}}}'
# Instant rollback if green is bad
kubectl patch service api -p '{"spec":{"selector":{"color":"blue"}}}'
```

### Strengths and costs

| Strength | Cost |
| --- | --- |
| Near-instant rollback (router flip) | Double the infrastructure during the deploy |
| Zero-downtime cutover | A bad release still hits 100% of users at once |
| Green tested in isolation first | Database schema changes are hard to make reversible |
| Simple mental model | No gradual confidence-building from real traffic |

The two real downsides are cost and blast radius. You pay for two full production-scale environments, at least transiently. And although blue-green gives you instant rollback, it does *not* limit blast radius on the way in: the flip exposes 100% of users to N+1 simultaneously. If N+1 has a subtle bug that smoke tests missed, everyone hits it at once — you just get to retreat quickly.

## Canary deployments

A canary release (named for the canary in the coal mine) deploys N+1 alongside N and routes a small percentage of live traffic to it — say 1%, then 5%, 25%, 50%, 100% — pausing at each step to evaluate health metrics. If the canary's error rate, latency, or business metrics degrade, you halt and roll back, having exposed only a fraction of users.

{{< mermaid >}}
graph TD
    A["Deploy N+1 canary"] --> B["Route 5% traffic to canary"]
    B --> C{"Metrics healthy?"}
    C -->|"No"| D["Roll back, route 0% to canary"]
    C -->|"Yes"| E["Route 25%"]
    E --> F{"Metrics healthy?"}
    F -->|"No"| D
    F -->|"Yes"| G["Route 100%, retire N"]
{{< /mermaid >}}

The defining property is **progressive exposure with automated analysis at each step**. The whole point is to catch problems with real production traffic while the blast radius is still tiny.

Tools like Argo Rollouts or Flagger encode this as a declarative strategy with automated metric gates:

```yaml
# Argo Rollouts canary with automated analysis between steps
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: api
spec:
  strategy:
    canary:
      steps:
        - setWeight: 5
        - pause: {duration: 5m}
        - analysis:                 # auto-evaluate metrics
            templates:
              - templateName: success-rate
        - setWeight: 25
        - pause: {duration: 10m}
        - setWeight: 50
        - pause: {duration: 10m}
        - setWeight: 100
```

```yaml
# The gate: abort if success rate drops below threshold
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  metrics:
    - name: success-rate
      interval: 1m
      successCondition: result[0] >= 0.99
      failureLimit: 2
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{job="api-canary",status!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{job="api-canary"}[2m]))
```

### Strengths and costs

| Strength | Cost |
| --- | --- |
| Tiny blast radius — bugs hit a fraction of users | Slower: full rollout takes minutes to hours |
| Validates with real production traffic | Requires solid metrics and automated analysis |
| Cheap — no second full environment | Both versions run together (schema/contract compat) |
| Confidence builds incrementally | Statistical noise at low traffic can mislead the gate |

Canary's slowness is a feature, not a bug — the pauses are where confidence accumulates. But it demands a real observability foundation. Without trustworthy per-version metrics and a sound success/failure condition, automated canary analysis either passes bad releases or flaps on noise. At low traffic percentages, a handful of errors can swing the success rate wildly, so the gate must account for sample size.

## The shared hard problem: state and contracts

Both strategies run **two versions concurrently** (canary for the whole rollout; blue-green during the overlap and for rollback), and that is where the genuinely hard engineering lives — not in the traffic routing, which tools handle, but in **shared state and API contracts**.

The database is the trap. Both versions usually share one database, so the schema must be compatible with N *and* N+1 simultaneously. A migration that drops a column N still reads, or adds a NOT-NULL column N does not write, breaks the other version and defeats the instant-rollback promise — you cannot flip back to blue if blue can no longer read the migrated schema.

The discipline that makes this safe is **expand/contract** (a.k.a. parallel-change) migrations:

```sql
-- Phase 1 EXPAND: add new column, nullable, both versions tolerate it
ALTER TABLE users ADD COLUMN email_verified BOOLEAN;

-- Deploy N+1 which writes the new column; backfill existing rows
UPDATE users SET email_verified = false WHERE email_verified IS NULL;

-- Phase 2 CONTRACT: only after N is fully gone and rollback window closed
ALTER TABLE users ALTER COLUMN email_verified SET NOT NULL;
```

The rule: schema changes are decoupled from code changes and rolled out in backward-compatible increments. The same applies to API contracts (additive changes only during overlap), message formats, and cache key shapes. This work is identical for blue-green and canary and is usually the part teams underestimate.

## Choosing between them

| Factor | Favors blue-green | Favors canary |
| --- | --- | --- |
| Rollback speed | Instant flip needed | Gradual abort acceptable |
| Blast radius tolerance | Acceptable to expose all at once | Must limit exposure |
| Infrastructure budget | Can afford 2x environment | Cost-sensitive |
| Observability maturity | Limited metrics | Strong per-version metrics |
| Traffic volume | Any | High enough for statistical signal |
| Release confidence | High (well-tested) | Low (want production validation) |

The decision often comes down to two questions. First, *can you afford a second full environment?* If not, canary is the natural fit. Second, *do you trust your tests or do you need production to tell you the truth?* High-confidence releases with reversible-but-risky changes suit blue-green's clean cutover and instant rollback; lower-confidence releases where you want real traffic to vet the change suit canary's progressive exposure.

### They combine

These are not mutually exclusive. A common advanced pattern is to deploy the new version as a canary, ramp it to 100% via progressive traffic shifting, and keep the old version around as a warm blue-green standby for fast rollback during the bake period. You get canary's blast-radius control on the way in and blue-green's instant rollback on the way out. Service meshes and rollout controllers make this layering practical.

## Summary

Blue-green and canary solve the same problem with opposite risk strategies. Blue-green runs two full environments and flips all traffic atomically — superb for instant rollback, weak on blast radius, expensive in infrastructure. Canary runs one environment and shifts traffic progressively under automated metric gates — superb for limiting blast radius and validating with real traffic, but slower and dependent on solid observability. Both run two versions at once, so both demand expand/contract migrations and backward-compatible contracts, which is the real difficulty regardless of which router trick you use. Pick blue-green when you value clean instant rollback and can pay for the second environment; pick canary when you must limit who sees a bad release and you have the metrics to judge it; and combine them when you want both guarantees.
