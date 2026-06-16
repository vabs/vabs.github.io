---
title: "Web Components interoperability"
date: 2026-03-02T09:00:00-04:00
draft: false
tags: [frontend, web-components, interoperability, custom-elements, design-systems]
---

Web Components are most valuable at boundaries: design systems used across frameworks, embeddable widgets, long-lived platform components, and islands inside applications that change framework stacks over time. Interoperability is the main promise, but it is not automatic. You get it by designing the component API around browser primitives that every framework can understand.

{{< mermaid >}}
flowchart TD
  Host[React/Vue/Angular/Svelte app] -->|attributes/properties| Element[Custom element]
  Element --> Shadow[Shadow DOM internals]
  Element -->|CustomEvent| Host
  Host -->|slots| Element
  Element --> CSS[CSS custom properties/parts]
{{< /mermaid >}}

## API mental model

A custom element has four public channels: attributes, properties, events, and slots. Attributes are string-based and declarative. Properties can hold richer values but require imperative assignment. Events are the portable callback mechanism. Slots let host markup provide content without the component knowing the host framework.

Design the stable API in those terms. Avoid exposing framework-specific concepts such as React nodes, Vue refs, or Angular services. A good custom element should be usable from plain HTML first, then enhanced by framework wrappers.

## Attributes versus properties

Use attributes for simple, serializable configuration: `disabled`, `variant`, `label`, `open`, `placement`. Reflect important state from property to attribute when CSS or external observers need to see it. For booleans, follow HTML semantics: presence means true, absence means false.

Use properties for objects, arrays, functions, controllers, and large data. Frameworks differ in how they bind custom-element properties. React historically treated unknown JSX fields as attributes unless configured or wrapped, while other frameworks may set DOM properties more naturally. A thin wrapper can normalize this.

```js
const picker = document.querySelector("date-range-picker");
picker.value = { start: "2026-03-01", end: "2026-03-31" };
picker.addEventListener("change", (event) => {
  console.log(event.detail.value);
});
```

Avoid attribute/property drift. If `element.value = x` updates internal state but does not reflect anything observable, framework wrappers may become inconsistent. If `setAttribute("value", "...")` updates a different path than the property setter, server-rendered and client-rendered usage will behave differently. Choose a source of truth and route both channels through it when both are supported.

For complex values, make property assignment explicit and document mutation semantics. If callers pass an array and later mutate it, should the component update? Most components should treat property values as immutable snapshots: assignment triggers an update, in-place mutation does not. That matches framework data flow and avoids deep observation.

```js
set items(value) {
  this.#items = Array.isArray(value) ? [...value] : [];
  this.#render();
}
```

This defensive copy is not always required for performance-sensitive components, but the contract must be clear. Interoperability suffers when each framework wrapper guesses whether it should clone, diff, or mutate.

## Events that interoperate

Emit `CustomEvent` with a documented `detail` object. Set `bubbles: true` when parent components should listen through normal delegation. Set `composed: true` when the event must cross a shadow boundary. Without `composed`, an event dispatched inside shadow DOM may not reach the host as expected.

Do not rely on event names that collide with native semantics unless the behavior matches. `change` is reasonable for committed value changes; `input` is reasonable for live edits. For domain-specific actions, use explicit names like `range-preview` or `option-remove`.

## Styling contracts

Shadow DOM protects internals, which is useful until product teams need styling control. Provide intentional styling hooks: CSS custom properties for tokens and `::part()` for named internal pieces. Avoid making consumers pierce implementation details. If a component needs many parts, the abstraction may be too broad.

Slots are also part of styling. Named slots such as `header`, `footer`, and `empty-state` let host apps provide content while the element owns layout. Document fallback content and slot expectations.

Make the contract design-token friendly. A design-system element should accept tokens such as `--control-bg`, `--control-border`, or `--focus-ring`, not require consumers to restyle implementation selectors. Use `part` for structural styling that tokens cannot express, such as targeting a label or menu item. Treat part names as semver-governed API.

Slots should be narrow enough that layout remains stable. A slot for `icon` can define size and alignment. A slot for arbitrary "left side content" may receive a button, a paragraph, or a nested menu. If the host app needs that much freedom, the component may be better as a lower-level primitive.

For framework wrappers, forward class names to the host element, not to internal nodes. The wrapper can also translate framework idioms into platform APIs: React `onValueChange` becomes a `value-change` event listener; a Vue `v-model` wrapper assigns the `value` property and listens for commits.

## Failure modes

The most common interoperability bug is setting object data as an attribute and receiving `"[object Object]"`. The second is events not escaping shadow DOM because `composed` is false. The third is hydration mismatch when server-rendered custom elements upgrade later and the framework assumes it owns all descendants.

Form participation is another trap. Native inputs integrate with forms automatically; custom elements need form-associated custom elements and `ElementInternals` to participate in validation and submission. If that support is not implemented, expose a wrapper or hidden input strategy.

Upgrade timing creates subtle bugs. Before the browser loads the custom element definition, the tag is just an `HTMLElement`. Attributes exist, but property setters do not. If application code assigns `el.value = ...` before upgrade, that assignment may create an own property that shadows the eventual class setter. Defensive custom elements can capture pre-upgrade properties in the constructor:

```js
constructor() {
  super();
  this.#upgradeProperty("value");
}

#upgradeProperty(name) {
  if (Object.hasOwn(this, name)) {
    const value = this[name];
    delete this[name];
    this[name] = value;
  }
}
```

This pattern matters in framework apps where rendering may assign properties before the component bundle finishes loading.

Server rendering has another edge: the shadow tree is usually not present in plain HTML unless using declarative shadow DOM. The initial page may show light DOM fallback, then change when the element upgrades. Test the no-JavaScript, pre-upgrade, and post-upgrade states if the component appears in critical content.

## Versioning and wrappers

A custom element used across frameworks should have a small compatibility test suite. Test plain HTML first, then wrappers. Each wrapper should prove that attributes, properties, events, slots, refs, and unmount cleanup work in that framework's lifecycle.

Keep wrapper APIs thin. A React wrapper can improve ergonomics, but it should not invent a second component model with different event names and state semantics. The more translation it does, the more likely plain HTML and React usage diverge. When the platform API changes, update wrappers as adapters, not as independent products.

## Diagnostics

Test every component in plain HTML and at least one framework wrapper. Inspect DOM properties in DevTools, not only attributes. Add event tests that listen outside the element and verify `detail`, `bubbles`, and `composed`.

For styling, create a fixture that uses only documented custom properties, parts, and slots. If the fixture needs deep selectors or internal class names, the public contract is incomplete.

Use `customElements.whenDefined("x-thing")` in tests that depend on upgraded behavior. Without it, tests can pass or fail based on bundle timing rather than component correctness. Also test property assignment before definition when the component is lazy-loaded; that catches the shadowing problem early.

## Checklist

- Make the plain HTML API coherent before adding wrappers.
- Use attributes for strings and booleans; properties for rich data.
- Emit documented `CustomEvent` objects.
- Set `bubbles` and `composed` intentionally.
- Provide styling hooks with CSS variables, parts, and slots.
- Test upgrade, form, and framework binding behavior.
