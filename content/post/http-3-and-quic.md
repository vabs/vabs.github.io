---
title: "HTTP/3 and QUIC"
date: 2026-03-16T10:30:00-04:00
draft: false
tags: [frontend, http3, quic, networking, performance]
---

## Mental model

HTTP/3 is HTTP semantics running over QUIC instead of TCP. QUIC is a UDP-based transport that includes encryption, streams, congestion control, loss recovery, and connection migration. For frontend engineers, the practical promise is lower latency under packet loss and faster connection setup, especially on mobile networks.

HTTP/2 multiplexes many requests over one TCP connection, but TCP still delivers bytes in order. If one packet is lost, all streams sharing that connection can stall until the missing TCP segment is retransmitted. QUIC moves ordering to independent streams, so packet loss blocks only affected streams.

{{< mermaid >}}
graph TD
    A["HTTP/2"] --> B["Streams multiplexed over TCP"]
    B --> C["TCP loss blocks connection delivery"]
    D["HTTP/3"] --> E["Streams multiplexed over QUIC"]
    E --> F["Loss blocks only impacted streams"]
    E --> G["TLS 1.3 built in"]
    E --> H["Connection IDs support migration"]
{{< /mermaid >}}

## Internals that matter

QUIC packet numbers are separate from stream offsets. Retransmitted data gets a new packet number, which removes TCP's retransmission ambiguity and improves RTT measurement. QUIC also uses TLS 1.3 during transport setup; there is no separate TCP handshake followed by TLS negotiation in the same shape as HTTPS over TCP.

Connection IDs allow a connection to survive IP and network changes. A phone switching from Wi-Fi to cellular can keep the QUIC connection logically alive if both endpoints support migration. That matters for long-lived apps, streaming, and flaky mobile use.

HTTP/3 uses QPACK for header compression. QPACK is designed to avoid the worst head-of-line blocking problems HPACK would have over independent streams, though dynamic table dependencies can still create bounded blocking.

QUIC runs over UDP, but it is not raw unreliable HTTP. QUIC implements reliable streams, congestion control, flow control, loss recovery, and encryption in user space. Moving these responsibilities out of the operating system TCP stack lets endpoints evolve faster, but it also means middleboxes that understand TCP may not understand QUIC.

Connection setup is one of the practical wins. A new HTTPS connection over TCP usually requires TCP setup plus TLS negotiation. QUIC combines transport and TLS 1.3 handshakes, and repeat connections may use 0-RTT. 0-RTT can reduce latency, but requests replayed in early data must be safe from replay concerns. Most application teams should let the CDN decide which requests are eligible.

Stream independence helps under loss, but it does not remove bandwidth limits. If the connection is saturated by huge images or video, HTTP/3 cannot make bytes free. It mainly reduces unnecessary blocking and improves connection behavior on unstable networks.

## Practical frontend impact

You usually do not change application code to "use HTTP/3." You enable it at the CDN, load balancer, or edge server, advertise it with `Alt-Svc`, and verify the browser negotiates it. The benefits show up in waterfalls: fewer stalled streams during loss, faster repeat connections, and sometimes better tail latency.

HTTP/3 helps most when:

- Users are on lossy mobile or Wi-Fi networks.
- Pages make many concurrent requests to the same origin.
- The site is served from an edge close to users.
- Connection setup cost is visible in navigation timing.

It helps less when the bottleneck is server rendering, JavaScript execution, third-party tags, image weight, or cache misses.

Enabling HTTP/3 is usually an edge configuration project. The browser first learns that HTTP/3 is available through `Alt-Svc` or HTTPS DNS records, then attempts QUIC on a later or parallel connection. The first-ever navigation may still use HTTP/2 while the browser discovers support.

Frontend changes still matter. HTTP/3 can improve transport behavior, but request count, cacheability, and critical path shape remain important. A page with hundreds of tiny uncached resources may negotiate `h3` and still perform poorly because JavaScript execution and server work dominate.

