---
title: "SameSite cookie modes"
date: 2026-02-16T08:40:00-05:00
draft: false
tags: [frontend, security, cookies, samesite, browser]
---

## Mental model

`SameSite` controls when the browser sends a cookie on cross-site requests. It is not about same-origin; it is about same-site, which is based on the registrable domain plus scheme. `app.example.com` and `api.example.com` are same-site, while `example.com` and `example.net` are cross-site.

The setting answers a narrow question: "Should this cookie be attached when the request was initiated from another site?" That makes it a major CSRF mitigation and a frequent source of auth bugs in embeds, OAuth, payment redirects, and local development.

{{< mermaid >}}
graph TD
    A["Request context"] --> B{"Same-site?"}
    B -->|Yes| C["Cookie sent"]
    B -->|No| D{"Cookie mode"}
    D -->|Strict| E["Blocked"]
    D -->|Lax| F["Sent only on safe top-level navigation"]
    D -->|"None; Secure"| G["Sent cross-site"]
{{< /mermaid >}}

SameSite is best understood as a browser delivery rule, not a server authorization rule. The server still must validate sessions, origins, CSRF tokens, and permissions. SameSite only changes whether the cookie reaches the server for a given request context.

## Modes

`SameSite=Strict` sends the cookie only in same-site contexts. It is best for highly sensitive actions but can break normal flows where users arrive from email, chat, or another site and expect to be signed in immediately.

`SameSite=Lax` sends cookies on same-site requests and on top-level cross-site navigations using safe methods like `GET`. It blocks most CSRF form posts and subresource requests while preserving common login navigation. Chromium-based browsers default unspecified cookies toward Lax-like behavior (Firefox and Safari do not), but you should set it explicitly.

`SameSite=None` allows cross-site sends, but it must be paired with `Secure`. Use it only when the product requires third-party contexts: iframes, embedded widgets, some SSO flows, or APIs called from a different site with credentials.

The practical default for most session cookies is `Lax`. It preserves normal link navigation into the app while blocking cookies on cross-site subresource requests and unsafe form posts. `Strict` is a deliberate product choice because it can make users appear signed out when entering from external links. `None` is an interoperability choice because it restores cross-site delivery and therefore requires other CSRF controls.

## Internals that matter

Site calculation is schemeful in modern browsers: `http://example.com` and `https://example.com` are different sites. This can surprise local development where one service is HTTP and another is HTTPS.

Subdomains are same-site but not necessarily same-origin. That means `SameSite` does not protect against every sibling-subdomain risk. If `marketing.example.com` is compromised, requests to `app.example.com` may still be same-site. Use CSRF tokens and origin checks for state-changing requests.

Cookie `Domain` and `Path` decide where a cookie is scoped; `SameSite` decides when it is sent based on initiator context. Do not confuse these controls.

"Top-level navigation" is another key phrase. A user clicking a link from another site to your app is different from another site embedding your app in an iframe or submitting a hidden form. Lax allows some top-level safe navigations, but not iframe loads, image loads, `fetch` calls, or unsafe methods such as POST.

Redirect chains deserve attention. The browser evaluates cookie inclusion based on request context through navigation and redirects. OAuth and payment flows often depend on temporary correlation cookies set before leaving your site and read when returning. If those cookies are `Strict`, the return request from the provider may not include them.

Cookie prefixes help with scoping. `__Host-` cookies must be Secure, have `Path=/`, and omit `Domain`, which pins them to the exact host. That can reduce sibling-subdomain risk for primary sessions:

```http
Set-Cookie: __Host-session=...; Path=/; Secure; HttpOnly; SameSite=Lax
```

This does not replace SameSite; it complements it by tightening where the cookie is valid.

## Practical patterns

For normal session cookies:

```http
Set-Cookie: session=...; Path=/; Secure; HttpOnly; SameSite=Lax
```

For admin or step-up cookies:

```http
Set-Cookie: admin_session=...; Path=/admin; Secure; HttpOnly; SameSite=Strict
```

For embedded widgets:

```http
Set-Cookie: widget_session=...; Path=/; Secure; HttpOnly; SameSite=None
```

