---
title: "Thread Pools vs Virtual Threads (Project Loom)"
date: 2026-03-08T11:27:00-04:00
draft: false
featured: false
tags: [backend, concurrency, java, loom, threads]
---

For two decades, the standard advice for writing scalable Java servers has been: never block a thread, because threads are expensive, so wrap everything in thread pools and reactive callbacks. Project Loom's virtual threads, now a stable feature of the JVM, upend that advice. They make blocking cheap again, letting you write straightforward synchronous code that scales to millions of concurrent operations. This post explains what changed, how virtual threads work under the hood, and when you should still reach for a classic thread pool.

## Why Platform Threads Are Expensive

A traditional Java thread, now called a **platform thread**, is a thin wrapper over an operating system thread. Each one costs:

- **Memory.** A default stack reservation of around 1 MB. Spin up 10,000 threads and you've reserved 10 GB of address space.
- **Scheduling overhead.** The OS scheduler manages these threads. Context switches between them involve kernel-mode transitions and cache pollution.
- **Creation cost.** Creating an OS thread is a syscall, far too slow to do per request.

Because they're expensive, you pool them. A thread pool of, say, 200 threads is shared across all incoming work. But this creates the central problem: if your request handler blocks on a slow database call, that platform thread is parked, idle but unavailable to anyone else. With 200 pool threads and a 100ms database call, you cap out around 2,000 requests per second no matter how much CPU you have, purely because threads are stuck waiting.

## The Two Old Escape Routes

Before Loom, you had two ways out of the blocking trap, both with serious downsides.

**Bigger thread pools** seem obvious but don't scale: thousands of platform threads consume gigabytes of stack and crush the scheduler with context switches.

**Asynchronous / reactive programming** (CompletableFuture, reactive streams, callbacks) avoids blocking by never parking a thread; instead you register a continuation that fires when the I/O completes. This scales beautifully but at a brutal cost to code clarity. Stack traces become useless, debugging is painful, and simple sequential logic fragments into a web of callbacks and operators. This is often called "callback hell" or "the colored function problem."

{{< mermaid >}}
graph TD
  A["Need to scale I/O-bound server"] --> B{"Pre-Loom options"}
  B --> C["Larger thread pool"]
  B --> D["Reactive / async"]
  C --> E["Runs out of memory, scheduler thrash"]
  D --> F["Loses readability, hard debugging"]
  A --> G["Loom: virtual threads"]
  G --> H["Blocking code that scales"]
{{< /mermaid >}}

## What Virtual Threads Actually Are

A virtual thread is a lightweight thread managed by the JVM, not the OS. It is not bound one-to-one to an OS thread. Instead, many virtual threads are multiplexed onto a small pool of platform threads called **carrier threads** (by default, sized to the number of CPU cores).

The magic is in **mounting** and **unmounting**. When a virtual thread runs, it is mounted on a carrier thread and executes normally. When it hits a blocking operation, the JVM's instrumented blocking calls unmount it: the virtual thread's stack is copied off to the heap, the carrier thread is freed to run a different virtual thread, and when the blocking operation completes, the virtual thread is remounted (on any available carrier) to continue.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Runnable
  Runnable --> Mounted: scheduled on carrier
  Mounted --> Unmounted: blocks on I/O, stack parked to heap
  Unmounted --> Runnable: I/O completes
  Mounted --> [*]: task finishes
{{< /mermaid >}}

This means a virtual thread blocked on a database call consumes **no carrier thread and almost no memory** while it waits. Its stack lives on the heap and grows on demand, starting at a few hundred bytes rather than a megabyte. You can have millions of them.

## The Programming Model

The beauty is that the code looks exactly like old-fashioned blocking code:

```java
// One virtual thread per task, blocking calls and all
try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
    for (int i = 0; i < 1_000_000; i++) {
        int id = i;  // lambdas capture only effectively-final locals
        executor.submit(() -> {
            // This blocks, but cheaply unmounts the virtual thread
            var user = userService.fetch(id);       // blocking HTTP
            var orders = orderRepo.findByUser(user); // blocking JDBC
            return render(user, orders);
        });
    }
}
```

You write `var user = userService.fetch(id)` as a plain blocking call. You get real stack traces. You use try-with-resources, try/catch, and the debugger works normally. There is no `CompletableFuture`, no reactive operator chain, no callback. Yet this scales to a million concurrent tasks, because each blocking call unmounts rather than hogging a carrier.

The guiding principle inverts old advice: **do not pool virtual threads.** Create one per task. They're so cheap that pooling them is counterproductive; a pool would just reintroduce the contention you're trying to avoid.

## The Pinning Pitfall

