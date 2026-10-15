---
title: "Virtual Memory and Page Faults Impact"
date: 2026-05-28T16:40:00-04:00
draft: false
tags: [backend, operating-systems, performance, memory, linux]
---

## The abstraction every process lives inside

Every process on a modern OS runs inside a private virtual address space. The pointers your program dereferences are virtual addresses; they do not correspond directly to physical RAM. A hardware unit called the MMU, driven by per-process page tables, translates virtual addresses to physical ones at the granularity of a **page** — typically 4 KiB on x86-64.

This indirection buys a lot: isolation between processes, the ability to over-commit memory, demand paging, copy-on-write, memory-mapped files, and shared libraries that exist once in physical RAM but appear in many address spaces. The cost is that every memory access is potentially a translation, and sometimes that translation reveals the page is not actually resident. That event is a **page fault**, and understanding its flavors is the key to reasoning about backend performance.

{{< mermaid >}}
graph TD
    A["CPU issues virtual address"] --> B["MMU checks TLB"]
    B -->|"TLB hit"| C["Physical address, access proceeds"]
    B -->|"TLB miss"| D["Walk page tables"]
    D -->|"PTE present"| C
    D -->|"PTE not present"| E["Page fault to kernel"]
    E --> F{"Fault type?"}
    F -->|"Minor"| G["Map existing physical page, fast"]
    F -->|"Major"| H["Read from disk/swap, slow"]
    F -->|"Invalid"| I["SIGSEGV"]
{{< /mermaid >}}

## Minor, major, and invalid faults

Not all page faults cost the same. The distinction dominates performance analysis.

| Fault type | What happened | Rough cost |
| --- | --- | --- |
| Minor (soft) | Page is in RAM but not mapped in this process's page table yet | ~100s of ns to a few µs |
| Major (hard) | Page must be fetched from disk or swap | ~µs (NVMe) to ~ms (HDD/swap) |
| Invalid | Address not backed by any valid mapping | Process gets SIGSEGV |

A **minor fault** is cheap. It happens constantly during normal operation: the first touch of a freshly `malloc`'d page (the kernel lazily allocates physical frames only on first write), a copy-on-write break after `fork()`, or a shared-library page already cached but not yet wired into this process. The kernel just updates a page table entry and returns.

A **major fault** is expensive — orders of magnitude more so. The faulting thread blocks while the kernel issues I/O: reading a page of a memory-mapped file from the filesystem, or pulling a swapped-out page back from the swap device. On a busy server, a spike in major faults almost always means you are swapping or thrashing the page cache, and latency goes off a cliff.

You can watch the split live:

```bash
# Per-process major/minor faults (maj_flt is the dangerous column)
ps -o min_flt,maj_flt,cmd -p <pid>

# System-wide rate; fault/s in the "faults" column, majflt/s separately
sar -B 1

# Detailed counters for a single run
/usr/bin/time -v ./myserver 2>&1 | grep -i fault
# -> Major (requiring I/O) page faults: 12
# -> Minor (reclaiming a frame) page faults: 184213
```

## The TLB: translation is not free even on a hit

Even when a page is resident, translating its virtual address requires walking the page tables — on x86-64 that is up to four memory accesses for a 4-level table. To avoid paying that on every access, the CPU caches recent translations in the **TLB** (Translation Lookaside Buffer).

A TLB hit makes translation effectively free. A TLB miss forces a page-table walk (the hardware does this automatically), which is a handful of cache-line accesses. The TLB is small — a few hundred to a couple thousand entries — so a workload touching a large, scattered set of pages suffers frequent misses. This is invisible to `ps` and `sar`; it shows up only in CPU performance counters:

```bash
perf stat -e dTLB-loads,dTLB-load-misses,iTLB-load-misses ./myserver
```

High `dTLB-load-misses` relative to loads is a sign your working set is spread across too many pages. The classic remedy is **huge pages**: a 2 MiB huge page covers 512 times the address range of a 4 KiB page with a single TLB entry, dramatically improving TLB coverage for large heaps. Databases and JVMs with multi-gigabyte heaps benefit substantially.

```bash
# Explicit hugepages
echo 1024 > /proc/sys/vm/nr_hugepages
# Or rely on Transparent Huge Pages (THP), with caveats below
cat /sys/kernel/mm/transparent_hugepage/enabled
```

A caution: Transparent Huge Pages can *hurt* latency-sensitive services. The kernel's background defragmentation (khugepaged) and the synchronous compaction that THP can trigger introduce unpredictable stalls. Many databases (Redis, Oracle, and MongoDB before 8.0) explicitly recommend disabling THP, and some, like Oracle, recommend explicit huge pages instead.

## Demand paging, overcommit, and the OOM killer

