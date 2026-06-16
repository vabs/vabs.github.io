---
title: "Cache invalidation strategies"
date: 2026-04-13T14:35:00-04:00
draft: false
tags: [frontend, caching, invalidation, cdn, state-management]
---

## Mental model

Cache invalidation is the discipline of making cached data stop being used when it no longer matches the source of truth. The hard part is not deleting entries; it is knowing which entries are affected, how quickly they must disappear, and what happens while different layers disagree.

Frontend systems usually have several caches at once: browser HTTP cache, service worker cache, CDN cache, in-memory data library cache, normalized entity cache, and sometimes local storage or IndexedDB. A mutation may need to update more than one.

{{< mermaid >}}
graph TD
    A["Mutation: update product price"] --> B["Origin database"]
    A --> C["API cache"]
    A --> D["CDN object"]
    A --> E["Browser HTTP cache"]
    A --> F["Client query cache"]
    F --> G["Visible UI"]
    C --> H["Future API responses"]
    D --> I["Future page loads"]
{{< /mermaid >}}

Every cache entry should have an answer to four questions: what source produced it, what key identifies it, what freshness rule governs it, and what event invalidates it. If any answer is implicit, stale data bugs become archaeology.

## Strategy 1: versioned URLs

For static assets, use content hashes in filenames:

```text
app.4f9a2c.js
styles.91dd0b.css
```

Then cache them for a year with `immutable`. Invalidation becomes publishing a new URL. This is the cleanest strategy because old and new assets can coexist safely. HTML should not be cached as aggressively because it points to the current asset graph.

Versioned URLs work because they avoid mutation. `app.4f9a2c.js` never changes meaning. A deploy publishes `app.a81d7e.js`, and HTML decides which graph the user should load. Keep old assets available longer than any cached HTML; otherwise dynamic imports can fail when a user navigates after a deploy.

## Strategy 2: explicit purge

CDNs and server caches often support purge by URL, prefix, surrogate key, or tag. Tag-based purge is powerful: a product update can purge `product:123`, listing pages, and search fragments that include it.

The risk is incomplete dependency mapping. If the product appears on category pages, recommendations, sitemap, and structured data, purging only `/products/123` leaves stale surfaces. Keep invalidation tags close to render code so dependencies are declared where data is used.

Surrogate keys are useful because one response can carry several dependencies:

```http
Surrogate-Key: product:123 category:shoes pricebook:ca
```

When product 123 changes, purge `product:123`. When regional pricing changes, purge `pricebook:ca`. This works only if render paths consistently annotate responses. Missing tags are the invalidation equivalent of missing indexes: everything looks fine until scale or change exposes the gap.

## Strategy 3: TTL and revalidation

TTL accepts bounded staleness. It is simple and resilient when exact invalidation is expensive. Pair TTL with ETags so stale entries can revalidate cheaply. Use shorter TTLs for volatile data and longer TTLs for reference data.

The failure mode is product mismatch: "price changes must show within 5 seconds" cannot be served by a 10 minute TTL unless you also purge or push updates.

Revalidation is not the same as refetching everything. With `ETag` or `Last-Modified`, the client can ask "is my version still current?" and receive a cheap `304 Not Modified`. This is ideal for data that changes occasionally but is read often.

Stale-while-revalidate is a useful compromise. Serve a stale response immediately within a grace window, refresh in the background, and update future users. Use it for content where speed matters and brief staleness is acceptable. Do not use it for balances, permissions, inventory reservations, or security decisions unless the stale semantics are explicitly safe.

## Strategy 4: client cache updates

After a frontend mutation, update or invalidate the client query cache. For example, React Query, Apollo, Relay, and SWR all provide mutation hooks that can patch known entities or refetch affected queries.

Prefer precise updates for local, obvious changes and invalidation/refetch for broad derived lists. If a mutation changes ordering, permissions, or server-computed fields, patching by hand can drift from backend logic.

Client cache keys need the same discipline as CDN keys. A query for `["products", { category, sort, currency }]` must include every input that affects the response. If currency is omitted, switching regions can show the wrong price from a "valid" cache entry.

For normalized caches, invalidate by entity and by derived query. Updating `Product:123` may refresh the product card, but the "top discounted products" list may need refetching because ordering changed. Treat derived lists as separate cached views with their own invalidation rules.

Optimistic updates add another layer. They improve perceived speed, but they must roll back or reconcile on server response. Use server-returned versions to prevent an older response from overwriting a newer optimistic state.

## Failure modes

Layer mismatch is the classic failure. The client invalidates its query cache, refetches, and receives stale data from the CDN. Or the CDN is purged, but a service worker keeps old HTML. Another failure is negative caching: a cached `404` remains after content is created.

Race conditions also matter. If purge happens before the database commit is visible to replicas, caches may immediately refill with old data. Invalidate after commit, or use version checks that prevent older representations from replacing newer ones.

Vary mismatch can leak or corrupt data. If a response varies by `Authorization`, cookie, locale, or experiment but the cache key ignores it, users can see another context's representation. Default personalized data to private or `no-store`, then deliberately introduce shared caches only for proven-safe fragments.

Service workers can become forgotten caches. A new deploy changes HTML and assets, but the service worker still serves an old app shell. Version service worker caches, delete old caches during activation, and design the update prompt so users can move to a coherent asset graph.

Purge storms are operational failures. A bulk import that purges millions of keys can overload a CDN API or origin refill path. Batch purges, use tags, or switch to versioned keys for high-volume invalidation domains.

## Diagnostics

Add cache metadata to responses in non-sensitive headers:

```http
X-Cache-Status: HIT
X-Content-Version: product-123-v57
```

Trace a stale report by following the layer order: UI cache, service worker, browser HTTP cache, CDN, API cache, database replica. Record the version seen at each layer. Without version identifiers, invalidation bugs become guesswork.

Add version numbers to domain objects. A stale bug report that says "price is wrong" is vague; one that says "UI saw product-123-v57, origin is v59, CDN served v57 HIT" is actionable. Use `Server-Timing` or debug headers to expose cache decisions in staging.

When diagnosing, avoid refreshing blindly. A hard refresh may bypass the layer that caused the bug. Instead, inspect:

- Client query cache key and stored version.
- Service worker response source.
- Browser cache headers and age.
- CDN cache status, age, and surrogate keys.
- API cache status.
- Database primary and replica version.

For mutation bugs, log the order: commit, replica visibility, purge request, purge completion, refetch, and client cache update. Many "invalidation" bugs are actually ordering bugs.

## Checklist

- Static assets use content-hashed URLs and long immutable caching.
- HTML and API responses have conservative freshness or validators.
- CDN purges cover all dependent surfaces, not only canonical URLs.
- Client mutation handlers update or invalidate affected query keys.
- Negative cache entries have short TTL or explicit purge.
- Debug headers expose cache status and content version.
- Purge/refill ordering avoids writing old data back into cache.
- Cache keys include every response-varying input.
- Personalized responses default to private or no-store.
- Service worker caches are versioned and cleared intentionally.
