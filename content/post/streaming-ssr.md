---
title: "Streaming SSR"
date: 2026-03-05T12:05:00-05:00
draft: false
tags: [frontend, ssr, streaming, hydration, performance]
---

## Mental model: send the shell before every dependency is done

Traditional server-side rendering waits until the whole page's data and HTML are ready, then sends one response. Streaming SSR sends useful HTML as soon as possible, then streams later chunks when slower work completes. The user can receive the document shell, critical layout, and fallbacks before every panel is ready.

Streaming is not just "flush earlier." It changes how you model latency. Parts of the page become independently deliverable regions, often aligned with Suspense boundaries. The server can reveal fast content immediately and let slow content arrive later without blocking the entire first byte.

{{< mermaid >}}
sequenceDiagram
    participant C as Browser
    participant S as Server renderer
    participant D as Data sources
    C->>S: request page
    S->>C: HTML shell + fallbacks
    S->>D: fetch slow panel data
    D-->>S: panel data
    S->>C: streamed boundary chunk
    C->>C: insert content and hydrate when JS is ready
{{< /mermaid >}}

## Internals

A streaming renderer starts rendering the route and flushes the shell once enough outer structure is known. Boundaries that suspend emit fallback HTML and placeholders. When suspended work resolves, the server sends additional HTML and small instructions that let the client place the completed content into the correct location.

Hydration can also become selective. The browser may display streamed HTML before all JavaScript has loaded. Interactive islands or boundaries hydrate when their code and data are available. This improves perceived performance but increases the need for deterministic server and client output.

Backpressure matters. The HTTP response is a stream with a receiver, buffers, proxies, compression, and timeouts. A server that renders faster than the network can consume can build memory pressure if it ignores stream backpressure. A proxy that buffers responses can accidentally erase the value of streaming.

Status codes and headers become more constrained after flushing. Once bytes are sent, you cannot change the HTTP status to 500 or redirect normally. Frameworks usually require critical auth, routing, and status decisions before the shell flushes.

## Practical patterns

Put navigation, page identity, and stable layout in the shell. Users should know where they landed quickly. Put slow recommendations, analytics-heavy widgets, comments, or personalized sidebars behind boundaries that can stream later.

Fetch critical data before shell flush only when the page cannot be meaningfully rendered without it. Everything else should either start in parallel or sit behind a boundary. Avoid parent components that await slow data before rendering children that could have streamed.

Design fallbacks with the same dimensions as final content. Streaming should feel like content filling in, not like the page repeatedly reflowing. Skeletons are usually better than spinners for regions that occupy layout.

Verify deployment infrastructure. CDNs, reverse proxies, serverless adapters, and compression middleware can buffer chunks. A locally streaming app may become a buffered response in production unless the platform supports streaming end to end.

Name boundaries according to product regions, not component implementation. `AccountSummary` and `RecommendationsRail` are useful in logs; `SuspenseWrapper2` is not. Boundary names make it possible to compare server latency, stream timing, and client reveal behavior across releases.

Plan cache behavior per region. The shell might be globally cacheable, while a personalized account panel is private and streamed per request. If one uncached dependency sits above the shell, the entire response becomes personalized and slow. Keep cacheable structure above personalized boundaries where the framework allows it.

## Failure modes

The most common failure is a hidden waterfall. The server renders a parent, awaits data, then discovers children that start their own fetches. The response technically streams, but the useful chunks are delayed sequentially. Start independent fetches early and place Suspense boundaries where latency can be isolated.

Another failure is late fatal errors. If a critical permission check happens after flushing the shell, the server can no longer send a clean redirect or 403. Move critical decisions ahead of streaming or design in-page error boundaries for non-critical regions.

Hydration mismatch is more painful with streaming because users may see server HTML before the client corrects it. Time-dependent rendering, locale differences, random IDs, and feature flags that differ between server and client can all produce warnings or broken interactivity.

Proxy buffering silently removes benefits. If first byte is fast but first meaningful content still arrives only after the full render, inspect response chunks with curl or browser network timing.

Resource ordering can also undermine the experience. If the server streams a boundary quickly but the JavaScript or CSS needed to display it arrives late, the user still waits. Emit preload hints for critical chunks and keep late boundaries from importing large client-only dependencies unless they truly need them.

## Debugging and diagnostics

Measure time to first byte, shell flush, each boundary reveal, and hydration readiness. Server logs should include boundary names and durations. Browser traces should show whether chunks arrive progressively or as one buffered block.

Use `curl -N` or similar tooling to inspect chunk arrival. In Chrome DevTools, look at response timing and streaming previews where available. Test through the same CDN and hosting path users hit, not only local development.

Inject artificial delay into specific panels. A good streaming page should still deliver the shell and unrelated regions quickly while the delayed boundary waits.

## Checklist

- Put route identity and stable layout in the initial shell.
- Use boundaries around slow, non-critical regions.
- Start independent data fetches in parallel.
- Decide redirects, auth, and status before flushing.
- Preserve fallback dimensions to avoid layout shift.
- Verify CDN and proxy streaming behavior.
- Track boundary reveal timing in production.
