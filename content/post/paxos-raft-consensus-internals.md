---
title: "Paxos / Raft Consensus Internals"
date: 2026-04-20T11:15:00-04:00
draft: false
featured: false
tags: [backend, consensus, raft, paxos, distributed-systems]
---

Consensus is the problem of getting a group of unreliable machines to agree on a single value — and to keep agreeing even as some of them crash, restart, and rejoin. It is the foundation under replicated databases, configuration stores like etcd and ZooKeeper, and leader election everywhere. Two algorithms dominate the conversation: Paxos, the theoretical bedrock, and Raft, the version designed to actually be understandable. This post walks through what they guarantee, how each one works mechanically, and why Raft replaced Paxos in most engineers' heads.

## What consensus must guarantee

A correct consensus protocol over a set of nodes must satisfy three properties even when a minority of nodes fail (crash-stop, not malicious):

- **Agreement** — no two nodes decide on different values.
- **Validity** — the decided value was actually proposed by some node (no inventing values).
- **Termination** — every non-faulty node eventually decides.

The hard part is achieving all three under asynchrony and failure. The FLP impossibility result proves you cannot guarantee termination in a fully asynchronous system with even one faulty node, so real protocols lean on partial synchrony — timeouts and eventual message delivery — to make progress in practice while never violating agreement.

The other foundational idea is the **quorum**. With `2f + 1` nodes you tolerate `f` failures by requiring any decision to be acknowledged by a majority (`f + 1`). Any two majorities overlap in at least one node, and that overlapping node is what prevents two conflicting decisions from both succeeding.

## Paxos: the original

Basic (single-decree) Paxos decides one value among proposers, acceptors, and learners. Most nodes play all three roles. It runs in two phases, both driven by monotonically increasing **proposal numbers** that act as a logical priority — higher numbers win.

### Phase 1: Prepare / Promise

A proposer picks a proposal number `n` higher than any it has used and sends `prepare(n)` to a majority of acceptors. An acceptor that receives `prepare(n)`:

- If `n` is greater than any prepare it has already promised, it **promises** not to accept any proposal numbered less than `n`, and replies with the highest-numbered proposal it has *already accepted* (if any).
- Otherwise it ignores or rejects.

### Phase 2: Accept / Accepted

If the proposer gets promises from a majority, it sends `accept(n, v)`. The crucial rule: `v` is **not** freely chosen. If any promise reported a previously accepted value, the proposer *must* propose the value with the highest proposal number among those reports. Only if no acceptor had accepted anything may the proposer use its own value. An acceptor accepts `(n, v)` unless it has since promised a higher number.

Once a majority accepts `(n, v)`, the value is chosen.

{{< mermaid >}}
sequenceDiagram
  participant P as Proposer
  participant A1 as Acceptor 1
  participant A2 as Acceptor 2
  participant A3 as Acceptor 3
  P->>A1: prepare(n)
  P->>A2: prepare(n)
  P->>A3: prepare(n)
  A1-->>P: promise(n, none)
  A2-->>P: promise(n, none)
  Note over P: majority promised
  P->>A1: accept(n, v)
  P->>A2: accept(n, v)
  A1-->>P: accepted(n, v)
  A2-->>P: accepted(n, v)
  Note over P: majority accepted -> v chosen
{{< /mermaid >}}

That "must adopt the highest accepted value" rule in Phase 2 is the entire safety argument: it guarantees that once a value could have been chosen, every later proposal carries that same value forward, so two different values can never both be chosen.

### Why Paxos is painful

Single-decree Paxos decides *one* value. Real systems need a *sequence* of decisions — a replicated log — which means Multi-Paxos: running an instance per log slot, with a stable leader to skip Phase 1 in the common case. The original papers left log management, leader election, membership changes, and recovery as exercises. The result is that every production "Paxos" is a different, under-specified beast, and almost no one implements it correctly from the paper alone. That gap is exactly what Raft set out to close.

## Raft: consensus you can hold in your head

Raft solves the same problem and is provably equivalent in guarantees, but it is *designed for understandability*. It does this by decomposing consensus into three crisp subproblems — **leader election**, **log replication**, and **safety** — and by enforcing a strong leader: all client writes flow through one leader, and the log only ever flows leader → followers.

