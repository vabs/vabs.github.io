---
title: "HTTP/3 and QUIC Packet Loss Recovery"
date: 2026-01-11T16:50:00-04:00
draft: false
featured: false
tags: [backend, quic, http3, networking, loss-recovery]
---

## Why QUIC reinvented loss recovery

HTTP/3 runs over QUIC, and QUIC runs over UDP. UDP gives you nothing: no ordering, no retransmission, no congestion control, no connection concept. QUIC rebuilds all of it in user space, on top of UDP, and in doing so it gets to fix the parts of TCP that were impossible to change because TCP is baked into operating system kernels and middleboxes.

The most important thing QUIC fixes is the interaction between loss recovery and stream multiplexing. HTTP/2 multiplexes streams over a single TCP connection, but TCP delivers a single, ordered byte stream. If one TCP segment is lost, the kernel holds back every later byte, across all HTTP/2 streams, until the missing segment is retransmitted. That is transport-layer head-of-line blocking, and HTTP/2 cannot escape it because it does not control TCP. QUIC controls its own transport, so it can make loss on one stream affect only that stream.

To make that work, QUIC's loss detection had to be redesigned from the ground up. The redesign centers on one deceptively simple decision: packet numbers are monotonic and never reused.

## Monotonic packet numbers: the key insight

In TCP, a sequence number identifies a byte position in the stream. When a segment is retransmitted, it carries the same sequence number as the original. This creates **retransmission ambiguity**: when an ACK arrives, the sender cannot tell whether it acknowledges the original transmission or the retransmission. That ambiguity poisons RTT measurement (you do not know which send time to subtract) and complicates loss detection.

QUIC separates the two concerns that TCP conflated. A **packet number** identifies a transmission; a **stream offset** identifies a position in a stream's data. When QUIC retransmits lost data, it puts that data in a brand-new packet with a brand-new, higher packet number. The same bytes can be carried by packet 42 the first time and packet 89 the second time.

```text
TCP:   seq=1000 carries bytes [1000..2000)
       retransmit -> seq=1000 again (ambiguous on ACK)

QUIC:  packet 42 carries STREAM frame (offset 1000, len 1000)
       loss -> packet 89 carries STREAM frame (offset 1000, len 1000)
       ACK of 42 vs 89 is unambiguous
```

Because every ACK refers to an unambiguous packet number, the sender always knows exactly which transmission was acknowledged and exactly when it was sent. RTT samples are clean. Loss inference is reliable.

## How QUIC detects loss

QUIC declares a packet lost using two complementary triggers, both defined in RFC 9002.

### Packet threshold (reordering)

When a packet is acknowledged, every unacknowledged packet sent sufficiently earlier is suspected lost. The default reordering threshold is 3: if a packet numbered at least 3 lower than the largest acknowledged packet is still outstanding, it is declared lost. This is the QUIC analog of TCP's "three duplicate ACKs," but cleaner because packet numbers are strictly increasing and never reused, so "earlier" is unambiguous.

### Time threshold

Reordering can also be temporal. If a later packet has been acknowledged and an earlier packet was sent more than a threshold of time ago, the earlier one is declared lost even if the packet-number gap is small. The threshold is derived from the smoothed RTT and its variation:

```text
time_threshold = max(kTimeThreshold * max(smoothed_rtt, latest_rtt),
                     kGranularity)
kTimeThreshold = 9/8
```

A packet is lost if it was sent before `now - time_threshold`.

{{< mermaid >}}
sequenceDiagram
    participant S as Sender
    participant R as Receiver
    S->>R: Packet 40 (stream A)
    S->>R: Packet 41 (stream B) [LOST]
    S->>R: Packet 42 (stream A)
    S->>R: Packet 43 (stream C)
    R->>S: ACK 40, 42, 43
    Note over S: 41 is 2+ below largest acked (43)
    Note over S: and older than time threshold
    S->>S: Declare packet 41 lost
    S->>R: Packet 44: retransmit frames from 41
{{< /mermaid >}}

### ACK frames carry ranges

QUIC ACK frames are richer than TCP's. They acknowledge ranges of packet numbers (like TCP SACK but always present), and they include an **ACK delay** field telling the sender how long the receiver waited before sending the ACK. The sender subtracts that delay when computing RTT, producing a more accurate estimate of the true network round trip.

## Probe Timeout: handling tail loss

