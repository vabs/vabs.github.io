---
title: "Garbage Collection Tuning: G1 vs ZGC"
date: 2026-03-04T15:42:00-04:00
draft: false
featured: false
tags: [backend, jvm, gc, performance, java]
---

Garbage collection is the JVM feature most developers ignore until a production incident forces them to care. A service that hums along at p50 latency of 5ms can suddenly spike to 800ms because a stop-the-world pause froze every thread to reclaim memory. Choosing and tuning the right collector is one of the highest-leverage things you can do for a latency-sensitive Java service. This post compares the two collectors that matter most for modern server workloads: G1 (the default since Java 9) and ZGC (the low-latency contender that went production-ready and non-generational in newer releases).

## The Fundamental Trade-off

Every garbage collector balances three competing goals, and you cannot maximize all of them simultaneously:

- **Throughput** — the fraction of total CPU time spent doing application work rather than GC.
- **Latency** — the length and frequency of pauses that stop application threads.
- **Footprint** — the heap and metadata overhead required to run the collector.

G1 (Garbage First) is a throughput-oriented collector that tries to keep pauses under a soft goal you set. ZGC is a latency-oriented collector designed to keep pauses under a millisecond regardless of heap size, trading some throughput and CPU for that guarantee.

{{< mermaid >}}
graph TD
  A["Workload Profile"] --> B{"Pause sensitivity?"}
  B -->|"Tolerate 50-200ms"| C["G1: better throughput, lower CPU"]
  B -->|"Need sub-millisecond"| D["ZGC: flat pauses, higher CPU"]
  C --> E["Batch, analytics, most web apps"]
  D --> F["Trading, real-time, huge heaps"]
{{< /mermaid >}}

## How G1 Works

G1 divides the heap into equal-sized regions (typically 1-32 MB each, sized automatically). Regions are dynamically assigned roles: Eden, Survivor, Old, or Humongous (for objects larger than half a region). This region model is what lets G1 do **incremental** collection: instead of collecting the whole old generation at once, it collects a subset of regions chosen to maximize garbage reclaimed per unit of pause time, hence "Garbage First."

A G1 cycle has phases:

1. **Young collection** — stop-the-world, copies live objects out of Eden and Survivor regions. Frequent and relatively cheap.
2. **Concurrent marking** — runs alongside the application to identify live objects across the old generation.
3. **Mixed collection** — stop-the-world young collections that *also* include some old regions, gradually cleaning up old garbage.

G1's headline knob is the pause target:

```bash
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200      # soft goal, default 200ms
-XX:G1HeapRegionSize=16m      # usually leave to auto-sizing
-XX:InitiatingHeapOccupancyPercent=45  # when concurrent marking starts
```

G1 treats `MaxGCPauseMillis` as a *soft* goal. It sizes the young generation and chooses how many regions to collect per pause to try to hit it. Set it too aggressively (say 10ms) and G1 will shrink the young gen so much that collections become frequent and throughput collapses. A realistic value is 100-200ms for most services.

## How ZGC Works

ZGC takes a radically different approach built around **colored pointers** and **load barriers**. The key insight: almost all of ZGC's work, including compaction (moving live objects to defragment the heap), happens concurrently with the application. The only stop-the-world pauses are tiny, bounded operations like scanning thread stack roots, and these do not grow with heap size.

Colored pointers embed metadata bits directly in the object reference. When the application loads a reference, a **load barrier** checks those bits. If the object has been relocated, the barrier transparently fixes up the pointer and may help with concurrent relocation. This is how ZGC moves objects out from under a running application without stopping it.

```bash
-XX:+UseZGC                  # generational by default in current releases
-Xmx16g
-XX:SoftMaxHeapSize=14g      # encourage GC before hitting hard max
```

Modern ZGC is **generational**, maintaining separate young and old generations. This was a major improvement: non-generational ZGC scanned the whole heap on every cycle, which was wasteful given that most objects die young. The generational version collects the young generation frequently and cheaply while collecting the old generation less often, dramatically improving CPU efficiency.

## Pause Behavior Compared

This is the crux of the comparison. G1's pause times grow with the amount of live data it processes per collection. ZGC's pauses are essentially constant.

| Metric | G1 | ZGC (generational) |
|---|---|---|
| Typical max pause | 50-200ms | < 1ms |
| Pause scales with heap? | Yes | No |
| Max practical heap | ~tens of GB | Multi-TB |
| Throughput overhead | Low (~5%) | Moderate (~10-15%) |
| CPU overhead | Low | Higher (barriers, concurrent work) |
| Memory footprint | Lower | Higher (colored pointers, remembered sets) |
| Compaction | During pauses | Concurrent |

