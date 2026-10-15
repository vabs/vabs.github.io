---
title: "Zero-Downtime Deployment Strategies"
date: 2026-01-13T13:05:00-04:00
draft: false
featured: false
tags: [backend, deployment, devops, reliability, kubernetes]
---

## What "zero downtime" actually requires

Zero-downtime deployment means rolling out a new version of a service without any request failing because of the deployment itself. That is a stricter requirement than it sounds. It is not enough to start the new version before stopping the old one. You also have to handle in-flight requests on the instances you are about to kill, keep the load balancer's view of healthy instances accurate, and ensure the database schema is compatible with both the old and new code at every instant during the rollout.

The deployment strategy (rolling, blue-green, canary) determines how traffic shifts. But the strategy is only half the story. The other half is the set of preconditions that make any strategy safe: graceful shutdown, health checks that mean something, and backward-compatible schema changes. Get the strategy right and the preconditions wrong, and you still drop requests.

## The three core strategies

### Rolling deployment

Replace instances a few at a time. Bring up some new-version instances, wait for them to pass health checks, route traffic to them, then retire an equal number of old instances. Repeat until everything is on the new version. This is the Kubernetes default and is cheap because you never need double the capacity.

The risk is that old and new versions serve traffic **simultaneously** for the entire duration of the rollout. Both versions must be compatible with the live database schema and with each other if they call each other.

{{< mermaid >}}
sequenceDiagram
    participant LB as Load Balancer
    participant V1 as v1 instances
    participant V2 as v2 instances
    Note over V1: Start: 4x v1 serving
    V2->>LB: 2x v2 start, pass readiness
    LB->>V2: route some traffic
    Note over V1,V2: 2x v1 + 2x v2 serving together
    V1->>LB: 2x v1 drain + terminate
    Note over V2: End: 4x v2 serving
{{< /mermaid >}}

### Blue-green deployment

Run two complete environments. Blue is live. Deploy the new version to green, fully, in isolation. Smoke-test green while it receives no production traffic. Then flip the load balancer (or DNS, or router) so all traffic goes to green at once. Blue stays warm so you can flip back instantly if something is wrong.

The advantage is a clean cutover: there is a single moment where v1 hands off to v2, and rollback is just flipping back. The cost is double the infrastructure during the deploy, and the database is still shared between blue and green, so schema compatibility is just as critical here.

### Canary deployment

Route a small percentage of traffic (say 1%, then 5%, then 25%) to the new version while watching metrics. If error rates, latency, or business KPIs degrade, halt and roll back having affected only a sliver of users. If metrics stay healthy, progressively increase until the canary serves everything.

{{< mermaid >}}
graph TD
    A["Deploy canary (1 instance)"] --> B["Route 1% traffic"]
    B --> C{"Metrics healthy?"}
    C -->|No| D["Roll back, alert"]
    C -->|Yes| E["Increase to 10%"]
    E --> F{"Metrics healthy?"}
    F -->|No| D
    F -->|Yes| G["Increase to 50%, then 100%"]
    G --> H["Retire old version"]
{{< /mermaid >}}

| Strategy | Extra capacity | Rollback speed | Blast radius of a bad release | Best for |
|----------|---------------|----------------|-------------------------------|----------|
| Rolling | Minimal | Slow (roll forward/back gradually) | Grows during rollout | Default, cost-sensitive |
| Blue-green | 100% (two envs) | Instant (flip back) | All users at flip moment | Fast rollback, clean cutover |
| Canary | Small | Fast (small % affected) | Limited to canary % | Risky changes, gradual validation |

## Precondition 1: Graceful shutdown

No matter the strategy, you will terminate old instances. If you kill an instance that is mid-request, those requests fail. Graceful shutdown is the dance that drains traffic before the process dies.

When an orchestrator decides to stop a pod, the correct sequence is:

```text
1. Stop accepting new connections (fail readiness probe, leave load balancer)
2. Wait for the LB/service mesh to notice and stop routing new requests
3. Finish in-flight requests (up to a grace period)
4. Close downstream resources (DB pool, message consumers)
5. Exit
```

The subtle bug almost everyone hits: there is a race between the load balancer removing the instance and the process exiting. Kubernetes sends `SIGTERM` and removes the pod from the Service endpoints roughly in parallel, but endpoint propagation through kube-proxy, ingress, and external load balancers is **eventually** consistent. If your app exits the instant it gets `SIGTERM`, the load balancer may still send it requests for a few hundred milliseconds.

The fix is a deliberate `preStop` delay so the process keeps serving during the propagation window before it starts draining:

