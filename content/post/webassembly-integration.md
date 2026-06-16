---
title: "WebAssembly integration"
date: 2026-01-08T09:00:00-04:00
draft: false
tags: [frontend, webassembly, wasm, performance, javascript]
---

WebAssembly integration is not "rewrite the frontend in Rust." In a browser application it is usually a narrow acceleration boundary: JavaScript keeps ownership of UI, routing, networking, storage, and orchestration, while a WebAssembly module owns a small deterministic core such as parsing, image processing, compression, cryptography, simulation, or rules evaluation.

The useful mental model is a foreign function interface inside the page. Calls cross from JavaScript into a linear memory owned by the module. That crossing has overhead. The module is fast once it is running, but strings, objects, callbacks, and DOM access still live on the JavaScript side. Good integrations therefore minimize crossings and move batches of primitive data through memory.

{{< mermaid >}}
flowchart LR
  UI[React/Vue/Svelte UI] --> JS[JS adapter]
  JS -->|copy or view bytes| MEM[Wasm linear memory]
  JS -->|call exported fn| WASM[Wasm module]
  WASM --> MEM
  WASM -->|status/result ptr| JS
  JS --> UI
{{< /mermaid >}}

## Internals that matter

A `.wasm` file exports functions and optionally memory. JavaScript loads it with `WebAssembly.instantiateStreaming` when the server returns `application/wasm`; otherwise it falls back to fetching an `ArrayBuffer` and compiling it. Framework bundlers wrap this with generated glue, but the runtime shape is the same.

Linear memory is a resizable `ArrayBuffer`. The module sees offsets, not JavaScript objects. If a function accepts text, the adapter usually UTF-8 encodes the string into memory, passes pointer plus length, and decodes the returned region later. That is why a naive "call Wasm for every row" port can get slower than plain JavaScript. The CPU wins are erased by serialization and allocation.

The module cannot touch the DOM directly. It can import JavaScript functions, but every imported call is another boundary crossing. Prefer a design where Wasm computes a compact result and JavaScript renders it.

## Practical integration pattern

Create an adapter module that hides allocation, encoding, and lifecycle:

```js
let instance;

export async function loadEngine() {
  if (instance) return instance;
  const response = await fetch("/assets/engine.wasm");
  const result = await WebAssembly.instantiateStreaming(response, imports);
  instance = result.instance;
  return instance;
}
```

Keep the rest of the app talking to domain functions, not pointers. For example, expose `parseDocument(bytes)` instead of `malloc`, `parse`, and `free` across the codebase. If the module uses generated bindings such as `wasm-bindgen`, still keep a local facade. Generated APIs are convenient, but they are not a good long-term application boundary.

For large inputs, prefer `Uint8Array` and memory views. For repeated work, allocate a reusable workspace in Wasm memory rather than allocating per call. For UI responsiveness, load and run the module inside a Web Worker when operations can exceed a frame budget.

Design the boundary around batches, not tiny method calls. If the module parses a document, pass the whole byte buffer and return a compact result index. If it scores search candidates, pass arrays of ids and features, then return ranked ids. Calling into Wasm once per row, once per character, or once per DOM node usually loses to JavaScript because the boundary overhead dominates.

Memory ownership should be explicit. A low-level module may export `malloc` and `free`; generated bindings may hide them. Either way, the application adapter should define who owns input and output buffers. If JavaScript allocates a buffer in Wasm memory, it should free it after the call or hand it to an object with a clear `dispose()` method. If Wasm returns a pointer, JavaScript should copy or view the result before freeing the region.

```js
export async function parseBytes(bytes) {
  const { exports } = await loadEngine();
  const ptr = exports.alloc(bytes.byteLength);
  new Uint8Array(exports.memory.buffer, ptr, bytes.byteLength).set(bytes);
  const resultPtr = exports.parse(ptr, bytes.byteLength);
  const result = readResult(exports.memory, resultPtr);
  exports.free_result(resultPtr);
  exports.free(ptr, bytes.byteLength);
  return result;
}
```

The adapter is intentionally boring. It concentrates pointer arithmetic in one place and gives the UI a normal promise-returning function. That makes it easier to swap toolchains, change memory layout, or move execution into a Worker later.

For streaming inputs, consider whether Wasm needs the entire payload. Some codecs, parsers, and hashers can accept chunks and maintain module-side state. That avoids building huge intermediate arrays in JavaScript. The tradeoff is a more complex lifecycle: create context, update with chunks, finalize, free context, and handle errors at every step.

## Failure modes

The most common production failure is MIME type. `instantiateStreaming` fails if the CDN serves Wasm as `application/octet-stream`. Another is incorrect asset paths after deploying under a subpath. Treat the Wasm file like a hashed chunk and verify it is emitted by the bundler where the runtime expects it.

Memory growth can also invalidate old JavaScript typed-array views. If the module calls `memory.grow`, recreate views before reading or writing. Watch for leaks when the module exposes explicit `free` semantics; garbage collection does not automatically reclaim module-side heap allocations unless the binding layer implements finalizers.

Debugging is better when you separate loader, adapter, and call-site concerns. Check the network response, log the module exports, assert input byte lengths, and benchmark with realistic batches. Chrome DevTools can show Wasm call stacks and profiling samples, but the first bug is usually at the boundary.

Version skew is another common issue. JavaScript glue generated for one Wasm binary may call exports that do not exist in another. This can happen when a CDN caches the `.wasm` file differently from the JS chunk or when a service worker serves stale assets. Hash both artifacts, precache them as a unit, and fail loudly if expected exports are missing.

Exceptions and panics need translation. A Rust panic, C++ abort, or unreachable instruction may surface as a generic `RuntimeError`. Add a narrow error layer that converts module failures into application errors with operation name, input size, module version, and browser support details. Avoid dumping raw user data into logs.

Threaded Wasm adds another set of constraints: it usually depends on `SharedArrayBuffer`, cross-origin isolation, and Worker setup. Before adopting it, verify deployment headers, third-party script compatibility, and fallback behavior for browsers or embedded contexts that cannot be isolated.

## Performance measurement

Benchmark three numbers separately: JavaScript baseline, Wasm compute time, and boundary time. A module can be 10x faster internally and still lose overall if every call encodes strings, reallocates memory, and decodes large JSON results. Use production-shaped inputs and warm the module before measuring steady-state behavior.

Measure startup too. Compiling and instantiating a large module can hurt route performance if done during initial render. Lazy-load modules behind user intent, prefetch them after the main interaction path is stable, or instantiate in a Worker while the UI remains responsive. Cache the compiled module where the platform and bundler make that practical.

For UI work, frame budget matters more than total throughput. A 120 ms parse may be acceptable in a Worker with a progress indicator; the same parse on the main thread feels broken. If the module cannot complete within a frame and the result is not immediately required for input, keep it off the main thread.

## Checklist

- Use Wasm for compute-heavy, deterministic, non-DOM work.
- Batch calls and pass bytes or numeric arrays instead of object graphs.
- Hide pointers and memory management behind a JavaScript adapter.
- Serve `.wasm` with `application/wasm`.
- Recreate typed-array views after memory growth.
- Move long-running Wasm work into a Worker.
- Benchmark boundary overhead, not just inner-loop speed.
