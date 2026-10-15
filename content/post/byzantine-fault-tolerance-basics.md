---
title: "Byzantine Fault Tolerance Basics"
date: 2026-04-17T13:50:00-04:00
draft: false
featured: false
tags: [backend, byzantine-fault-tolerance, consensus, distributed-systems, security]
---

Most distributed systems assume failures are honest: a node either works correctly or it crashes and stops. Byzantine fault tolerance throws out that comfortable assumption. A Byzantine node can do anything — send different messages to different peers, lie about its state, forge data, collude with other bad nodes, or simply behave arbitrarily because of a bug, a memory corruption, or an attacker. Tolerating that is dramatically harder than tolerating a crash, and the math reflects it. This post explains where the famous `3f + 1` bound comes from, how PBFT achieves agreement, and when this expensive machinery is actually worth it.

## Crash faults versus Byzantine faults

The fault model is the most important assumption a distributed protocol makes. Crash-fault-tolerant (CFT) protocols like Raft and Paxos assume the **fail-stop** model: a faulty node simply goes silent. It never sends a *wrong* message. That assumption is what lets a majority quorum work — with `2f + 1` nodes you survive `f` crashes, because the silent nodes contribute nothing and the honest majority decides.

A Byzantine node breaks this completely. It can send message `A` to one peer and contradictory message `B` to another, claim to have committed something it never did, or impersonate a value it never received. Crucially, a single such node can make two honest nodes believe two different things — exactly the disagreement consensus must prevent.

| Aspect | Crash fault (CFT) | Byzantine fault (BFT) |
|--------|-------------------|-----------------------|
| Faulty behavior | Stops responding | Arbitrary, possibly malicious |
| Nodes to tolerate f faults | 2f + 1 | 3f + 1 |
| Messages can be wrong? | No | Yes |
| Typical use | Internal datacenter clusters | Open / adversarial networks |
| Examples | Raft, Paxos | PBFT, Tendermint, blockchains |

## The Byzantine Generals framing

The classic intuition is the Byzantine Generals Problem. Several generals surround a city and must agree to all attack or all retreat. They communicate only by messenger, and some generals may be traitors who send conflicting orders. The honest generals must reach a common plan despite the traitors actively trying to split them.

The key result: with only verbal (unsigned) messages, agreement is possible only if more than two-thirds of the generals are loyal. With three generals and one traitor, the two loyal ones cannot tell who is lying — the traitor tells general A "attack" and general B "retreat," and each honest general sees one "attack" and one "retreat" vote with no way to break the tie.

## Why 3f + 1

The `3f + 1` requirement falls out of a quorum-intersection argument that has to account for liars.

A BFT system must collect a quorum of matching messages before acting. Call the total number of nodes `N` and the quorum size `Q`. Two constraints must hold simultaneously:

1. **Progress despite silence.** Up to `f` nodes may be faulty and unresponsive, so a quorum must be reachable using only the `N - f` nodes that respond. Thus `Q ≤ N - f`.

2. **Safety despite lies.** Any two quorums must intersect in at least one *honest* node, otherwise two quorums could decide differently with no honest witness in common. Two quorums of size `Q` overlap in `2Q - N` nodes. That overlap must contain at least one honest node, i.e. exceed the `f` possible liars: `2Q - N > f`.

Combine them. From (1), the worst case is `Q = N - f`. Substitute into (2):

```
2(N - f) - N > f
N - 2f > f
N > 3f
```

So `N ≥ 3f + 1`. To tolerate even one Byzantine node you need four; to tolerate two you need seven. The extra `f` over the crash-fault `2f + 1` is the literal price of not being able to trust what a node tells you.

## PBFT: practical Byzantine fault tolerance

Castro and Liskov's PBFT (1999) was the breakthrough that made BFT efficient enough for real systems. It tolerates `f` Byzantine faults with `3f + 1` replicas and runs in three phases per request, coordinated by a designated **primary** (leader) for the current **view**.

The phases exist to defeat the equivocation problem — a node telling different things to different peers. Each replica only acts once it has *cryptographic proof* that a supermajority saw the same thing.

{{< mermaid >}}
sequenceDiagram
  participant C as Client
  participant P as Primary
  participant R1 as Replica 1
  participant R2 as Replica 2
  participant R3 as Replica 3 (faulty)
  C->>P: request
  P->>R1: pre-prepare(m)
  P->>R2: pre-prepare(m)
  P->>R3: pre-prepare(m)
  R1->>R2: prepare
  R1->>P: prepare
  R2->>R1: prepare
  R2->>P: prepare
  Note over P,R2: each collects 2f matching prepares
  P->>R1: commit
  R1->>R2: commit
  R2->>P: commit
  Note over P,R2: each collects 2f+1 commits -> execute
  R1-->>C: reply
  R2-->>C: reply
  P-->>C: reply
{{< /mermaid >}}

