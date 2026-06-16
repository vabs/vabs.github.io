---
title: "Custom Elements lifecycle"
date: 2026-03-12T09:00:00-04:00
draft: false
tags: [frontend, custom-elements, web-components, lifecycle, browser-apis]
---

Custom elements are classes that the browser upgrades into real DOM behavior. Their lifecycle is not a framework lifecycle with a virtual tree in front of it. It is the platform telling your element when it is constructed, connected, disconnected, adopted into another document, or affected by observed attribute changes. That makes the lifecycle precise, but also unforgiving: your element can be created by the parser, by `document.createElement`, by cloning, or by a framework that moves DOM around during reconciliation.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Constructed: constructor
  Constructed --> Constructed: attributeChangedCallback (during upgrade)
  Constructed --> Connected: connectedCallback
  Connected --> Connected: attributeChangedCallback
  Connected --> Disconnected: disconnectedCallback
  Disconnected --> Connected: reattach
  Connected --> Adopted: adoptedCallback
  Adopted --> Connected
{{< /mermaid >}}

## Constructor rules

The constructor is for internal setup, not DOM reads that assume children exist. The element may be created before attributes or light-DOM children are available. Initialize private fields, attach shadow DOM, create static internal nodes, and bind methods. Avoid fetching data, measuring layout, or dispatching events from the constructor.

```js
class AsyncChart extends HTMLElement {
  static observedAttributes = ["src", "variant"];

  constructor() {
    super();
    this.attachShadow({ mode: "open" });
    this.abortController = null;
  }
}
```

The browser requires `super()` before using `this`. Returning another object or mutating attributes in the constructor can cause hard-to-debug upgrade issues.

The constructor also runs during upgrade. If the document contains `<async-chart src="/data.json">` before the definition loads, the browser later upgrades that existing element into your class. At that point attributes may already exist, children may already be parsed, and `attributeChangedCallback` may run around the same time. Code that assumes a neat "constructor, then set attributes, then connect" path will fail in parser-created cases.

Keep constructor state boring:

- Private fields and flags.
- Shadow root creation.
- Static template nodes.
- Bound callbacks used later.

Do not read `offsetWidth`, query slotted children, start network work, or register global listeners. Those operations belong to connection or a scheduled render.

## Connection and disconnection

`connectedCallback` runs whenever the element is inserted into a document-connected tree. It can run more than once for the same instance. That means setup must be idempotent. Add event listeners, start observers, and kick off rendering here, but guard against duplicate subscriptions.

`disconnectedCallback` is for cleanup. Remove listeners, disconnect observers, abort fetches, stop timers, and release external resources. In single-page apps, DOM nodes may be moved or temporarily detached; cleanup should be correct even if the element later reconnects.

The safest pattern is paired ownership:

- If `connectedCallback` adds a listener, `disconnectedCallback` removes it.
- If it starts a fetch, cleanup aborts it.
- If it creates an observer, cleanup disconnects it.
- If it registers with a store, cleanup unsubscribes.

A common pattern is an explicit connection token:

```js
connectedCallback() {
  if (this.connected) return;
  this.connected = true;
  this.abortController = new AbortController();
  window.addEventListener("resize", this.onResize, {
    signal: this.abortController.signal,
  });
  this.requestRender();
}

disconnectedCallback() {
  this.connected = false;
  this.abortController?.abort();
  this.abortController = null;
}
```

Using `AbortController` for event listeners, fetches, and async workflows keeps cleanup centralized. Still make reconnect safe: a disconnected element may be reinserted seconds later with the same instance and the same internal fields.

## Attribute changes

`attributeChangedCallback(name, oldValue, newValue)` runs for names listed in `observedAttributes`. It can fire before connection during upgrade. It also receives string values, or `null` when an attribute is removed. Parse carefully and route changes through a single render/update method.

Properties need their own setters. If `element.value = data` should update the UI, implement a setter that stores the value and requests render. Do not assume property changes automatically invoke attribute callbacks.

