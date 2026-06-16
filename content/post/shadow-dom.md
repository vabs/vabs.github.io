---
title: "Shadow DOM"
date: 2026-03-23T09:00:00-04:00
draft: false
tags: [frontend, shadow-dom, web-components, css, encapsulation]
---

Shadow DOM is an encapsulation boundary for DOM and CSS. It lets a component own internal markup without leaking every class name into the page, and without page styles accidentally rewriting its internals. The tradeoff is that styling, events, accessibility, and testing must be designed around the boundary instead of pretending it is normal nested HTML.

{{< mermaid >}}
flowchart TD
  Host[custom-element host]
  Host --> Light[Light DOM children]
  Host --> ShadowRoot[Shadow root]
  ShadowRoot --> Internal[Internal DOM]
  ShadowRoot --> Slot[slot]
  Light -->|assigned nodes| Slot
  PageCSS[Page CSS] -. limited .-> Host
  ComponentCSS[Shadow CSS] --> Internal
{{< /mermaid >}}

## Mental model

A shadow root is attached to a host element with `attachShadow({ mode: "open" })` or `closed`. The component renders internal DOM inside that root. Selectors in the page do not cross into the shadow tree, and selectors inside the shadow tree do not target the rest of the page. This gives component authors a local styling environment.

Slots are the controlled hole in that boundary. Light-DOM children remain owned by the host page, but they are rendered at slot positions. The component can style slot containers and use `::slotted()` for limited styling of assigned nodes, but it does not fully own the slotted subtree.

## Styling internals responsibly

Use CSS custom properties for theme tokens:

```css
:host {
  --card-border: color-mix(in srgb, currentColor 20%, transparent);
  display: block;
}

.panel {
  border: 1px solid var(--card-border);
}
```

Use `::part()` when consumers need to target specific internal elements. Expose parts like `button`, `label`, or `panel`, not implementation names like `div3`. Parts are a public API. Rename them with the same care you would use for JavaScript methods.

Use `:host()` for host states and `:host-context()` cautiously. Context selectors can couple a component back to page structure and weaken encapsulation.

Design the styling contract before the internal CSS grows. A component typically needs three layers:

- Host layout: `:host` controls display, box sizing, and high-level state attributes.
- Theme inputs: CSS custom properties accept colors, spacing, typography, and motion tokens.
- Targeted escape hatches: `part` exposes a small set of stable internal elements.

Avoid exposing every internal node as a part. If consumers need to style twenty internals, the component may be trying to own too much. Split the component or make more content slotted. Conversely, if consumers must use brittle global CSS or JavaScript to reach internals, the public API is too narrow.

Custom properties cross the shadow boundary through inheritance, which makes them ideal for design tokens. Normal selectors do not cross. This distinction is useful: product teams can theme `--button-accent` without depending on whether the internal button is a `<button>`, `<a>`, or wrapper plus icon.

Slots need styling rules of their own. `::slotted(*)` only targets the assigned node itself, not arbitrary descendants. If callers pass complex markup, the component should either document the expected shape or provide named slots with layout wrappers. A slot named `actions` is easier to support than a default slot that accepts anything and then tries to guess spacing.

## Events and retargeting

Events crossing a shadow boundary are retargeted. External listeners often see the host as `event.target`, not the deep internal button. This is usually good because internals stay private. If the outside world needs details, dispatch a `CustomEvent` with a clear `detail` payload.

Events also need `composed: true` to cross the shadow boundary. Without it, a custom event can appear to vanish. For interactive components, test listeners both inside and outside the shadow root.

Use `event.composedPath()` when debugging event flow. It reveals the path through shadow roots and slots while still respecting closed-root privacy. Production code should rarely depend on deep composed paths because that couples the host to internals, but it is the fastest way to understand why a listener fires on the host rather than the internal control.

When designing public events, dispatch them from the host or make the payload independent of internals:

```js
this.dispatchEvent(new CustomEvent("value-change", {
  detail: { value: this.value },
  bubbles: true,
  composed: true,
}));
```

Do not leak internal DOM nodes in `detail`. They may be retargeted, removed in a future version, or inaccessible to test tools. Send values, ids, or domain objects instead.

## Accessibility

Shadow DOM does not remove accessibility obligations. Labels, roles, focus order, keyboard behavior, and ARIA relationships must still work. Be careful with IDs: an `aria-labelledby` reference may not behave like a normal document-wide relationship across boundaries. Prefer internal labels for internal controls and expose host-level semantics when the custom element itself represents a control.

Focus delegation can help but is not a complete solution. If using `delegatesFocus`, test keyboard navigation in multiple browsers and screen readers. Complex widgets should follow established ARIA patterns.

For form-like controls, decide whether the host is the accessible control or whether the shadow tree contains a native control. If the host is the control, it needs role, name, value, disabled state, keyboard handling, and form integration if applicable. If an internal native input is the control, the component must make labeling and focus behavior predictable from outside.

Form-associated custom elements can use `ElementInternals` to participate in form submission and validation. That is powerful, but it adds a contract: the element must update its internals when disabled, reset, validated, or associated with a form. If that is too much, a documented hidden-input wrapper may be more reliable for application code.

Screen reader testing should include slotted labels, error text, disabled states, and dynamic updates. A component that looks encapsulated visually may still need host-level ARIA reflection so the accessibility tree presents a coherent control.

## Failure modes

The most common failure is over-encapsulation: consumers cannot style required states, automate tests, or integrate with forms. The second is under-designed slots, where arbitrary light DOM breaks layout. The third is event confusion from retargeting and missing `composed`.

Closed shadow roots rarely help application code. They make debugging and testing harder while providing limited real protection. Use open roots unless you have a strong platform reason.

## Diagnostics

Inspect the composed tree in DevTools and verify slot assignment. Check computed styles inside the shadow root and on the host. Write tests that use the public API: attributes, properties, events, slots, CSS variables, and parts. If a test must query internal class names, decide whether the test is too coupled or the component lacks a public hook.

Create a fixture page that intentionally stresses integration: long slotted text, missing optional slots, nested interactive content, high-contrast mode, keyboard-only navigation, and theme overrides. Shadow DOM bugs often show up where layout, focus, and encapsulated CSS meet. Keep this fixture independent of the main app so component regressions are easy to reproduce.

For testing libraries, prefer helpers that understand shadow roots when you are testing the component itself. For application tests, interact through the host API. That split keeps component internals testable without teaching every app-level test about the shadow tree.

## Checklist

- Treat shadow DOM as an API boundary, not a hiding trick.
- Expose styling through CSS variables and `part` names.
- Use slots for host-provided content with documented expectations.
- Dispatch composed custom events when parents must listen.
- Verify focus and accessibility relationships.
- Prefer open roots for debuggability.
