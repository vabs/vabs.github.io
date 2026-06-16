---
title: "Web Workers vs Service Workers"
date: 2026-02-20T09:00:00-04:00
draft: false
tags: [frontend, web-workers, service-workers, offline, performance]
---

Web Workers and Service Workers both run off the main thread, but they solve different problems. A Web Worker is a compute companion for a page. A Service Worker is a network proxy and lifecycle-managed background agent for an origin. Confusing them leads to brittle caching, misplaced business logic, and debugging sessions where the code you changed is not the code currently controlling the page.

{{< mermaid >}}
flowchart LR
  Page[Browser page] -->|postMessage| WW[Web Worker]
  WW -->|result| Page
  Page -->|fetch/navigation| SW[Service Worker]
  SW --> Cache[Cache Storage]
  SW --> Network[Network]
  SW --> Page
{{< /mermaid >}}

## Mental model

A Web Worker is created by a page with `new Worker()`. It lives as long as the page keeps it alive. It is good for parsing large files, running search indexes, image processing, compression, WebAssembly, and any task that would otherwise create main-thread long tasks. It cannot intercept network requests for other pages and does not survive independently as a general daemon.

A Service Worker is registered for a scope. Once installed and activated, the browser can start it in response to fetches, push events, sync events, and other lifecycle events. It can intercept requests, fulfill them from Cache Storage, update resources in the background, and enable offline behavior. It can be terminated when idle, so it must not rely on in-memory state being present.

## Internals that matter

Web Worker communication is explicit. You send messages, optionally transfer buffers, and receive responses. If a Worker crashes, the page can recreate it. Versioning is straightforward because the page imports a worker script URL, often with the same bundler hash as the application.

Service Worker lifecycle is more nuanced: `install`, `waiting`, `activate`, and `controllerchange` affect what code handles fetches. A newly downloaded Service Worker may sit waiting while old tabs remain open. Calling `skipWaiting()` and `clients.claim()` changes that behavior, but it can also activate new caching logic while old app code is still running.

## Practical patterns

Use Web Workers behind application-level adapters. A search module can expose `indexDocuments()` and `query()` while hiding `postMessage` details. Keep cancellation, timeouts, and error propagation in the adapter.

Use Service Workers for asset caching, offline shells, request routing, and resilience. Keep product logic out of the Service Worker unless it is directly about network behavior. A Service Worker that knows too much about UI state becomes hard to update safely.

For generated apps, prefer a proven Service Worker strategy such as Workbox for precaching and runtime routes. Hand-rolled Service Workers are fine for small cases, but cache invalidation is unforgiving. Name caches by version, delete obsolete caches on activation, and design fallback responses intentionally.

For Web Workers, define a message protocol rather than passing ad hoc objects. Include message type, id, payload, and error shape. The page should be able to correlate responses with requests, time out abandoned work, and terminate or recreate the Worker after a fatal error.

```js
worker.postMessage({ id, type: "search", payload: { query } });

worker.onmessage = (event) => {
  const { id, ok, result, error } = event.data;
  resolvePendingRequest(id, ok ? result : Promise.reject(error));
};
```

Use transfer lists for large binary payloads and keep structured-clone costs visible for object-heavy messages. A Worker that receives a huge object graph on every keystroke may move CPU off the main thread but still block serialization.

For Service Workers, separate precache assets from runtime data. Hashed JavaScript, CSS, and font files are good cache-first candidates. HTML documents often need network-first or stale-while-revalidate behavior. API responses need route-specific policies based on freshness, authentication, and offline expectations. One global "cache everything" handler eventually causes stale sessions or broken deploys.

Design the offline UX at the same time as the cache policy. If a write fails offline, does the app queue it, reject it, or let the user edit a draft? That decision belongs in product and application code, not only in the Service Worker fetch handler.

## Lifecycle details

A Web Worker lifecycle is page-owned. The page creates it, sends work, and terminates it when no longer useful. Dedicated Workers serve one page; Shared Workers can coordinate multiple same-origin contexts where supported. Workers do not have DOM access, so all UI changes must be represented as messages back to the page.

A Service Worker lifecycle is browser-owned. Registration downloads the script. Install can populate caches. Activate can clean old caches. Fetch events may start the worker after it was idle. Because the browser can stop it between events, durable state belongs in Cache Storage, IndexedDB, or the network, not module-level variables.

Updates require special care. A new Service Worker script is byte-compared against the old one. If different, it installs, then usually waits until old controlled clients close. Calling `skipWaiting()` activates sooner, and `clients.claim()` lets it control existing pages. Those APIs are useful, but pairing new Service Worker behavior with old page JavaScript can break protocols. Many apps show an "update available" prompt and reload all clients into a consistent version.

## Failure modes

For Web Workers, common failures are serialization cost, missing transfer lists, unhandled errors, and creating too many workers. A worker pool is often better than one worker per task when tasks are frequent.

For Service Workers, common failures are stale assets, update deadlocks, scope mistakes, and opaque responses from cross-origin requests. The most confusing symptom is "I deployed a fix but the browser still runs old JavaScript." Check Application > Service Workers in DevTools, unregister during diagnosis, and inspect Cache Storage contents.

Another Service Worker trap is caching HTML too aggressively. If `index.html` is stale but references old chunk names, the app may fail after a deploy. Many production setups use network-first or stale-while-revalidate for HTML and cache-first for hashed static assets.

Service Workers can also cache authenticated data incorrectly. A response for one user should not be served to another after logout or account switch. Respect `Cache-Control` where appropriate, include user or tenant scoping in runtime caches when necessary, and clear sensitive caches on logout. Be cautious with opaque cross-origin responses because you cannot inspect status or body.

Navigation preload can reduce latency when a Service Worker starts cold, but it adds another path to reason about. If enabled, the fetch handler should consistently choose between the preload response, cache, and network. Otherwise diagnostics become confusing because the same route sometimes comes from preload and sometimes from a manual fetch.

For Web Workers, cancellation is easy to fake and hard to implement. Ignoring a response after it arrives does not stop CPU work already running. For long tasks, add cooperative cancellation checks, chunk the work, or terminate the Worker and recreate it. Termination is blunt but reliable when the Worker has no important state.

## Diagnostics

For Web Workers, instrument queue length, processing time, message size, and error events. Use Performance profiles to verify that main-thread long tasks actually moved.

For Service Workers, log lifecycle events with version identifiers. Inspect which worker is `installing`, `waiting`, `active`, and which clients it controls. Test upgrade paths with two tabs open, not just a fresh page load.

During Service Worker debugging, always answer four questions:

- Which script URL and version is registered?
- Which worker controls this page?
- Which cache entry served this request?
- Is the page using old app code with a new worker, or the reverse?

Chrome DevTools Application panel answers most of this, but application logs with a build id make remote reports much easier. Include the page build id, Service Worker build id, cache name, and fetch strategy in debug output.

For Web Workers, add a synthetic benchmark route or dev command that sends representative payloads and reports clone time, transfer time, processing time, and response time. This prevents "we moved it to a Worker" from becoming a substitute for measurement.

## Checklist

- Use Web Workers for page-owned compute.
- Use Service Workers for origin-scoped network control.
- Do not keep critical Service Worker state only in memory.
- Version caches and clean old entries on activation.
- Test Service Worker upgrades with existing tabs.
- Measure Worker message costs before assuming a win.
