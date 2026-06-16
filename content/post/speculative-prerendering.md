---
title: "Speculative prerendering"
date: 2026-03-08T10:05:00-04:00
draft: false
tags: [frontend, performance, navigation, browser-internals, caching]
---

Speculative prerendering loads and renders a likely future page before the user navigates to it. When the prediction is right, navigation can feel instant because HTML parsing, subresource loading, script execution, layout, and sometimes rendering have already happened in a hidden context. When the prediction is wrong, you have spent bandwidth, CPU, memory, cache capacity, and possibly backend quota for no user-visible result.

The mental model is a pipeline: predict intent, declare safe candidates, let the browser prerender under constraints, then activate or discard. Your application must be safe to run before visible navigation.

{{< mermaid >}}
flowchart TD
  A[User behavior signal] --> B[Candidate URL]
  B --> C[Speculation Rules]
  C --> D[Hidden prerender]
  D --> E{User navigates?}
  E -->|yes| F[Activate prerendered page]
  E -->|no| G[Discard work]
{{< /mermaid >}}

## Speculation rules

Modern Chromium-based browsers support the Speculation Rules API, where you provide JSON rules for prefetch or prerender candidates. Prefetch fetches resources. Prerender goes further by creating a hidden page that can later be swapped in.

```html
<script type="speculationrules">
{
  "prerender": [{
    "where": {
      "href_matches": "/docs/*"
    },
    "eagerness": "moderate"
  }]
}
</script>
```

Use conservative candidates. Good candidates include the next page in a checkout funnel, likely documentation links after hover or pointer down, or the first result in a command palette after strong keyboard intent. Bad candidates include logout links, destructive actions, highly personalized dashboards with expensive data, and URLs that trigger side effects on load.

## Application safety

A prerendered page is not visible, but its JavaScript may run. That means page-load side effects become dangerous. Do not mark notifications read, increment view counters, start media playback, open WebSockets unnecessarily, request geolocation, or mutate server state just because a route loaded. Move those effects behind explicit user intent or activation checks.

Use `document.prerendering` to detect hidden prerender execution where supported, and listen for `prerenderingchange` or `pageshow` activation-related signals depending on the browser API surface. The practical rule is: initialize pure data and render-safe UI early; delay irreversible effects until activation.

```js
function runWhenActivated(callback) {
  if (!document.prerendering) {
    callback();
    return;
  }
  document.addEventListener("prerenderingchange", callback, { once: true });
}
```

For analytics, distinguish prerender from activated navigation. Counting a page view during hidden prerender inflates metrics. Send page-view analytics only after activation.

## Caching and credentials

Prerendering generally uses the user's normal credentials, cookies, and cache partition context. This makes it powerful for logged-in pages, but it also means backend load can increase. Coordinate with server caching headers. Pages that are private but cacheable in the browser may benefit; pages that perform expensive personalized queries may need stricter candidate selection.

Do not assume every browser supports the same behavior. Speculation Rules support is uneven. Build it as progressive enhancement: normal navigation must be correct and fast enough; prerendering is an acceleration path.

Design the server as if speculative requests are real requests that may never become visits. That means GET endpoints must be safe, but it also means expensive reads should be cache-aware. If a product page prerender performs ten personalized API calls and only one in five prerenders activates, you have multiplied backend load for a small median win. Prefer prerendering pages whose critical path is mostly cacheable HTML, static assets, or low-cost user state. For personalized data, split the shell from volatile fragments so activation can be instant while the page still revalidates the pieces that genuinely need freshness.

Credentials create another subtle issue: a prerendered page can observe the current session state, then activate after that state changes in another tab. Treat activation like a resume point. Recheck auth-sensitive assumptions, refresh stale CSRF tokens if your stack rotates them, and avoid embedding one-time tokens in prerendered documents unless they remain valid across activation. If you use service workers, verify that navigation preload, cache strategies, and request logging do not accidentally treat speculative and normal navigations differently in a way that breaks activation.

## Choosing candidates

The best candidates come from strong product intent rather than vague popularity. A "next" button in a wizard, a checkout confirmation step after payment details validate, or a documentation link after hover plus dwell time are better than prerendering every visible link. Start with one route class and measure it. Add gates such as same-origin only, non-destructive route only, authenticated state allowed, payload size below a threshold, and no known activation blockers.

Eagerness should reflect confidence. Immediate prerendering on page load is expensive and should be rare. Moderate or conservative rules give the browser more room to wait for hover, pointer down, viewport proximity, or idle capacity. Also consider device and network conditions. Speculation that is helpful on desktop broadband can be harmful on low-memory mobile devices. Browser heuristics already apply constraints, but your rules should still avoid candidates that are predictably wasteful.

Roll out with an experiment that includes backend metrics. Track prerender attempts, activations, cancellations, bytes loaded, CPU time where available, server request amplification, and user-facing navigation latency. A successful feature has both high activation value and acceptable waste. If the activation rate is low, downgrade to prefetch or remove the rule.

## Failure modes

The most severe failure is side effects on load. A prerendered "mark invoice paid" route is a design bug even without prerendering; speculative execution makes it visible. GET routes must be safe.

Another failure is memory pressure. Prerendered pages can be cancelled by the browser if they use too much memory or forbidden APIs. If activation is unreliable, inspect browser diagnostics rather than assuming your rules are ignored.

Third-party scripts can block prerendering or behave badly in hidden contexts. Audit analytics, ads, chat widgets, and tag managers. Lazy-load or defer them until activation when they are not needed for first interaction.

Stale data is also possible. A prerendered page may sit briefly before activation. For volatile screens, revalidate on activation while keeping the prerendered shell visible.

## Diagnostics

Chrome DevTools exposes prerender attempts, activation status, and cancellation reasons. Add server headers or logs to identify speculative requests if needed, but avoid changing responses in ways that make prerendered and normal pages diverge. Measure hit rate, wasted bytes, activation latency, memory impact, and backend request amplification. A low hit-rate prerender can make aggregate performance worse even if successful activations look impressive.

Checklist:

- Prerender only high-confidence, safe navigations.
- Keep GET routes side-effect-free.
- Delay analytics and irreversible effects until activation.
- Treat support as progressive enhancement.
- Audit third-party scripts.
- Measure hit rate and wasted work, not only best-case speed.
