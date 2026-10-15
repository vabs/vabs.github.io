---
title: "Service Discovery: Consul vs DNS"
date: 2026-06-02T13:50:00-04:00
draft: false
tags: [backend, service-discovery, consul, dns, distributed-systems]
---

## The problem service discovery solves

In a static world, service `A` calls service `B` at a hardcoded IP and port. In a dynamic world — autoscaling groups, container orchestrators, rolling deploys, spot-instance churn — `B`'s instances appear and disappear constantly, and their addresses change. Service discovery is the mechanism by which `A` finds a current, healthy instance of `B` without anyone editing config.

Every solution must answer three questions:

1. **Registration** — how does a new instance announce itself?
2. **Lookup** — how does a caller find available instances?
3. **Health** — how do dead instances get removed before callers hit them?

DNS-based discovery and Consul represent two ends of a spectrum. DNS leans on a protocol every machine already speaks; Consul is a purpose-built registry with rich health and metadata. Understanding their trade-offs is mostly about understanding what each one *cannot* do well.

## DNS-based service discovery

The appeal of DNS is universality. Every language, OS, and library can resolve a hostname — no SDK, no sidecar, no special client. You register instances by adding records, and callers resolve a name to get addresses.

Two record types matter:

- **A/AAAA records** return a set of IP addresses for a name. The client picks one (or the resolver round-robins). Simple, but carries no port or weight information.
- **SRV records** return host, port, priority, and weight — enough to express "these instances on these ports, prefer these, weight traffic like this." Richer, but far fewer clients actually consume SRV records.

```bash
# A-record round robin: multiple IPs for one name
$ dig +short api.internal.example.com
10.0.1.20
10.0.1.21
10.0.1.22

# SRV record carries port and weighting
$ dig +short SRV _api._tcp.service.consul
1 50 8080 node-a.node.dc1.consul.
1 50 8080 node-b.node.dc1.consul.
```

Kubernetes' built-in discovery is essentially DNS done well: CoreDNS resolves `my-svc.my-namespace.svc.cluster.local` to a stable ClusterIP (a virtual IP that kube-proxy load-balances) or, for headless services, to the set of pod IPs directly.

### Where DNS hurts

The limitations are structural, not implementation bugs:

| Limitation | Consequence |
| --- | --- |
| TTL-driven caching | Stale records: clients keep calling dead instances until TTL expires |
| No real health signal | DNS only knows "this record exists," not "this instance is healthy" |
| Client-side caching ignores TTL | JVMs and OS resolvers cache aggressively; some cache forever |
| No load metadata in A records | Pure round-robin only; no weighting, no locality awareness |
| Silent record-size limits | Large instance sets overflow UDP DNS responses and truncate |

The TTL problem is the killer. If you set a 30-second TTL, then for up to 30 seconds after an instance dies, resolvers may still hand its address to callers. Drop the TTL to 1 second and you hammer the DNS server and still cannot beat caching layers you do not control. Worse, many clients **ignore TTL entirely** — the classic JVM example uses its own cache policy (`networkaddress.cache.ttl`, 30 seconds by default) instead of the record's TTL, and caches successful lookups for the lifetime of the process when a security manager is installed, so a long-running service may never notice that an instance moved.

{{< mermaid >}}
graph TD
    A["Instance B2 dies"] --> B["DNS record still cached, TTL not expired"]
    B --> C["Caller resolves name"]
    C --> D["Gets dead B2 address"]
    D --> E["Connection timeout / error"]
    E --> F["Client retries, eventually picks live instance"]
{{< /mermaid >}}

DNS, in short, is *eventually consistent with a lag you only partially control*, and it has no native concept of health. It works beautifully for slow-changing fleets and is unbeatable for simplicity, but it is a weak foundation for fast-churning, latency-sensitive systems.

## Consul

Consul is a dedicated service registry built around active health checking and a real-time view of the fleet. Instances register with a local Consul agent, the agent runs continuous health checks, and only healthy instances are returned by queries. Critically, Consul exposes results through **both** an HTTP API *and* a DNS interface — so you can get its richer model while still letting legacy clients use plain DNS.

```hcl
# A service registration with multiple health checks
service {
  name = "api"
  port = 8080
  tags = ["v2", "primary"]

  check {
    id       = "api-http"
    http     = "http://localhost:8080/health"
    interval = "5s"
    timeout  = "2s"
  }
  check {
    id       = "api-tcp"
    tcp      = "localhost:8080"
    interval = "10s"
  }
}
```

```bash
# Rich query over HTTP: only healthy instances, with metadata
$ curl -s 'http://localhost:8500/v1/health/service/api?passing' \
    | jq '.[].Service | {address: .Address, port: .Port, tags: .Tags}'

# Or the DNS interface for dumb clients
$ dig +short api.service.consul
```

### What Consul adds over DNS

