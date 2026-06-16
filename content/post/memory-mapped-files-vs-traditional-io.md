---
title: "Memory-Mapped Files vs Traditional I/O"
date: 2026-02-27T09:14:00-04:00
draft: false
featured: false
tags: [backend, io, performance, memory, filesystem]
---

When a service needs to read or write large files, the choice between traditional stream-based I/O and memory-mapped files (mmap) can change throughput, latency, and memory behavior by an order of magnitude. Both eventually move bytes between disk and process, but they take fundamentally different paths through the operating system. Understanding those paths is the difference between a database that sustains millions of reads per second and one that thrashes under load.

## Two Ways to Move Bytes

Traditional I/O is built around explicit system calls: `read()` and `write()`. Your application maintains a buffer, asks the kernel to copy data into it, processes the bytes, and asks the kernel to copy them back out. The kernel keeps its own copy of recently accessed file pages in the **page cache**, so a `read()` of cached data is just a memory-to-memory copy from kernel space to user space.

Memory-mapped I/O takes a different stance. The `mmap()` system call asks the kernel to map a region of a file directly into the process's virtual address space. After that, the file *is* memory. You dereference a pointer; if the underlying page isn't resident, the CPU raises a page fault, the kernel reads the page from disk, maps it, and your instruction resumes as if nothing happened.

{{< mermaid >}}
graph LR
  subgraph "Traditional I/O"
    A1["Application Buffer"] -->|"read() syscall"| K1["Kernel Page Cache"]
    K1 -->|"DMA"| D1["Disk"]
  end
  subgraph "Memory-Mapped I/O"
    A2["Pointer Dereference"] -->|"page fault"| K2["Kernel Page Cache"]
    K2 -->|"DMA"| D2["Disk"]
  end
{{< /mermaid >}}

The critical structural difference: traditional I/O always involves a copy between the page cache and the user-space buffer. Memory-mapped I/O maps the page cache pages directly into user space, so reading mapped data after the first fault involves **zero copies**.

## The Cost of a Copy

That extra copy in traditional I/O is not free, but it's also not always the bottleneck people imagine. A `memcpy` of a 4 KB page on modern hardware costs perhaps tens of nanoseconds. The real costs of traditional I/O are:

- **System call overhead.** Each `read()`/`write()` is a mode switch into the kernel. With spectre/meltdown mitigations enabled, a single syscall can cost 1-2 microseconds. If you do millions of small reads, this dominates.
- **Buffer management.** You size buffers, handle partial reads, and loop until satisfied.
- **Double buffering for random access.** Random access patterns waste readahead and force frequent small syscalls.

Memory-mapped I/O trades these for a different cost profile:

- **Page faults.** The first touch of each page triggers a minor or major fault. Minor faults (page already in cache) are cheap. Major faults (page must be read from disk) are expensive and synchronous.
- **TLB pressure.** Mapping a large file consumes translation lookaside buffer entries. Walking randomly across a multi-gigabyte mapping causes TLB misses that hurt.
- **Unpredictable latency.** A simple pointer dereference can block for milliseconds if it triggers a major fault. There is no syscall to fail or return `EAGAIN`; your thread just stalls.

## A Concrete Benchmark

Consider sequentially summing every byte in a 4 GB file. Here's the traditional approach in C:

```c
ssize_t n;
char buf[1 << 16];   // 64 KB buffer
uint64_t sum = 0;
int fd = open("data.bin", O_RDONLY);
while ((n = read(fd, buf, sizeof buf)) > 0) {
    for (ssize_t i = 0; i < n; i++) sum += (uint8_t)buf[i];
}
close(fd);
```

And the memory-mapped version:

```c
int fd = open("data.bin", O_RDONLY);
struct stat st;
fstat(fd, &st);
uint8_t *p = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
madvise(p, st.st_size, MADV_SEQUENTIAL);
uint64_t sum = 0;
for (off_t i = 0; i < st.st_size; i++) sum += p[i];
munmap(p, st.st_size);
```

For pure sequential scans, the two are often within 10-20% of each other when the file is cold, because both are dominated by disk bandwidth. The interesting differences emerge with access patterns and reuse.

| Workload | Traditional I/O | Memory-Mapped |
|---|---|---|
| Cold sequential scan | Disk-bound, slight edge | Disk-bound |
| Warm sequential scan (cached) | Copy overhead per read | Fastest, zero-copy |
| Random small reads | Syscall per read, slow | Page fault per page, faster |
| Repeated random reads (cached) | Copy each time | Near memory speed |
| Streaming write of huge file | Predictable, simple | Dirty page writeback storms |

## Why Databases Love (and Fear) mmap

Many storage engines built their early versions on memory-mapped files because the programming model is seductive: the OS handles caching, eviction, and readahead for you. LMDB famously uses mmap for its entire read path, achieving extraordinary read throughput because cached reads are literally just pointer dereferences with no syscall.

