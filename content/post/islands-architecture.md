---
title: "Islands architecture"
date: 2026-03-19T09:45:00-04:00
draft: false
tags: [frontend, islands-architecture, hydration, performance, static-sites]
---

## Mental model: static HTML with targeted interactivity

Islands architecture starts from the assumption that most of a page can be delivered as inert HTML. Only specific interactive regions, or islands, receive client JavaScript. Instead of hydrating one large application root, the page contains multiple independent interactive mounts embedded in server-rendered or statically generated markup.

This model fits content-heavy sites, ecommerce pages, documentation, marketing pages, and dashboards with isolated widgets. The performance win comes from avoiding JavaScript for regions that do not need browser-side state.

{{< mermaid >}}
flowchart TD
    Page[Server/static HTML page] --> Header[Static header]
    Page --> Article[Static article content]
    Page --> Cart[Cart island JS]
    Page --> Filter[Filter island JS]
    Page --> Comments[Comments island JS]
    Cart --> Hydrate1[Hydrate only cart]
    Filter --> Hydrate2[Hydrate only filter]
    Comments --> Hydrate3[Hydrate on visibility or interaction]
{{< /mermaid >}}

## Internals

An island is usually rendered to HTML on the server, annotated with enough metadata for the client runtime to find it, load its component code, and hydrate or mount it. The rest of the document remains ordinary HTML. Each island can have its own props payload, hydration trigger, and bundle.

Hydration strategies are central. An island may hydrate immediately, when visible, when the browser is idle, after media conditions match, or on first interaction. This turns hydration from a page-level event into a per-widget scheduling decision.

Because islands are separate roots, communication is more explicit. Two islands do not automatically share in-memory component state unless the framework provides a shared client store or you build one. Server-rendered HTML, URL state, cookies, custom events, or a small external store often become the coordination layer.

Bundling also changes. Each island can pull a different dependency graph into the browser. This is powerful, but it means a large shared dependency imported by many islands may still dominate the page unless it is split and cached well.

## Practical patterns

Default to static content. Make an element an island only when it needs event handlers, client-side state, browser APIs, real-time updates, or immediate client validation. A button that navigates via a normal link does not need an island.

Choose hydration triggers by user value. A cart summary above the fold may hydrate immediately. A comments widget at the bottom of a long article can wait until visible. A theme toggle should hydrate early enough to avoid a broken click.

Use URL state for cross-island coordination when it represents navigation or shareable state. Filters, pagination, tabs, and search queries often belong in the URL. Use custom events or a tiny store for ephemeral coordination such as opening a mini-cart after an add-to-cart action.

Keep island props small and serializable. Passing an entire product catalog into a filter island can erase the JavaScript savings. Let the server render bulk content and pass only the data needed for interaction.

Use a consistent naming and ownership model for islands. Each island should have a clear reason to exist, a known hydration trigger, and an owner who understands its bundle impact. Without that discipline, islands become a dumping ground for arbitrary client components.

For design systems, separate static styling primitives from interactive primitives. A card, stack, badge, or typography component should not force hydration. A combobox, modal, tooltip, or drag handle probably will. This separation lets teams compose rich server-rendered pages without accidentally importing browser-only behavior.

## Failure modes

Island explosion is a real cost. A page with twenty tiny islands can create many script requests, many hydration tasks, and many duplicated dependencies. Group related interactions when they share state and are always used together.

Coordination bugs appear when islands assume a shared application context that does not exist. A login island may update, but a header island still shows the old user because it hydrated with stale props. Define how shared facts update: full navigation, server refresh, event, or shared store.

Delayed hydration can break perceived interactivity. If a user clicks an island before its JavaScript is ready, the page needs a strategy: hydrate on interaction, preserve native behavior, or make the disabled state honest. Do not ship controls that look ready but drop input.

SEO and accessibility can regress if islands render critical content only on the client. The baseline HTML should contain meaningful content, labels, links, and form structure wherever possible.

Version skew is another operational failure. Static HTML generated at build time may reference island manifests from a newer or older deployment if caching is misconfigured. Use content-hashed assets and deploy HTML plus manifests atomically so the browser can always find the code for an island marker.

## Debugging and diagnostics

Audit JavaScript by island. Track which components produce which chunks and how much shared code they import. A bundle analyzer is more useful when mapped to island names than when it only shows files.

Measure hydration timing per island. Record when the island enters the viewport, when its code loads, when hydration finishes, and whether the user interacted before readiness. These events expose delayed-interaction bugs quickly.

Test with JavaScript disabled or blocked. The page should still present static content and native navigation. For interactive-only features, the fallback should be understandable rather than blank.

## Data and state strategy

Islands force a useful question: which state is local, shareable, or navigational? Local state can live inside one island. Navigational state belongs in the URL or server route. Shareable ephemeral state needs a deliberate bridge, such as a small client store or custom events. Avoid reaching for a global store before proving two islands need live coordination.

Server actions and normal form posts can reduce cross-island complexity. An add-to-cart island may submit to the server, then the response can update the page or emit a small event for the cart island. For many commerce and content workflows, this is simpler and more resilient than maintaining a large client app shell.

## Operational concerns

Treat island manifests as part of the HTML contract. If the server emits a marker for `ProductFilter` with props schema version 3, the browser must be able to load compatible code. Content-hashed assets, atomic deploys, and careful CDN invalidation matter more when old HTML can survive longer than JavaScript bundles.

Observability should include island names. Log hydration failures, time to interactive per island, and pre-hydration interactions. Without island-level metrics, teams see only page-level JavaScript cost and miss the widget that quietly regressed.

## Checklist

- Make static HTML the default.
- Create islands only for real client interactivity.
- Pick hydration triggers by importance and visibility.
- Keep serialized props small.
- Define explicit communication between islands.
- Watch duplicated dependencies across island bundles.
- Test pre-hydration clicks and no-JavaScript behavior.
