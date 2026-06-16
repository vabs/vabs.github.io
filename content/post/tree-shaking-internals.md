---
title: "Tree shaking internals"
date: 2026-05-06T09:00:00-04:00
draft: false
tags: [frontend, tree-shaking, bundling, esm, performance]
---

Tree shaking is dead-code elimination for module graphs. The bundler starts from entry points, follows imports, marks used exports, and drops code it can prove is unused. The phrase sounds simple, but the result depends on module syntax, side effects, package metadata, and how confidently the bundler can reason about execution.

{{< mermaid >}}
flowchart TD
  Entry[entry module] --> ImportA[import used fn]
  Entry --> ImportB[import component]
  Lib[library module] --> Used[used export]
  Lib --> Unused[unused export]
  ImportA --> Used
  Unused -. dropped if safe .-> Output[final bundle]
  Used --> Output
  ImportB --> Output
{{< /mermaid >}}

## Why ESM matters

ES modules have static structure. `import { format } from "./date.js"` can be analyzed without running the program. CommonJS is dynamic: `require()` can be conditional, computed, or mixed with runtime mutation. Bundlers can optimize some CommonJS, but ESM gives them much stronger guarantees.

This is why modern libraries publish ESM builds and why application code should avoid patterns that obscure imports. A barrel file that re-exports everything can be fine if it is pure ESM, but it can also pull side effects into the graph if it imports modules that run setup at top level.

Tree shaking has two broad phases: marking and removal. The bundler marks exports that are reachable from entry points, then a minifier or optimizer removes code proven unreachable or unused. If earlier transforms convert ESM into CommonJS, wrap modules in dynamic helpers, or preserve unknown side effects, the marking phase becomes less precise.

ESM live bindings also matter. An exported binding can be updated by the exporting module and observed by importers, so bundlers must preserve semantics. They are conservative when code uses namespace imports, re-export chains, or top-level mutations in ways that make usage harder to prove.

CommonJS can still be optimized in limited cases, especially when packages follow predictable patterns, but it is not as transparent. A single `module.exports = condition ? a : b` or computed `require(path)` can force the bundler to keep more code than expected.

## Side effects

Tree shaking cannot drop code that might change program behavior. Top-level work such as registering globals, patching prototypes, importing CSS, initializing telemetry, or mutating shared objects is a side effect. Package authors communicate purity with the `sideEffects` field in `package.json`.

`"sideEffects": false` tells bundlers that unused modules can be removed. A list such as `["*.css", "./src/polyfills.js"]` keeps known side-effect files. Incorrect metadata can break applications by removing required setup.

Side-effect analysis is intentionally conservative. A function call at top level might register something globally, patch a prototype, read the current time, throw, or mutate imported state. Even if the return value is unused, the call may need to remain. Pure annotations such as `/* @__PURE__ */` can help minifiers remove known-safe calls, but incorrect annotations can break behavior.

Package-level `"sideEffects": false` applies at module granularity. It tells the bundler that unused modules can be dropped, not that every expression inside a used module is removable. If a used module imports a large table or registers all icons at top level, that work may stay even when only one export is referenced.

CSS imports are side effects in most frontend builds. Marking all files side-effect-free while importing CSS from component modules can remove required styles. Package authors often use a sideEffects allowlist for `*.css` and setup files.

## Practical patterns

Prefer named ESM exports:

```js
export function formatCurrency(value, locale) {
  return new Intl.NumberFormat(locale, { style: "currency", currency: "USD" })
    .format(value);
}
```

Avoid top-level initialization in modules that mainly export utilities. Move setup into explicit functions. If a module must have side effects, name it clearly, such as `install-polyfills.ts`, and import it intentionally from the app entry.

Be careful with libraries that expose both modular and aggregate imports. `import debounce from "lodash/debounce"` historically shook better than importing from a CommonJS aggregate. Modern ESM packages improve this, but bundle analysis is the source of truth.

Keep entry modules boring. Import polyfills, global CSS, telemetry setup, and runtime patches explicitly from the app entry. Keep utility modules pure and lazy. This makes it clear which files are allowed to do top-level work and which should shake aggressively.

For icon sets, date libraries, chart libraries, and component systems, prefer per-feature imports or generated manifests. If the app dynamically indexes a giant object, the bundler may need to keep the whole object. A build-time generated map containing only configured icons or locales gives you dynamic lookup without importing the universe.

For TypeScript, check the emitted module format. `module: "ESNext"` or a bundler-aware setting usually preserves ESM for the bundler. Running Babel or TypeScript first and outputting CommonJS can undo tree-shaking before the production bundler sees the graph.

## Failure modes

The first failure is assuming unused code will disappear because it is not called. If it is imported through a side-effectful module, it may remain. The second is transpiling ESM to CommonJS before the bundler sees it. TypeScript or Babel configuration can accidentally destroy static module information.

The third is dynamic property access. Patterns like `icons[name]` can force bundlers to keep a whole icon map because any property may be used. Prefer explicit imports or generated manifests for large collections.

CSS and component libraries are another trap. Importing a root stylesheet or root component registry may include styles for every component. Use per-component style imports or a build-time CSS strategy when bundle size matters.

Barrel files deserve measurement, not superstition. A pure `export { Button } from "./Button"` barrel can shake well. A barrel that imports every component, attaches metadata, exports a registry, and imports all styles will not. Inspect the emitted graph before banning or blessing the pattern.

Transpiler helpers can also add weight. If every module inlines helpers, tree shaking may work but the output still grows. Use shared helpers where appropriate and ensure production builds deduplicate dependencies.

Minifier settings matter. Development builds usually do not shake or minify as aggressively. Always verify production output. A scary dev bundle may disappear in production, and a clean dev import graph may still retain code after production transforms add side effects.

## Diagnostics

Use a bundle analyzer to inspect what stayed. Then trace why: which entry imported it, whether the module is marked side-effectful, and whether the import style prevents static analysis. Source-map explorers are useful because minified output can hide module boundaries.

Create a small reproduction when library shaking looks wrong. Import one function, build in production mode, and inspect the output. This separates bundler configuration issues from package publishing issues.

Trace retained code backwards. Bundle analyzers show what is present; import traces explain why. Look for the first edge from your app into the retained module. Then inspect whether that edge is a value import, namespace import, side-effect import, re-export, or generated context import.

When a package refuses to shake, inspect its `package.json`: `module`, `exports`, `main`, `sideEffects`, and conditional export fields. Some packages expose ESM only under a specific condition. Your bundler may be resolving the CommonJS entry because of configuration or dependency version.

## Implementation guidance

Add bundle-size checks around high-risk areas rather than the whole app only. A route-level budget can catch a chart library leaking into the landing page. A package-level reproduction can catch a dependency upgrade that switches from ESM to CommonJS.

Keep side-effectful files named and isolated: `setupTelemetry`, `installPolyfills`, `registerIcons`, `globalStyles`. Import them once from an entry point. That naming convention helps humans and bundlers agree about what must run.

For libraries you publish, test tree shaking as a consumer. Build a tiny app that imports one function or component, run a production bundle, and inspect output. Publishing ESM is not enough if your entry point imports every feature at top level.

## Checklist

- Keep ESM intact until bundling.
- Prefer named exports and explicit imports.
- Avoid top-level side effects in utility modules.
- Configure `sideEffects` accurately.
- Watch barrel files and root library imports.
- Use bundle analysis to verify, not guess.
- Preserve ESM through TypeScript and Babel before bundling.
- Isolate setup modules from pure utility modules.
- Test library shaking from a real consumer build.
