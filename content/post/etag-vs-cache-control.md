---
title: "ETag vs Cache-Control"
date: 2026-03-23T11:45:00-04:00
draft: false
tags: [frontend, caching, http, etag, cache-control]
---

## Mental model

`Cache-Control` tells caches how long and under what rules a response can be reused. `ETag` gives caches a validator they can send back to ask, "Is my stored response still current?" They are complementary, not alternatives.

Freshness avoids a network round trip. Validation makes a round trip but can avoid downloading the full response. The fastest request is the one never made; the next best is a `304 Not Modified`.

{{< mermaid >}}
sequenceDiagram
    participant B as Browser cache
    participant S as Server
    B->>B: Check Cache-Control freshness
    alt fresh
        B->>B: Use cached response
    else stale with ETag
        B->>S: If-None-Match: abc
        S-->>B: 304 Not Modified
        B->>B: Reuse body, update headers
    else no validator
        B->>S: Full request
        S-->>B: 200 with body
    end
{{< /mermaid >}}

## Internals that matter

`Cache-Control: max-age=60` means the response is fresh for 60 seconds from the response time. During freshness, the browser can reuse it without contacting the server. `no-cache` does not mean "do not store"; it means "store, but revalidate before reuse." `no-store` means do not store.

An `ETag` is an opaque version identifier:

```http
ETag: "users-v42"
```

On revalidation, the browser sends:

```http
If-None-Match: "users-v42"
```

If unchanged, the server returns `304` with no body. Strong ETags represent byte-for-byte identity. Weak ETags, prefixed with `W/`, represent semantic equivalence and are useful when byte-level output can differ without meaningful content changes.

The browser's decision is roughly: find a matching cache entry, check whether the request method and `Vary` metadata still match, compute freshness, then either reuse, validate, or bypass. `Vary` is easy to overlook. If a response varies by `Accept-Encoding`, `Accept-Language`, or `Origin`, those request headers are part of the cache key. A CDN or browser cache that misses a necessary `Vary` can serve the right URL with the wrong representation.

Validators come in two main forms: `ETag` and `Last-Modified`. `ETag` wins for precision because it can represent application-level versions, content hashes, or database row versions. `Last-Modified` is second-level time based and can be wrong when many updates happen quickly. If both are present, clients can send both `If-None-Match` and `If-Modified-Since`; servers should give `If-None-Match` precedence.

`Age` matters in shared caches. A CDN response may already be 20 seconds old when it reaches the browser, so `Cache-Control: max-age=60` gives the browser about 40 seconds of remaining freshness. Debugging cache behavior without looking at `Age` often leads to confusion where the browser appears to revalidate too early.

## Practical patterns

For fingerprinted static assets:

```http
Cache-Control: public, max-age=31536000, immutable
```

The URL changes when content changes, so long freshness is safe.

For HTML documents:

```http
Cache-Control: no-cache
ETag: "home-render-123"
```

The browser may store the page but must revalidate before reuse.

For API responses:

```http
Cache-Control: private, max-age=30, stale-while-revalidate=60
ETag: "account-987"
```

Use `private` when the response is user-specific and must not be stored by shared caches.

For generated JSON, prefer validators tied to the data version rather than the rendered bytes. A list endpoint can use a version derived from the newest row timestamp, a monotonically increasing collection revision, or a hash of stable serialized output. The key requirement is consistency across app servers. If server A emits `"users-v42"` and server B emits `"users-v42"` for the same representation, a load-balanced revalidation can return `304`. If each server includes its own boot time or random salt, every revalidation becomes a full `200`.

For HTML behind a CDN, separate the shell from long-lived assets. The document can be `no-cache` or short-lived with validation, while `/assets/app.8f3a.js` is immutable for a year. That lets deploys take effect quickly without throwing away the value of asset caching. If you cannot fingerprint assets, keep `max-age` short and accept the extra network traffic.

For authenticated pages, decide whether browser-only caching is acceptable. `Cache-Control: private, no-cache` allows the user's browser to store and revalidate, but shared caches must not keep it. `no-store` is appropriate for highly sensitive responses, logout responses, and pages where back-button restoration would expose data after session end. Do not use `no-store` as a blanket performance workaround; it disables useful browser features and can make apps feel slower.

