---
title: "DOM clobbering"
date: 2026-01-19T11:15:00-05:00
draft: false
tags: [frontend, security, dom, xss, browser-apis]
---

## Mental model

DOM clobbering is a browser legacy behavior where elements with certain `id` or `name` attributes become properties on global objects like `window`, `document`, or forms. If application code expects `window.config` to be a trusted object, injected markup like `<form id="config">` may replace that lookup with an element.

This is not the same as executing script. It is a confused-reference bug: attacker-controlled markup changes what a variable resolves to. The impact depends on how that reference is used. If clobbered data becomes a URL, sanitizer option, feature flag, or script source, it can become a real security vulnerability.

{{< mermaid >}}
graph LR
    A["Injected safe-looking HTML"] --> B["id/name creates global property"]
    B --> C["App reads window.someName"]
    C --> D["Expected trusted object"]
    C --> E["Actually attacker-controlled element"]
    E --> F["URL/config/sanitizer confusion"]
{{< /mermaid >}}

## Internals that matter

Browsers preserve named property access for compatibility with older pages. Elements can be exposed through `window.foo`, `document.foo`, `document.forms.foo`, and form control collections. Resolution rules are messy and differ by object type, which is why relying on named globals is fragile even without an attacker.

The vulnerability appears when markup injection is allowed but script injection is not. Many sanitizers allow harmless tags and attributes. An attacker may not be able to run `<script>`, but they may be able to create `<a id="redirectTo" href="https://evil.example">`. If code later does `location.href = redirectTo.href`, the sanitized markup influenced navigation.

## Practical patterns

Do not read application state from implicit globals. Always import modules, close over constants, or read from explicit script tags selected by known ids and validated types.

```js
// Fragile
const apiBase = window.appConfig.apiBase;

// Better
import { apiBase } from "./config.js";
```

If bootstrapped config must live in HTML, read it from a script tag with `type="application/json"` and parse text, not named properties:

```html
<script id="app-config" type="application/json">
{"apiBase":"/api"}
</script>
```

```js
const el = document.getElementById("app-config");
if (!(el instanceof HTMLScriptElement)) throw new Error("bad config node");
const config = JSON.parse(el.textContent);
```

Sanitizers should restrict `id` and `name` attributes in user-controlled HTML, especially names matching application globals, form fields, or DOM API properties. For rich text, a prefixing strategy works well: rewrite user ids to `user-content-...` and never let them collide with app-owned ids.

Treat DOM references as untrusted until verified. `document.getElementById("app-config")` is better than `window.appConfig`, but it still returns whatever element has that id. Check the element type, expected attributes, and location before using it. For boot data, ensure the node is a script tag, has the exact `application/json` type, and is under the expected root.

```js
function readJsonScript(id) {
  const node = document.getElementById(id);
  if (!(node instanceof HTMLScriptElement)) {
    throw new Error(`Expected JSON script #${id}`);
  }
  if (node.type !== "application/json") {
    throw new Error(`Unexpected script type for #${id}`);
  }
  return JSON.parse(node.textContent ?? "{}");
}
```

Keep app-owned ids in a namespace that user content cannot enter. For example, reserve `app-` or `__app_` for framework and boot nodes, then configure rich-text rendering to strip or rewrite those prefixes. This is less brittle than trying to list every current global. The policy should live near the sanitizer configuration, not as an informal convention in component code.

When integrating third-party widgets, avoid assuming their injected markup is passive. A comments widget, CMS block, or markdown preview can introduce ids and names into the same document. Render untrusted rich content inside a container with strict sanitizer rules, or inside an iframe when isolation is more important than native styling.

## Security-sensitive sinks

DOM clobbering becomes severe when a clobbered reference flows into a sink. Navigation is one example: `location.href = redirectTo.href` can become an open redirect if `redirectTo` resolves to an attacker-controlled anchor. Script loading is worse: `script.src = cdnBase + "/app.js"` becomes dangerous if `cdnBase` is clobbered. Sanitizer configuration is another subtle sink; if code reads `window.sanitizeOptions` and an element can occupy that name, fallback behavior may change.

Boolean checks are also risky. Code such as `if (window.isAdmin) { ... }` may pass because an element object is truthy. That does not grant server-side authorization by itself, but it can expose UI controls, enable debug flows, or select weaker client-side validation. The fix is explicit typed configuration, not truthiness.

Forms deserve extra attention because named controls are intentionally exposed through form collections. Prefer `form.elements.namedItem("email")` and verify the returned element type. Do not call methods through possibly shadowed names. For example, if a control is named `submit`, `form.submit` may not be the method you expect. Use `HTMLFormElement.prototype.submit.call(form)` only when you truly need the low-level submit behavior, and prefer `requestSubmit()` for normal user-like submission.

## Failure modes

The common failure is "we sanitize HTML, so this is safe." Sanitization often focuses on script execution, event handlers, and dangerous URLs. DOM clobbering abuses allowed HTML. Another failure is using `var` globals or undeclared assignments, which makes name resolution through `window` more likely.

Form handling has its own traps. A form control named `submit` can shadow `form.submit`, breaking code or forcing alternate paths. A control named `action` can confuse code that reads `form.action` expecting the attribute. Use `form.requestSubmit()` and `new FormData(form)` rather than trusting named properties.

## Diagnostics

Search for property reads on `window`, `document`, and forms where the property name is not a standard API:

```text
window.config
document.redirect
form.action.value
```

In tests, inject sanitized HTML with colliding ids:

```html
<a id="appConfig" href="https://attacker.example"></a>
<form name="csrfToken"><input name="value" value="bad"></form>
```

Then assert that boot, navigation, and form submission still use explicit trusted sources. Browser DevTools can help: evaluate `window.appConfig` before and after inserting the markup.

Automated tests should run clobbering payloads through the same sanitizer used in production. It is not enough to mount raw malicious HTML if production would rewrite it; the interesting question is whether the allowed output can still collide with app names. Snapshot the sanitized output and then run the app behavior against it.

During incident response, capture the live DOM around the user-content container and list named properties:

```js
Array.from(document.querySelectorAll("[id],[name]"))
  .map((el) => [el.tagName, el.id, el.getAttribute("name")]);
```

This quickly shows whether the page contains surprising names such as `config`, `redirect`, `submit`, `constructor`, or app-specific globals.

## Checklist

- App config is imported or parsed from explicit JSON script tags.
- User HTML cannot create ids/names that collide with app-owned names.
- Code avoids implicit global variables and named DOM lookups.
- Form code uses `FormData`, `elements.namedItem`, and method calls carefully.
- Sanitizer tests include clobbering payloads, not only XSS payloads.
- Security review treats allowed HTML as active input to browser name resolution.
