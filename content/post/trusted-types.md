---
title: "Trusted Types"
date: 2026-01-26T14:20:00-05:00
draft: false
tags: [frontend, security, xss, trusted-types, browser]
---

## Mental model

Trusted Types is a browser enforcement layer that moves DOM XSS prevention from "remember to sanitize every string" to "dangerous DOM sinks reject plain strings." It does not sanitize by itself. It forces code to pass values created by approved policies, such as `TrustedHTML`, `TrustedScript`, or `TrustedScriptURL`.

The goal is to reduce the number of places where XSS can enter. Instead of auditing every `innerHTML` assignment, you audit the small set of policies that are allowed to create trusted values.

{{< mermaid >}}
graph TD
    A["Untrusted string"] --> B["Policy"]
    B --> C["Sanitize / validate"]
    C --> D["TrustedHTML"]
    D --> E["DOM sink: innerHTML"]
    A --> F["Direct sink assignment"]
    F --> G["Blocked by require-trusted-types-for 'script'"]
{{< /mermaid >}}

## Internals that matter

Trusted Types protects injection sinks such as `innerHTML`, `outerHTML`, `insertAdjacentHTML`, script URLs, and script text. Enforcement is activated through Content Security Policy:

```http
Content-Security-Policy: require-trusted-types-for 'script'; trusted-types app-html;
```

In supporting browsers, assigning a normal string to a protected sink throws a `TypeError`. That failure is useful: it shows exactly where legacy code is still using raw strings. Chromium has enforced it since version 83, but Safari (26) and Firefox (148) shipped support only recently, so older browsers still in use have no enforcement; Trusted Types should be paired with normal sanitization and CSP rather than treated as the only defense.

Policies are JavaScript factories:

```js
const policy = trustedTypes.createPolicy("app-html", {
  createHTML(input) {
    return DOMPurify.sanitize(input, { RETURN_TRUSTED_TYPE: false });
  }
});

element.innerHTML = policy.createHTML(markdownHtml);
```

The policy name is part of your security boundary. CSP can restrict which policies may be created.

The protected sinks are the places where strings become executable or parseable markup. That includes obvious APIs such as `innerHTML`, but also less obvious paths such as assigning script text, creating script URLs, or passing strings to APIs that evaluate code. Trusted Types changes the failure mode from "the browser parses whatever string arrived" to "the assignment throws unless the value came from an approved factory."

Policy creation is therefore the critical audit point. A policy that simply returns input is equivalent to turning the alarm off. A policy should either sanitize HTML, validate a URL against a strict allowlist, or reject input. Keep policy functions small enough to review and test with malicious fixtures.

Trusted Types enforcement is new outside Chromium, so some of your users may still run browsers without it. That does not make it useless: it catches bugs for a large user population and, more importantly, forces the codebase into safer patterns. Non-supporting browsers still rely on the sanitizer, framework escaping, CSP, and server-side encoding.

## Practical rollout

Start in report-only mode:

```http
Content-Security-Policy-Report-Only: require-trusted-types-for 'script'; report-uri /csp-report
```

Collect violations, group them by sink, and remove unnecessary HTML injection first. Many `innerHTML` writes can become `textContent`, DOM construction, or framework rendering. For the remaining legitimate HTML paths, create narrow policies. Avoid a broad `default` policy that blindly returns input; it silences the signal and recreates the original problem.

For React, most rendering is already escaped. The main sink is `dangerouslySetInnerHTML`; wrap the value creation, not every component. For legacy widgets, isolate adapters so the rest of the app never touches raw trusted values.

A practical migration starts by replacing accidental HTML writes. Many uses of `innerHTML` are not actually HTML requirements; they are text updates, clearing containers, or simple element construction. Use `textContent`, `replaceChildren`, `createElement`, or framework rendering. Every removed sink is one less policy decision.

