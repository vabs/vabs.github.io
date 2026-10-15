---
title: "Feature Flags with Rollout Strategies"
date: 2026-06-05T10:22:00-04:00
draft: false
tags: [backend, feature-flags, deployment, observability, experimentation]
---

Feature flags decouple deployment from release. Once that decoupling exists, the interesting engineering question stops being "is the code in production?" and becomes "for whom is this code active, and how do we move that population safely from 0% to 100%?" A rollout strategy is the answer to that second question, encoded as data rather than as a redeploy.

This post covers the backend mechanics of feature flagging: flag evaluation models, the common rollout strategies, consistency guarantees, and the operational machinery (kill switches, observability, cleanup) that separates a toy flag library from a production-grade release platform.

## The Evaluation Model

A flag is a function. Given a flag key and an evaluation context (user id, account tier, region, request attributes), it returns a variation. For a boolean flag that variation is `on` or `off`; for a multivariate flag it might be `control`, `treatment_a`, or `treatment_b`.

```python
def evaluate(flag_key: str, context: dict, default: Variation) -> Variation:
    flag = store.get(flag_key)
    if flag is None:
        return default  # unknown flag
    if not flag.enabled:
        return flag.off_variation  # kill state
    for rule in flag.rules:
        if rule.matches(context):
            return rule.resolve(context)
    return flag.fallthrough.resolve(context)
```

The critical design decision is *where* this function runs. There are three models:

| Model | Evaluation location | Latency | Consistency | Notes |
|-------|--------------------|---------|-------------|-------|
| Remote eval | Flag service per request | High (network hop) | Strong, centralized | Simple SDK, scaling burden on service |
| Local eval (streamed rules) | In-process SDK | Microseconds | Eventually consistent | Rules streamed to clients via SSE/websocket |
| Bootstrapped/static | Build or boot time | Zero runtime cost | Stale until redeploy | Only for low-churn flags |

Production systems overwhelmingly favor **local evaluation**: the flag service streams rule definitions to every SDK instance, and evaluation happens in-process. This keeps the hot path free of network calls while a background channel keeps rules fresh.

{{< mermaid >}}
flowchart LR
  A["Flag dashboard"] -->|"write rules"| B["Flag service"]
  B -->|"stream rule updates (SSE)"| C["SDK in App 1"]
  B -->|"stream rule updates (SSE)"| D["SDK in App 2"]
  C -->|"local eval (no network)"| E["Request handler"]
  D -->|"local eval (no network)"| F["Request handler"]
  C -->|"flush events"| G["Analytics sink"]
  D -->|"flush events"| G
{{< /mermaid >}}

## Rollout Strategies

### 1. Percentage Rollout via Consistent Bucketing

The foundational strategy: expose the feature to N% of users. The naive implementation — `random() < 0.10` — is wrong, because a user would flip in and out of the treatment on every request. You need *sticky* bucketing.

The standard technique is to hash a stable identity together with the flag key into a bucket in `[0, 100)`:

```python
import hashlib

def bucket(flag_key: str, user_id: str, salt: str = "") -> float:
    h = hashlib.sha1(f"{flag_key}:{salt}:{user_id}".encode()).hexdigest()
    # use the first 15 hex digits to avoid float precision loss
    n = int(h[:15], 16)
    return (n % 100_000) / 1000.0  # 0.000 .. 99.999

def in_rollout(flag_key, user_id, percent) -> bool:
    return bucket(flag_key, user_id) < percent
```

Two properties matter here. First, the hash includes the flag key, so a user bucketed into the treatment for flag A is *not* correlated with their bucket for flag B — otherwise the same unlucky 5% would be guinea pigs for everything. Second, increasing the percentage only adds users; it never removes anyone who was already in, because the bucket function is monotonic in the threshold. Going from 10% to 20% keeps the original 10% and adds the next 10%.

### 2. Ring / Canary Deployment

Rather than a random percentage, expose the feature to progressively larger, intentionally chosen audiences ("rings"):

```text
ring 0: internal employees        (~0.1%)
ring 1: beta opt-in users         (~1%)
ring 2: low-risk region           (~10%)
ring 3: everyone                  (100%)
```

Each ring promotion is gated on health metrics from the previous ring. This is the strategy of choice for risky infrastructure changes where you want *human-meaningful* cohorts rather than statistical samples.

### 3. Targeting Rules (Attribute-Based)

Flags often need to express business logic: enable for `tier == "enterprise"`, or for `region in ("us-east", "us-west")`, or for a specific allowlist of account ids. Rules are evaluated top to bottom and short-circuit on first match:

```json
{
  "rules": [
    { "if": { "attr": "account_id", "op": "in", "values": ["a1", "a2"] },
      "serve": "on" },
    { "if": { "attr": "tier", "op": "eq", "value": "enterprise" },
      "serve": { "rollout": { "on": 50, "off": 50 } } }
  ],
  "fallthrough": { "serve": "off" }
}
```