### Pre-prepare

The primary assigns the request a sequence number and broadcasts `pre-prepare`. This proposes an ordering. A faulty primary could propose different orderings to different replicas — the next two phases catch that.

### Prepare

Each replica that accepts the pre-prepare broadcasts `prepare` to all others. When a replica has collected `2f` matching prepares (plus its own pre-prepare), it is **prepared**. Being prepared proves that a supermajority agrees on *this request at this sequence number within this view* — no two honest replicas can be prepared for different requests at the same slot, because their quorums would overlap in an honest node that cannot have voted both ways.

### Commit

A prepared replica broadcasts `commit`. When it gathers `2f + 1` matching commits, it executes the request and replies to the client. This second round guarantees the ordering survives even a **view change** (leader replacement), so a request committed in one view is never reordered in the next.

### Client acceptance

The client waits for `f + 1` matching replies before trusting the result. Since at most `f` replicas are faulty, `f + 1` matching answers guarantees at least one came from an honest replica — and honest replicas only report committed results.

## View changes

If the primary is faulty or slow, replicas trigger a **view change** to elect a new primary. They exchange their prepared-state proofs so the new primary can reconstruct any request that might already have committed, preventing the new view from losing or reordering decided work. View changes are the most intricate part of PBFT, precisely because they must preserve safety while the leadership is in flux — analogous to Raft's leader election but with the added burden of not trusting the messages exchanged during the handover.

## Cost and scalability

BFT is expensive, and the bill comes in three parts:

- **Message complexity.** The prepare and commit phases are all-to-all broadcasts, giving `O(n²)` messages per request. Doubling the replica count quadruples the chatter. This is why classic PBFT works well around a dozen nodes and poorly at hundreds.
- **Cryptographic overhead.** Every message is signed or MAC-authenticated so receivers can prove provenance and detect forgery.
- **Replica count.** You need `3f + 1` machines doing redundant work to tolerate `f` faults — `f` more machines (approaching 50% more hardware as `f` grows) than a crash-fault system for the same `f`.

Modern descendants attack the `O(n²)` problem. HotStuff (used by Diem/Libra-lineage systems) linearizes communication to `O(n)` by routing through the leader and using threshold signatures to aggregate votes, which is why it scales to far more validators than classic PBFT.

| System | Fault model | Communication | Notable use |
|--------|-------------|---------------|-------------|
| PBFT | Byzantine | O(n²) | Permissioned ledgers |
| Tendermint | Byzantine | O(n²) | Cosmos chains |
| HotStuff | Byzantine | O(n) | Diem-lineage, scalable BFT |
| Raft | Crash only | O(n) | etcd, Consul |

## When you actually need BFT

This is the question that matters most, because BFT's cost is real and most systems do not need it. Reach for Byzantine fault tolerance when **you cannot trust the nodes themselves**:

- **Open, permissionless networks** — public blockchains, where anyone can run a node and some will be adversarial by design.
- **Cross-organizational systems** — a consortium ledger where competing companies each run replicas and none fully trusts the others.
- **Extreme-integrity environments** — avionics or aerospace, where a node may behave arbitrarily due to radiation-induced bit flips rather than malice, and silent corruption is unacceptable.

For an internal datacenter cluster where you operate every machine, run trusted code, and your real threats are crashes and network partitions — not lying nodes — crash-fault tolerance (Raft, Paxos) is the correct, far cheaper choice. Paying for BFT there buys protection against a threat your environment does not actually contain.

## Conclusion

Byzantine fault tolerance is consensus for a world where nodes can lie. That single change to the fault model raises the replica requirement from `2f + 1` to `3f + 1`, because quorums must now overlap in an *honest* node, not just any node. PBFT showed it could be done efficiently with a three-phase protocol whose prepare and commit rounds exist precisely to defeat a node that says different things to different peers, and modern protocols like HotStuff push the scalability further by linearizing communication. The deciding question is never "is BFT cooler than Raft" — it is "can I trust my own nodes?" If you can, use crash-fault tolerance and save the hardware. If you genuinely cannot, BFT is the only thing that keeps a single traitor from splitting your system in two.
