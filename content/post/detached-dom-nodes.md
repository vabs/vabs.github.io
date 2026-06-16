---
title: "Detached DOM nodes"
date: 2026-02-05T08:35:00-05:00
draft: false
tags: [frontend, dom, memory-leaks, javascript, diagnostics]
---

A detached DOM node is a node that is no longer connected to the document tree but is still retained by JavaScript or browser internals. Detached nodes are not automatically leaks. A framework may temporarily hold nodes during reconciliation, an animation library may stage elements before disposal, and a virtual scroller may reuse nodes. They become a leak when the application no longer needs them but something keeps them reachable.

The mental model is two graphs: the DOM tree and the JavaScript object graph. Removing a node from the DOM only disconnects it from the document. If a closure, array, map, event listener, observer, or pending task still points to it, the node and often its entire subtree remain alive.

{{< mermaid >}}
flowchart TD
  A[Document] --> B[Live DOM subtree]
  C[Removed node] -. no parent .-> D[Detached subtree]
  E[JS closure or cache] --> C
  E --> F[Listener metadata]
  C --> G[Child nodes and data]
{{< /mermaid >}}

## Common retention paths

The simplest leak is a global cache:

```js
const selectedNodes = [];

function rememberSelection(node) {
  selectedNodes.push(node);
}
```

If selected nodes are removed later, the array still owns them. Maps have the same problem when DOM nodes are keys or values. Use `WeakMap` for metadata keyed by nodes, and delete explicit map entries during cleanup when values reference nodes.

Event listeners can retain detached subtrees when the listener closure captures a node or model. The browser can collect listeners attached to a node if the node itself is unreachable, but if something else retains the listener or node, the whole graph remains.

Observers are another source. `MutationObserver`, `ResizeObserver`, and `IntersectionObserver` all create relationships between callback, observed targets, and captured state. Always disconnect them when the owning component unmounts.

```js
function observePanel(panel) {
  const observer = new ResizeObserver(() => updateLayout(panel));
  observer.observe(panel);
  return () => observer.disconnect();
}
```

## Framework-specific patterns

In React, detached nodes usually come from imperative escape hatches: refs stored outside component lifetime, portals that are not unmounted, third-party widgets initialized in `useEffect` without cleanup, and document-level event handlers that capture component refs.

In Vue and Svelte, leaks often appear around actions/directives, manual event listeners, and external library instances. The rule is the same: if setup creates a reference outside the component, teardown must remove it.

Custom elements need special care because `disconnectedCallback` can run multiple times. Cleanup should be idempotent, and reconnect logic should not stack duplicate listeners or observers.

## Debugging in DevTools

Chrome DevTools can surface detached nodes in heap snapshots. A practical workflow:

1. Open the page and take a baseline heap snapshot.
2. Perform the workflow that creates and removes UI, such as opening and closing a modal 20 times.
3. Trigger garbage collection from DevTools.
4. Take a second snapshot.
5. Search for "Detached" or inspect retained objects by constructor.

The important view is the retaining path. It tells you why the node is still reachable. You might see a closure from a timer, an array in a module scope, a framework fiber, or an observer callback. Do not stop at "there are detached nodes"; find the owner.

Allocation instrumentation is useful when the leak happens over time. Record allocations while repeating the workflow, then inspect objects that survive after GC.

## Reproducing leaks

Make leaks measurable. Build a small loop around the suspected workflow:

```js
for (let i = 0; i < 50; i++) {
  await openModal();
  await closeModal();
  await new Promise((resolve) => setTimeout(resolve, 0));
}
```

Then compare heap snapshots before and after. A single detached node may be harmless. A count that grows linearly with repetitions is actionable.

## Fix patterns

Prefer ownership symmetry. The code that creates an external reference should return or register cleanup in the same scope.

```js
function mountTooltip(anchor) {
  const tooltip = document.createElement("div");
  document.body.appendChild(tooltip);

  const onMove = () => positionTooltip(anchor, tooltip);
  window.addEventListener("scroll", onMove, { passive: true });

  return () => {
    window.removeEventListener("scroll", onMove);
    tooltip.remove();
  };
}
```

Use `AbortController` to group DOM listeners:

```js
const controller = new AbortController();
window.addEventListener("resize", onResize, { signal: controller.signal });
document.addEventListener("keydown", onKeydown, { signal: controller.signal });

// later
controller.abort();
```

For caches, define an eviction policy. If the cache is keyed by route, clear it on route unload. If it is keyed by DOM node metadata, use `WeakMap`. If it stores rendered HTML or nodes for reuse, cap its size.

## Failure modes

Not every detached node is your leak. DevTools itself can retain inspected elements through `$0` and console history. Clear console references or test in a fresh profile if results look suspicious.

Detached iframes are especially expensive because they can retain entire documents, JavaScript realms, and resources. Always remove event listeners between parent and iframe, stop timers inside the frame when possible, and null references to `contentWindow` or frame documents.

Third-party widgets often require explicit destroy calls. Removing their container is not enough if the library registered global listeners or stored the instance in a registry.

## Ownership boundaries

The most reliable prevention technique is to make DOM ownership explicit. If a component creates a node outside its own subtree, such as a tooltip portal under `document.body`, that component also owns removing it. If a helper creates listeners or observers, it should return a cleanup function. If an integration wraps a third-party widget, its public API should expose `mount` and `destroy` rather than leaking the library's lifecycle into callers.

Avoid storing raw DOM nodes in application state. State tends to outlive view instances through caches, devtools, undo stacks, or persistence layers. Store stable IDs, model references, or weak metadata instead. If a DOM node must be stored temporarily, keep it in the narrowest possible scope, such as a ref owned by the component that renders it.

## Automated regression checks

Memory leaks need repetition to become visible. Add a development-only stress path for important workflows: open and close a dialog, mount and unmount a route, create and destroy a chart, or switch tabs repeatedly. After the loop, force garbage collection in a controlled browser test when possible and compare heap growth or retained node counts.

Exact heap sizes are noisy, so assert trends carefully. A small retained baseline can be normal. Linear growth with each repetition is the signal. Keep screenshots or heap snapshot notes for known third-party retainers so future investigations do not rediscover the same harmless retained nodes.

## Checklist

- Treat DOM removal and JavaScript reachability as separate concerns.
- Reproduce by repeating the same create/remove workflow many times.
- Use heap snapshot retaining paths to identify the owner.
- Clean up observers, timers, global listeners, portals, and widget instances.
- Prefer `WeakMap` for DOM-node metadata.
- Use `AbortController` to group listener cleanup.
- Watch for detached iframes and third-party destroy methods.
- Ignore isolated detached nodes unless they grow or retain large subtrees.
