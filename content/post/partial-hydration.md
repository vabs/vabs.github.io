---
title: "Partial hydration"
date: 2026-04-02T14:10:00-04:00
draft: false
tags: [frontend, partial-hydration, hydration, performance, ssr]
---

## Mental model: hydrate less of what you already rendered

Partial hydration is the practice of server-rendering a page while hydrating only the parts that need client-side behavior. The HTML can contain a full page, but the browser does not have to download, parse, execute, and attach listeners for every component that produced it.

This differs from classic full-app hydration, where the client framework rebuilds a matching component tree for the whole page. Partial hydration asks a sharper question: which rendered regions actually need to become live?

{{< mermaid >}}
flowchart LR
    SSR[Server renders full HTML] --> Browser[Browser displays page]
    Browser --> Static[Static regions remain inert]
    Browser --> Live[Interactive regions load JS]
    Live --> Hydrate[Attach state and event handlers]
    Static --> NoJS[No client component cost]
{{< /mermaid >}}

## Internals

The server emits HTML plus markers or manifests that identify hydratable regions. The client runtime uses those markers to locate a region, load the right component code, deserialize props, and attach event handling. Static regions are never reconstructed as client components.

Frameworks implement this differently. Some use islands as separate hydration roots. Some compile components so static and dynamic parts are split automatically. Some use resumability, where the server serializes enough execution state for the client to resume specific handlers without replaying the full render.

The hard part is dependency boundaries. If a hydratable child depends on context from a non-hydrated parent, the runtime needs a way to provide that context or the boundary must move. Partial hydration works best when interactive regions have explicit, serializable inputs and limited reliance on ambient client-only state.

Hydration triggers can be eager or lazy. A region may hydrate immediately, on viewport entry, on idle, or on interaction. Lazy triggers reduce initial cost but introduce readiness states that product and accessibility behavior must handle.

## Practical patterns

Start by classifying page regions: static content, interactive controls, personalized dynamic content, and real-time widgets. Static content should stay inert. Interactive controls should become hydratable regions. Personalized content might be server-rendered per request without client hydration if it does not need browser state.

Keep interactive boundaries coarse enough to share state naturally. A product configurator with color, size, price, and add-to-cart is usually one hydratable region, not four independent partial islands. Splitting too far creates coordination cost and duplicated JavaScript.

Prefer native browser behavior when it solves the interaction. Links, forms, details/summary, CSS hover states, and server submissions can avoid hydration entirely. Partial hydration is most valuable when teams resist making every small behavior a client component.

Serialize only stable inputs. If a region needs a large object graph, consider server-rendering more of it or fetching additional data after hydration. Large inline JSON payloads can become a hidden replacement for JavaScript bloat.

Define ownership for data freshness. A partially hydrated price widget, stock counter, or notification badge may need fresher data than the static page around it. Decide whether it refreshes on hydration, subscribes after hydration, or relies on navigation to refresh. Each choice has different cache and consistency trade-offs.

Use progressive enhancement as the baseline contract. A newsletter form can submit normally before hydration and become richer afterward. A filter panel can use query-string links first and upgrade to instant client filtering later. This keeps the page useful even when hydration is delayed.

## Failure modes

Boundary leakage happens when a supposedly static parent imports client-only hooks, context, or browser APIs. The hydratable area expands upward until most of the page is live again. Track why each boundary hydrates and which imports force it.

Pre-hydration interaction is another common failure. A user clicks before the region is ready. For critical controls, hydrate early or use native fallback behavior. For lazy controls, show an honest pending state or hydrate on first interaction while preserving the event if the framework supports it.

Mismatch bugs still apply. The hydratable region's server HTML must match what the client expects. Locale, time, random values, feature flags, and environment-specific branches can all produce hydration warnings or remounts.

Debugging can be harder because some components exist only on the server and some exist on both sides. Logging without clear server/client labels quickly becomes misleading.

Testing gaps often hide in the non-hydrated path. Teams run end-to-end tests after JavaScript is ready, so the static and pre-hydration states are never exercised. Add tests or manual checks that interact during slow hydration, with JavaScript disabled, and after client upgrade.

## Debugging and diagnostics

Build a hydration map for key pages. It should show each hydratable region, trigger, bundle size, props size, and reason for hydration. This often reveals regions that became live accidentally.

Use browser performance traces to find script parse and hydration tasks. Compare the trace with a full-hydration baseline if available. The win should appear as less JavaScript and fewer main-thread hydration tasks, not only a lower bundle number.

Test delayed JavaScript. Throttle network and CPU, then click controls before hydration completes. The result should be native behavior, queued/resumed interaction, or a clear disabled/pending affordance.

## Boundary design

A good partial hydration boundary has a stable server-rendered shell, serializable inputs, and a clear owner for client state. Bad boundaries cut through state that users perceive as one control. For example, a product image carousel, variant picker, price, and add-to-cart button may need to coordinate closely enough that one hydratable product island is simpler than several tiny regions.

Boundaries should also match deployment and caching behavior. If a static page is cached for hours but an island fetches live inventory, make that freshness split intentional. The server HTML should not claim "in stock" while the hydrated island immediately flips to "sold out" without explanation. Use neutral copy, revalidation, or fast server-side personalization for facts that change quickly.

## Accessibility and resilience

Pre-hydration markup must be accessible on its own. Buttons should either be real native controls with fallback behavior or visibly unavailable until the island is ready. Form fields need labels before hydration. Collapsed sections should not rely on a client component to expose their names and relationships.

Partial hydration also changes error recovery. If one island fails to load, the whole page should not become unusable. Show an island-level fallback, keep static content readable, and log enough metadata to identify the component, trigger, and asset URL that failed. A missing island script is an operational issue, but it should degrade like a localized feature failure.

## Checklist

- Classify regions before choosing hydration boundaries.
- Keep static content inert by default.
- Group related interactive state into coherent live regions.
- Track bundle and props size per hydratable region.
- Handle clicks before hydration is ready.
- Avoid server/client output divergence.
- Watch imports that force boundary expansion.