Attributes are serialization. They are good for strings, booleans, ids, URLs, and small configuration. Properties are for rich values: arrays, objects, callbacks, controllers, and data models. Reflect from property to attribute only when the value has a clear string representation and external CSS, forms, or markup need to observe it.

Boolean attributes are especially easy to mishandle. `<x-panel disabled="false">` is disabled because the attribute is present. Use `hasAttribute("disabled")`, not string comparison to `"true"`, unless you intentionally designed a string-valued attribute.

## Practical rendering pattern

Use a small scheduler to batch updates:

```js
requestRender() {
  if (this.renderPending) return;
  this.renderPending = true;
  queueMicrotask(() => {
    this.renderPending = false;
    if (this.isConnected) this.render();
  });
}
```

This prevents repeated attribute and property updates from causing multiple synchronous renders. For layout-dependent work, use `requestAnimationFrame` or `ResizeObserver` instead of measuring during every setter.

Separate state normalization from DOM writes. Attribute and property setters should parse input, store normalized state, and call `requestRender`. The render method should read the current normalized state once and update the shadow DOM. This makes ordering less fragile when several attributes change during upgrade.

For slotted content, remember that children are external. Use `slotchange` when your element depends on assigned nodes. Do not assume the initial children are final when `connectedCallback` runs; frameworks and templating systems can append children later.

If your element participates in forms, use form-associated custom elements deliberately. `ElementInternals` can connect validation, labels, and form value submission, but it also adds lifecycle responsibilities. Update internals whenever the element's value or disabled state changes, and test reset behavior.

## Failure modes

Duplicate listeners are common because `connectedCallback` runs repeatedly. Memory leaks appear when observers survive after removal. Race conditions appear when async work resolves after disconnection and writes into stale DOM. Solve these with idempotent setup, abort controllers, and connection checks before applying results.

Another failure is assuming upgrade order. If HTML is parsed before `customElements.define`, elements exist as unknown elements until definition loads. Attribute values and children may already be present when callbacks run. Test both parser-created and `document.createElement()` paths.

There are also cross-document failures. `adoptedCallback` fires when an element moves to another document, for example into an iframe or a new `Document`. Any cached `ownerDocument`, global constructors, stylesheets, or document-level listeners may now point at the wrong place. Most elements never need adoption logic, but libraries and editors that move nodes between documents should handle it.

Framework interoperability creates another class of bugs. Some frameworks set properties, some set attributes, and some set attributes first and properties later. If your element exposes `value`, `checked`, `items`, or `config`, make the property path first-class and document whether an attribute mirror exists.

Shadow DOM styling can fail silently. Custom properties cross shadow boundaries; most selectors do not. If the element depends on host page styling, expose parts, custom properties, or attributes intentionally rather than expecting global CSS to reach internal nodes.

## Diagnostics

Add lifecycle logging with instance IDs during development. It quickly reveals repeated connects, missing disconnects, and attributes firing before expected. Use DevTools memory snapshots for components that register global listeners or observers.

Unit tests should create, attach, detach, reattach, and mutate attributes. A custom element that only works on first connection is not lifecycle-safe.

Add tests for upgrade timing:

```js
document.body.innerHTML = `<async-chart src="/a.json"></async-chart>`;
customElements.define("async-chart", AsyncChart);
await customElements.whenDefined("async-chart");
```

Then test the opposite path:

```js
const el = document.createElement("async-chart");
el.src = "/a.json";
document.body.append(el);
```

If those behave differently, the lifecycle code is relying on accidental ordering.

For memory leaks, create and remove the element many times in a test page while watching listener counts, observer counts, and heap snapshots. If old instances remain reachable through a global listener or store subscription, `disconnectedCallback` is incomplete.

## Checklist

- Keep constructors minimal and side-effect-light.
- Make `connectedCallback` idempotent.
- Pair every external subscription with cleanup.
- Treat attributes as strings and properties as rich state.
- Batch renders instead of rendering in every setter.
- Test upgrade, reattach, and async cancellation paths.
- Handle boolean attributes by presence.
- Use `slotchange` for light-DOM dependencies.
- Document property and attribute contracts for framework users.
- Consider adoption only when nodes may cross documents.