The threshold-based detectors only fire when later ACKs arrive. If the very last packets in a burst are lost, no later ACK exists to trigger detection. TCP handles this with the RTO and, partially, with Tail Loss Probe. QUIC unifies these into the **Probe Timeout (PTO)**.

```text
PTO = smoothed_rtt + max(4 * rttvar, kGranularity) + max_ack_delay
```

When the PTO timer fires, QUIC does **not** assume congestion and does not collapse its congestion window the way a TCP RTO does. Instead it sends one or two probe packets (often new data, or PING frames if there is nothing to send) to elicit an ACK. If those probes are acknowledged but earlier packets are not, the threshold detectors then declare the earlier packets lost. The PTO interval doubles on each consecutive expiry (exponential backoff). Crucially, separating "probe to elicit information" from "react to congestion" avoids the brutal throughput cliff that a spurious TCP RTO causes.

| Mechanism | TCP | QUIC |
|-----------|-----|------|
| Fast retransmit | 3 duplicate ACKs | Packet threshold (default 3) |
| Reordering by time | Limited | Time threshold (9/8 x RTT) |
| Tail loss | RTO (resets cwnd to 1) | PTO (probes, no cwnd reset) |
| Selective ACK | Optional SACK | Always range-based ACKs |
| RTT ambiguity | Present on retransmit | Eliminated by new packet numbers |

## Streams isolate the damage

Now the payoff. When QUIC declares packet 41 lost in the diagram above, only the STREAM frames that were in packet 41 need retransmission. Suppose packet 41 carried data for stream B. Streams A, C, and D are completely unaffected. Their data, which arrived in other packets, is delivered to the application immediately. Only stream B waits for the retransmission.

{{< mermaid >}}
graph TD
    A["Packet 41 lost (stream B data)"] --> B["QUIC declares loss"]
    B --> C["Retransmit only stream B frames"]
    D["Stream A data in packet 40, 42"] --> E["Delivered to app now"]
    F["Stream C data in packet 43"] --> E
    G["Stream B data"] --> H["Waits for retransmit"]
    C --> H
{{< /mermaid >}}

Compare this to HTTP/2 over TCP, where the loss of the segment carrying stream B's bytes would stall stream A and stream C as well, because TCP refuses to deliver any bytes past the gap. This per-stream isolation is the single biggest reason HTTP/3 outperforms HTTP/2 on lossy networks like mobile.

## Congestion control still applies

Loss recovery and congestion control are separate concerns, and QUIC keeps them separate. When a packet is declared lost (by threshold, not by PTO probe), QUIC feeds that signal to its congestion controller, which by default behaves like NewReno but can be CUBIC or BBR. The congestion controller reduces the congestion window. Because QUIC lives in user space, deploying a new congestion control algorithm is a library update, not a kernel upgrade across an entire fleet, so QUIC stacks iterate on congestion control far faster than TCP ever could.

QUIC also tracks bytes in flight per connection and paces packet sending, smoothing out bursts that would otherwise cause queueing and loss. Pacing pairs naturally with model-based controllers like BBR.

## Connection migration changes the loss picture

QUIC connections are identified by a **Connection ID**, not by the 4-tuple of IPs and ports. When a phone moves from Wi-Fi to cellular, its IP changes, which would kill a TCP connection. QUIC can continue the same connection on the new path (typically switching to a fresh Connection ID issued by the peer, so the two paths cannot be linked). From a loss-recovery standpoint, a path change means RTT and bandwidth estimates may be stale, so QUIC validates the new path and is conservative until it has fresh measurements. This is a scenario TCP simply cannot handle without tearing down and re-establishing.

## Practical notes for operators

```text
- QUIC needs UDP open; some networks block or throttle UDP, so
  clients keep a TCP/HTTP-2 fallback (happy eyeballs style).
- Monitor PTO counts and spurious-retransmit rates; high spurious
  retransmits suggest your time/packet thresholds are too aggressive.
- Choose congestion control per workload: BBR for high-BDP/long-haul,
  CUBIC for general internet, all swappable in user space.
- GSO/GRO and UDP offload matter: QUIC's per-packet CPU cost is higher
  than TCP, so kernel offloads are important at scale.
```

The throughline: by giving itself unambiguous, never-reused packet numbers, QUIC turns loss detection into a clean, well-defined problem. Threshold and time detectors handle reordering, PTO handles tail loss without punishing throughput, and because the transport understands streams, a lost packet only delays the streams whose data it carried. That combination is what finally kills transport-layer head-of-line blocking, the one thing HTTP/2 could never fix while it was chained to TCP.
