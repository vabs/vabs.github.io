---
title: "Service Worker lifecycle traps"
date: 2026-01-09T10:15:00-05:00
draft: false
tags: [frontend, service-workers, caching, pwa, browser-internals]
---

## The lifecycle is a deployment protocol

A service worker is not just a background script. It is a versioned proxy that the browser installs, validates, pauses, restarts, and swaps independently from page JavaScript. Most production bugs come from treating it like an immediately loaded bundle. The browser treats it more like an update transaction: a candidate worker installs, waits until old controlled clients go away, then activates and begins handling fetches.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Installing
  Installing --> Installed: install event resolves
  Installing --> Redundant: install rejects
  Installed --> Activating: no older clients or skipWaiting()
  Activating --> Activated: activate event resolves
  Activated --> Redundant: newer worker activates
{{< /mermaid >}}

That state machine is conservative on purpose. If a tab is still running code loaded under worker version A, the browser does not want worker version B suddenly serving incompatible assets. The safety property is good; the trap is that your deployment pipeline can now have two versions live at once.

## Mental model: clients, scope, and control

Registration is keyed by origin plus scope. A page is "controlled" only after navigation under that scope. Calling `navigator.serviceWorker.register("/sw.js")` does not mean the current page's fetches immediately go through the worker. On first install, the worker may activate, but the current document was already loaded without a controller.

`clients.claim()` changes that after activation by taking control of open clients in scope. It is useful for app shells, but risky if your page boot code assumes a clean reload boundary. A claimed page can start receiving cached responses midway through a session.

`skipWaiting()` is similarly sharp. It moves the new worker out of the waiting phase, but it does not update the JavaScript already running in every tab. If worker B serves `main.abc.js` while a tab still references runtime metadata from worker A, you can produce missing chunks, stale API adapters, or hydration mismatches.

## Practical update pattern

For most applications, prefer explicit update coordination:

1. Install new assets into a versioned cache.
2. Do not delete old caches until activation.
3. When a waiting worker exists, notify the page.
4. Let the user accept a reload, then post a message to call `skipWaiting()`.
5. Reload all app tabs after `controllerchange`.

The page owns the user experience; the worker owns cache correctness. Avoid burying reload policy entirely in the worker.

```js
navigator.serviceWorker.addEventListener("controllerchange", () => {
  if (!window.__reloadingForSwUpdate) {
    window.__reloadingForSwUpdate = true;
    location.reload();
  }
});
```

Inside the worker, make install idempotent. The `install` event can be retried after failure, and a browser can kill an idle worker between events.

```js
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open("static-v42").then((cache) =>
      cache.addAll(["/", "/app.css", "/app.js"])
    )
  );
});
```

## Cache traps

The biggest mistake is using a single cache name forever. Updating cached responses in place destroys your rollback path and makes partially installed releases harder to reason about. Version caches by build, then remove old versions only in `activate`.

Another trap is caching opaque cross-origin responses. An opaque response from `no-cors` has status `0`; you cannot inspect whether it is an error page, a blocked font, or a real asset. Cache it only when you are comfortable storing unknown bytes.

Navigation fallback is also easy to overreach. Returning `/index.html` for every failed request breaks real 404s, API calls, source maps, and asset probes. Gate fallbacks by `request.mode === "navigate"` and usually by `Accept: text/html`.

## Failure modes

Stuck waiting worker: at least one old tab is still open. Inspect Application -> Service Workers in DevTools and list clients from the worker.

Install failure loop: one `cache.addAll()` request is failing. `addAll()` rejects the whole install if any response is not OK. Precache only same-origin immutable assets and log the URL during build-time manifest generation.

Offline works in DevTools but not in production: localhost is a secure context, but production scope, path, or HTTPS differs. Confirm the registered script URL and the scope shown in DevTools.

Random stale API data: a broad cache-first handler is catching API requests. Split static asset, navigation, and API strategies. API defaults should normally be network-first or bypassed.

## Fetch strategy boundaries

Write fetch handlers as a routing table, not as one clever catch-all. Static build assets usually want cache-first with immutable revisioned URLs. HTML navigations usually want network-first with an offline fallback. API requests usually want network-only or network-first with carefully bounded fallback data. Images may use stale-while-revalidate if visual freshness is not critical. Mixing those strategies in one broad condition is how stale APIs and broken navigations appear.

Always clone responses when a response must be both returned and cached. A `Response` body is a stream and can be consumed once. Forgetting this creates intermittent failures that depend on which branch reads first. Also handle failed network responses explicitly; caching a 500 page for an app shell can trap users in a broken state until cache cleanup.

## Release engineering

Service workers make asset retention a deployment requirement. If your CDN deletes old chunks immediately after deploy, an old tab can request a chunk that no longer exists even though the browser correctly kept the old worker alive. Keep old assets for at least the maximum expected tab lifetime or use a manifest strategy that can serve old chunks by version.

Build a local two-version test. Start the app, register worker A, open two tabs, then serve worker B with different asset names. Confirm the waiting state, update prompt, reload behavior, old cache cleanup, and offline fallback. This catches most lifecycle bugs before production because it exercises the state machine instead of testing only first install.

## Debugging checklist

- Check the active script URL, scope, and update status in DevTools.
- Verify whether the current page has `navigator.serviceWorker.controller`.
- Log cache names during `install` and `activate`.
- Confirm `event.waitUntil()` wraps all async install and cleanup work.
- Test two-tab deployment: open old app, deploy new worker, open a second tab, then update.
- Test chunk deletion behavior on your CDN; old HTML may reference old chunk names.

## Summary

Treat the service worker as a versioned edge process installed inside the browser. The lifecycle protects users from unsafe swaps, but it means your release can span old pages, waiting workers, active workers, and multiple caches. Keep cache versions immutable, coordinate updates with the page, and debug from the state machine instead of assuming registration equals control.