Linux allocates lazily. When you `malloc(1 GiB)`, you get a virtual mapping but essentially no physical memory — frames are assigned on first touch, one minor fault at a time. This is why a process's virtual size (VSZ) can vastly exceed its resident set size (RSS), and why total committed virtual memory across all processes can exceed physical RAM. That is **overcommit**.

Overcommit works because most processes never touch everything they reserve. But it means the kernel can hand out memory it cannot actually back. When processes genuinely demand more physical pages than exist and swap is exhausted, the kernel invokes the **OOM killer**, which picks a victim process (scored by `oom_score`) and kills it. For a backend service this is a hard crash that no amount of in-process error handling can catch.

```bash
# Inspect / tune overcommit policy
cat /proc/sys/vm/overcommit_memory   # 0=heuristic, 1=always, 2=strict accounting
# Protect a critical process from the OOM killer
echo -1000 > /proc/<pid>/oom_score_adj
```

For containers this matters even more: a cgroup memory limit caps RSS, and exceeding it triggers a cgroup-scoped OOM kill of a process inside the container — the dreaded exit code 137. Setting a JVM heap larger than the container limit is a reliable way to get killed.

## Page reclaim, swap, and thrashing

When free memory runs low, the kernel reclaims pages. Clean file-backed pages (page cache) can be dropped instantly since they can be re-read. Dirty pages must be written back first. Anonymous pages (heap, stack) have no file backing, so reclaiming them requires writing to **swap**.

A small amount of swap is healthy — it lets the kernel evict genuinely cold anonymous pages and use that RAM for hot page cache. The `vm.swappiness` knob (0–200 since Linux 5.8, previously 0–100; default 60) tunes how aggressively the kernel prefers swapping anonymous pages versus dropping file cache.

The pathological state is **thrashing**: the working set exceeds RAM, so the kernel constantly swaps pages out and faults them right back in. Major fault rate spikes, the disk saturates, CPU sits in I/O wait, and throughput collapses while the system appears "busy." The fix is never tuning — it is reducing the working set or adding RAM.

{{< mermaid >}}
graph LR
    A["Working set > RAM"] --> B["Reclaim evicts hot page to swap"]
    B --> C["Process touches it again"]
    C --> D["Major fault, swap-in"]
    D --> E["Reclaim must evict another hot page"]
    E --> B
{{< /mermaid >}}

## Practical impact on backend services

How does all this translate into engineering decisions?

- **Cold-start latency.** The first requests after a deploy are slow because code and data pages fault in lazily (minor faults) and memory-mapped files fault in from disk (major faults). Warming caches and pre-touching critical pages (`mlock`/`MADV_WILLNEED`) reduces tail latency on a freshly started instance.
- **`mmap`-based I/O.** Memory-mapped files turn reads into page faults. Sequential access is great (the kernel readahead prefetches), but random access over a file larger than RAM produces a stream of major faults. This is why some databases prefer explicit buffered I/O with their own cache management over relying on `mmap`.
- **Garbage-collected runtimes.** A full GC walks the heap, touching pages that may have been reclaimed, generating a burst of faults. Keeping the heap resident (and below the container limit) avoids GC-induced swapping.
- **NUMA effects.** On multi-socket machines, a page faulted in on one node but accessed from another costs more. The "first-touch" allocation policy means the thread that *writes* a page first determines where it lives — relevant for thread-pool and allocator design.
- **Latency tails, not averages.** Page faults rarely move the median. They live in the p99/p999 tail, where a single major fault on a request's hot path adds milliseconds. Latency-sensitive systems lock critical memory (`mlockall(MCL_CURRENT | MCL_FUTURE)`) to keep it from ever being reclaimed.

## A diagnostic checklist

When a service shows latency spikes or unexplained slowness, walk these in order:

1. `sar -B 1` — is `majflt/s` non-trivial? If so, you are doing disk I/O on the memory path.
2. `vmstat 1` — are `si`/`so` (swap in/out) non-zero? Any sustained swap activity on a latency-sensitive service is a red flag.
3. `ps -o rss,vsz` and the cgroup `memory.current` — is RSS approaching the limit? You are headed for OOM or reclaim pressure.
4. `perf stat` TLB miss rate — if high with a large heap, evaluate huge pages.
5. `dmesg | grep -i oom` — did the OOM killer fire? Exit 137 in a container confirms it.

## Summary

Virtual memory makes RAM look bigger, safer, and more flexible than it is, and most of the time the machinery is invisible. The performance story lives in the faults: minor faults are the cheap, constant background hum of demand paging and copy-on-write; major faults are disk I/O wearing a memory costume and the source of nasty latency tails; and the TLB silently taxes even resident accesses unless your working set fits its coverage. Backend performance work is largely about keeping the hot working set resident, avoiding swap entirely, sizing heaps under container limits, and using huge pages or memory locking when the tail latency justifies it.
