---
title: "Zero-Copy Networking with sendfile"
date: 2026-05-08T09:42:00-04:00
draft: false
featured: false
tags: [backend, linux, performance, networking, kernel]
---

## Why copies are the enemy

When a server streams a file to a socket, the naive approach involves a surprising amount of data movement. The bytes don't travel from disk to network card in a straight line. They bounce through kernel buffers and user-space buffers, get copied multiple times, and force several transitions between user mode and kernel mode. Each copy burns CPU cycles, pollutes the cache, and consumes memory bandwidth that could be doing useful work.

For a file server, a CDN edge node, a video streaming service, or a Kafka broker, this overhead is not academic. At high throughput, the memory copy itself becomes the bottleneck long before the network link saturates. Zero-copy techniques exist to eliminate the redundant copies entirely, letting the kernel shuttle data from the page cache directly to the network stack.

This post walks through what actually happens during a traditional `read`/`write` loop, how `sendfile` collapses the data path, and where the technique helps versus where it quietly does nothing.

## The traditional read/write path

Consider the textbook way to serve a file:

```c
char buf[65536];
ssize_t n;
while ((n = read(file_fd, buf, sizeof(buf))) > 0) {
    write(socket_fd, buf, n);
}
```

This looks innocent, but it triggers four context switches and four data copies per buffer's worth of data.

1. `read` issues a syscall (user to kernel). DMA copies data from disk into the kernel page cache.
2. The kernel copies data from the page cache into the user-space buffer `buf`. `read` returns (kernel to user).
3. `write` issues a syscall (user to kernel). The kernel copies `buf` into the socket buffer.
4. DMA copies data from the socket buffer into the network card. `write` returns (kernel to user).

So we have two DMA copies (unavoidable, since hardware must touch the data) and two CPU copies (pure overhead). The CPU copies are the ones zero-copy attacks.

{{< mermaid >}}
graph LR
  Disk["Disk"] -->|"DMA copy 1"| PC["Kernel page cache"]
  PC -->|"CPU copy 2"| UB["User buffer"]
  UB -->|"CPU copy 3"| SB["Socket buffer"]
  SB -->|"DMA copy 4"| NIC["Network card"]
{{< /mermaid >}}

The user buffer round trip is the waste. The data was never modified in user space; it just passed through. Why involve user space at all?

## Enter sendfile

The `sendfile` syscall tells the kernel: copy data directly from one file descriptor to another, without ever surfacing it into user space.

```c
#include <sys/sendfile.h>

off_t offset = 0;
ssize_t sent = sendfile(socket_fd, file_fd, &offset, file_size);
```

With a single call, the data path shrinks. The kernel reads from the page cache and writes to the socket buffer internally. We drop from four context switches to two, and from two CPU copies to one (or zero, with hardware help).

| Stage | read/write | sendfile (basic) | sendfile + SG-DMA |
|-------|-----------|------------------|--------------------|
| Context switches | 4 | 2 | 2 |
| DMA copies | 2 | 2 | 2 |
| CPU copies | 2 | 1 | 0 |
| User buffer needed | yes | no | no |

The "basic" `sendfile` still does one CPU copy from the page cache into the socket buffer. To eliminate even that, the kernel needs help from the network card.

## True zero-copy with scatter-gather DMA

Modern NICs support scatter-gather DMA, which means the card can gather data from multiple memory regions and assemble a packet without requiring contiguous memory. Combined with checksum offloading, this lets the kernel skip the copy into the socket buffer entirely.

Instead of copying page-cache data into the socket buffer, the kernel appends a descriptor to the socket buffer that *points at* the page-cache pages. When the NIC transmits, its DMA engine reads directly from those page-cache pages. No CPU copy occurs at all.

{{< mermaid >}}
graph LR
  Disk["Disk"] -->|"DMA copy 1"| PC["Kernel page cache"]
  PC -.->|"descriptor (pointer)"| SB["Socket buffer"]
  PC -->|"DMA copy 2 (gather)"| NIC["Network card"]
{{< /mermaid >}}

Now there are exactly two DMA copies and zero CPU copies. This is the genuine zero-copy path. On Linux, this kicks in automatically when the underlying hardware advertises scatter-gather and checksum offload support, which essentially all server-grade NICs do.

## A practical server snippet