The trade-off is clear: ZGC buys you flat, tiny pauses at the cost of more CPU and memory. If you run a 200 GB heap and cannot tolerate multi-hundred-millisecond pauses, ZGC is transformative. If you run a 4 GB heap on a batch job, G1's superior throughput wins.

## A Tuning Workflow

Tuning starts with measurement, never with guessing. Enable unified GC logging:

```bash
-Xlog:gc*,gc+heap=debug,gc+age=trace:file=gc.log:time,uptime,level,tags
```

Then walk through this decision flow.

{{< mermaid >}}
graph LR
  A["Collect GC logs"] --> B["Compute pause distribution"]
  B --> C{"p99 pause acceptable?"}
  C -->|"Yes"| D["Stay on G1, tune young gen"]
  C -->|"No, and heap large"| E["Try ZGC"]
  D --> F["Watch allocation rate"]
  E --> G["Watch CPU and allocation stalls"]
  F --> H["Iterate"]
  G --> H
{{< /mermaid >}}

### Tuning G1

The most common G1 problems and their fixes:

- **Frequent young GCs / high allocation rate.** Your application allocates too fast. First, reduce allocation (object pooling, avoiding autoboxing, reusing buffers). If you can't, increase the young generation indirectly by relaxing `MaxGCPauseMillis` or raising the heap.
- **Long mixed collections.** Too much old garbage accumulating. Lower `InitiatingHeapOccupancyPercent` so concurrent marking starts earlier, giving G1 more time to clean up before the heap fills.
- **Humongous allocations.** Objects larger than half a region get special, expensive handling. If you allocate many large arrays, increase `G1HeapRegionSize` so they no longer count as humongous.
- **Full GC (the failure mode).** A full GC in G1 is a fallback that means concurrent collection couldn't keep up. It's a long stop-the-world event. Seeing these means you need more heap or earlier marking.

### Tuning ZGC

ZGC has far fewer knobs by design, which is a feature. The main concerns:

- **Allocation stalls.** If the application allocates faster than ZGC can reclaim, threads stall waiting for memory. The log shows `Allocation Stall` events. The fix is almost always more heap or more GC CPU (ZGC auto-sizes its concurrent threads, but you can bound them).
- **SoftMaxHeapSize.** Set this below `-Xmx` to give ZGC a target it tries to stay under, triggering collection earlier and leaving headroom to absorb allocation spikes.
- **CPU budget.** ZGC's concurrent work competes with your application for cores. On a CPU-saturated box, ZGC may struggle. Ensure you have spare cores.

## Reading the Allocation Rate

The single most useful number across both collectors is **allocation rate** (bytes/second of new objects). It drives young-GC frequency directly. From GC logs you can compute it as the heap consumed between consecutive young collections divided by the time elapsed. A service allocating 2 GB/s on a 1 GB young generation will trigger a young GC roughly twice per second. Lowering allocation rate is often more effective than any collector tuning, because the cheapest GC is the one that never runs. Common wins: avoid creating short-lived wrapper objects in hot loops, reuse byte buffers, and prefer primitive collections over boxed ones.

## A Worked Decision

Suppose you run an order-matching service: 32 GB heap, latency SLO of p99 < 10ms, moderate allocation rate. G1 with a 200ms pause target will blow your SLO every time it does a mixed collection. Even an aggressive 20ms target won't reliably hold, and it tanks throughput trying. This is a textbook ZGC case: switch to generational ZGC, set `-Xmx32g -XX:SoftMaxHeapSize=28g`, ensure you have cores to spare, and your GC pauses drop into the sub-millisecond range, comfortably inside the SLO.

Now suppose you run a nightly ETL job: 8 GB heap, no latency SLO, you just want it to finish fast. Here ZGC's CPU overhead is pure waste. Stick with G1 (or even the throughput-maximizing Parallel collector), set a generous pause target, give it plenty of young generation, and let it rip.

## Conclusion

G1 and ZGC are not competitors so much as tools for different jobs. G1 is the sensible default: good throughput, predictable enough pauses for the vast majority of web and batch services, and a low resource footprint. ZGC is the specialist that erases the relationship between heap size and pause time, making it the right choice for large heaps and strict latency SLOs, at the cost of extra CPU and memory. Whichever you choose, the discipline is the same: turn on GC logging, measure allocation rate and pause distribution, change one thing at a time, and let the numbers, not folklore, guide your flags.
