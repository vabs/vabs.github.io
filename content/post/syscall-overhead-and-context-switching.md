---
title: "Syscall Overhead and Context Switching"
date: 2026-05-15T11:05:00-04:00
draft: false
featured: false
tags: [backend, linux, performance, kernel, cpu]
---

## The hidden tax on every system call

A system call looks like an ordinary function call in your code, but it is anything but. Crossing the boundary from user space into the kernel is one of the more expensive operations a CPU performs in the course of normal work, and a context switch between threads is more expensive still. When you're chasing tail latency or trying to squeeze throughput out of a hot path, these costs stop being abstract and start showing up in flame graphs.

This post breaks down where the cycles actually go: what happens mechanically during a syscall, why context switches are pricier than they look, how the CPU's caches and TLB get punished, and the techniques modern systems use to amortize or eliminate the overhead entirely.

## Anatomy of a system call

When you call `read()`, you're invoking a thin libc wrapper that ultimately executes a special instruction (`syscall` on x86-64) to trap into the kernel. That single instruction kicks off a sequence:

1. The CPU switches from user mode (ring 3) to kernel mode (ring 0).
2. It saves the user-space register state and loads the kernel stack pointer.
3. The kernel validates arguments, including bounds-checking any user pointers.
4. The kernel does the actual work (or queues it).
5. It restores user register state and returns to ring 3 via `sysret`.

```c
// What looks like one call ...
ssize_t n = read(fd, buf, len);

// ... compiles down to roughly:
//   mov  rax, 0        ; syscall number for read
//   mov  rdi, fd
//   mov  rsi, buf
//   mov  rdx, len
//   syscall            ; trap into the kernel
//   ; rax now holds the return value
```

The mode transition alone costs on the order of tens to low hundreds of nanoseconds on modern hardware, before the kernel does any useful work. That's hundreds of CPU cycles spent purely on the privilege boundary.

{{< mermaid >}}
graph TD
  A["User code calls read()"] --> B["syscall instruction"]
  B --> C["CPU: ring 3 to ring 0"]
  C --> D["Save user registers, swap to kernel stack"]
  D --> E["Validate args, do the work"]
  E --> F["Restore user registers"]
  F --> G["sysret: ring 0 to ring 3"]
  G --> H["read() returns"]
{{< /mermaid >}}

### The Spectre/Meltdown tax

It got worse after 2018. Mitigations for the Meltdown and Spectre vulnerabilities, particularly Kernel Page Table Isolation (KPTI), added overhead to the user/kernel transition. KPTI maintains separate page tables for user and kernel space, so each syscall now involves a page-table switch and associated TLB flushing. Depending on workload, syscall-heavy applications saw measurable slowdowns. The exact cost depends on CPU generation and whether the hardware has PCID support to reduce the TLB penalty.

## Context switching: an order of magnitude more

A syscall stays within the same thread. A context switch tears down one thread's execution context and installs another's. This is fundamentally more expensive, and the direct cost is only part of the story.

### Direct costs

The kernel must save the outgoing thread's full register set, update scheduler bookkeeping, pick the next thread, and restore its registers. If the switch crosses process boundaries, it also swaps the page tables (the `CR3` register on x86), which has cascading effects we'll get to.

### Indirect costs: the real killer

The direct register save/restore is a few hundred nanoseconds. The indirect cost, cache and TLB pollution, often dwarfs it.

When thread A runs, it warms the CPU caches with its working set. The moment thread B takes over, B's accesses miss in the cache and have to fetch from memory. When A eventually resumes, its data has been evicted by B, so A also suffers misses. The cost is paid twice and is invisible in a naive measurement that only times the switch itself.

The TLB (translation lookaside buffer), which caches virtual-to-physical address mappings, is hit even harder on a cross-process switch. Changing `CR3` can flush the TLB entirely (PCID tagging mitigates this on newer CPUs). After the switch, every memory access must walk the page tables to repopulate the TLB.

| Cost component | Rough magnitude | Visible in microbenchmark? |
|----------------|-----------------|----------------------------|
| Mode transition (syscall) | ~50-300 ns | Yes |
| Register save/restore | ~few hundred ns | Yes |
| TLB flush (cross-process) | varies | Partially |
| Cache repopulation | can be many microsec | No (deferred) |
| Scheduler overhead | ~hundreds of ns | Yes |

