---
title: "Module federation"
date: 2026-04-03T09:00:00-04:00
draft: false
tags: [frontend, module-federation, micro-frontends, webpack, bundling]
---

Module Federation lets one JavaScript build load modules from another build at runtime. It is often used for micro-frontends, but the underlying idea is simpler: split deployment ownership without publishing every shared piece as an npm package. A host application discovers a remote container, asks for an exposed module, and executes it with a shared dependency scope.

{{< mermaid >}}
flowchart LR
  Host[Host app] -->|loads remoteEntry.js| Remote[Remote container]
  Host --> Share[Shared scope]
  Remote --> Share
  Remote --> Exposed[./Widget module]
  Host -->|render| Exposed
{{< /mermaid >}}

## Mental model

At build time, the remote declares which modules it exposes. The host declares remotes it may consume. At runtime, the host loads the remote entry script, initializes dependency sharing, then imports exposed modules. This means integration failures can happen after deploy even when both projects compiled successfully.

Module Federation is not just code splitting. Code splitting splits one build graph. Federation composes multiple independently built graphs. That gives organizational flexibility, but it also moves compatibility checks from package install time to runtime.

The runtime sequence matters. The host loads the remote container, initializes the share scope, asks the container for a module factory, executes that factory, then renders or calls the exposed module. Any step can fail independently: the remote entry can be unavailable, share initialization can reject because versions do not match, or the exposed module can load but throw during render.

This is why federation should map to ownership boundaries. If two teams must coordinate every prop and release anyway, federation may add runtime failure without reducing organizational coupling. If teams can own coarse features with stable contracts, federation can let them deploy without waiting for a central app release.

Federation also affects security posture. Loading a remote is loading executable JavaScript from another deployable artifact. The host should trust the remote origin, pin expected environments, and avoid letting arbitrary configuration choose remote URLs at runtime.

## Shared dependencies

Shared dependencies are the sharp edge. React, router libraries, state managers, design systems, and runtime utilities often need singleton behavior. If the host and remote load incompatible React copies, hooks can fail. If they load mismatched router versions, navigation contracts can break.

Use explicit sharing rules. Pin critical singletons and define version expectations. Avoid sharing every dependency by default; that creates invisible coupling. Share dependencies that must be singletons or are large enough to justify runtime coordination. Bundle remote-private implementation dependencies inside the remote.

Version negotiation is not a replacement for compatibility discipline. A remote that says it accepts `react@^18` may still rely on behavior from a specific minor, and a design-system component may compile against tokens the host has not deployed. Treat shared versions as one layer of protection, then add contract tests that exercise real host and remote combinations.

Singletons deserve special attention. React, CSS-in-JS runtimes, state stores, analytics clients, and router objects can break when duplicated. For a singleton, define who provides it, what version range is accepted, and what happens if the requirement is not met. Silent fallback to a second copy may make the page render while corrupting state or context.

Do not share dependencies only to reduce bytes. Runtime sharing adds coordination and failure modes. For small utilities, duplication may be cheaper and safer than negotiating a shared instance across independently deployed builds.

## Practical patterns

Keep exposed modules coarse-grained. Expose `./CheckoutApp` or `./SettingsPanel`, not dozens of internal buttons and hooks. A remote boundary should look like a product or platform boundary with a small contract: props, events, route base, auth assumptions, and styling tokens.

Wrap remote imports with failure handling:

```js
const RemoteSettings = lazy(() =>
  import("settings/Panel").catch((error) => {
    reportRemoteLoadFailure("settings/Panel", error);
    return import("./fallbacks/SettingsUnavailable");
  }),
);
```

Runtime configuration should provide remote URLs per environment. Avoid baking production remote URLs into host builds when promotion pipelines require independent deploys.

Define the boundary API in boring terms. Props should be serializable where possible. Events should be named and versioned. Auth assumptions should be explicit: does the remote read a token from a shared client, receive it through props, or call a same-origin API? Styling should use tokens or scoped classes, not accidental global CSS.

Use a host-owned adapter around each remote. The adapter handles lazy loading, error fallback, telemetry, feature flags, and prop normalization. The rest of the host should not import remote modules directly from many places. That gives you one place to change behavior during an incident.

For local development, provide a fixture that runs the host against a local remote and against the latest deployed remote. Many federation bugs come from developing both sides in lockstep locally, then discovering that independent deployment produces mixed versions.

## Failure modes

The obvious failure is remote entry unavailable due to CDN, deploy, or cache issues. The less obvious failure is contract drift: a remote deploy changes props or shared dependency expectations before the host is updated. Because deploys are independent, semver discipline and compatibility tests matter more than in a monolith.

Caching can produce mixed versions. A host may load a new remote entry that references old chunks, or an old remote entry that references purged chunks. Use immutable hashed chunks and carefully controlled caching for the remote entry itself.

CSS leakage is another issue. Federation does not create style isolation. Use CSS modules, scoped naming, shadow DOM, or a design-system token contract. Decide how global resets and fonts are owned.

Operational ownership can fail too. If the remote team deploys a broken `remoteEntry.js`, the host team may receive the user reports. Agree on rollback paths, alert ownership, service-level expectations, and communication for breaking changes before the architecture is used for critical flows.

Another failure is assuming federation handles data isolation. A remote can still call APIs, read shared browser storage, and affect global state. Apply the same auth, authorization, CSP, and dependency review standards you would apply to code compiled into the host.

Performance can regress through remote waterfalls. The host loads its entry, then `remoteEntry.js`, then remote chunks, then remote data. Preload or preconnect high-confidence remotes, but first check whether the remote belongs on the initial route at all.

## Diagnostics

Log remote name, remote URL, exposed module, share-scope versions, and load timing. When a runtime import fails, the error alone is often too vague. Inspect the network waterfall for `remoteEntry.js` and its referenced chunks.

Create an integration fixture that loads each remote against the host's real shared dependencies. Contract tests should verify exported component shape, required props, event behavior, and critical user flows.

During an incident, separate network failure from compatibility failure. A missing remote entry, blocked script, wrong MIME type, or CORS/CSP issue appears in the Network and Console panels. A share-scope mismatch or render-time contract drift appears after scripts load. Log enough state to classify the failure without asking users for DevTools output.

Track remote load time as a first-class metric. Include DNS/TLS if the remote is on another origin, remote entry download, chunk downloads, initialization, and first render. A remote that is technically available but adds two seconds to a common route is an architecture problem, not just a performance bug.

## Implementation guidance

Create a manifest per environment that maps remote names to URLs, expected versions, and owners. The host reads this manifest through a controlled path, not arbitrary query parameters. Include a kill switch or fallback version for non-critical remotes.

Publish a contract package or schema for each exposed module. It can contain TypeScript types, event names, test fixtures, and compatibility notes. Types alone are not enough because deploys can mix old host with new remote; keep backwards compatibility for at least one deployment window.

Cache `remoteEntry.js` with short or revalidation-friendly headers, and cache its referenced chunks with immutable hashes. The entry is the pointer to the current graph; chunks are content-addressed assets. Mixing those policies causes many stale deploy failures.

## Checklist

- Use federation for independent deployment boundaries, not ordinary laziness.
- Keep exposed modules coarse and contract-driven.
- Share only dependencies that need sharing.
- Treat React and similar libraries as strict singletons.
- Cache remote entries differently from immutable chunks.
- Provide fallbacks for remote load failure.
- Run host-remote compatibility tests before deploy.
- Use host-owned adapters for remote loading and telemetry.
- Define owners, rollback paths, and version windows.
- Treat remote code as executable trust from another deploy.
