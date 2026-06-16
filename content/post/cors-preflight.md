---
title: "CORS preflight"
date: 2026-02-23T12:25:00-05:00
draft: false
tags: [frontend, cors, browser, http, security]
---

## Mental model

CORS preflight is the browser asking a server for permission before sending a cross-origin request that could have side effects or expose non-simple behavior. The browser sends an `OPTIONS` request with the intended method and headers. If the server responds with matching `Access-Control-Allow-*` headers, the real request proceeds.

Preflight is not authentication and not a firewall. It is a browser-enforced read/write permission protocol. Non-browser clients can ignore it, and same-origin requests do not need it.

{{< mermaid >}}
sequenceDiagram
    participant App as Frontend origin
    participant B as Browser
    participant API as API origin
    App->>B: fetch PUT with Authorization
    B->>API: OPTIONS preflight
    API-->>B: allow origin, method, headers
    B->>API: actual PUT
    API-->>B: response exposed to app
{{< /mermaid >}}

## Internals that matter

A request avoids preflight only if it is a "simple" request: method `GET`, `HEAD`, or `POST`; only simple headers; and a simple `Content-Type` such as `application/x-www-form-urlencoded`, `multipart/form-data`, or `text/plain`. Add `Authorization`, `X-Request-Id`, `application/json`, `PUT`, `PATCH`, or `DELETE`, and the browser usually preflights.

The preflight request includes:

```http
Origin: https://app.example
Access-Control-Request-Method: PUT
Access-Control-Request-Headers: authorization, content-type
```

The response must match:

```http
Access-Control-Allow-Origin: https://app.example
Access-Control-Allow-Methods: PUT
Access-Control-Allow-Headers: authorization, content-type
Access-Control-Max-Age: 600
```

For credentialed requests, `Access-Control-Allow-Origin` cannot be `*`; it must echo or specify the requesting origin, and `Access-Control-Allow-Credentials: true` is required.

Preflight results are cached by the browser using the requesting origin, target URL, method, and requested header set. `Access-Control-Max-Age` controls that cache, subject to browser caps. The actual response is cached separately under normal HTTP rules. Do not confuse a cached preflight permission with a cached API response; one permits the request, the other stores data.

Header matching is stricter than many server implementations expect. If the browser asks for `authorization, content-type`, the response must allow those names, case-insensitively. Some frameworks accidentally omit `Content-Type` or fail when header order changes. Normalize names before comparing.

Proxies can affect preflight before your app sees it. Load balancers may not route `OPTIONS`, API gateways may require an explicit method configuration, and CDN caches may need `Vary: Origin, Access-Control-Request-Method, Access-Control-Request-Headers` for preflight responses that differ by request.

## Practical patterns

Handle `OPTIONS` before auth middleware rejects the request. Preflight usually does not include application credentials in the same way the actual request does, and it should not require a bearer token. It should validate origin, method, and headers against policy.

Keep allowed headers small. Every custom header increases preflight frequency and configuration surface. If a header is only for debugging, remove it from production cross-origin calls.

Use `Access-Control-Max-Age` to cache successful preflights, but do not set it blindly high during active API changes. Browsers cap it, and stale preflight policy can confuse rollouts.

Design APIs so common browser calls do not need unnecessary custom headers. `Authorization` is often unavoidable, but headers such as `X-Requested-With`, `X-Debug`, or `X-Client-Version` may be optional or better represented elsewhere. Removing one non-simple header can remove a preflight from a hot path.

If you control both frontend and API, keep same-origin deployment on the table. Serving the API under the app origin through a reverse proxy avoids CORS entirely for browser calls. That is often simpler for first-party apps, though it does not remove authentication, authorization, or CSRF requirements.

For public APIs, treat CORS as a product contract. Document allowed origins if they are fixed, supported methods, required headers, whether credentials are allowed, and which response headers are exposed through `Access-Control-Expose-Headers`. A successful request can still hide response headers from JavaScript unless they are simple or explicitly exposed.

## Failure modes

The common failure is debugging the actual request when the actual request was never sent. In DevTools, the blocked request may show as CORS failed, but the server log for `PUT /resource` is empty because `OPTIONS /resource` failed first.

Another failure is reflecting any `Origin` and allowing credentials. That turns CORS into "any website can read this user's authenticated API response." If credentials are enabled, origin matching must be explicit.

CORS also does not prevent CSRF. A cross-site form post can still cause side effects without reading a response. Protect unsafe methods with CSRF defenses even when CORS is strict.

Wildcard plus credentials is the dangerous configuration people remember, but broad origin reflection is just as risky. If the server copies any `Origin` into `Access-Control-Allow-Origin` and also allows credentials, every website becomes an allowed reader for logged-in users. Origin reflection must be backed by an allowlist.

Another failure is returning CORS headers only on success responses. Browsers enforce CORS on error responses too. If a `401`, `403`, or `500` lacks CORS headers, frontend code sees a generic CORS failure instead of the real status, which slows debugging and can break auth refresh flows.

Redirects can complicate preflight. A preflight or actual request that redirects to a different host must still satisfy CORS at the final response, and some legacy browser behaviors around preflight redirects are surprising. Prefer direct API URLs for cross-origin calls.

## Diagnostics

In the Network panel, inspect the `OPTIONS` request and response. Verify status code, `Access-Control-Allow-Origin`, allowed method, allowed headers, and whether credentials are involved. Server logs should record rejected preflights with origin and requested headers.

Use curl to simulate the browser:

```sh
curl -i -X OPTIONS https://api.example/resource \
  -H 'Origin: https://app.example' \
  -H 'Access-Control-Request-Method: PUT' \
  -H 'Access-Control-Request-Headers: authorization, content-type'
```

Automated integration tests should cover allowed origin, rejected origin, missing header, credentialed request, and `OPTIONS` routing through proxies.

When the browser says "CORS error," first answer whether the actual request was sent. If not, inspect the `OPTIONS` response. If yes, inspect the actual response's CORS headers and exposed headers. This prevents chasing authentication or application handlers that never ran.

Add server logs specifically for rejected preflights: origin, requested method, requested headers, route, and rejection reason. Without those fields, all failures look like "CORS blocked" from the frontend side. Be careful not to log sensitive header values; header names are usually enough.

## Implementation guidance

Put CORS handling near the edge of the app, before route auth, but after enough routing context to apply the right policy. A single global `*` policy is easy but usually wrong. A small set of named policies, such as `publicReadCors`, `firstPartyCredentialedCors`, and `adminCors`, keeps intent clear.

Return `204 No Content` or another simple success for valid preflight, with no application body. Include `Vary: Origin` when the allowed origin is echoed, and include the request-method and request-headers vary fields when those inputs affect the response. This keeps shared caches from reusing one origin's permission for another.

Keep CORS tests at the HTTP boundary, not only in unit tests. Exercise the deployed gateway or local proxy path because that is where `OPTIONS` routing, redirects, and stripped headers usually break.

## Checklist

- `OPTIONS` reaches CORS middleware before auth rejection.
- Allowed origins are explicit for credentialed requests.
- Allowed methods and headers match real frontend calls.
- `Vary: Origin` is set when responses depend on origin.
- Preflight cache duration is intentional.
- CSRF is handled separately from CORS.
- Error responses include the same CORS policy as success responses.
- `Vary` covers origin, requested method, and requested headers when needed.
- Rejected preflights are logged with safe diagnostic fields.