But there is a well-documented cautionary tale. The authors of WiredTiger and the broader database community have written about the pitfalls of relying on mmap for a serious storage engine. The core problems:

1. **No control over eviction.** The OS decides which pages to evict based on its own LRU-ish heuristics. A database often knows better which pages are hot, but mmap gives it no say.
2. **No control over writeback timing.** Dirty pages get flushed by the kernel on its schedule, which can cause latency spikes (the dreaded writeback storm) and complicates durability guarantees.
3. **Error handling is brutal.** A disk read error during a normal `read()` returns `EIO` you can handle. The same error during a page fault delivers a `SIGBUS` signal. Recovering gracefully from a signal mid-transaction is nightmarish.
4. **Transaction safety.** Ensuring data hits stable storage in the right order requires `msync()`, whose semantics across platforms are subtle and whose performance can be poor.

This is why production-grade engines that started with mmap frequently migrate to a custom buffer pool with `pread`/`pwrite`, where they control every aspect of caching and durability.

## Page Faults in Detail

The page fault is the heart of mmap's behavior, so it's worth understanding the state machine the CPU and kernel walk through.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Resident: "page already in RAM"
  [*] --> MinorFault: "page in cache, not mapped"
  [*] --> MajorFault: "page on disk"
  MinorFault --> Resident: "map existing cache page"
  MajorFault --> DiskRead: "schedule I/O"
  DiskRead --> Resident: "page loaded and mapped"
  Resident --> [*]: "dereference completes"
{{< /mermaid >}}

A **minor fault** happens when the page is already in the page cache (perhaps another process loaded it) but isn't yet mapped into your address space. The kernel just updates your page table. Cheap, microseconds.

A **major fault** requires actual disk I/O. The faulting thread blocks until the data arrives. This is where unpredictable latency comes from, and it's why `madvise()` hints matter so much.

## Tuning Memory-Mapped Access

The `madvise()` system call lets you tell the kernel about your intended access pattern:

```c
madvise(p, len, MADV_SEQUENTIAL);  // aggressive readahead, early eviction
madvise(p, len, MADV_RANDOM);      // disable readahead
madvise(p, len, MADV_WILLNEED);    // prefetch these pages now
madvise(p, len, MADV_DONTNEED);    // drop these pages from RAM
```

For a sequential scan, `MADV_SEQUENTIAL` tells the kernel to read ahead aggressively and evict pages behind you, keeping the resident set small. For a random-access index, `MADV_RANDOM` disables readahead so you don't waste bandwidth pulling in pages you'll never touch. `MADV_WILLNEED` is essentially an asynchronous prefetch: issue it, do other work, and the pages should be resident by the time you need them, converting potential major faults into minor ones.

Huge pages are another lever. A 4 GB mapping with 4 KB pages needs a million page table entries and constantly misses the TLB. Mapping with 2 MB huge pages cuts that to ~2000 entries, dramatically reducing TLB pressure for large working sets:

```c
void *p = mmap(NULL, len, PROT_READ,
               MAP_PRIVATE | MAP_HUGETLB, fd, 0);
```

## When to Choose Which

Reach for **traditional I/O** when:

- You need predictable latency with no surprise page-fault stalls.
- You stream data once and don't reread it (no benefit from the cache mapping).
- You need robust error handling on a per-operation basis.
- You write large amounts of data and want explicit control over flushing.
- You use `O_DIRECT` to bypass the page cache entirely for a custom buffer pool.

Reach for **memory-mapped I/O** when:

- You have a read-heavy workload with a working set that fits comfortably in RAM.
- You do random access into a large file and want the OS to handle caching.
- You want the simplest possible programming model and can tolerate occasional latency spikes.
- You share read-only data across many processes (mmap with `MAP_SHARED` gives them all the same physical pages).

## The Async I/O Wildcard

Modern Linux offers a third path that sidesteps both: `io_uring`. It provides a ring-buffer interface for submitting batches of I/O operations asynchronously without a syscall per operation, and without the page-fault unpredictability of mmap. For high-performance servers built today, `io_uring` with a custom buffer pool often beats both classic approaches, combining the explicit control of traditional I/O with throughput that rivals or exceeds mmap. It's the direction most new storage engines are heading.

## Conclusion

Memory-mapped files are not magic and traditional I/O is not obsolete. mmap shines for read-heavy, cache-friendly, random-access workloads where its zero-copy path and OS-managed caching pay off, and it lets multiple processes share pages cheaply. Traditional I/O wins where you need predictability, robust error handling, and explicit control over caching and durability, which is exactly why so many serious databases ultimately build their own buffer pools. Measure your actual access pattern, watch your major fault rate, and let the data, not the elegance of pointer dereferences, drive the decision.