For APIs used by SPAs, HTTP/3 can reduce tail latency for many concurrent requests to the same origin, especially on mobile. It will not fix inefficient API fan-out by itself. If a route makes ten serial API calls, address the serialization before expecting transport improvements.

## Failure modes

UDP can be blocked or degraded by some networks. Browsers fall back to HTTP/2 or HTTP/1.1, so your system must perform well without HTTP/3. Another issue is observability: some older proxies, firewalls, and logging systems assume TCP semantics and lose visibility into QUIC traffic.

Misconfigured `Alt-Svc` can advertise HTTP/3 for an origin that is not actually reachable, causing wasted attempts before fallback. Certificate, SNI, and CDN routing must match the advertised endpoint.

UDP blocking is normal in some enterprise, hotel, carrier, and captive portal networks. Treat fallback as a normal path, not an exception. If HTTP/2 performance quietly rots because dashboards focus only on `h3`, a meaningful share of users will suffer.

Observability can regress after enabling QUIC. TCP-based packet captures, proxy logs, and connection-level metrics may no longer show the same details. Make sure edge logs include protocol, handshake failures, fallback reasons, and request timing before using HTTP/3 as an optimization story.

0-RTT can create correctness concerns for non-idempotent requests if misapplied. Most browser and CDN stacks are conservative, but teams handling payments, mutations, or auth-sensitive flows should understand their edge provider's policy.

## Diagnostics

In Chrome DevTools, enable the Protocol column and look for `h3`. Use `curl --http3` if your local curl supports it. At the edge, track negotiation rate, fallback rate, handshake failures, and latency by protocol.

Compare p75 and p95 metrics, not only medians. QUIC's benefit is often in bad network conditions. Synthetic tests should include packet loss; a clean fiber connection may show little difference.

Segment results by protocol, region, device class, effective connection type, and cache state. If HTTP/3 users look faster only because they are on newer browsers or better networks, the protocol may not be the cause. Compare similar cohorts and watch tail percentiles.

Use fallback tests intentionally. Block UDP in a test environment or use a network that does not negotiate QUIC, then verify the site still performs and logs cleanly over HTTP/2. Also test a bad `Alt-Svc` rollback path so clients stop attempting a broken endpoint quickly.

In DevTools, a request's protocol column showing `h3` confirms negotiation for that request, not necessarily for every origin. Third-party scripts, image CDNs, and API hosts each negotiate separately. Optimize the origins that are actually on the critical path.

## Implementation guidance

Start at the CDN or edge: enable HTTP/3 for one hostname, verify TLS and routing, then watch negotiation and fallback rates. Roll out by hostname or traffic segment if your provider allows it. Keep HTTP/2 enabled because it remains the fallback for blocked UDP and unsupported clients.

Publish an operational dashboard before declaring success. Include protocol mix, handshake failures, p75 and p95 TTFB, request duration, retransmission or loss signals if available, and fallback rate. A protocol rollout without visibility is hard to debug when a regional network or enterprise proxy behaves badly.

Do not let HTTP/3 distract from higher-impact work. If LCP is dominated by a 700 KB hero image and five seconds of main-thread JavaScript, QUIC may improve some network stalls but will not produce a fast page. Treat it as transport tuning after caching, asset weight, and rendering are under control.

## Checklist

- HTTP/3 is enabled at the edge with valid TLS and `Alt-Svc`.
- Fallback to HTTP/2 works and is monitored.
- Protocol is verified in browser waterfalls.
- Metrics are segmented by protocol and network quality.
- UDP-blocked networks are expected, not treated as outages.
- Performance work still addresses JS, images, caching, and server time.
- Edge logs expose protocol, fallback, and handshake failures.
- Tail latency is compared across similar network cohorts.
- Non-idempotent requests are reviewed for 0-RTT implications.
