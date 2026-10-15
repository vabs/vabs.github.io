---
title: "epoll and kqueue Internals"
date: 2026-05-12T14:18:00-04:00
draft: false
featured: false
tags: [backend, linux, bsd, networking, performance]
---

## The problem they solve

A server that handles thousands of concurrent connections faces a deceptively simple question: which sockets are ready for I/O right now? The naive answers don't scale. Spawning a thread per connection drowns the scheduler. Polling each socket in a loop wastes the CPU. The classic readiness syscalls, `select` and `poll`, scale linearly with the number of watched descriptors, which collapses under load.

`epoll` on Linux and `kqueue` on the BSDs (including macOS) are the scalable answers. Both deliver O(1) readiness notification with respect to the number of *idle* connections, which is exactly the property you need for the C10K problem and beyond. Understanding how they work internally explains why they're fast, why edge-triggered mode is tricky, and how to avoid the subtle bugs that bite event-loop authors.

## Why select and poll don't scale

`select` and `poll` are stateless. Every call hands the kernel the *entire* set of descriptors you care about. The kernel walks that whole set, checks each descriptor's readiness, builds a result, and returns. Then on the next iteration you do it all again.

```c
// poll: you rebuild and rescan the full set every single call.
struct pollfd fds[NUM];
// ... fill fds ...
int ready = poll(fds, NUM, timeout);
for (int i = 0; i < NUM; i++) {
    if (fds[i].revents & POLLIN) handle(fds[i].fd);
}
```

If you watch 10,000 connections but only 5 are active, `poll` still scans all 10,000 every call. The cost is O(N) in the number of watched descriptors, not the number of ready ones. At scale this dominates.

The deeper issue is that there's no kernel-side memory of your interest set. Each call re-establishes everything from scratch, copying the full descriptor array across the user/kernel boundary every time.

## The epoll model: stateful interest sets

`epoll` splits the work into setup and wait. You register your interest *once*, and the kernel maintains that state across calls. There are three syscalls:

```c
int epfd = epoll_create1(0);                  // create an epoll instance

struct epoll_event ev = {
    .events = EPOLLIN,
    .data.fd = conn_fd,
};
epoll_ctl(epfd, EPOLL_CTL_ADD, conn_fd, &ev); // register interest once

struct epoll_event events[MAX];
int n = epoll_wait(epfd, events, MAX, -1);    // returns ONLY ready fds
for (int i = 0; i < n; i++)
    handle(events[i].data.fd);
```

The crucial difference: `epoll_wait` returns only the descriptors that are actually ready. The work is proportional to the number of *active* connections, not the total watched. Ten thousand idle sockets cost essentially nothing.

### How the kernel makes this O(1)

Internally, an epoll instance holds two key data structures.

The **interest list** is a red-black tree of all registered descriptors, keyed by file descriptor. The tree gives O(log N) add, modify, and remove operations for `epoll_ctl`.

The **ready list** is a doubly linked list of descriptors that have become ready. Here's the trick: when you register a descriptor, the kernel installs a callback on that file's wait queue. When the socket becomes readable (data arrives, the TCP stack wakes the wait queue), that callback fires and *appends the descriptor to the ready list*. No scanning involved.

{{< mermaid >}}
graph TD
  A["Data arrives on socket"] --> B["TCP stack wakes wait queue"]
  B --> C["epoll callback fires"]
  C --> D["Append fd to ready list"]
  E["epoll_wait()"] --> F["Drain ready list"]
  D --> F
  F --> G["Return ready fds to user"]
{{< /mermaid >}}

So `epoll_wait` just splices the ready list into the user's buffer. The cost is O(number ready), and idle descriptors never enter the picture. This event-driven, callback-based design is what gives epoll its scalability.

## Level-triggered vs edge-triggered

This is the single most misunderstood part of epoll, and the source of most event-loop bugs.

**Level-triggered (LT)** is the default and mirrors `poll` semantics. As long as a condition holds (the socket has readable data), `epoll_wait` keeps reporting it ready. If you read only half the available data and return to `epoll_wait`, it immediately tells you the socket is still readable. LT is forgiving.

**Edge-triggered (ET)**, enabled with `EPOLLET`, reports readiness only on the *transition* from not-ready to ready. You get notified once when data arrives. If you don't drain the socket completely, you will *not* be notified again until *new* data arrives, even though unread bytes remain in the buffer. Forget to drain, and that connection silently stalls.

| Aspect | Level-triggered | Edge-triggered |
|--------|-----------------|----------------|
| Notification | While condition holds | On transition only |
| Reads per wakeup | Can read partially | Must drain fully |
| EAGAIN handling | Optional | Mandatory loop until EAGAIN |
| Risk of stall | Low | High if not drained |
| Wakeup count | More | Fewer |

The correct ET pattern is to loop reading until you get `EAGAIN`, which tells you the kernel buffer is empty:

```c
// Edge-triggered: you MUST drain until EAGAIN.
for (;;) {
    ssize_t n = read(fd, buf, sizeof(buf));
    if (n > 0) {
        process(buf, n);
        continue;
    }
    if (n == -1 && errno == EAGAIN)
        break;            // drained; safe to return to epoll_wait
    if (n == -1 && errno == EINTR)
        continue;
    // n == 0 (peer closed) or a real error
    close(fd);
    break;
}
```

ET is more efficient because it generates fewer wakeups, which matters when a high-traffic socket would otherwise trigger repeated LT notifications. The price is that your code must always fully drain. Most high-performance servers (nginx, for instance) use ET with non-blocking sockets precisely for this efficiency.

## kqueue: the BSD answer

`kqueue` predates `epoll` and is arguably more elegant. It's a single, unified interface for many kinds of events, not just socket readiness. You can watch socket I/O, file changes, process exits, signals, and timers all through one mechanism.

```c
int kq = kqueue();

struct kevent change;
EV_SET(&change, conn_fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
kevent(kq, &change, 1, NULL, 0, NULL);        // register

struct kevent events[MAX];
int n = kevent(kq, NULL, 0, events, MAX, NULL); // wait
for (int i = 0; i < n; i++)
    handle(events[i].ident);
```

The genius of `kqueue` is that a single `kevent` call both submits changes and retrieves events. The `changelist` argument registers or modifies filters, and the `eventlist` argument receives ready events. This batches what epoll splits across `epoll_ctl` and `epoll_wait`, saving syscalls.

### Filters: the unifying abstraction

A kqueue event is identified by a `(ident, filter)` pair. The `filter` decides what kind of event. `EVFILT_READ` and `EVFILT_WRITE` cover sockets. `EVFILT_VNODE` watches file system changes. `EVFILT_PROC` watches process state. `EVFILT_SIGNAL` and `EVFILT_TIMER` round it out. This composability is something epoll lacks; on Linux you stitch together `signalfd`, `timerfd`, and `inotify`, then feed *those* descriptors into epoll. kqueue does it natively.

{{< mermaid >}}
graph LR
  K["kqueue instance"] --> R["EVFILT_READ (sockets)"]
  K --> W["EVFILT_WRITE (sockets)"]
  K --> V["EVFILT_VNODE (files)"]
  K --> P["EVFILT_PROC (processes)"]
  K --> T["EVFILT_TIMER (timers)"]
  K --> S["EVFILT_SIGNAL (signals)"]
{{< /mermaid >}}

kqueue also supports both level- and edge-triggered modes, the latter via the `EV_CLEAR` flag, with the same drain-fully discipline as epoll's ET.

## Comparing the two

The mechanisms are conceptually twins but differ in ergonomics.

| Feature | epoll (Linux) | kqueue (BSD/macOS) |
|---------|---------------|---------------------|
| Register + wait | Separate syscalls | Single kevent call |
| Event types | Sockets; others via fd bridges | Native: I/O, files, procs, signals, timers |
| Batching changes | One epoll_ctl per change | Batched changelist |
| Triggering modes | LT (default), ET via EPOLLET | LT, ET via EV_CLEAR |
| Extra info per event | data union | data + udata + fflags |

kqueue's single-call design reduces syscall count, and its filter model is genuinely more general. epoll's split design is slightly more syscall-heavy but the model is simpler to reason about for pure socket servers.

## Common pitfalls

**The thundering herd.** If multiple threads each have their own epoll fd watching the same listening socket and a connection arrives, all of them may wake for one event. `EPOLLEXCLUSIVE` (Linux 4.5+) mitigates this by waking only one (or a few) of those epoll instances, important for multi-acceptor designs.

**Stale descriptors after close.** When you `close` a descriptor, the kernel removes it from the epoll interest list automatically *only if no other reference exists*. Dup'd descriptors keep the registration alive, leading to confusing phantom events. Explicitly `EPOLL_CTL_DEL` before close when in doubt.

**The level-triggered busy loop.** If you register `EPOLLOUT` (writable) in level-triggered mode and forget to remove it, the socket is almost always writable, so `epoll_wait` returns instantly forever, pinning a core. Only watch for writability when you actually have buffered data to send.

**Forgetting EAGAIN in ET.** Covered above, but worth repeating: edge-triggered without a full drain loop is the most common stall bug in hand-rolled event loops.

## The takeaway

Both `epoll` and `kqueue` win by keeping the interest set in the kernel and using callbacks to populate a ready list, turning readiness notification from an O(N) scan into an O(ready) splice. epoll is Linux-specific and socket-focused; kqueue is BSD-native and gloriously general. Whichever you target, the same disciplines apply: prefer edge-triggered for efficiency but always drain to EAGAIN, manage your interest set carefully around close, and never watch for writability you don't need. Get those right and a single core can comfortably juggle tens of thousands of connections.
