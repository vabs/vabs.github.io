---
title: "Accessibility tree"
date: 2026-01-24T11:20:00-05:00
draft: false
tags: [frontend, accessibility, dom, aria, browser-internals]
---

The accessibility tree is the browser's semantic projection of the page. It is derived from the DOM, CSS, native element semantics, ARIA, and computed state, then exposed through platform accessibility APIs. Screen readers, switch devices, voice control, automated accessibility tooling, and browser devtools all depend on this projection.

The important mental model is that users of assistive technology do not consume your DOM directly. They consume roles, names, descriptions, states, relationships, and actions. A visually polished custom control can be invisible or misleading if its accessibility tree node is wrong.

{{< mermaid >}}
flowchart TD
  A[HTML DOM] --> B[CSS visibility and layout]
  A --> C[Native semantics]
  A --> D[ARIA overrides]
  B --> E[Accessibility tree]
  C --> E
  D --> E
  E --> F[Platform accessibility API]
  F --> G[Assistive technology]
{{< /mermaid >}}

## What gets exposed

Each accessible node has a role such as `button`, `link`, `heading`, `textbox`, `list`, or `dialog`. It has an accessible name, often computed from text content, `aria-label`, `aria-labelledby`, `alt`, or form labels. It can have a description from `aria-describedby`, state such as expanded/checked/disabled, and relationships such as controls, owns, active descendant, or labelled-by.

Native HTML gives you most of this for free. A `<button>` exposes a button role, handles keyboard activation, participates in forms where appropriate, and maps disabled state correctly. A `<div role="button">` needs role, name, keyboard handlers for Enter and Space, focusability, disabled behavior, and visual state synchronization. ARIA can patch semantics, but it does not add browser behavior.

## Name computation

Accessible name computation is deterministic but easy to misuse. For many controls, `aria-labelledby` wins over `aria-label`, which wins over descendant text. `aria-describedby` is not the name; it is supporting description. This distinction affects screen reader output and voice control commands.

```html
<button aria-label="Close">
  <svg aria-hidden="true">...</svg>
</button>

<input id="email" aria-describedby="email-help">
<label for="email">Email</label>
<p id="email-help">Use your work address.</p>
```

The input's name is "Email"; the description is "Use your work address." That is a better contract than naming the field "Use your work address", which would be confusing in forms mode and voice navigation.

## CSS and tree inclusion

CSS affects the accessibility tree. `display: none` and `visibility: hidden` remove content from it. The `hidden` attribute does too. Offscreen visually hidden content can remain accessible when implemented with clipping and dimensions. `opacity: 0` can leave content accessible and focusable, which may create invisible traps if used carelessly.

`display: contents` has historically had browser bugs where element semantics disappeared while children remained. It is safer on layout wrappers than semantic elements. Before applying it to lists, tables, buttons, or labelled containers, inspect the accessibility tree in target browsers.

## Practical patterns

Start with semantic HTML. Use headings in order, real buttons for actions, links for navigation, labels for inputs, fieldsets for grouped choices, and lists for actual lists. Add ARIA only when the native model cannot express the interaction.

For complex widgets, implement the full pattern, not just the role. A combobox needs relationships between the input and popup, active option management, keyboard behavior, focus strategy, expanded state, and stable names. A tablist needs tabs, tabpanels, selected state, and arrow key behavior. Incomplete ARIA is often worse than no ARIA because it promises interactions that do not exist.

Use `aria-hidden="true"` on decorative icons inside named controls, but never put it on a focusable element or an ancestor of focused content. If a modal opens, mark background content inert with `inert` when available rather than hand-applying `aria-hidden` across large subtrees. `inert` removes focusability and accessibility exposure together, which matches modal behavior.

## Failure modes

Common failure: a control has no accessible name. Icon-only buttons need labels. SVG text may not become a reliable button name. Another failure: duplicate names in repeated controls, such as ten "Edit" buttons in a table. Include context with `aria-label="Edit billing address"` or reference row text with `aria-labelledby`.

Virtualized lists are tricky. If only visible rows exist in the DOM, assistive technology sees only those rows unless you expose set size and position metadata. For very large grids, consider whether native table semantics, pagination, or an accessible non-virtualized mode gives users a better experience than a custom virtual scroller.

Portals can also break relationships. `aria-labelledby` and `aria-describedby` work across DOM positions by ID, but focus order and reading order still matter. A popover rendered at the end of `body` must still have coherent focus management and dismissal behavior.

## Debugging

Use Chrome, Firefox, or Safari accessibility inspectors to check role, name, description, and states. Keyboard-test every interactive control before using a screen reader. Then test with assistive technology because the tree can look right while interaction still feels wrong. Automated tools catch missing names and invalid ARIA, but they cannot verify whether your widget model matches user expectations.

## Dynamic updates

The accessibility tree is not static. Expanding panels, validation errors, loading states, route transitions, and virtualized content all change what assistive technology can perceive. Update semantics at the same time as visual state. If a disclosure opens, update `aria-expanded`. If a form field becomes invalid, expose `aria-invalid` and connect the error text with `aria-describedby`. If content is loading, use an appropriate live region only when the update genuinely needs announcement.

Live regions are easy to overuse. A chat message, background sync result, or failed save may need announcement. A counter changing on every keystroke usually does not. Noisy live regions make the page harder to use because they interrupt the user's current task. Prefer polite announcements for non-urgent updates and reserve assertive announcements for rare situations where immediate interruption is necessary.

For route changes in single-page apps, manage focus deliberately. The browser's native page-load focus reset does not happen automatically. Move focus to a meaningful heading or main landmark, update the document title, and ensure the old interactive region is no longer reachable if it was removed visually.

## Review workflow

Accessibility review works best in layers. First inspect static semantics: landmarks, headings, labels, names, and roles. Then keyboard-test the tab order and activation behavior. Then inspect dynamic state transitions. Finally test with the assistive technologies your users are likely to rely on. Each layer catches a different class of bug.

When reviewing pull requests, ask for the user-facing contract, not just the ARIA attributes. "This is a menu button with arrow-key navigation and escape dismissal" is reviewable. "This div has role menu" is not enough.

Checklist:

- Prefer native HTML semantics.
- Verify role, name, description, state, and relationships.
- Do not hide focusable content from the accessibility tree.
- Use ARIA to express semantics, not to create missing behavior.
- Inspect the accessibility tree during development.
- Test complex widgets with keyboard and real assistive technology.
