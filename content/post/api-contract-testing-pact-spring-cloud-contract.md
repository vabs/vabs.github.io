---
title: "API Contract Testing with Pact and Spring Cloud Contract"
date: 2026-05-02T11:27:48-04:00
draft: false
featured: false
tags: [backend, testing, microservices, contract-testing, ci-cd]
---

## The Integration Testing Gap

You have two services: a `consumer` (say, a web BFF) and a `provider` (an `orders` API). How do you guarantee they actually work together? The traditional answer is **end-to-end integration tests**: spin up both services, plus their databases, plus their dependencies, and exercise real requests. This works until it doesn't. E2E suites are slow, flaky, expensive to maintain, and they scale combinatorially badly. With `N` services, the number of integration paths explodes, and a single deployment can require coordinating the whole graph.

The alternative is **contract testing**. Instead of testing the real provider, the consumer tests against a recorded **contract** describing exactly the requests it makes and the responses it expects. The provider is then verified independently against that same contract. Each side is tested in isolation, fast and deterministically, yet you retain a strong guarantee that they will integrate. This post covers the two dominant frameworks — Pact and Spring Cloud Contract — their philosophies, and how to wire them into CI.

## Consumer-Driven vs Provider-Driven

The first conceptual fork is *who owns the contract*.

| Approach | Who defines the contract | Best when |
|----------|-------------------------|-----------|
| Consumer-driven | The consumer, from its real usage | Provider serves known internal consumers |
| Provider-driven | The provider, as a published spec | Public API, many unknown consumers |

**Consumer-driven contract testing (CDC)** is the more powerful idea. The consumer expresses *only what it actually uses* from the provider's API. The provider then verifies it satisfies the union of all its consumers' contracts. This flips the usual relationship: the provider learns precisely which fields and endpoints are truly depended upon, so it can change everything else freely. Pact is built around this philosophy.

{{< mermaid >}}
graph LR
  A["Consumer test runs<br/>against mock provider"] --> B["Generates pact file<br/>(the contract)"]
  B --> C["Publish to broker"]
  C --> D["Provider fetches contract"]
  D --> E["Provider verifies<br/>real responses match"]
  E --> F{"All interactions<br/>satisfied?"}
  F -- "Yes" --> G["Safe to deploy"]
  F -- "No" --> H["Break the build"]
{{< /mermaid >}}

## Pact: How It Works

Pact is consumer-driven and polyglot (JVM, JS, Go, Python, .NET share one wire format). The flow has two distinct phases.

### Phase 1: Consumer Side

The consumer writes a test against a **Pact mock server**. It declares the expected interaction — request and response — and runs its real client code against the mock. If the client behaves as declared, Pact emits a **pact file** (JSON) describing the interaction.

```javascript
const provider = new PactV3({ consumer: 'web-bff', provider: 'orders-api' });

provider
  .given('order 42 exists')              // provider state
  .uponReceiving('a request for order 42')
  .withRequest({ method: 'GET', path: '/orders/42' })
  .willRespondWith({
    status: 200,
    headers: { 'Content-Type': 'application/json' },
    body: {
      id: like(42),                      // matcher: any integer
      status: term({ matcher: 'PAID|PENDING', generate: 'PAID' }),
      total: like(99.5)
    }
  });

await provider.executeTest(async (mock) => {
  const order = await fetchOrder(mock.url, 42);   // real client code
  expect(order.status).toBe('PAID');
});
```

Notice the **matchers** — `like`, `term`, `eachLike`. The contract does not pin exact values (`42`); it pins *shape and type*. This is essential: the provider must be free to return a different order ID without breaking the contract. Contract tests verify structure, not specific data.

### Phase 2: Provider Side

The generated pact is published to a **Pact Broker**. The provider's CI fetches all pacts naming it as provider and replays each interaction against the *real* running provider, asserting the actual responses match.

```java
@Provider("orders-api")
@PactBroker(url = "https://broker.internal")
class OrdersContractTest {

  @State("order 42 exists")
  void seedOrder42() {
    repository.save(new Order(42, "PAID", 99.5));   // set up provider state
  }

  @TestTemplate
  @ExtendWith(PactVerificationInvocationContextProvider.class)
  void verify(PactVerificationContext ctx) {
    ctx.verifyInteraction();
  }
}
```

The `@State` hook is the bridge: each interaction declares a `given(...)` provider state, and the provider implements a matching setup so the data exists when the request replays.

## Spring Cloud Contract: How It Works

Spring Cloud Contract (SCC) defaults to a **provider-driven** model and is JVM-centric. The provider authors contracts in a Groovy or YAML DSL. From those, SCC does two things:

