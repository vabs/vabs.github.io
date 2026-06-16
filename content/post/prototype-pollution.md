---
title: "Prototype pollution"
date: 2026-01-12T10:45:00-05:00
draft: false
tags: [frontend, security, javascript, prototype-chain, input-validation]
---

## Mental model

Prototype pollution is a JavaScript object graph bug where attacker-controlled input writes properties onto `Object.prototype` or another shared prototype. Once polluted, ordinary objects appear to have attacker-chosen defaults. The dangerous part is not the write itself; it is later code that trusts property lookup.

The classic payload is a nested key like `__proto__.isAdmin=true`, `constructor.prototype.debug=true`, or JSON shaped to trick a merge function. If a parser or deep merge helper treats those keys as normal object paths, it mutates the prototype chain instead of only the target object.

{{< mermaid >}}
graph TD
    A["Untrusted JSON / query string"] --> B["Deep merge or path setter"]
    B --> C["__proto__ / constructor.prototype key"]
    C --> D["Object.prototype polluted"]
    D --> E["Fresh objects inherit attacker property"]
    E --> F["Auth, config, rendering, or sanitizer bypass"]
{{< /mermaid >}}

## Internals that matter

JavaScript property reads walk the prototype chain. If `user.isAdmin` is missing on `user`, the engine checks `Object.getPrototypeOf(user)`, then the next prototype, until it reaches `null`. That is useful for methods like `toString`, but disastrous when business logic confuses "own property" with "any inherited property."

Modern engines and libraries have patched many obvious paths, but the vulnerability still appears in custom merge utilities, URL parameter expanders, form-to-object mappers, and state hydration code. Frontend code is not immune: a polluted config object can turn on debug sinks, change template behavior, poison feature flags, or weaken client-side validation. Even if the server is authoritative, the browser can still be pushed into XSS-adjacent behavior.

## Practical patterns

Reject dangerous keys at every recursive write boundary.

```js
const BLOCKED = new Set(["__proto__", "prototype", "constructor"]);

function safeSet(target, path, value) {
  let node = target;
  for (const segment of path.slice(0, -1)) {
    if (BLOCKED.has(segment)) throw new Error("unsafe key");
    node = node[segment] ??= Object.create(null);
  }
  const last = path[path.length - 1];
  if (BLOCKED.has(last)) throw new Error("unsafe key");
  node[last] = value;
}
```

Use null-prototype dictionaries for untrusted maps:

```js
const params = Object.create(null);
```

When checking authorization, feature flags, or sanitizer options, require own properties:

```js
if (Object.hasOwn(user, "isAdmin") && user.isAdmin === true) {
  showAdminTools();
}
```

Prefer schema validation over generic merging. A schema turns "arbitrary nested object" into "these exact keys and value types." This is more maintainable than trying to make every downstream consumer defensive.

For config objects, prefer allow-list construction over mutation. Instead of merging an arbitrary payload into defaults, create a fresh object from known fields:

```js
function buildWidgetConfig(input) {
  return {
    theme: input.theme === "dark" ? "dark" : "light",
    pageSize: Number.isInteger(input.pageSize) ? input.pageSize : 25,
    analytics: input.analytics === true,
  };
}
```

This looks less clever than a generic merge, but it removes the attack surface entirely. The code says which keys are meaningful and which conversions are allowed. It also prevents a later feature from accidentally inheriting a value that was never explicitly accepted.

When a generic dictionary is truly needed, `Map` is often a better fit than an object. `Map` does not consult `Object.prototype` during key lookup, can safely store keys named `constructor`, and makes the "this is a bag of arbitrary keys" intent visible. For JSON serialization you may still need plain objects at the boundary, but the internal representation can be safer.

```js
const flags = new Map();
for (const [key, value] of Object.entries(input.flags ?? {})) {
  if (!/^[a-z0-9_.-]+$/i.test(key)) continue;
  flags.set(key, Boolean(value));
}
```

Be careful with defaults. A common vulnerable shape is `const opts = merge(defaults, userOptions)`, followed by downstream code that reads `opts.escapeHtml`, `opts.template`, or `opts.isAdmin`. If `merge` mutates `defaults`, every later request or component instance can inherit polluted state. If it mutates a normal `{}`, a malicious key can still reach the prototype. Safer patterns create a null-prototype destination and copy only schema-approved fields.

## Implementation review hotspots

Pollution often hides in convenience layers rather than obvious security code. Query parsers that turn `?a[b][c]=1` into nested objects, form serializers that parse field names like `profile[address][zip]`, and state hydration code that merges server payloads into client stores are all worth reviewing. Any function named `setPath`, `deepAssign`, `mergeDeep`, `defaults`, `hydrate`, `inflate`, or `expand` deserves a look.

Also check libraries that accept option objects and then merge them internally. A frontend sanitizer, template renderer, markdown processor, validation library, or charting component may treat options as trusted. If polluted input can set a sanitizer option such as `ALLOW_DATA_ATTR` or change a template lookup fallback, the bug can turn from integrity loss into script execution.

In TypeScript, remember that types do not protect runtime keys. `Record<string, unknown>` can still contain `__proto__`. A typed API that accepts `unknown` from JSON must validate before object walking. Add runtime checks at the trust boundary, not only at the call site where the value has already been asserted into a friendly type.

## Failure modes

The most common failure is using object spread or merge as a security boundary without understanding the source shape. Spreading a polluted object does not copy inherited properties, which is good, but the damage may already have happened if the merge step wrote to a prototype. Another failure is only blocking `__proto__`; `constructor.prototype` can reach the same class of issue in vulnerable setters.

Do not assume `JSON.parse` alone is the bug. JSON can represent `"__proto__"` as an ordinary own key. The bug appears when later code interprets that key as a path or merges it into a normal object.

## Diagnostics

During security tests, send payloads like:

```json
{"__proto__":{"polluted":"yes"}}
```

Then check:

```js
({}).polluted
```

If the result is `"yes"`, the environment is polluted. In app tests, assert that parsing or merging malicious keys either rejects the payload or stores them as inert data in a null-prototype object.

Static review should search for `merge`, `defaultsDeep`, `set`, querystring parsers with bracket syntax, and recursive object walkers. Dependency review matters because prototype pollution often enters through small utility packages.

For a focused regression test, test both the target object and a fresh object:

```js
expect(result).not.toHaveProperty("polluted");
expect({}.polluted).toBeUndefined();
```

The first assertion catches normal assignment. The second catches prototype mutation. Run the test in isolation if the environment is already polluted, because one failing test can contaminate later tests in the same process. When diagnosing a test suite, clean up with `delete Object.prototype.polluted` only as a temporary containment step; the real fix is to prevent the write.

## Checklist

- Untrusted keys are schema-validated before recursive writes.
- `__proto__`, `prototype`, and `constructor` are blocked in path setters.
- Security-sensitive checks use `Object.hasOwn`.
- Dictionaries created from user input use `Object.create(null)` or `Map`.
- Dependency advisories for merge/parser libraries are monitored.
- Tests include malicious nested keys, not only normal JSON payloads.