- **Active health checks.** Consul runs HTTP, TCP, gRPC, TTL, or script checks on a tight interval. A failing instance is removed from results within seconds, not at the mercy of a TTL. This is the single biggest difference.
- **Rich metadata and filtering.** Tags, versions, and key/value pairs let you query "healthy instances of `api` tagged `v2` in datacenter `dc1`." DNS A records cannot express any of this.
- **Watches and push updates.** Instead of polling, clients can block on a watch and be notified the instant the healthy set changes — true real-time convergence.
- **Multi-datacenter awareness.** Consul understands datacenters and can prefer local instances, failing over to a remote DC only when local ones are unhealthy.
- **Service mesh.** Consul Connect layers mTLS and authorization on top of discovery, turning the registry into a full mesh control plane.

### What Consul costs

Nothing is free. Consul is a distributed system you now have to operate.

| Cost | Detail |
| --- | --- |
| Operational burden | A Raft-based server cluster (3 or 5 nodes) plus an agent on every host |
| Consistency choices | Strongly consistent reads cost a round trip; stale reads are faster but, well, stale |
| Quorum sensitivity | Lose quorum and the catalog goes read-only; you must protect the server cluster |
| Client integration | Best behavior requires the HTTP API or a sidecar, not just DNS |
| Another failure domain | The registry itself can be the outage |

Consul's servers use the **Raft** consensus protocol, which means writes (registrations, health-state changes) go through a leader and a quorum. This gives strong consistency but makes the system sensitive to network partitions among servers and caps write throughput. For reads you choose a consistency mode — `consistent` (leader-verified, an extra round trip), `default` (leader-served, may be slightly stale during a leadership change), or `stale` (any server, fastest, can lag) — trading freshness for latency and load.

{{< mermaid >}}
graph LR
    I1["api instance"] -->|"register + checks"| AG["Local Consul agent"]
    AG -->|"gossip + Raft"| SRV["Consul server quorum (Raft leader + followers)"]
    CALLER["Caller"] -->|"HTTP API or DNS"| AG
    SRV -->|"healthy set"| AG
{{< /mermaid >}}

## Head to head

| Dimension | DNS-based | Consul |
| --- | --- | --- |
| Client requirement | None — universal | HTTP API ideal; DNS fallback available |
| Health awareness | None (record existence only) | Active multi-protocol checks |
| Staleness window | TTL + client caching (seconds to forever) | Seconds, push-driven |
| Metadata / filtering | A records: none; SRV: limited | Tags, versions, KV, datacenters |
| Load balancing | Round-robin | Weighted, locality-aware, filtered |
| Operational cost | Minimal (reuse existing DNS) | Run and protect a Raft cluster |
| Failure mode | Stale records, silent | Registry outage / quorum loss |
| Best fit | Slow-changing fleets, simplicity | Fast churn, health-critical, multi-DC |

## The CAP angle

The two approaches sit on different sides of the consistency/availability trade-off. DNS is **AP-leaning**: it is almost always available and answers fast, but the answer may be wrong (stale) — it sacrifices consistency. Consul's core catalog is **CP-leaning** via Raft: it gives you a consistent, health-accurate view, but if the server quorum is lost it would rather stop accepting writes than serve an inconsistent catalog. This is not academic — it dictates how each fails. DNS keeps serving (possibly dead) addresses during trouble; Consul may refuse updates during a partition to protect correctness. Match the choice to whether your system tolerates stale-but-available or demands correct-or-nothing.

## A pragmatic recommendation

You rarely need a religious choice. The common patterns:

- **Pure DNS / Kubernetes DNS** when your platform already provides it and instance churn is moderate. CoreDNS plus readiness probes plus kube-proxy gives you health-gated discovery without running anything extra. This covers a large fraction of real workloads.
- **Consul** when you have heavy instance churn, need health-accurate routing within seconds, run across multiple datacenters or a mixed VM/container fleet, or want a path to service mesh. Lean on its HTTP API or a sidecar to get the real benefits, and use the DNS interface only as a bridge for clients you cannot change.
- **Tune what you have first.** Before adopting Consul, fix the DNS pitfalls you can control: lower JVM DNS cache TTLs, add readiness probes, and use client-side load balancers that retry on connection failure. Many "we need a service registry" problems are really "our clients cache DNS forever" problems.

## Summary

DNS-based discovery wins on universality and operational simplicity but is fundamentally blind to health and bounded by TTL-plus-client-caching staleness, making it a weak fit for fast-churning fleets. Consul wins on active health checking, rich metadata, real-time updates, and multi-datacenter awareness, at the price of operating a Raft consensus cluster and accepting its consistency trade-offs. The decision hinges on churn rate and how much staleness your callers can tolerate: stable fleets with forgiving clients are well served by DNS; high-churn, health-critical, multi-DC systems justify the registry. And whichever you pick, the failure to fix first is almost always the client that caches a dead address far longer than anyone intended.