Note the nesting: a targeting rule can itself contain a percentage rollout, so you can say "roll out to 50% of enterprise customers."

### 4. Experimentation (A/B/n)

When the goal is measuring impact rather than de-risking a release, the flag becomes an experiment. Each variation is assigned a traffic slice, and every evaluation emits an *exposure event* that downstream analytics joins against conversion metrics. The bucketing must be stable for the entire experiment lifetime so a user's variation never changes mid-test.

## Consistency and the "Flicker" Problem

The hardest correctness issue in flagging is *evaluation consistency*. Consider a user whose request fans out to three services. If each service evaluates the same flag independently and the rules are mid-update, two services might see `on` and one `off`, producing a broken hybrid experience.

Mitigations, in increasing order of strength:

1. **Stable bucketing** (above) ensures the same identity + same rules → same result everywhere.
2. **Flag evaluation at the edge**: evaluate once at the gateway, then propagate resolved variations downstream as headers or in the request context.
3. **Versioned rule sets**: stamp every rule set with a monotonic version; propagate the version with the request so all services evaluate against the *same* snapshot.

{{< mermaid >}}
flowchart TD
  A["Incoming request"] --> B["Edge / gateway"]
  B --> C["Evaluate all flags once"]
  C --> D["Attach resolved variations + ruleset version to context"]
  D --> E["Service A reads context"]
  D --> F["Service B reads context"]
  D --> G["Service C reads context"]
  E --> H["Consistent experience"]
  F --> H
  G --> H
{{< /mermaid >}}

## Operational Machinery

### Kill Switches

Every flag is implicitly a kill switch. The single most valuable operational property of a flag system is that flipping a flag `off` takes effect in seconds without a deploy. This requires that the `off` path be a real, tested code path — not a stub that throws. Treat the off variation as a first-class behavior.

### Default Values and Fail-Safe

SDKs must evaluate to a caller-supplied default when the flag service is unreachable, the flag is unknown, or evaluation throws. The default should represent the *safe* state — usually the old behavior:

```python
show_new_checkout = client.bool_variation(
    "new-checkout", context, default=False  # old checkout if anything goes wrong
)
```

A flag system that hard-fails when its backend is down has inverted the entire value proposition: you added a dependency that can take down the feature it was meant to protect.

### Observability

Each evaluation should be (sampled and) recorded with the flag key, resolved variation, and the rule index that matched. This answers the questions you will actually ask during an incident: "what fraction of traffic is seeing the new path right now?" and "did this user get treatment or control?" Pair evaluation metrics with the business and error metrics for the feature so a bad rollout is visible as a divergence between the treatment and control cohorts.

| Metric | Why it matters |
|--------|----------------|
| Evaluations/sec by variation | Confirms rollout percentage is taking effect |
| Error rate by variation | Detects treatment-specific regressions |
| Latency p99 by variation | Catches performance cliffs in new code |
| Default-served count | Spikes indicate SDK/service connectivity loss |

### Automated Guardrails

Mature platforms close the loop: define a health metric and an abort condition, and let the system auto-rollback. A progressive delivery controller advances the percentage on a schedule (e.g., 1% → 5% → 25% → 50% → 100% over hours) and halts or reverts if error budgets are breached. This turns rollout from a manual dashboard ritual into a policy.

## Flag Lifecycle and Debt

Flags are liabilities. Each adds a branch, doubling the logical test surface; ten boolean flags imply up to 1024 combinations. Two disciplines keep this in check:

- **Categorize flags by lifespan.** Release flags are temporary and must be removed once a feature reaches 100% and is deemed stable. Ops flags (kill switches) and permission/entitlement flags are long-lived by design. Tagging them differently prevents the cleanup process from deleting your kill switches.
- **Automate stale-flag detection.** A flag that has served 100% `on` for 30 days with no rule changes is a removal candidate. Surface these in CI as warnings and file cleanup tickets automatically.

```text
created -> ramping (0% -> 100%) -> fully rolled out -> code cleanup -> archived
                |                          |
                v                          v
           rolled back               long-lived (ops/entitlement) -> retained
```

## Putting It Together

A production flag evaluation, end to end, looks like this:

```python
def resolve_checkout(client, user):
    ctx = {
        "user_id": user.id,
        "tier": user.tier,
        "region": user.region,
    }
    variation = client.string_variation(
        "checkout-experience", ctx, default="legacy"
    )
    # exposure event emitted by the SDK automatically
    return {
        "legacy": LegacyCheckout,
        "v2": NewCheckout,
        "v2-express": ExpressCheckout,
    }.get(variation, LegacyCheckout)
```

The flag key, the context, the safe default, and the implicit exposure event are all present. Behind that one call sits the bucketing, the streamed rules, the kill switch, and the observability that let you ship the new checkout to 1%, watch the cohorts, and ramp to 100% — all without touching the deploy pipeline. That is the whole point of feature flags: turning release into a runtime decision you can observe, control, and reverse.
