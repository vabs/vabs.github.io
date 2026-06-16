---
title: "Selective hydration"
date: 2026-04-01T10:05:00-04:00
draft: false
tags: [frontend, hydration, ssr, react, performance]
---

## Mental model: hydration is scheduling, not just attaching events

Hydration turns server-rendered HTML into an interactive client tree. Selective hydration means the browser does not hydrate the entire page with one equal-priority pass. It can prioritize the parts the user needs first, often driven by Suspense boundaries, user input, visibility, and resource readiness.

This matters because SSR can improve first paint while still leaving the page unusable during a large hydration task. Selective hydration attacks that gap. The goal is not merely a pretty static page; it is a page where the first meaningful interaction is not blocked by unrelated widgets.

{{< mermaid >}}
flowchart TD
    HTML[Server HTML visible] --> Queue[Hydration work queue]
    Queue --> Nav[High priority nav/search]
    Queue --> Main[Visible content boundary]
    Queue --> Below[Below fold widgets]
    User[User clicks search] --> Nav
    Nav --> Interactive[Search becomes interactive first]
    Below --> Later[Hydrated when idle/visible]
{{< /mermaid >}}

The user experiences hydration as a contract: the page looks ready, so controls should behave ready. Selective hydration is a way to make that contract true sooner for the important controls without paying the cost of hydrating every recommendation card, footer widget, and analytics panel first.

## Internals

The client renderer needs to match the server HTML to the component tree. It walks existing DOM, creates component instances, attaches listeners, and verifies that markup expectations line up. If the server and client output differ, the renderer may warn, patch, or discard server DOM.

Selective hydration adds prioritization. A Suspense boundary gives the renderer a unit of work that can be hydrated independently once its code and data are available. If the user interacts with an unhydrated boundary, that boundary can jump ahead in the queue.

The browser main thread is the scarce resource. Hydration competes with parsing JavaScript, running effects, layout, painting, analytics, and user input. Breaking hydration into meaningful units lets the scheduler yield instead of freezing the page.

Two resources gate each boundary: the JavaScript for the client components and the data needed to reproduce the server tree. A boundary cannot become interactive if its code chunk has not loaded. It also cannot safely hydrate if the client render would produce different markup. Selective hydration therefore works best with code splitting, streaming, and deterministic render inputs aligned around the same boundaries.

Event replay is part of the story in some renderers. If a user clicks a not-yet-hydrated control, the renderer can capture the event, prioritize that boundary, hydrate it, and then replay the event. This is useful, but it is not a license to leave critical controls inert for seconds. The longer the delay, the more likely layout, state, or user intent has changed before replay.

Hydration also has a commit cost. Even when no DOM nodes are replaced, the renderer initializes component state, attaches listeners, and runs effects after hydration. A page with many client components can have small visible changes but large main-thread work.

## Practical patterns

Place boundaries around areas with different urgency. Header navigation, search, and primary call-to-action controls should hydrate early. Comments, recommendations, charts, and below-the-fold panels can wait.

Reduce client component surface area. If a component never handles events and does not need browser APIs, keep it server-rendered or static. Selective hydration helps, but shipping less hydratable code is still better than scheduling too much code.

Make fallback HTML useful. A server-rendered button that looks clickable but cannot respond for two seconds is frustrating. For critical controls, either hydrate them early or render a disabled/pending affordance until ready.

Keep providers low in the tree. A top-level client provider can force a broad region to hydrate before anything inside it is usable. Move theme toggles, tracking contexts, and interactive state providers as close as possible to the components that need them. Static layout should not become client-side just because one child opens a menu.

Design boundaries by interaction priority:

- Immediate: navigation, search, login state, cart, dismissible critical banners.
- Soon: primary content controls, filters visible above the fold, media playback controls.
- Later: comments, related items, charts below the fold, social embeds.
- Idle: analytics dashboards, low-priority personalization, decorative interactions.

Pair this with resource hints. If the search box must hydrate first but its chunk is discovered late, the priority plan fails. Preload or eagerly include the code for the most important interactive boundary, then defer less urgent chunks.

Use stable serialized data. Pass server-generated ids, timestamps, locale strings, and experiment assignments into the client rather than recalculating them. For responsive differences, render a deterministic baseline and adapt after hydration.

When using islands or partial hydration frameworks, apply the same reasoning. The syntax changes, but the questions remain: which island ships JavaScript, when is it discovered, what data does it need, and what happens if the user interacts before it is ready?

## Failure modes

Hydration mismatches are the classic failure. They often come from rendering `Date.now()`, random ids, locale-dependent formatting, viewport checks, or feature flags differently on server and client. Use deterministic values from the server or defer client-only rendering until after hydration.

Another issue is invisible priority inversion. A heavy analytics provider or global state initialization runs before the visible search box hydrates. Audit top-level client code, not just component boundaries.

Third-party scripts can also destroy the plan. If they mutate server HTML before hydration, the renderer may fail to match nodes. Keep third-party DOM mutation outside hydrated regions or run it after hydration.

A subtle failure is over-fragmentation. Too many tiny boundaries can add overhead, scattered fallbacks, and chunk waterfalls. Boundaries should map to meaningful UI and scheduling decisions, not every component file.

Another failure is misleading interactivity. A server-rendered dropdown can look enabled even though it cannot open. If delayed hydration is expected, use CSS-only disclosure where appropriate, render an actual disabled state, or prioritize that boundary. Avoid controls that accept focus but cannot respond.

Streaming introduces partial failure modes. The shell may have been sent, headers committed, and some boundaries hydrated when a later boundary fails. Plan local error UI for delayed regions. Do not let a recommendations failure invalidate the whole document after the user is already reading.

Cache variation can cause mismatches too. If the server rendered experiment A from an edge cache but the client bootstraps experiment B from local storage, hydration may patch or discard markup. Keep experiment assignment in the HTML payload used for the first client render.

## Debugging and diagnostics

Measure time to first interaction, hydration duration, long tasks, and input delay. Browser performance traces reveal whether hydration is one giant task or multiple smaller tasks. Add marks around boundary hydration where the framework allows it.

To reproduce issues, throttle CPU and network together. Many hydration bugs are invisible on a developer laptop. Test with JavaScript delayed, route code split chunks missing from cache, and fast user clicks immediately after first paint.

Instrument from the user's point of view. Mark when the server HTML is visible, when the critical boundary code loads, when hydration starts, when it commits, and when the first event handler successfully runs. A simple timeline can show that the page painted at 800 ms but search became interactive at 3.4 seconds.

Useful debugging checks:

- Compare server and client rendered text for timestamps, ids, and locale output.
- Inspect which modules enter the first client bundle because of high-level `"use client"` boundaries.
- Record long tasks during hydration and attribute them to providers, effects, or third-party scripts.
- Click critical controls immediately after first paint under CPU throttling.
- Test with blocked or delayed async chunks to verify local fallbacks.

For React-style apps, watch for effects doing heavy work after hydration. Hydration may commit quickly, then a large effect blocks input. That is still part of interaction readiness. Move non-critical effects to idle callbacks, split them, or run them after the critical boundary is usable.

## Checklist

- Treat hydration as main-thread work with priorities.
- Keep critical controls in early hydration boundaries.
- Avoid nondeterministic server/client rendering.
- Reduce client component surface before tuning scheduling.
- Guard third-party DOM mutation.
- Profile on throttled CPU and network.
- Track interaction readiness, not only first paint.
- Align Suspense boundaries with code and data availability.
- Keep providers and client boundaries as low as practical.
- Test immediate post-paint clicks and delayed chunk scenarios.