When using `SameSite=None`, assume CSRF risk is back and require explicit anti-CSRF tokens or signed request state.

For OAuth correlation state, choose based on the actual flow. A temporary cookie used only on the top-level return from an identity provider often works with `Lax`. An identity provider embedded in an iframe or a cross-site POST callback may require `None; Secure`. Document the reason next to the cookie-setting code because future maintainers will otherwise "tighten" it and break login.

For split frontend/API deployments, distinguish site and origin. `https://app.example.com` calling `https://api.example.com` is cross-origin but same-site. SameSite may allow the cookie, but CORS still needs `Access-Control-Allow-Credentials`, a non-wildcard allowed origin, and `credentials: "include"` on fetch. Debugging auth without separating these layers wastes time.

For local development, use hostnames that resemble production when possible, such as `app.localhost` and `api.localhost`, or document the differences. Secure cookies require HTTPS except for special localhost handling in some browsers. Do not infer production cookie behavior from a single localhost happy path.

For state-changing endpoints, keep defense in depth:

- Require CSRF tokens or double-submit tokens for browser form/API mutations.
- Check `Origin` or `Referer` for unsafe methods where feasible.
- Use idempotency keys for retryable mutations.
- Keep session cookies `HttpOnly` so XSS cannot directly read them.

## Failure modes

OAuth and payment redirects often fail when correlation cookies are `Strict`; the browser returns from another site and the cookie is absent. Embedded apps fail when cookies are `Lax`; iframe requests are not top-level navigations. Localhost tests can pass while production fails because scheme, domain, and secure attributes differ.

Another failure is setting multiple cookies with the same name and different paths or domains. DevTools may show a cookie exists, but the request may send a different one or none at all.

Credentialed CORS is often misdiagnosed as SameSite. If the cookie is not sent from `fetch`, check all of these: cookie SameSite mode, `Secure`, request `credentials`, API CORS headers, preflight handling, domain/path scope, and whether the request is same-site. Any one missing piece can look like "the browser dropped my session."

Safari and other browsers with tracking prevention can apply additional restrictions, especially in third-party contexts. `SameSite=None; Secure` is necessary for third-party cookies, but it may not be sufficient for all users or all embed scenarios. Products that depend on embedded authentication should plan token-based or storage-access fallbacks where supported.

Clock and expiry bugs can mimic delivery bugs. A cookie with the right SameSite mode but an expired `Expires` value or a too-short `Max-Age` will disappear before the callback. Log expiry decisions and inspect the cookie store, not just request headers.

## Diagnostics

Use the browser Network panel and inspect the request cookies and the "blocked cookies" explanation. Chrome DevTools shows SameSite exclusion reasons. Reproduce flows from a genuinely different site, not only another route on localhost.

Log authentication failures with whether a session cookie was absent, invalid, or expired. That separates SameSite delivery issues from backend session problems.

Create a small diagnostic matrix for each auth flow:

```text
Flow                 Context             Expected mode
Login return          top-level GET        Lax or None
Payment callback      top-level GET/POST   depends on provider
Embedded widget       iframe/fetch         None; Secure
Admin navigation      same-site only       Strict or Lax
```

Then test each row in a real browser. For cross-site testing, use two different registrable domains or a staging setup that mirrors production. Different ports on localhost are different origins, but they are not necessarily different sites.

When a cookie is missing, inspect in this order: was it set, was it stored, did scope match the request URL, did SameSite block it, did Secure block it, did CORS omit credentials, did the server reject it? This keeps debugging grounded in the browser's actual pipeline.

## Checklist

- Session cookies explicitly set `SameSite`, `Secure`, and `HttpOnly`.
- Normal app sessions default to `Lax`.
- `Strict` is reserved for flows that tolerate cross-site entry sign-out behavior.
- `None; Secure` is used only for required cross-site contexts.
- CSRF tokens still protect unsafe methods.
- Redirect, iframe, SSO, and payment flows are tested in real browser contexts.
- CORS credential settings are verified separately from SameSite.
- Cookie `Domain`, `Path`, expiry, and duplicate names are audited.
- Cross-site tests use production-like scheme and hostnames.
