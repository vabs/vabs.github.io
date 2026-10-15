---
title: "TCP Congestion Control Algorithms"
date: 2026-01-03T09:15:00-04:00
draft: false
featured: false
tags: [backend, tcp, networking, congestion-control, performance]
---

## Why congestion control exists

A TCP sender has two limits on how fast it can transmit. The first is the receiver's advertised window (rwnd), which protects the receiver's buffer. The second is the congestion window (cwnd), which protects the network. Without the second limit, every sender would dump packets into shared links as fast as the receiver could absorb them, queues would overflow, routers would drop packets en masse, and the whole network would collapse into a state where almost everything retransmits and almost nothing makes progress. That scenario actually happened on the early internet in 1986, and congestion control is the response.

The core idea is simple: the sender never knows the available bandwidth in advance, so it probes. It increases its sending rate until it sees a signal of congestion, then it backs off. The differences between algorithms come down to two questions: what counts as a congestion signal, and how aggressively do you increase and decrease in response.

The effective send rate is bounded by the minimum of the two windows:

```text
send_window = min(cwnd, rwnd)
in_flight   = bytes sent but not yet acknowledged
sender may transmit while: in_flight < send_window
```

## The classic loss-based model: Reno and NewReno

TCP Reno treats packet loss as the congestion signal. It operates in distinct phases.

### Slow start

When a connection opens, the sender has no idea what the network can handle. It starts with a small `cwnd` (typically 10 MSS in modern stacks, historically 1-4) and doubles it every round trip. Despite the name, this is exponential growth: each ACK increases `cwnd` by one MSS, so after a full window of ACKs the window has doubled.

```text
on each ACK during slow start:
    cwnd += MSS
```

Slow start continues until `cwnd` reaches the slow start threshold (`ssthresh`) or a loss occurs.

### Congestion avoidance

Once `cwnd >= ssthresh`, the sender switches to additive increase: it grows `cwnd` by roughly one MSS per round trip rather than per ACK.

```text
on each ACK during congestion avoidance:
    cwnd += MSS * MSS / cwnd
```

This is the "AI" half of AIMD (Additive Increase, Multiplicative Decrease). The window probes upward in a gentle straight line.

### Reacting to loss

Reno distinguishes two loss signals:

| Signal | Interpretation | Reaction |
|--------|---------------|----------|
| Three duplicate ACKs | Mild congestion, packet lost but later packets arriving | Halve cwnd, fast retransmit, fast recovery |
| Retransmission timeout (RTO) | Severe congestion, pipe likely empty | cwnd back to 1, restart slow start |

On three duplicate ACKs, Reno sets `ssthresh = cwnd / 2`, sets `cwnd = ssthresh`, and retransmits the missing segment without waiting for a timeout. NewReno improves the recovery logic so that multiple losses within one window do not each trigger a separate, expensive timeout.

{{< mermaid >}}
stateDiagram-v2
    [*] --> SlowStart
    SlowStart --> CongestionAvoidance: cwnd >= ssthresh
    SlowStart --> SlowStart: ACK doubles window
    CongestionAvoidance --> CongestionAvoidance: ACK adds 1 MSS/RTT
    CongestionAvoidance --> FastRecovery: 3 dup ACKs
    FastRecovery --> CongestionAvoidance: new ACK
    CongestionAvoidance --> SlowStart: RTO timeout
    SlowStart --> SlowStart: RTO resets cwnd to 1
{{< /mermaid >}}

The classic sawtooth pattern of `cwnd` over time comes directly from AIMD: a slow ramp up, a sudden halving on loss, and another slow ramp.

## The problem with loss-based control

Reno and NewReno equate loss with congestion. That assumption breaks in two important ways for modern networks.

First, **bufferbloat**. Routers and middleboxes ship with deep buffers. A loss-based sender keeps increasing its window until a buffer somewhere overflows. Before the overflow, those buffers are full, which means every packet sits in a long queue. The connection achieves high throughput but terrible latency, because the algorithm is literally optimizing toward keeping queues full.

Second, **random loss**. On wireless and long-distance links, packets can be lost for reasons unrelated to congestion (radio interference, bit errors). A loss-based sender misinterprets this as congestion and needlessly halves its window, leaving bandwidth unused. This is why Reno performs poorly on high-bandwidth, high-latency paths (high bandwidth-delay product).

## CUBIC: scaling to fat pipes

CUBIC is the default congestion control on Linux and therefore on most servers you interact with. It is still loss-based, but it replaces the linear additive increase with a cubic function of time since the last congestion event.

