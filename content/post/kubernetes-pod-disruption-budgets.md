---
title: "Kubernetes Pod Disruption Budgets"
date: 2026-03-27T09:14:22-04:00
draft: false
featured: false
tags: [backend, kubernetes, reliability, availability, sre]
---

Pod Disruption Budgets (PDBs) are one of the most misunderstood reliability primitives in Kubernetes. They sit quietly in your manifests until the day a node drain takes down half your fleet, and only then do most teams discover what they were supposed to be protecting against. This post digs into how PDBs actually work, the difference between voluntary and involuntary disruptions, the arithmetic behind `minAvailable` and `maxUnavailable`, and the failure modes that bite production clusters.

## Voluntary vs. Involuntary Disruption

The single most important concept in this entire topic is the distinction between the two classes of disruption. PDBs only protect against one of them.

**Involuntary disruptions** are events outside the control of the cluster's eviction machinery:

- A node's kernel panics or the hardware fails.
- The underlying VM is preempted (spot/preemptible instances).
- A network partition isolates a node.
- The kubelet is OOM-killed and pods are lost.

**Voluntary disruptions** are deliberate actions, usually triggered by an operator or controller through the Eviction API:

- `kubectl drain` during a node upgrade.
- Cluster autoscaler scaling down an underutilized node.
- A node being drained for maintenance (cordoning alone evicts nothing).
- A rolling update of the node pool.

PDBs gate **only voluntary disruptions**. If a node dies, the budget does nothing — Kubernetes does not consult your PDB before a kernel panic. This is the first thing to internalize: a PDB is a contract with the *eviction subsystem*, not a guarantee of availability.

{{< mermaid >}}
graph TD
  A["Disruption Event"] --> B{"Voluntary?"}
  B -->|"Yes: drain, autoscaler scale-down"| C["Eviction API consulted"]
  C --> D{"PDB budget available?"}
  D -->|"Yes"| E["Pod evicted"]
  D -->|"No"| F["Eviction blocked (429)"]
  B -->|"No: hardware fail, OOM, preempt"| G["Pod terminated immediately"]
  G --> H["PDB ignored"]
{{< /mermaid >}}

## How the Eviction API Enforces a Budget

When something calls the Eviction API (`POST .../pods/<name>/eviction`), the API server checks every PDB whose selector matches that pod. It computes the number of *currently healthy* pods and asks: if I evict this one, will the budget still be satisfied?

If yes, the eviction proceeds. If no, the API server returns `429 Too Many Requests` with a `DisruptionBudget` reason, and the caller — `kubectl drain`, the autoscaler — must back off and retry. This is why a drain can hang: it is politely waiting for your application to become healthy enough to tolerate losing another replica.

The controller behind this is the **disruption controller**, which continuously recalculates `status.disruptionsAllowed` for each PDB. That field is the live answer to "how many more pods can I evict right now."

## minAvailable vs. maxUnavailable

A PDB is defined with exactly one of two mutually exclusive fields.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: payments-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: payments
```

| Field | Meaning | Best for |
|-------|---------|----------|
| `minAvailable: N` | At least N pods (or N%) must stay healthy | Fixed-floor services where you know the minimum |
| `maxUnavailable: N` | At most N pods (or N%) may be down at once | Scaling deployments where the absolute count varies |

Both fields accept either an integer or a percentage string like `"50%"`. Percentages are computed against `status.expectedPods` and rounded **up** for both fields — so `minAvailable` errs toward keeping more pods alive, while `maxUnavailable` can allow slightly more disruption than the percentage suggests.

A subtle but critical rule: **you cannot use `maxUnavailable`, or a percentage `minAvailable`, if the workload's scale subresource is unknown.** For bare pods (not backed by a controller with a scale subresource) Kubernetes cannot derive the expected pod count, so `maxUnavailable` does not work. Use an integer `minAvailable` for those.

### The arithmetic, worked out

Say you run 5 replicas with `maxUnavailable: 25%`. Kubernetes computes `ceil(5 * 0.25) = 2`. So `disruptionsAllowed = 2` when all 5 are healthy. Drain one node, one pod is evicted, now 4 healthy — `disruptionsAllowed` drops to 1. A second eviction takes it to 0 until a replacement pod becomes Ready, and the drain on a third node blocks.

Now flip it: `minAvailable: 25%` gives `ceil(5 * 0.25) = 2`. The budget requires 2 healthy at all times, so `disruptionsAllowed = 5 - 2 = 3`. Very different posture from the same percentage.

## The Single-Replica Trap

The most common production mistake: a PDB with `minAvailable: 1` on a single-replica deployment.

```yaml
spec:
  minAvailable: 1   # on a Deployment with replicas: 1
