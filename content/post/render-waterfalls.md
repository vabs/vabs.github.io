---
title: "Render waterfalls"
date: 2026-04-28T09:40:00-04:00
draft: false
tags: [frontend, rendering, performance, data-fetching, diagnostics]
---

## Mental model: sequential work hiding in a tree

A render waterfall happens when work that could have run in parallel is discovered sequentially during rendering. Component A renders, starts a fetch, waits, then renders child B, which starts another fetch, waits, then renders child C. The UI may look componentized, but the latency graph is a linked list.

Waterfalls are not limited to network requests. Code splitting, image discovery, font loading, server component fetches, client effects, and even permissions checks can all create sequential dependency chains. The important signal is not "many things loaded"; it is "the next thing could not even be discovered until the previous thing finished."

{{< mermaid >}}
sequenceDiagram
    participant Render
    participant API
    Render->>API: fetch user
    API-->>Render: user
    Render->>API: fetch projects for user
    API-->>Render: projects
    Render->>API: fetch tasks for first project
    API-->>Render: tasks
    Render-->>Render: finally paint complete view
{{< /mermaid >}}

In a trace, a waterfall often looks like tidy, reasonable code. A profile page fetches a user, the projects component fetches projects, and the task list fetches tasks. Each component owns its data, so nothing feels obviously wrong locally. The page-level latency, however, is the sum of each round trip plus parsing and rendering between them. On a 40 ms office network that may be acceptable. On a 180 ms mobile path with TLS warmup and a cold CDN edge, it becomes visibly slow.

## Internals

Frameworks render trees top-down. If data fetching is hidden inside components and only starts when that component renders, the parent controls when the child even gets a chance to begin. This is convenient for colocation, but it can serialize independent work. The renderer does not know that a grandchild will need `/api/permissions` until the grandchild exists. If the parent suspends, awaits, or renders a loading state first, discovery of that grandchild is delayed.

On the client, `useEffect` fetches are a common source. Effects run after paint, so a component may first render a loading state, then start a request, then render children that start their own effects. On the server, awaiting data in a parent before rendering children can create the same shape.

Waterfalls also happen through bundles. A route loads JavaScript, discovers a lazy component, loads its chunk, then that component discovers another lazy child. Each discovery waits for the previous execution. The same applies to CSS and images: if the browser cannot see an image URL until JavaScript renders a carousel, preload scanning cannot help.

There are three kinds of edges in the dependency graph:

- Data edges: request B genuinely needs a value from response A.
- Discovery edges: request B is independent but hidden behind rendering A.
- Resource edges: code, CSS, font, or image B is referenced only after resource A executes or parses.

Only the first kind is inherently sequential. The other two are design artifacts, and they are usually where the biggest wins are.

## Practical patterns

Fetch as early as correctness allows. Route loaders, server components, query preloading, and intent-based prefetching all start work before the leaf component renders. Keep data ownership clear, but do not confuse ownership with late discovery. A route can preload the user, projects, feature flags, and notifications while still letting the components read those results through their normal query hooks.

Model data dependencies explicitly. If projects and notifications both require only the user id from the URL, start them in parallel. If tasks require selected project id from the projects response, that edge is genuinely sequential. Optimize real dependencies, not imagined ones.

Use request deduplication so early fetching and component reads do not duplicate network calls. A query cache or server fetch cache lets route-level preloading coexist with component-level data access.

For code, avoid deeply nested lazy boundaries for above-the-fold UI. Preload critical chunks on navigation intent. Split heavy rarely used panels, not every component by habit.

For images and fonts, give the browser discoverable hints. Put the primary image in HTML when possible, use `preload` for critical fonts with matching `crossorigin`, and avoid hiding above-the-fold media behind client-only rendering. If an image depends on data, consider sending a small server-rendered shell with the URL so the preload scanner can start before the client bundle runs.

A useful implementation pattern is "declare, then read." At the route level, declare the possible work:

```js
const userPromise = queryClient.ensureQueryData(userQuery(userId));
const projectsPromise = queryClient.ensureQueryData(projectsQuery(userId));
const flagsPromise = queryClient.ensureQueryData(flagsQuery(accountId));

await Promise.all([userPromise, projectsPromise, flagsPromise]);
```

Components still call `useQuery(userQuery(userId))`, but the request is already in flight or fulfilled. This keeps component APIs local while moving discovery earlier.

On the server, avoid:

```js
const user = await getUser(id);
const projects = await getProjects(user.id);
const flags = await getFlags(user.accountId);
```

when `projects` and `flags` do not depend on each other. Start what you can before awaiting:

```js
const user = await getUser(id);
const projectsPromise = getProjects(user.id);
const flagsPromise = getFlags(user.accountId);
const [projects, flags] = await Promise.all([projectsPromise, flagsPromise]);
```

## Failure modes

The common failure is fixing one waterfall by centralizing all data in a giant route loader. That can overfetch and make every page wait for data only one tab needs. A better fix is parallel preloading with scoped consumption.

Another failure is prefetching without invalidation. If prefetched data sits too long, the user sees stale state. Attach freshness windows and revalidation rules to preloaded queries.

Waterfalls can be masked by fast local networks. They become production problems on mobile latency, cold caches, or cross-region APIs. Always inspect production-like traces.

Be careful with "fixes" that move latency rather than remove it. Prefetching every likely route after page load may improve the next click but degrade the current page, burn mobile data, and pressure the HTTP connection pool. Use intent signals, route probability, data size, and freshness to decide what deserves early work.

Also watch authorization waterfalls. A page fetches the user, then roles, then permissions, then allowed resources. If the backend can return an authorization envelope with the first response, the client can avoid multiple gatekeeping round trips.

## Debugging and diagnostics

Use browser performance traces and network waterfalls. Look for requests whose start time is immediately after another request's end time. In application logs, add parent request ids and data dependency labels so server-side waterfalls are visible.

React and framework profilers can show repeated loading renders. For server rendering, `Server-Timing` headers are useful: include named durations for user, projects, recommendations, and render.

When debugging, write down each request with four fields: earliest possible start time, actual start time, dependency, and owner. If actual start is later than earliest possible start, you have avoidable discovery delay. If the dependency is real, optimize the upstream response or change the API shape.

Synthetic throttling helps. Use network latency high enough that sequencing is obvious, then record a cold navigation. Disable cache, clear service worker state if relevant, and test both direct page load and in-app navigation. Many apps have no waterfall on first SSR load but create one on client transitions because loaders are bypassed or chunks are discovered differently.

Server-side diagnostics need the same rigor. Log child spans for each data source with a shared render id. If the spans do not overlap, ask whether the code made them sequential. Expose a compact `Server-Timing` header in non-sensitive environments:

```http
Server-Timing: user;dur=82, projects;dur=140, flags;dur=35, render;dur=41
```

If `projects` starts only after `user` finishes, the trace should make that visible.

## Checklist

- Draw the dependency graph before optimizing.
- Start independent data requests in parallel.
- Avoid effect-only fetching for critical above-the-fold data.
- Use caches to dedupe preload and component reads.
- Preload critical route chunks on navigation intent.
- Measure under cold cache and high latency.
- Prefer scoped parallelism over one giant loader.
- Check images, fonts, and lazy chunks for late discovery.
- Add timing labels that distinguish real dependencies from discovery delays.
- Keep freshness and invalidation rules attached to preloaded data.
