---
title: "CSRF vs XSS mitigation"
date: 2026-02-09T13:10:00-05:00
draft: false
tags: [frontend, security, csrf, xss, cookies]
---

## Mental model

CSRF and XSS are both browser security problems, but they abuse different trust relationships. Cross-Site Request Forgery makes the browser send an authenticated request the user did not intend. Cross-Site Scripting runs attacker-controlled script inside the trusted origin.

CSRF asks, "Can another site cause this user's browser to perform an action?" XSS asks, "Can attacker code run as this site?" XSS is usually more powerful because it can read page state, call same-origin APIs, and often bypass CSRF tokens by reading them.

{{< mermaid >}}
graph TD
    A["Attacker site"] --> B["CSRF: browser sends cookies to victim origin"]
    B --> C["State-changing request"]
    D["Injected script on victim origin"] --> E["XSS: attacker runs as trusted page"]
    E --> F["Read DOM, tokens, call APIs, alter UI"]
{{< /mermaid >}}

## Internals that matter

Browsers attach cookies based on cookie attributes and request context, not on user intent. Historically, a hidden form post from `evil.example` to `bank.example` could include the user's `bank.example` cookies. CSRF defenses add intent signals that the attacker cannot provide.

XSS is different. Once script runs in `bank.example`, same-origin rules treat it as the application. It can submit fetches with credentials, read non-HttpOnly tokens, and modify forms. This is why "we have CSRF tokens" is not an XSS mitigation.

## CSRF mitigation patterns

Use `SameSite=Lax` or `SameSite=Strict` cookies where possible. `Lax` blocks most cross-site subresource and form-post cookie sends while still allowing top-level navigation use cases. For cross-site embeds or federated flows that require cookies, use `SameSite=None; Secure` deliberately.

Add server-side CSRF tokens for unsafe methods. The token should be bound to the user's session or derived with a server secret, sent in a form field or custom header, and verified on every state-changing request. Custom headers are useful because simple cross-origin forms cannot set them.

Check `Origin` and sometimes `Referer` for state-changing requests. These headers are not the only defense, but they are strong signals for browser-initiated writes.

Treat method semantics as part of the defense. `GET` should not change server state, even if it is "only" a preference toggle or tracking action. Link prefetchers, crawlers, previews, and image tags can trigger GETs without user intent. Put writes behind `POST`, `PUT`, `PATCH`, or `DELETE`, then enforce CSRF checks on those methods.

For JSON APIs, do not rely on `Content-Type: application/json` alone. It raises the bar because plain HTML forms cannot send that exact content type, but misconfigured CORS, text/plain JSON parsing, method override headers, and legacy endpoints can reopen the path. A CSRF token or origin check remains clearer.

Double-submit cookies can work when implemented carefully: set a CSRF cookie and require the same value in a request header or body field. The server accepts only if both match and the cookie is protected against attacker-controlled subdomains. If sibling subdomains are untrusted, bind the token to the session server-side instead of trusting a domain-wide cookie.

## XSS mitigation patterns

Escape output by context: HTML text, attributes, URLs, CSS, and JavaScript strings all need different handling. Prefer framework rendering over manual string concatenation. Use DOMPurify or an equivalent sanitizer for user-authored HTML, and pair high-risk apps with CSP and Trusted Types.

Store session cookies as `HttpOnly` so injected script cannot read the cookie value. This does not stop the script from making authenticated requests, but it reduces token theft and replay outside the browser.

Use CSP as damage reduction, not as your only XSS control. A useful policy removes inline script, restricts script sources, disables dangerous object/embed surfaces, and reports violations. Nonce-based CSP works well for server-rendered pages when every legitimate script tag receives a fresh nonce. Hash-based CSP works for fixed inline snippets. Policies with broad `unsafe-inline` or wildcard script sources are mostly documentation, not protection.

Trusted Types help in large apps because they turn dangerous DOM sinks into typed boundaries. Instead of letting any string reach `innerHTML`, `insertAdjacentHTML`, or script URL sinks, the browser requires a `TrustedHTML` or related object created by an approved policy. This does not sanitize by magic; it centralizes the places where sanitization or template generation is allowed.

Frameworks reduce XSS risk by escaping text by default, but they do not remove it. Escape hatches such as React's `dangerouslySetInnerHTML`, Vue's `v-html`, Svelte's `{@html}`, direct DOM calls, markdown renderers, and third-party widgets are the real inventory. Treat every escape hatch as a mini security review.

## How they interact

CSRF defenses assume the attacker cannot read secrets from the victim origin. XSS breaks that assumption. If a CSRF token is rendered into the DOM, injected script can read it and submit a valid request. If the token is available through an API endpoint, injected script can fetch it. If the session cookie is `HttpOnly`, injected script still cannot read the cookie value, but it can send credentialed same-origin requests through the browser.

That does not make CSRF defenses useless. They still protect users from other sites and reduce exploitability when no script execution exists. It means XSS must be treated as the higher-privilege failure. A realistic security design layers the controls: XSS prevention and containment first, CSRF validation for intent, authorization on the server for every action, and audit logs for sensitive changes.

For high-risk actions such as password changes, payout changes, or admin grants, add step-up controls that are meaningful against both classes. Re-authentication, WebAuthn confirmation, or transaction signing can force fresh user presence. A simple "are you sure?" modal rendered in the compromised page is not a strong XSS boundary, but a server-enforced re-authentication challenge raises the cost.

## Failure modes

CSRF tokens stored in readable JavaScript globals are not useful against XSS. SameSite does not protect same-site subdomain attacks if an attacker controls a sibling subdomain. CORS is also not a CSRF defense by itself: a form post does not need CORS, and many unsafe effects happen without reading the response.

For XSS, the classic failure is sanitizing once and then concatenating later. Another is allowing Markdown or rich text through a sanitizer but then adding unsafe link handling, custom embeds, or post-processing that reintroduces HTML.

## Diagnostics

For CSRF, build a local attacker page with a form that posts to your app and verify the request fails without a valid token and origin. For XSS, test every rendering path with payloads appropriate to the context. Use CSP reports to find unexpected script execution attempts.

Log rejected CSRF attempts with route, method, origin, and token reason. For XSS, track sanitizer drops and Trusted Types violations; a sudden increase often means a new content path is bypassing the intended renderer.

During review, create two separate test matrices. The CSRF matrix should vary method, content type, SameSite mode, token presence, origin header, and subdomain origin. The XSS matrix should vary output context: HTML text, attribute, URL, markdown, rich text, template string, and DOM sink. Mixing the two into one vague "security test" usually misses the boundary where one mitigation stops helping.

## Checklist

- Unsafe methods require CSRF validation server-side.
- Cookies use `SameSite`, `Secure`, and `HttpOnly` where appropriate.
- Origin checks protect state-changing endpoints.
- XSS defenses rely on contextual escaping, sanitization, CSP, and Trusted Types.
- CSRF tokens are not treated as XSS protection.
- Tests include attacker-site form posts and injected-script rendering paths.
