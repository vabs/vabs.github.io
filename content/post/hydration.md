---
title: "Hydration"
date: 2026-04-16T10:50:00-04:00
draft: false
tags: [frontend, hydration, ssr, rendering, performance]
---

## Mental model: make server HTML interactive without replacing it

Hydration is the client-side process that takes server-rendered HTML and attaches the JavaScript component model to it. The browser already has DOM nodes on screen. The framework recreates enough of the component tree to connect state, event handlers, refs, and effects to those existing nodes.

The key constraint is that the client render must agree with the server output. If the first client render produces different markup, the framework may warn, patch, discard nodes, or remount a subtree. Hydration is fastest and safest when the server and client produce the same initial tree.

{{< mermaid >}}
sequenceDiagram
    participant S as Server
    participant B as Browser DOM
    participant C as Client runtime
    S->>B: HTML response
    B->>B: parse and paint
    C->>B: load JS bundle
    C->>C: render initial component tree
    C->>B: match nodes and attach handlers
    C->>C: run effects after hydration
{{< /mermaid >}}

## Internals

During hydration, the runtime walks the existing DOM and the client component output together. Matching nodes are reused. Event delegation is attached, refs are assigned, and effects are scheduled. The framework tries to avoid recreating DOM because the point of SSR is to show useful content before JavaScript completes.

Hydration is not the same as painting. Users may see content before it is interactive. This gap is especially visible on slower devices: links with native behavior may work, but custom buttons, menus, carousels, and client-side validation may not respond until hydration reaches them.

Many frameworks use event delegation, so not every button receives a separate listener. Still, the component tree must run on the client for hydrated regions. That means JavaScript download, parse, execution, initial render, matching, and effect work all contribute to interactivity delay.

Selective hydration can prioritize parts of the page. If the user interacts with a boundary, the runtime may hydrate that region first. Streaming SSR and Suspense can also let the browser hydrate completed regions as their code and HTML become available.

## Practical patterns

Make initial render deterministic. Avoid reading `Date.now()`, `Math.random()`, viewport size, local storage, or user agent during the first render unless the server used the exact same value. If client-only data is needed, render a stable placeholder first and update after hydration.

Preserve native behavior. A server-rendered link should be a real anchor. A basic form should have an action when possible. Native fallbacks reduce the damage of a long hydration gap.

Minimize the client tree. Do not hydrate static prose, decorative layout, or server-only data formatting. Use server components, islands, partial hydration, or framework conventions to keep client JavaScript focused on interaction.

Move expensive effects out of the critical path. Hydration is followed by effects, and a heavy effect can block the page just as it becomes interactive. Lazy-load analytics, defer non-critical observers, and avoid layout thrashing in layout effects.

Make the hydration boundary visible in code review. Components that read browser-only state should be marked clearly by file placement, directives, or naming conventions. Reviewers should be able to tell whether a change expands the hydrated tree or only changes server-rendered output.

Treat serialized props as an API. They should be stable, minimal, and safe to expose to the browser. If the client needs only a display name and an ID, do not serialize the whole user object. Smaller payloads reduce parse cost and lower the chance of leaking server-only fields.

## Failure modes

Hydration mismatch is the headline failure. Common causes include time zones, locale formatting, random IDs, conditional rendering based on `window`, A/B flags that differ by environment, invalid HTML corrected differently by the browser, and data that changes between server render and client boot.

The second failure is the illusion of readiness. The page looks complete, but controls do not work yet. This is worse than a visible loading state because users may click and lose trust. Critical controls should hydrate early, use native behavior, or clearly indicate pending readiness.

Third-party scripts can mutate DOM before hydration. Cookie banners, personalization scripts, ad tags, and browser extensions may insert or rewrite nodes. If they touch framework-owned markup, hydration can fail or remount.

Over-hydration is a performance failure. Shipping a full SPA runtime for a mostly static article creates main-thread work with no user value. The page may have good first paint but poor time to interactive.

Hydration can also fail because of invalid HTML. Browsers repair malformed tables, nested anchors, or invalid paragraph structure before the framework hydrates. The client tree then tries to match a DOM shape the server did not literally send. Validate HTML when mismatches point at ordinary-looking markup.

## Debugging and diagnostics

Treat hydration warnings as production bugs. Capture the server HTML, the first client render inputs, and any environment-dependent branches. Reproduce with JavaScript disabled first to inspect the true server output.

Throttle CPU and network, then interact immediately after first paint. This exposes the hydration gap. Record whether clicks are ignored, queued, handled natively, or handled by a selectively hydrated boundary.

Use performance traces to locate script evaluation, hydration tasks, and post-hydration effects. A long task after bundle load often points to initial client render or effect work rather than network.

## Checklist

- Keep server and first client render deterministic.
- Avoid browser-only reads during initial render.
- Use native links and forms where possible.
- Hydrate only regions that need interactivity.
- Prioritize critical controls.
- Defer non-critical effects and third-party scripts.
- Investigate every hydration mismatch warning.
