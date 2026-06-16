---
title: "Content Security Policy (CSP)"
date: 2026-02-02T09:00:00-05:00
draft: false
tags: [frontend, security, csp, xss, browser]
---

## Mental model

Content Security Policy is a browser-enforced allowlist for what a page may load, execute, embed, connect to, and submit to. Its highest-value use is XSS damage reduction: even if an attacker injects markup, CSP can block inline script, remote script, plugin loads, and data exfiltration paths.

CSP is not a sanitizer. It is a runtime constraint. Good CSP assumes bugs will happen and makes successful exploitation harder.

{{< mermaid >}}
graph TD
    A["HTML response"] --> B["CSP header"]
    B --> C["Browser policy engine"]
    C --> D["script-src"]
    C --> E["connect-src"]
    C --> F["img/style/frame directives"]
    D --> G["Allow nonce/hash scripts"]
    D --> H["Block inline or unknown script"]
{{< /mermaid >}}

## Internals that matter

A policy is delivered by HTTP header or a meta tag. Prefer headers because they apply earlier and support reporting. Directives fall back to `default-src` when absent, but not all directives behave identically. A practical baseline separates script, style, images, fonts, frames, workers, and network connections.

For modern apps, nonce-based script policies are usually cleaner than host allowlists:

```http
Content-Security-Policy:
  default-src 'self';
  script-src 'nonce-r4nd0m' 'strict-dynamic';
  object-src 'none';
  base-uri 'none';
  frame-ancestors 'none';
  connect-src 'self' https://api.example.com;
  img-src 'self' data:;
  style-src 'self' 'unsafe-inline';
  report-to csp-endpoint
```

The nonce must be unpredictable and unique per response. Every trusted script tag gets that nonce. With `strict-dynamic`, trust flows from nonce-bearing scripts to scripts they load, reducing brittle host allowlists.

Policy evaluation is per directive and per resource type. `script-src` does not control image loads; `connect-src` controls `fetch`, XHR, WebSocket, EventSource, and similar network connections; `frame-ancestors` controls who may embed the page and is ignored in meta-delivered policies. This is why a single broad `default-src 'self'` is a starting point, not a full policy.

Nonce policies work because injected markup usually cannot know the per-response nonce. The nonce must not be reused across responses, logged into places attackers can read, or exposed through predictable templates. A build-time nonce is not a nonce; it is a static password in markup.

Hashes are useful for small inline scripts that truly cannot move to external files, but they create maintenance overhead. Any byte change requires a new hash. For applications that render many pages, request nonces are usually easier to operate than long lists of hashes.

## Practical patterns

Start with `Content-Security-Policy-Report-Only` and collect violations. Remove inline event handlers, `javascript:` URLs, string-based timers, and unneeded third-party scripts. Then enforce the policy once reports are understood.

For server-rendered pages, generate a nonce in request middleware and inject it into both the CSP header and script tags. For SPAs, avoid runtime template strings that require `unsafe-eval`. Some bundler dev modes use eval-based source maps; keep development CSP separate from production CSP rather than weakening production.

Use `frame-ancestors` to prevent clickjacking, `base-uri 'none'` to stop injected `<base>` tags from changing URL resolution, and `form-action` to restrict form submission endpoints.

Treat CSP rollout as a migration. Inventory current script sources, inline handlers, eval usage, third-party tags, worker URLs, image origins, font origins, and API endpoints. Then remove what is dead before encoding what remains. A policy that perfectly preserves a messy page is less valuable than a policy that forces a smaller execution surface.

For third-party scripts, prefer a loader that you own and nonce. Keep the number of vendors small, isolate optional tags behind consent or delayed loading, and avoid adding entire vendor domains to `script-src` without understanding what else they can serve. Host allowlists are only as strong as every executable endpoint on the allowed host.

For SPAs, remember that CSP is attached to the document response. Client-side route changes do not fetch a new policy. If an admin route needs extra API origins or frame permissions, decide whether the whole app can safely have them or whether that route should be served as a separate document with a narrower policy boundary.

## Failure modes

Host allowlists are often overtrusted. If `script-src` allows a JSONP endpoint, user-upload CDN, or compromised third party, an attacker can still execute script. `unsafe-inline` largely disables the most important script protection unless paired with hashes in specific legacy cases.

Another failure is ignoring reports. CSP reports can be noisy because extensions inject scripts. Group by user agent, blocked URI, directive, and source file before changing policy. Do not add broad domains just to silence noise.

`unsafe-eval` often sneaks in through development tooling, source maps, template engines, or older libraries. If production requires `unsafe-eval`, understand exactly which dependency needs it and whether a production build option can remove it. Leaving it enabled makes many script injection bugs easier to exploit.

CDN transformations can break CSP. HTML minifiers, tag managers, A/B testing tools, and edge personalization may inject scripts without nonces. Either make those systems nonce-aware or keep them out of pages with strict policies. "Works locally, fails at edge" is a common CSP rollout symptom.

Reporting endpoints can become noisy or sensitive. Violation bodies may contain URLs and snippets. Sample reports, rate-limit clients, and avoid storing more payload than you need for debugging.

## Diagnostics

Browser DevTools logs CSP violations with directive names. Production reports should be sampled and stored with release version, route, and user agent. Debugging flow:

1. Identify the violated directive.
2. Determine whether the blocked load is expected app behavior.
3. If expected, prefer moving it behind a nonce or narrower origin.
4. If unexpected, treat it as a bug or possible injection.

Automated tests can fetch key pages and assert required directives exist. End-to-end tests can run with CSP enforced to catch accidental inline script regressions.

When a violation appears, first classify it as expected application behavior, browser extension noise, attack traffic, or a broken integration. Extension noise often has unusual source locations and blocked URIs. Broken integrations usually cluster by release and route. Attack traffic may show unexpected inline script, `data:` URLs, or unfamiliar exfiltration endpoints.

Use a local reproduction header while debugging. A reverse proxy, dev server middleware, or browser extension can inject a candidate CSP into an existing page. This lets you iterate before changing production headers, but final verification must happen through the real server and CDN because nonces, compression, and edge rewrites affect behavior.

## Implementation guidance

Generate policy in one server-side module rather than scattering header strings across routes. The module should accept per-request values such as nonce and environment-specific origins, then produce a deterministic header. Keep development relaxations explicit and impossible to enable in production by accident.

Add tests at two levels. Unit tests should assert that production policy does not contain `unsafe-inline` for scripts, `unsafe-eval`, wildcard script origins, or missing `base-uri`. Integration tests should request representative pages and verify the nonce in the header matches nonce-bearing script tags.

Pair CSP with output encoding and Trusted Types where possible. CSP reduces exploitability after an injection bug; it does not make unsafe rendering safe. The best result is layered: escape by default, sanitize intentional HTML, reject unsafe DOM sinks, and constrain runtime execution with CSP.

## Checklist

- Policy is shipped as an HTTP header.
- Scripts use nonces or hashes; inline handlers are removed.
- `object-src 'none'`, `base-uri 'none'`, and `frame-ancestors` are set.
- `connect-src` only includes required APIs.
- Report-only data is reviewed before enforcement.
- Dev-only CSP relaxations do not leak into production.
- Nonces are unique per response and injected consistently.
- Third-party script origins are reviewed as executable trust.
- Reporting is sampled, grouped, and tied to release versions.