Virtual threads are not a free lunch in every case. A virtual thread can become **pinned** to its carrier, meaning it can't unmount even when it blocks. This defeats the whole purpose and can starve the carrier pool. Pinning historically happened in two situations:

1. **Inside a `synchronized` block.** If a virtual thread blocks while holding a monitor via `synchronized`, older JVMs pinned it. The recommended fix was to replace `synchronized` with `ReentrantLock`, which Loom understands. (Recent JVM versions have largely eliminated synchronized-induced pinning, but legacy libraries may still trigger it.)
2. **Inside a native method (JNI).** Blocking inside native code pins, because the JVM can't park a native stack frame to the heap.

You can diagnose pinning by running with diagnostics enabled and watching for events that report pinned virtual threads (this flag works on JDK 21–23; JDK 24 removed it in favor of the JFR `jdk.VirtualThreadPinned` event):

```bash
-Djdk.tracePinnedThreads=full
```

If you see frequent pinning under load, that's a signal a hot path is blocking inside a monitor or native call, and your effective concurrency is capped by the carrier count rather than scaling freely.

## When Thread Pools Still Win

Virtual threads are optimized for **I/O-bound** workloads where threads spend most of their time waiting. For **CPU-bound** work they offer no advantage, because the bottleneck is cores, not thread count. If every task is doing heavy computation, you want exactly as many threads as cores, and a fixed platform-thread pool (or a `ForkJoinPool`) is the right tool. Spawning a million virtual threads for CPU-bound work just adds scheduling overhead.

| Dimension | Platform thread pool | Virtual threads |
|---|---|---|
| Best for | CPU-bound, bounded parallelism | I/O-bound, high concurrency |
| Memory per thread | ~1 MB stack | Few hundred bytes, grows on heap |
| Practical count | Thousands | Millions |
| Blocking cost | Wastes a pooled thread | Cheaply unmounts |
| Pooling | Required | Anti-pattern (one per task) |
| Code style | Blocking | Blocking |
| Backpressure | Pool size limits concurrency | Must add explicitly |

That last row matters. A bounded thread pool gives you free **backpressure**: when all threads are busy, work queues up or is rejected. Virtual threads have no inherent limit, so a flood of requests can each spawn a virtual thread that all hammer your database simultaneously, overwhelming it. With virtual threads you must add backpressure explicitly, typically with a `Semaphore` guarding the contended downstream resource:

```java
private final Semaphore dbPermits = new Semaphore(100);

List<Order> handle() throws InterruptedException {
    dbPermits.acquire();   // cap concurrent DB calls at 100
    try {
        return orderRepo.query();  // virtual thread unmounts while waiting
    } finally {
        dbPermits.release();
    }
}
```

The semaphore limits concurrency at the resource (the database) rather than at the thread level. The other 900,000 virtual threads waiting on the semaphore cost almost nothing.

## Structured Concurrency

Loom ships alongside structured concurrency (still a preview API, enabled with `--enable-preview`), which treats a group of concurrent subtasks as a single unit of work with a defined lifetime. It ensures that if you fan out to several services, they all complete or all get cancelled together, and errors propagate cleanly:

```java
try (var scope = StructuredTaskScope.open()) {
    var user = scope.fork(() -> userService.fetch(id));
    var prefs = scope.fork(() -> prefsService.fetch(id));
    scope.join();           // wait for both
    return combine(user.get(), prefs.get());
}
```

If either fork fails, the scope cancels the other automatically. This brings the discipline of try-with-resources to concurrency, eliminating leaked threads and orphaned tasks, and it composes naturally with virtual threads since forking is cheap.

## Migration Strategy

Adopting virtual threads in an existing service is usually low-risk because the API surface is small. The typical steps:

1. Swap your request-handling executor to `Executors.newVirtualThreadPerTaskExecutor()`. Most web frameworks now offer a config flag to do this.
2. Audit hot paths for `synchronized` blocks that wrap blocking I/O and replace them with `ReentrantLock`.
3. Add semaphores or connection pools to cap concurrency against databases and downstream services that can't handle unbounded load.
4. Keep CPU-bound work on a separate, fixed platform-thread pool.

## Conclusion

Virtual threads resolve a tension that defined Java server programming for two decades: you no longer have to choose between readable blocking code and scalable concurrency. By making blocking cheap, Loom lets you write simple synchronous logic that scales to millions of concurrent I/O-bound tasks, with real stack traces and a working debugger. But they don't replace thread pools everywhere: CPU-bound work still wants bounded parallelism, and you must add explicit backpressure where the framework used to provide it implicitly. Use virtual threads for the waiting, use bounded pools for the computing, and let each do what it's good at.