```yaml
# pod spec
terminationGracePeriodSeconds: 45   # must exceed sleep + max request time
containers:
  - name: app
    lifecycle:
      preStop:
        exec:
          # keep serving while endpoint removal propagates
          command: ["sh", "-c", "sleep 10"]
```

The application must also catch `SIGTERM`, flip its readiness probe to failing, and then drain. The grace period must be longer than the longest expected request plus the preStop sleep, or the orchestrator will `SIGKILL` mid-request.

## Precondition 2: Health checks that mean the right thing

Orchestrators use probes to decide what to do, and conflating them causes outages.

| Probe | Question it answers | Failure consequence |
|-------|---------------------|---------------------|
| Liveness | Is the process wedged and needing a restart? | Pod is killed and restarted |
| Readiness | Can this instance serve traffic right now? | Removed from load balancer, NOT killed |
| Startup | Has a slow-starting app finished booting? | Delays liveness/readiness until done |

The classic self-inflicted outage: a liveness probe that checks the database. The database has a hiccup, every instance's liveness probe fails, the orchestrator restarts every instance simultaneously, and now you have a full outage caused by a transient dependency blip. **Liveness should check only the process itself.** Dependency health belongs in readiness, where the consequence is "stop sending traffic," not "restart everything."

Readiness is also what makes rolling deploys safe: a new instance must not receive traffic until it has warmed caches, established its connection pool, and is genuinely able to serve. A readiness probe that returns 200 before the app is truly ready will route real traffic into a cold or broken instance.

## Precondition 3: Backward-compatible schema migrations

This is the precondition that breaks the most deploys, because it is invisible until two versions run against one database. During any rolling or canary deploy, and during the warm period of blue-green, old code and the new schema (or new code and the old schema) coexist. A migration that the old code cannot tolerate will break the old instances that are still serving traffic.

The rule: **never do a backward-incompatible schema change in the same release as the code that requires it.** Use the expand-contract (also called parallel-change) pattern, splitting one logical change across multiple deploys.

Consider renaming a column `email` to `email_address`:

```sql
-- Migration would-be-naive: BREAKS old code instantly
ALTER TABLE users RENAME COLUMN email TO email_address;
```

The safe expand-contract sequence spread across three deploys:

```text
EXPAND (deploy 1):
  - Add new column email_address (nullable)
  - Backfill: copy email -> email_address
  - Code writes to BOTH columns, reads from old (email)

MIGRATE (deploy 2):
  - Code reads from email_address, still writes both
  - Old instances are gone by now

CONTRACT (deploy 3):
  - Code writes only to email_address
  - Drop the old column email
```

{{< mermaid >}}
sequenceDiagram
    participant App as Application versions
    participant DB as Schema
    Note over DB: Expand: add email_address, dual write
    App->>DB: v1 writes email, v2 writes both
    Note over DB: Both versions work simultaneously
    Note over DB: Migrate: read new column
    App->>DB: all instances on v2
    Note over DB: Contract: drop old column
    App->>DB: v3 only knows email_address
{{< /mermaid >}}

The same principle applies to adding a `NOT NULL` column (add nullable first, backfill, then add the constraint), removing a column (stop using it in code first, drop it a release later), and changing a column type (add new, dual-write, migrate reads, drop old). Each transformation is decomposed so that at every instant, the schema is compatible with whichever code versions are live.

Operationally, also watch for **locking** migrations. On large tables, an `ALTER TABLE` that rewrites the table or takes an exclusive lock can block all reads and writes for the duration, which is itself an outage even if the schema is logically compatible. Prefer online schema-change tooling, add indexes concurrently, and split big backfills into batches.

## Putting strategy and preconditions together

A safe deploy is the intersection of a strategy and its preconditions:

```text
Rolling/canary deploy is safe WHEN:
  graceful shutdown drains in-flight requests
  AND readiness gates traffic to warm instances only
  AND liveness does not cascade on dependency blips
  AND schema is backward-compatible (expand-contract)
  AND old + new code can both run against the live schema
```

Notice that the database is the thread running through every strategy. You can have flawless blue-green infrastructure and still take an outage because deploy added a `NOT NULL` column that the blue environment cannot satisfy. Zero downtime is achieved less by picking the fanciest traffic-shifting strategy and more by enforcing the discipline that, at every single moment of the rollout, every live version of your code is compatible with the live state of the system, in flight requests are allowed to finish, and the load balancer's idea of "healthy" is actually true. Get those invariants right and rolling, blue-green, and canary all become safe; get them wrong and none of them are.