Every node is in one of three states, and time is divided into **terms**, each beginning with an election. The term number is a logical clock that lets nodes reject stale leaders.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Follower
  Follower --> Candidate: election timeout, no heartbeat
  Candidate --> Leader: wins majority vote
  Candidate --> Follower: discovers current leader or higher term
  Candidate --> Candidate: split vote, new election
  Leader --> Follower: discovers higher term
{{< /mermaid >}}

### Leader election

Followers expect periodic heartbeats from the leader. If a follower hears nothing within its randomized election timeout, it becomes a candidate, increments the term, votes for itself, and requests votes from everyone. A node grants its vote at most once per term, and only to a candidate whose log is **at least as up-to-date** as its own. A candidate that collects a majority becomes leader and starts sending heartbeats.

Randomized timeouts are the clever bit: by spreading timeouts over a range, Raft makes simultaneous candidacies (split votes) rare, so elections usually resolve in one round.

### Log replication

The leader appends each client command to its log and sends `AppendEntries` to followers. Each entry carries its term and index. A follower accepts an entry only if its log matches the leader's at the preceding entry — the **Log Matching Property** — which the leader checks by including the index and term of the entry immediately before the new one.

```
Leader log:    [1:x] [1:y] [2:z] [3:w]
Follower log:  [1:x] [1:y] [2:q]          <- diverged at index 3
```

When AppendEntries fails the consistency check, the leader decrements the index it sends and retries, walking backward until it finds the last point of agreement, then overwrites the follower's conflicting suffix. The leader never overwrites its *own* log — only followers' logs are forced to match the leader.

An entry is **committed** once it is stored on a majority. The leader then applies it to its state machine and tells followers the new commit index so they apply it too.

```python
# leader's commit advancement (simplified)
def advance_commit_index(self):
    for n in range(self.commit_index + 1, len(self.log)):
        replicated = 1 + sum(
            1 for f in self.followers if f.match_index >= n
        )
        # only commit entries from the current term directly
        if replicated > len(self.cluster) // 2 \
                and self.log[n].term == self.current_term:
            self.commit_index = n
```

That last condition — only directly commit entries from the *current* term — closes a subtle safety hole where a leader could otherwise commit an old entry that a later leader might still overwrite.

### The safety rules

Raft's correctness rests on a small set of guarantees that work together:

| Property | What it ensures |
|----------|-----------------|
| Election Restriction | Only a candidate with an up-to-date log can win, so no committed entry is ever lost |
| Leader Append-Only | A leader never deletes or overwrites its own entries |
| Log Matching | If two logs agree at an index/term, they agree on everything before it |
| Leader Completeness | A committed entry is present in every future leader's log |
| State Machine Safety | If a node applies an entry at an index, no node applies a different entry there |

## Paxos versus Raft

| Dimension | Multi-Paxos | Raft |
|-----------|-------------|------|
| Mental model | Symmetric, any node proposes | Strong single leader |
| Log handling | Left to implementer | Built into the protocol |
| Leader election | Underspecified | First-class, randomized timeouts |
| Understandability | Notoriously hard | Designed to be teachable |
| Membership changes | Ad hoc | Joint consensus, specified |
| Where you see it | Chubby, Spanner internals | etcd, Consul, CockroachDB, TiKV |

They offer the same fault tolerance (`f` failures out of `2f+1`) and the same safety. Raft trades the theoretical generality of Paxos — where any node can propose at any time — for a prescriptive structure that an engineer can implement correctly without a PhD. That trade is why almost every new system since roughly 2014 chose Raft.

## Practical realities

Both protocols share operational truths worth internalizing. Writes need a round trip to a majority, so consensus latency is bounded by your slowest *median* replica, not your fastest — placing replicas across distant regions makes every commit pay the inter-region RTT. A cluster of `2f+1` only stays available while a majority is up; lose the majority and the system correctly refuses writes rather than risk split-brain. And membership changes are dangerous if done naively — adding or removing nodes can momentarily create two disjoint majorities — which is why Raft specifies joint consensus to transition through a combined old-and-new configuration safely.

## Conclusion

Paxos proved that fault-tolerant agreement is possible and gave us the quorum-overlap argument that underlies every consensus protocol since. Raft took the same guarantees and made them *operational*, by insisting on a strong leader, baking the replicated log into the protocol, and specifying election and membership changes that Paxos left vague. If you are building on consensus, you almost certainly want Raft for its clarity; if you are reading the literature or the internals of older giants, you need Paxos to understand where it all came from. Either way, the durable lessons are the same: majorities overlap, terms or proposal numbers impose order, and committed means replicated on a quorum — never just stored locally.