```

This creates a PDB that can **never** be satisfied during a drain. With one replica, evicting it would leave zero healthy pods, violating `minAvailable: 1`. The eviction is permanently rejected, and `kubectl drain` hangs forever. Node upgrades stall cluster-wide.

If you have a single-replica workload that genuinely cannot tolerate disruption, the answer is not a PDB — it is to scale to at least 2 replicas with anti-affinity, or to accept the disruption. A PDB on a singleton just converts "brief downtime" into "stuck drain."

## Healthy Pod Eviction Policy

A long-standing footgun was that pods stuck in a `Running` but not-`Ready` state (e.g., crash-looping) could block eviction forever because the budget never recovered. The `unhealthyPodEvictionPolicy` field (beta in Kubernetes 1.27, stable since 1.31) addresses this.

```yaml
spec:
  maxUnavailable: 1
  unhealthyPodEvictionPolicy: AlwaysAllow
  selector:
    matchLabels:
      app: ingest
```

| Policy | Behavior |
|--------|----------|
| `IfHealthyBudget` (default) | Unhealthy pods only evictable if the budget is currently met |
| `AlwaysAllow` | Unhealthy (not-Ready) pods always evictable regardless of budget |

`AlwaysAllow` is what you usually want for stateless workloads: it lets a drain clear out broken pods that were never contributing to availability anyway, instead of deadlocking on them.

## Interaction with the Cluster Autoscaler

The cluster autoscaler respects PDBs when deciding whether a node can be removed during scale-down. If removing a node would require evicting a pod that the PDB protects, and the budget cannot absorb it, the node is marked unremovable. This is good for safety but can stall cost-saving scale-downs.

A frequent anti-pattern is over-tight PDBs across many small deployments. Each one individually looks reasonable, but collectively they pin nodes in place. The autoscaler tries to evict, gets 429s on multiple PDBs, gives up, and your cluster stays expensive. Audit `disruptionsAllowed == 0` PDBs:

```bash
kubectl get pdb -A -o json | \
  jq -r '.items[] | select(.status.disruptionsAllowed==0) |
  "\(.metadata.namespace)/\(.metadata.name)"'
```

Any PDB consistently sitting at zero allowed disruptions is a drain-blocker waiting to happen.

## A Drain Lifecycle

Here's the full state flow when an operator drains a node holding a budgeted pod.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Cordoned: kubectl drain
  Cordoned --> EvictAttempt: schedule new pods elsewhere
  EvictAttempt --> Allowed: disruptionsAllowed > 0
  EvictAttempt --> Blocked: disruptionsAllowed == 0
  Blocked --> EvictAttempt: retry after backoff
  Allowed --> Draining: pod terminating
  Draining --> Recovered: replacement pod Ready
  Recovered --> [*]: node empty
{{< /mermaid >}}

The dangerous window is `Draining` → `Recovered`. If the replacement pod cannot schedule (no capacity, node selector unmatched, PVC bound to the old zone), the budget never recovers, and any subsequent drains block. PDBs assume that evicted pods get rescheduled promptly; if your scheduler can't place them, the whole mechanism stalls.

## Practical Guidelines

- **Always run at least 2 replicas** for anything that has a PDB. A budget on a singleton is a trap.
- **Prefer `maxUnavailable` for HA web services** — it scales naturally as you change replica counts.
- **Prefer `minAvailable` for quorum systems** (etcd, ZooKeeper, Kafka controllers) where you need an exact floor to maintain quorum.
- **Set `unhealthyPodEvictionPolicy: AlwaysAllow`** for stateless workloads to avoid deadlocking on crash-looped pods.
- **Audit for `disruptionsAllowed: 0`** as a routine SRE check — it predicts stuck node upgrades.
- **Remember PDBs do nothing for spot interruptions.** For preemptible capacity you need replica spread plus graceful termination handlers, not a budget.

## Conclusion

A Pod Disruption Budget is a precise, narrow tool: it tells the eviction subsystem how aggressive it may be during voluntary disruptions. It is not a magic availability shield, it does not protect against hardware failure, and it actively harms you when misconfigured on low-replica workloads. Treated with respect — adequate replica counts, sensible eviction policy, and routine auditing of allowed disruptions — it makes node maintenance safe and predictable. Treated carelessly, it becomes the reason your cluster upgrade has been hanging for forty minutes.