Here is a minimal but realistic file-serving loop that handles partial sends and large files:

```c
off_t offset = 0;
size_t remaining = file_size;

while (remaining > 0) {
    ssize_t sent = sendfile(socket_fd, file_fd, &offset, remaining);
    if (sent <= 0) {
        if (errno == EAGAIN || errno == EINTR)
            continue;          // socket buffer full or interrupted
        perror("sendfile");
        break;
    }
    remaining -= sent;         // offset already advanced by the kernel
}
```

Note that `sendfile` updates `offset` in place, so you don't track position manually. When the socket is non-blocking and its send buffer fills, `sendfile` returns `EAGAIN`, which pairs naturally with an event loop driven by `epoll`.

## Constraints and gotchas

Zero-copy is not free of caveats, and reaching for it blindly can backfire.

### The source must be a file (page cache)

On Linux, the source descriptor for `sendfile` must support `mmap`-style access, which in practice means a regular file. The destination historically had to be a socket, though newer kernels relaxed this. You cannot `sendfile` from a pipe or another socket directly with the classic call; for those, `splice` is the right tool.

### You cannot transform the data

The entire premise is that user space never touches the bytes. If you need to encrypt, compress, or otherwise modify the payload on the fly, zero-copy is off the table for that segment. This is precisely why TLS historically defeated `sendfile`: the data had to be encrypted in user space. Kernel TLS (kTLS) was introduced specifically to restore zero-copy for encrypted connections by moving the symmetric encryption into the kernel, sometimes offloaded to the NIC.

### Cold cache hurts

Zero-copy shines when the file is already warm in the page cache. On a cache miss, the `sendfile` call blocks while the disk read completes, and you've gained nothing on the I/O side. The technique optimizes the copy path, not disk latency. Pair it with readahead tuning for sequential workloads.

### Small files see little benefit

The win scales with payload size. For a 200-byte response, the copy overhead is negligible compared to syscall and TCP overhead, and the added complexity isn't worth it. Reserve zero-copy for large transfers: media files, backups, log shipping, replication streams.

## splice, vmsplice, and the broader family

`sendfile` is the best known member of a family of zero-copy primitives. The more general tool is `splice`, which moves data between two descriptors as long as one of them is a pipe. The pipe acts as an in-kernel buffer of page references.

```c
// Move data from a file to a socket via a pipe, zero-copy.
int pipefd[2];
pipe(pipefd);

ssize_t n = splice(file_fd, &off, pipefd[1], NULL, len, SPLICE_F_MOVE);
splice(pipefd[0], NULL, socket_fd, NULL, n, SPLICE_F_MOVE);
```

This indirection seems wasteful but the pipe never copies data; it holds references to page-cache pages. `splice` is more flexible than `sendfile` because it can connect arbitrary descriptor pairs through the pipe intermediary, which is how proxies forward data between two sockets without it ever entering user space.

`vmsplice` lets you feed user-space memory pages into a pipe by reference, useful when you generate data programmatically but still want to avoid a copy on the way out.

## Measuring the difference

The clearest way to see the effect is to profile CPU usage at fixed throughput. Serve a large file repeatedly with both implementations and watch system CPU time. A read/write server saturating a 10 GbE link can spend a substantial fraction of a core just memcpy-ing through the user buffer. The `sendfile` version drops that to near zero, freeing the CPU for connection handling.

| Metric | read/write | sendfile |
|--------|-----------|----------|
| CPU per GB transferred | high (memcpy bound) | low |
| Memory bandwidth used | 2x payload | ~1x payload |
| Page cache pressure | extra user pages | none |
| Max connections per core | lower | higher |

The memory bandwidth column matters on multi-tenant boxes. Eliminating the user-space copy means you're not evicting other tenants' hot data from the LLC just to ferry bytes you never inspect.

## When to use it

Reach for zero-copy when you are moving large, unmodified payloads from disk to network and CPU or memory bandwidth is your constraint. File servers, object storage gateways, video origins, and log/replication pipelines are the canonical fits. Skip it for small dynamic responses, for anything requiring on-the-fly transformation in user space (unless you adopt kTLS), and when your bottleneck is disk latency rather than copy overhead.

The mental model is simple: every CPU copy of data you never look at is pure waste. `sendfile`, `splice`, and friends exist to delete that waste, and on a busy server the savings compound into real headroom.