The deferred, invisible cache cost is why a system that context-switches heavily can have surprisingly poor throughput even when each switch "only" takes a microsecond in isolation.

## Voluntary vs involuntary switches

Not all context switches are equal in cause.

A **voluntary** switch happens when a thread blocks, typically on I/O or a contended lock. It calls into the kernel, finds it must wait, and yields the CPU. These are often unavoidable and reflect real waiting.

An **involuntary** switch happens when the scheduler preempts a running thread because its time slice expired or a higher-priority thread became runnable. Excessive involuntary switches often signal CPU oversubscription: more runnable threads than cores.

```bash
# Watch context switches per second system-wide.
vmstat 1
# the "cs" column is context switches/sec

# Per-process voluntary vs involuntary switches.
cat /proc/<pid>/status | grep ctxt
# voluntary_ctxt_switches:   ...
# nonvoluntary_ctxt_switches: ...
```

A high ratio of involuntary switches tells you to reduce thread count or pin work to cores. A high ratio of voluntary switches points at I/O waits or lock contention to attack.

## Strategies to reduce the overhead

The general principle is the same throughout: do more work per crossing, or eliminate the crossing.

### Batch syscalls

If you're making many small syscalls, coalesce them. Instead of one `write` per message, buffer messages and flush with a single larger `write`. Instead of `read`-ing a few bytes at a time, read a large chunk. The fixed per-syscall cost is then amortized over more useful work.

`io_uring` takes this to its logical end. It exposes shared ring buffers between user and kernel space, so you submit many operations and reap many completions while crossing the boundary rarely, sometimes not at all if the kernel polls the submission ring.

```c
// Submit a batch of operations, then a single enter call drives them all.
io_uring_submit(&ring);              // potentially many ops, one syscall
io_uring_wait_cqe(&ring, &cqe);      // reap completions
```

### Avoid syscalls with vDSO

Some "syscalls" don't actually trap into the kernel at all. The vDSO (virtual dynamic shared object) maps a small kernel-provided code page into every process. Calls like `gettimeofday()` and `clock_gettime()` read kernel-maintained data directly from user space, skipping the mode switch entirely. This is why time-reading is cheap on Linux when done through the standard interfaces.

### Reduce context switches structurally

The architectural answer to context-switch overhead is to use fewer threads doing more work each. Event-loop designs (one thread per core, driven by `epoll` or `kqueue`) replace thousands of blocking threads with a handful of busy ones, slashing involuntary switches and cache thrashing. Thread-per-core architectures with CPU pinning push this further: pin each worker to a core, give it its own data, and the scheduler rarely needs to move anything.

{{< mermaid >}}
graph LR
  A["Thread-per-connection"] --> B["Many threads"]
  B --> C["Heavy context switching"]
  C --> D["Cache and TLB thrash"]
  E["Thread-per-core + event loop"] --> F["Few pinned threads"]
  F --> G["Minimal switching"]
  G --> H["Caches stay warm"]
{{< /mermaid >}}

### Busy-polling for ultra-low latency

At the extreme end, latency-critical systems (high-frequency trading, packet processing with DPDK) abandon interrupts and blocking entirely. A dedicated core spins in a tight loop polling the NIC. This wastes the core's cycles when idle but eliminates both the syscall and the wakeup-from-block context switch, shaving microseconds off the critical path. It's a deliberate trade of CPU for latency.

## Measuring it yourself

You can quantify syscall cost with a tight loop calling a cheap syscall like `getpid()` (which isn't cached) and dividing total time by iterations. For context switches, `perf` is the right tool:

```bash
# Count context switches and CPU migrations for a command.
perf stat -e context-switches,cpu-migrations,cache-misses ./myserver

# Profile where time goes, including kernel.
perf record -g ./myserver
perf report
```

Watch the `context-switches` and `cache-misses` counters together. A workload that's switch-heavy will show both climbing in tandem, confirming the indirect cache cost.

## The mental model

Treat every user/kernel crossing and every context switch as a tax with a fixed component you pay regardless of how little work you do across it. The optimization playbook follows directly: amortize the tax by batching, dodge it with vDSO and shared-memory interfaces like io_uring, and minimize switches by running few threads that stay busy and keep their caches warm. The cheapest syscall is the one you never make, and the cheapest context switch is the one the scheduler never has to perform.