1. **Generates provider verification tests** automatically, which run against the real provider (using MockMvc, WebTestClient, or an explicit base).
2. **Produces a stub** (a WireMock JSON mapping) published as a Maven artifact, which consumers download and run their tests against.

```groovy
Contract.make {
    request {
        method 'GET'
        url '/orders/42'
    }
    response {
        status 200
        headers { contentType(applicationJson()) }
        body(
            id: 42,
            status: 'PAID',
            total: 99.5
        )
        bodyMatchers {
            jsonPath('$.id', byType())
            jsonPath('$.status', byRegex('PAID|PENDING'))
        }
    }
}
```

On `build`, SCC generates a JUnit test asserting the provider returns this for `GET /orders/42`, and packages a stub jar. The consumer then declares a dependency on that stub and uses `@AutoConfigureStubRunner` to launch WireMock backed by it:

```java
@SpringBootTest
@AutoConfigureStubRunner(
    ids = "com.acme:orders-api:+:stubs:8090",
    stubsMode = StubRunnerProperties.StubsMode.REMOTE)
class WebBffStubTest {
  @Test
  void fetchesOrder() {
    Order o = client.getOrder(42);    // hits WireMock stub on :8090
    assertThat(o.getStatus()).isEqualTo("PAID");
  }
}
```

## Pact vs Spring Cloud Contract

| Dimension | Pact | Spring Cloud Contract |
|-----------|------|----------------------|
| Default direction | Consumer-driven | Provider-driven |
| Languages | Polyglot (shared format) | JVM-centric |
| Contract authored by | Consumer (as code) | Provider (DSL) |
| Sharing mechanism | Pact Broker | Maven stub artifacts / Git |
| Consumer mock | Pact mock server | WireMock stub |
| Best fit | Mixed-language orgs, many consumers | Spring shops, monorepo or Maven-native |

The deciding factors in practice: if your fleet is polyglot and you want consumers to drive the contracts, Pact fits. If you are a Spring/Maven shop and prefer providers to publish a spec consumers code against, SCC fits naturally into your build.

## The Critical CI Piece: Can-I-Deploy

A contract testing setup is only as good as its deployment gate. The dangerous scenario: the provider verified an *old* contract, then changed, and a consumer relies on the new behavior — or vice versa. You must answer "is the version I am about to deploy compatible with what is *already deployed* on the other side?"

Pact's broker answers this with **`can-i-deploy`**. The broker tracks which versions of each consumer and provider have been verified against each other, tagged by environment.

```bash
pact-broker can-i-deploy \
  --pacticipant web-bff \
  --version "$GIT_SHA" \
  --to-environment production
# exits 0 only if this consumer version is verified
# against the provider version currently in production
```

{{< mermaid >}}
graph TD
  A["Consumer CI: publish pact"] --> B["Provider CI: verify pact"]
  B --> C["Broker records<br/>verification result"]
  C --> D["Deploy pipeline:<br/>can-i-deploy?"]
  D -- "Compatible" --> E["Deploy"]
  D -- "Incompatible" --> F["Block deploy"]
{{< /mermaid >}}

This is what makes contract testing safe for **independent deployment**. Without a compatibility gate, you have recorded contracts but no enforcement that the live systems agree.

## Pitfalls and Discipline

- **Contracts are not schema validation.** A contract proves the consumer and provider agree on the interactions the consumer *uses*. It does not validate the provider's full API surface; fields no consumer reads are untested by design.
- **Over-specifying breaks flexibility.** Pinning exact values instead of matchers turns the provider's data into part of the contract, causing false failures. Match types and patterns, not literals.
- **Provider states must be honest.** If the `given` state setup diverges from production reality, you verify against fiction. Keep state setup minimal and faithful.
- **You still need a few E2E tests.** Contract testing covers pairwise integration superbly but does not catch issues spanning three-plus services, infrastructure config, or auth wiring. Keep a thin smoke-test layer.
- **Versioning the broker correctly.** Tag verifications by environment and use the git SHA as the version, or `can-i-deploy` gives you misleading answers.

## Closing Thought

Contract testing trades a small amount of up-front discipline — writing and publishing contracts, wiring a broker — for the elimination of brittle, slow, combinatorial E2E suites and, crucially, the ability to deploy services independently with confidence. The framework matters less than the workflow: consumers and providers agree on a shared, executable contract, each side is verified in isolation, and a compatibility gate refuses any deployment that would break the pact. Get that loop running in CI and "did my change break a downstream service?" becomes a question your pipeline answers automatically, before production ever finds out.