For range requests and downloads, strong validators are important. A client resuming a partial download needs confidence that the bytes are from the same representation. Weak ETags are not enough for `If-Range` semantics because "semantically equivalent" is not the same as byte-compatible.

## Failure modes

The common failure is using long `max-age` on non-fingerprinted assets. Users keep stale JavaScript and CSS until the cache expires. Another is generating unstable ETags from timestamps, gzip output, or per-server implementation details, which causes unnecessary `200` responses instead of `304`.

For personalized data, forgetting `private` can leak through shared caches. Conversely, putting `no-store` everywhere kills useful browser caching and makes back/forward navigation slower.

Compression can create subtle validator bugs. If an origin calculates an ETag over uncompressed bytes but an intermediary stores gzip and brotli variants, that can be fine as long as `Vary: Accept-Encoding` is correct and the validator semantics are documented. If an intermediary rewrites ETags per encoding, conditional requests may fail to match across layers. Pick one strategy and test through the CDN, not only against localhost.

Another failure is returning `304` without updating headers you expect caches to refresh. A `304` response has no body, but it can update metadata such as `Cache-Control`, `Expires`, and `ETag`. If you change caching policy during a rollout, verify the revalidation path returns the new headers.

`Set-Cookie` and shared caching also need care. Some CDNs avoid caching responses with cookies by default; others can be configured to cache while stripping or varying on selected cookies. Accidentally caching a response that includes user-specific cookies or user-specific body data is a serious isolation bug.

## Diagnostics

Inspect Network panel size and status. `from memory cache` and `from disk cache` indicate freshness reuse. `304` indicates successful validation. A full `200` for unchanged content suggests validator mismatch or missing conditional handling.

Use response headers and request headers together. A response with `ETag` is only useful if later requests include `If-None-Match` and the server honors it.

When the behavior differs between browser and curl, reproduce the browser request headers. Include `Accept-Encoding`, credentials, and relevant `Vary` inputs. Then test conditional handling explicitly:

```sh
curl -i https://example.com/data.json
curl -i https://example.com/data.json -H 'If-None-Match: "users-v42"'
```

For CDN-backed systems, inspect both origin and edge headers. Many CDNs add `Age`, `X-Cache`, `CF-Cache-Status`, Fastly's `X-Served-By`, or similar diagnostics. A browser `MISS` may actually be an edge `HIT` plus browser validation, or an edge `MISS` caused by a cache key mismatch. Log the origin request path for `If-None-Match` and compare it to edge analytics.

In application tests, assert the full lifecycle: first request returns `200` with validator, second conditional request returns `304`, changed content returns `200` with a new validator, and private responses include the right cache directives. For multi-server deployments, test two different app instances if possible.

## Implementation guidance

At the server boundary, treat caching as part of the route contract. A static asset handler, HTML renderer, public API endpoint, and private API endpoint should not share one vague helper that emits the same headers for everything. Use small named policies such as `immutableAssetCache`, `htmlRevalidationCache`, and `privateApiCache`.

For ETag generation, prefer cheap deterministic inputs. Content hashes are fine for files. Database version columns or updated-at maxima are fine for API collections. Avoid hashing very large response bodies on every request unless you already have the body and the cost is acceptable. If the endpoint is expensive to render, compute a version key before doing the expensive work; a matching `If-None-Match` can then return `304` early.

Document cache invalidation. If a product update changes `/api/products`, which validator changes? If a feature flag changes rendered HTML, does the HTML ETag include the flag version or user segment? Cache bugs often come from hidden inputs that affect output but are not represented in the cache key or validator.

## Checklist

- Fingerprinted assets use long `max-age` and `immutable`.
- HTML uses revalidation-friendly caching.
- Personalized responses are `private` or `no-store` as appropriate.
- ETags are stable across equivalent responses and server instances.
- `304` handling is implemented and tested.
- Cache headers are verified in real browser requests, not only server code.
- `Vary` matches every request header that changes the representation.
- CDN and origin behavior are tested together.
- Cache policy is documented per route class.
