---
title: "Micro-frontend orchestration"
date: 2026-02-17T13:20:00-05:00
draft: false
tags: [frontend, micro-frontends, orchestration, module-federation, architecture]
---

## Mental model: composition is the product

Micro-frontends are not primarily about splitting code. They are about splitting ownership while still shipping one coherent product. Orchestration is the layer that decides which independently built UI units load, where they mount, how they communicate, and what happens when one of them fails.

Without orchestration, a micro-frontend system becomes a set of teams deploying JavaScript into the same page and hoping version boundaries hold. A good shell gives teams autonomy while preserving routing, identity, observability, design constraints, and failure isolation.

{{< mermaid >}}
flowchart TD
    Shell[Application shell] --> Router[Route matcher]
    Shell --> Auth[Identity/session]
    Shell --> Registry[Remote registry]
    Router --> MFE1[Orders remote]
    Router --> MFE2[Billing remote]
    Router --> MFE3[Support remote]
    Auth --> MFE1
    Auth --> MFE2
    Registry --> MFE1
    Registry --> MFE2
    Registry --> MFE3
{{< /mermaid >}}

The shell is the product's operating system. Users do not care that billing and support are owned by different teams. They care that navigation is consistent, authentication works once, errors are understandable, and the page does not load three copies of the same library.

## Internals

The shell owns stable contracts. It should provide route mounting, shared runtime services, global error boundaries, feature flags, telemetry, and design-system version policy. Remotes own domain UI and can deploy independently inside those contracts.

There are two common loading models. Build-time composition packages remotes as dependencies and releases them with the shell. Runtime composition loads remote manifests or module federation containers at request time. Runtime composition gives more deployment autonomy, but it moves failure from CI to production unless the shell validates manifests, versions, and health.

Communication should be boring. Prefer URL state, explicit shell services, and typed custom events over importing another remote's internal store. Shared global state is tempting, but it couples release cycles and makes ownership unclear.

The orchestration layer has several responsibilities that should not be scattered through remotes:

- Route ownership: which remote handles which path and what fallback appears on failure.
- Runtime compatibility: which shell and remote versions may run together.
- Shared services: auth token access, API client policy, telemetry, feature flags, and locale.
- Dependency policy: which packages are shared singletons and which are bundled privately.
- Lifecycle: mount, update, unmount, error, and dispose.
- Observability: consistent error metadata across independently deployed code.

The mount contract is especially important. A remote should expose a small API such as `mount(container, services)` and return a cleanup function. The shell should not know the remote's component tree, state library, or internal router.

## Practical patterns

Define a remote manifest:

```json
{
  "name": "billing",
  "version": "2026.02.17",
  "entry": "https://cdn.example.com/billing/remoteEntry.js",
  "routes": ["/billing/*"],
  "requiredShell": ">=3.4.0"
}
```

The shell should validate this before mounting. If validation fails, render a domain-specific fallback and emit telemetry. Do not let a broken remote white-screen the full product.

Use a shared design system, but avoid sharing every utility package. Shared dependencies should be few, versioned, and treated as platform APIs. React, routing primitives, telemetry clients, and tokens are candidates. A team's table helper is not.

For CSS, choose a containment strategy early: CSS modules, shadow DOM, strict naming, or compiled atomic classes. Global CSS from remotes is one of the fastest ways to make unrelated deployments break each other.

Make services explicit:

```ts
type ShellServices = {
  auth: { getAccessToken(): Promise<string | null> };
  telemetry: { event(name: string, fields?: object): void };
  flags: { get(name: string): boolean };
  navigate(to: string): void;
  locale: string;
};
```

Passing services through a typed contract is less convenient than importing a shared singleton, but it makes tests and compatibility clearer. It also lets the shell enforce policy, such as token refresh, request headers, and audit logging.

Use route-level isolation first. Page-level remotes are easier to reason about than many tiny remotes embedded in one screen. Fragment-level composition can work for mature platforms, but it increases coordination costs around layout, loading states, and cross-fragment communication.

Define failure UI per domain. Billing might show "Billing is temporarily unavailable" with support links. Notifications might silently degrade. A generic blank shell fallback is rarely enough. The shell should also support circuit breaking: if a remote repeatedly fails to load, stop retrying aggressively and show a stable fallback.

For local development, provide a registry override so a developer can run one remote locally against a stable shell. Keep the same manifest shape in local and production environments so local success means something.

## Failure modes

The sharpest failure mode is dependency drift. Two remotes expect incompatible singleton versions of React, router, or design-system context. Pin shared singleton policy and test each remote against the shell's compatibility matrix.

Another failure is cross-remote synchronous assumptions. If the cart remote calls directly into the pricing remote, both must be loaded and healthy in one timing order. Use shell-mediated services or backend APIs for domain interactions.

Performance can also regress quietly. Multiple remotes may each ship date libraries, charting libraries, and API clients. Track total route cost, not only individual remote bundle size. Autonomy without budgets becomes duplicated JavaScript.

CSS leakage is another production-grade failure. A remote ships `button { ... }` or resets `box-sizing` globally and breaks the shell. Lint for global selectors, scope CSS by build tooling, and run visual smoke tests with multiple remotes mounted.

Authentication drift is dangerous. If remotes fetch tokens differently, one remote may refresh too often, another may use stale credentials, and a third may leak auth state into logs. Auth belongs behind a shell service or shared platform client with clear rules.

Deployment order can break runtime composition. A remote may deploy code that requires shell service `x`, but users still run an older shell. Compatibility metadata should prevent mounting, and CI should test both latest-latest and allowed skew combinations.

Ownership can become muddy around shared UX. If every team designs its own empty states, permissions errors, and loading skeletons, the product feels stitched together. The shell or platform team should provide patterns, components, and review gates for cross-cutting states.

## Debugging and diagnostics

Expose a shell diagnostics panel in non-production environments. It should show mounted remotes, manifest versions, load times, shared dependency resolution, feature flags, and recent mount errors. In production logs, attach `shellVersion`, `remoteName`, `remoteVersion`, and `routeId` to every frontend error.

Synthetic tests should load each route with the latest shell and latest remote manifests. Also test the previous shell against the latest remote if independent deployment allows that combination.

Add lifecycle logging around remote mount:

- manifest fetch start/end
- compatibility validation result
- remote entry load start/end
- mount start/end
- unmount result
- first meaningful paint inside the remote

When a page is slow, this separates CDN latency, remote bootstrap, data fetching, and rendering. When a page crashes, it shows whether the shell failed before loading the remote or the remote failed during mount.

For module federation or similar runtimes, inspect shared dependency resolution. A remote may silently fall back to its own copy of a package if the shell version does not satisfy its range. That can create duplicate React instances or duplicated design-system contexts. Make this visible in diagnostics rather than discovering it through strange hook errors.

Use contract tests. A remote's CI should mount it with a fake shell service object and verify cleanup. The shell's CI should load manifests and assert required fields, allowed routes, CSP compatibility, and dependency declarations.

## Checklist

- Let the shell own routing, identity, telemetry, and failure boundaries.
- Publish explicit remote manifests with compatibility metadata.
- Keep shared dependencies small and governed.
- Prefer URL and shell services for communication.
- Contain CSS by construction.
- Measure route-level JavaScript and load time.
- Test compatibility combinations, not just each remote alone.
- Keep mount/unmount contracts small and typed.
- Provide domain-specific fallbacks and circuit breaking.
- Make shared service usage explicit, especially auth and telemetry.