For the remaining intentional HTML, define sources. Markdown rendering, CMS snippets, rich-text editor output, and trusted internal templates may need separate policies because they have different validation rules. Markdown HTML should go through a sanitizer profile. Internal template output might be generated from known-safe components. Script URLs should almost never be accepted from user content.

For third-party libraries, prefer configuration that accepts DOM nodes or safe rendering callbacks. If a library insists on raw HTML, wrap it in a small adapter and keep the trusted value local to that adapter. Do not pass `TrustedHTML` broadly through application state; it should be a boundary object, not a common data type.

## Failure modes

The biggest failure is policy sprawl. If every team creates a policy, the audit surface becomes as large as the old sink surface. Keep policies few, named by purpose, and covered by tests. Another failure is sanitizing after trust creation. The policy should validate before returning the trusted type.

Trusted Types also does not fix unsafe URL navigation, CSS injection, server-rendered XSS, or DOM clobbering by itself. It is targeted at DOM XSS sinks. Keep URL allowlists, output encoding, and server-side escaping.

A broad default policy is the migration escape hatch that often becomes permanent. It may be useful temporarily in report-only mode to collect stack traces, but enforcing with a permissive default policy makes dangerous assignments succeed. If you use one during migration, give it noisy logging, restrict it to development or a short rollout, and delete it once named policies cover legitimate sinks.

Sanitizer configuration drift is another failure mode. DOMPurify profiles, allowed URL schemes, SVG support, and custom hooks can change security properties. Pin sanitizer versions, review config changes, and test representative payloads. Allowing SVG or MathML, for example, increases the payload surface and may not be necessary.

Server/client mismatches can surprise SSR apps. A server-rendered HTML bug can execute before client-side Trusted Types enforcement initializes. Keep server escaping and CSP strict; do not assume client-side enforcement protects the initial document parse.

## Diagnostics

Violation reports include the blocked sink and stack in supporting browsers. In development, set a breakpoint on `TypeError` and inspect the call site. Search for:

```text
innerHTML
outerHTML
insertAdjacentHTML
dangerouslySetInnerHTML
new Function
setTimeout("string")
```

Tests should assert that raw strings fail when enforcement is active and that approved rendering paths produce expected sanitized output. Include malicious samples such as event handlers, `javascript:` URLs, SVG payloads, and malformed HTML.

In production reports, group by sink and call stack. One library helper may be responsible for hundreds of violations. Fixing the helper is better than patching each call site. Track violation count by release so you can see whether a migration is moving toward zero.

During local debugging, enable enforcement early and click through high-risk flows: CMS preview, comments, search highlighting, rich-text editing, notifications, and error rendering. These are common places where escaped text turns into "just set HTML" code over time.

## Implementation guidance

Create a small `security/trustedTypes` module that owns policy creation. Application code should import functions such as `sanitizeMarkdownHtml` or `createTrustedTemplateHtml`, not call `trustedTypes.createPolicy` directly. This keeps the policy list aligned with the CSP `trusted-types` directive.

Make unsafe APIs visible in code review. Add lint rules or static checks for `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `dangerouslySetInnerHTML`, string timers, and `new Function`. The goal is not to ban every use blindly; it is to make each use explain why it is safe and which policy owns it.

For rollout, use report-only CSP, remove accidental sinks, introduce narrow policies, enforce in a small browser cohort if your deployment system supports it, then enforce broadly. Keep the report endpoint after enforcement because new dependencies can reintroduce violations.

## Checklist

- Trusted Types is first deployed in report-only mode.
- Unnecessary HTML sinks are replaced with `textContent` or DOM APIs.
- Remaining policies are narrow, named, and reviewed.
- CSP restricts allowed policy names.
- Sanitization happens inside policy creation.
- Tests cover both blocked raw strings and allowed sanitized HTML.
- Policy creation is centralized and matched by CSP.
- Temporary default policies are logged and removed.
- Server-side escaping remains in place for initial HTML.
