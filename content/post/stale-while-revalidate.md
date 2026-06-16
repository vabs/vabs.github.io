---
title: "Stale-while-revalidate"
date: 2026-04-06T10:10:00-04:00
draft: false
tags: [frontend, caching, http, service-worker, performance]
---

## Mental model

`stale-while-revalidate` serves a cached response immediately while a refresh happens in the background. The user gets low latency, and the cache eventually catches up. It is a deliberate trade: accept bounded staleness to improve responsiveness.

The pattern exists in HTTP cache directives, service workers, CDNs, and client data libraries. The same question applies everywhere: "How stale is acceptable for this resource?"

{{< mermaid >}}
sequenceDiagram
    participant U as User
    participant C as Cache
    participant S as Server
    U->>C: Request resource
    C-->>U: Return stale cached response immediately
    C->>S: Revalidate in background
    alt changed
        S-->>C: 200 new body
        C->>C: Update cache
    else unchanged
        S-->>C: 304
        C->>C: Extend cached metadata
    end
{{< /mermaid >}}

## Internals that matter

HTTP expresses the pattern like this:

```http
Cache-Control: public, max-age=60, stale-while-revalidate=300
```

For 60 seconds, the response is fresh. For the next 300 seconds, a cache may serve the stale response while revalidating. After that, it should not use the response without blocking validation.

Service workers implement the same behavior manually:

```js
self.addEventListener("fetch", event => {
  event.respondWith((async () => {
    const cache = await caches.open("pages-v1");
    const cached = await cache.match(event.request);
    const refresh = fetch(event.request).then(response => {
      cache.put(event.request, response.clone());
      return response;
    });
    return cached || refresh;
  })());
});
```

That code is simplified; production implementations need method checks, error handling, cache limits, and opaque response policy.

The directive extends the usable lifetime of a stale response, not the fresh lifetime. With `max-age=60, stale-while-revalidate=300`, a cache can serve without contacting origin for 60 seconds. From second 61 through second 360, it may serve stale immediately and revalidate in parallel. After that, it should block on validation or fetch a new response. `stale-if-error` is a separate directive for serving stale when origin fails; do not assume SWR automatically covers outages.

Different layers can implement SWR at the same time. The browser HTTP cache, CDN, service worker, and client data library may each have a freshness model. If their windows disagree, users can see unexpectedly old data. Document which layer owns staleness for each resource.

Revalidation still needs cache keys and validators. `Vary`, `ETag`, `Last-Modified`, and authorization semantics all apply. A fast stale response is only safe if it is the right response for that user, locale, encoding, and feature state.

## Practical patterns

Use stale-while-revalidate for resources where slightly old data is better than a spinner: article pages, product catalog metadata, avatars, feature configuration, or navigation shells. Avoid it for bank balances after transfer, checkout totals, access control decisions, and destructive workflow state.

In UI data libraries, label the state honestly. Showing cached data while revalidating is fine, but the UI should avoid implying a just-confirmed server state. A subtle refresh indicator or "updated moments ago" timestamp can prevent confusion.

At the CDN, pair SWR with validators so revalidation is cheap. In service workers, avoid caching authenticated API responses unless you have a clear privacy and invalidation model.

For content sites, SWR works well on article HTML and API-backed lists. Readers get instant pages while edits propagate within a bounded window. If legal, pricing, or availability text changes must be immediate, keep those fragments outside the stale layer or use targeted purge.

For feature flags and configuration, choose a short stale window and include a kill-switch path. It is reasonable for a UI experiment assignment to lag by a minute; it is not reasonable for a broken checkout flag to remain stale for an hour. Keep emergency config in a path with stricter validation or active purge.

For service workers, cache only successful `GET` responses with acceptable status and content type. Clone responses before caching. Do not cache `opaque` cross-origin responses unless you accept that you cannot inspect status or contents. Limit cache size and evict old entries, otherwise a helpful SWR strategy becomes unbounded storage growth.

## Failure modes

The biggest failure is unbounded staleness. If background revalidation fails repeatedly and the app keeps serving old data, users may never see corrections. Add maximum stale windows and visible failure paths for important data.

Another failure is cache stampede. If many edge nodes revalidate the same stale resource at once, the origin gets hit hard. CDNs often provide request coalescing; application caches may need locks or single-flight behavior.

Service workers add lifecycle risk. A buggy SWR strategy can keep serving old HTML that references deleted assets. Version caches and provide a way to bypass or update the worker.

A common product failure is stale confirmation. A UI that says "saved" or "available" based on stale data can push users into wrong decisions. For state that affects money, permissions, inventory, or destructive actions, revalidate before acting even if the surrounding page uses SWR.

Another failure is double revalidation. A service worker returns stale and refreshes in the background; the client data library then immediately fetches the same data; the CDN also revalidates. This creates extra traffic and confusing traces. Decide whether the page shell, API response, or client cache should own the refresh.

Privacy leakage is a risk when SWR meets shared caches. `public, stale-while-revalidate` on personalized data is wrong even if the origin response was correct. Use `private` for browser-only storage or avoid caching authenticated data at shared layers.

## Diagnostics

Log cache status: `HIT`, `STALE`, `REVALIDATED`, `MISS`. At the browser level, inspect `Age`, `Cache-Control`, and CDN-specific cache headers. For service workers, use Application panel cache storage and update-on-reload during debugging.

Tests should simulate stale cache plus server change, stale cache plus network failure, and cache expiration beyond the SWR window.

Add timestamps to payloads while debugging. A `generatedAt`, version, or ETag displayed in non-production tools makes it obvious whether the UI is fresh, stale within policy, or stale beyond policy. Remove or hide debug fields from user-facing surfaces if they create confusion.

For CDN behavior, test with repeated requests across the freshness boundary. Capture headers before max-age expires, during SWR, and after SWR expires. Confirm whether the CDN serves stale while a background origin request happens, whether it coalesces simultaneous revalidations, and whether a failed origin response is cached accidentally.

For service workers, inspect both the request path and worker lifecycle. A newly deployed worker may be waiting while old code controls the page. Use skip-waiting only when you understand the migration consequences; forcing a new worker can interrupt in-flight tabs if caches and clients are not compatible.

## Implementation guidance

Model each resource with three values: fresh duration, stale-while-revalidate duration, and maximum tolerated incorrectness. The last one is a product value, not a technical default. A blog avatar can be stale for days; a seat reservation cannot.

Expose revalidation state to code that makes decisions. Rendering stale catalog data is fine, but submitting an order should use a fresh price and inventory check. In client code, pass metadata such as `isStale`, `isFetching`, or `updatedAt` through the view model rather than burying it in the cache library.

For background refresh, use single-flight behavior where possible. If ten requests arrive for the same stale key, one refresh should update the cache while the others receive the stale object. At the CDN this may be built in; in application caches it may require a lock keyed by cache key.

## Checklist

- The resource has an explicit acceptable staleness window.
- Revalidation uses ETag or Last-Modified where possible.
- Important UIs reveal refresh or last-updated state.
- Failures do not create infinite stale data.
- Service worker caches are versioned and bounded.
- Metrics distinguish fresh hits, stale hits, revalidations, and misses.
- Shared caches never store personalized stale responses.
- User actions that require correctness revalidate before committing.
- Deploys retain assets needed by stale HTML.