```text
W(t) = C * (t - K)^3 + W_max

W_max = window size at last loss
K     = cube root of (W_max * (1 - beta) / C)
C     = scaling constant (default 0.4)
beta  = multiplicative decrease factor (0.7)
```

The shape matters. Right after a loss, the cubic function grows fast (the concave region), quickly reclaiming most of the bandwidth that was just lost. As the window approaches `W_max`, growth flattens out, letting the connection probe carefully around the level that previously caused loss. Then, past `W_max`, the convex region accelerates again to discover newly available bandwidth.

Critically, CUBIC's growth depends on real elapsed time, not on RTT. This makes it RTT-fair: two flows with very different round-trip times grow their windows on the same wall-clock schedule, so the short-RTT flow does not starve the long-RTT flow the way Reno does.

## BBR: modeling the pipe instead of reacting to loss

BBR (Bottleneck Bandwidth and Round-trip propagation time), developed at Google, takes a fundamentally different stance. Instead of treating loss as the signal, it builds an explicit model of the path and paces packets to match it.

BBR continuously estimates two quantities:

- **BtlBw**: the bottleneck bandwidth, measured as the maximum delivery rate observed.
- **RTprop**: the round-trip propagation delay, measured as the minimum RTT observed (minimum because the minimum has no queueing delay added).

The ideal operating point, the bandwidth-delay product, is `BtlBw * RTprop`. That is exactly enough data in flight to keep the bottleneck link busy with no standing queue. BBR aims to put precisely this much data in flight, which keeps latency low while saturating throughput.

{{< mermaid >}}
sequenceDiagram
    participant S as BBR Sender
    participant N as Bottleneck Link
    participant R as Receiver
    S->>N: Send at pacing rate
    N->>R: Forward (BtlBw limited)
    R->>S: ACK with delivery info
    S->>S: Update BtlBw = max rate
    S->>S: Update RTprop = min RTT
    S->>S: inflight target = BtlBw * RTprop
{{< /mermaid >}}

BBR cycles through states: it periodically probes for more bandwidth by briefly sending faster (ProbeBW), and periodically drains the queue to re-measure true RTprop (ProbeRTT). Because it does not need loss to back off, BBR maintains high throughput on lossy links and avoids filling deep buffers, directly attacking the two weaknesses of loss-based control.

The trade-off is fairness. Early BBR could be aggressive when sharing a link with CUBIC flows, sometimes claiming more than its fair share. BBRv2 and later versions add a response to loss and to ECN signals to coexist more politely.

## Comparing the families

| Algorithm | Signal | Increase | Decrease | Strength | Weakness |
|-----------|--------|----------|----------|----------|----------|
| Reno/NewReno | Loss | Linear (AIMD) | Halve | Simple, well understood | Poor on high BDP, fills buffers |
| CUBIC | Loss | Cubic in time | x0.7 | RTT-fair, scales to fat pipes | Still loss-based, bufferbloat |
| Vegas | Delay (RTT increase) | Linear | Linear | Low queueing, proactive | Loses to loss-based flows |
| BBR | Bandwidth + RTT model | Model-based pacing | Model-based | High throughput, low latency | Fairness vs CUBIC, complexity |

## ECN: an explicit alternative to inference

Every loss-based scheme is fundamentally inferring congestion from a side effect. Explicit Congestion Notification (ECN) lets routers mark packets (rather than drop them) when their queues start to build. The receiver echoes the mark back to the sender, which reacts as if a loss occurred but without losing data. Data-center variants like DCTCP use the proportion of ECN-marked packets to scale the window reduction precisely, which produces far smoother behavior than the blunt instrument of halving on loss.

## What this means for backend engineers

You rarely write congestion control, but the choice affects your services directly. On Linux, you can inspect and change it:

```bash
sysctl net.ipv4.tcp_congestion_control   # current default, usually cubic
sysctl net.ipv4.tcp_available_congestion_control
sysctl -w net.ipv4.tcp_congestion_control=bbr
```

For latency-sensitive services behind load balancers, or for serving large objects over long-haul links, switching to BBR often improves tail latency and throughput simultaneously, because it stops filling intermediate buffers. For internal data-center traffic, ECN-based schemes like DCTCP keep queues tiny and predictable. The unifying lesson is that congestion control is a feedback loop, and the quality of the feedback signal (loss, delay, explicit marks, or a measured model) determines how well that loop performs.
