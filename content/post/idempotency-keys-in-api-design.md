---
title: "Idempotency Keys in API Design"
date: 2026-04-15T10:45:00-04:00
draft: false
featured: false
tags: [backend, api-design, idempotency, reliability, http]
---

Networks fail in the most inconvenient way possible: not by losing the request, but by losing the *response*. The client sends "charge this card $50," the server charges it, and then the acknowledgment vanishes into a dropped connection. The client, seeing no answer, retries. Without protection, the customer is charged twice. Idempotency keys are the standard, battle-tested mechanism for making "retry safely" a first-class property of your API. This post covers what they guarantee, how to implement them correctly, and the subtle failure modes that trip up most first attempts.

## The problem idempotency keys solve

An operation is *idempotent* if performing it multiple times has the same effect as performing it once. `GET`, `PUT`, and `DELETE` are idempotent by HTTP's definition. `POST` is not — and most state-changing operations (create a payment, place an order, send an email) are naturally `POST`-shaped and naturally non-idempotent.

The danger zone is the gap between a side effect committing and the client learning that it committed.

{{< mermaid >}}
sequenceDiagram
  participant C as "Client"
  participant S as "Server"
  participant DB as "Database"
  C->>S: POST /charges ($50)
  S->>DB: insert charge
  DB-->>S: committed
  S--xC: response lost (timeout)
  Note over C: no response, assume failure
  C->>S: POST /charges ($50) [retry]
  S->>DB: insert charge AGAIN
  DB-->>S: committed
  S-->>C: 200 OK
  Note over DB: customer charged twice
{{< /mermaid >}}

The client did nothing wrong. Retrying on timeout is correct behavior. The server's job is to recognize the retry as a duplicate of work it already did and return the *original* result instead of doing the work again.

## What an idempotency key is

An idempotency key is a client-generated unique token, sent with a request, that the server uses to deduplicate. The contract is simple and powerful:

> For a given idempotency key, the server performs the operation **at most once** and returns the **same response** for every request carrying that key.

The client generates a fresh key (typically a UUID) for each *logical* operation and reuses that same key across all retries of that operation. The convention, popularized by Stripe, is an HTTP header:

```http
POST /v1/charges HTTP/1.1
Idempotency-Key: 7c9e6679-7425-40de-944b-e07fc1f90ae7
Content-Type: application/json

{"amount": 5000, "currency": "usd", "source": "tok_visa"}
```

The key belongs to the *operation*, not the request. A retry is the same operation, so it reuses the key. A genuinely new charge is a new operation, so it gets a new key.

## The naive implementation and why it breaks

A first attempt usually looks like this:

```python
def create_charge(key, payload):
    if store.exists(key):
        return store.get_response(key)   # already done
    result = do_charge(payload)           # side effect
    store.save(key, result)               # remember it
    return result
```

This has a race: two concurrent requests with the same key both pass the `exists` check before either has saved, and both execute `do_charge`. Concurrency is not hypothetical here — aggressive client retries and load balancers replaying requests are *exactly* the situation idempotency keys exist for, so the duplicates arrive simultaneously by nature.

The fix is to claim the key atomically *before* doing any work, using the database's uniqueness guarantee as the lock.

## A correct implementation

The robust pattern uses three states per key — `started`, `succeeded`, `failed` — and an atomic insert to claim the key.

```python
def create_charge(key, payload, payload_hash):
    # 1. Atomically claim the key. Unique constraint on idempotency_key.
    row = idempotency.try_insert(
        key=key,
        request_hash=payload_hash,
        state="started",
    )

    if row is None:  # key already exists
        existing = idempotency.get(key)

        # 2. Guard against key reuse with a different body.
        if existing.request_hash != payload_hash:
            raise Conflict("Idempotency key reused with different payload")

        # 3. If the original finished, replay its stored response.
        if existing.state in ("succeeded", "failed"):
            return existing.response

        # 4. Original still in flight -> tell client to retry later.
        raise Conflict("Request with this key is still processing")

    # 5. We own the key. Do the work and persist the result atomically.
    try:
        result = do_charge(payload)
        idempotency.update(key, state="succeeded", response=result)
        return result
    except DomainError as e:
        idempotency.update(key, state="failed", response=e.to_response())
        return e.to_response()
```

The flow, including the concurrent case:

{{< mermaid >}}
stateDiagram-v2
  [*] --> Claiming
  Claiming --> Started: insert succeeded (we own it)
  Claiming --> Exists: insert conflict (someone else owns it)
  Started --> Succeeded: work done
  Started --> Failed: domain error
  Exists --> Replay: original finished
  Exists --> Retry409: original in flight
  Succeeded --> [*]
  Failed --> [*]
  Replay --> [*]
  Retry409 --> [*]
{{< /mermaid >}}

Several design choices in that code are load-bearing.

### Store the request fingerprint

By hashing the request body and storing it with the key, you catch a dangerous client bug: reusing one idempotency key for two *different* requests. If the bodies differ, the second request is not a retry — it is a mistake — and returning the first response would be silently wrong. Rejecting with `409 Conflict` surfaces the bug instead of hiding it.

### Persist response and side effect in one transaction

The single most important correctness property: the side effect and the recorded outcome must commit *together*. If you charge the card and then crash before saving `succeeded`, the retry will charge again. Where possible, write the idempotency record in the same database transaction as the side effect:

```sql
BEGIN;
  INSERT INTO charges (...) VALUES (...);
  UPDATE idempotency_keys
     SET state = 'succeeded', response = :resp
   WHERE key = :key;
COMMIT;
```

When the side effect lives in an external system (a payment processor) that you cannot enlist in your transaction, you need an additional handle from that system — pass *your* idempotency key down to the processor too, so the duplicate is caught at the bottom of the stack as well.

### Cache failures, but choose carefully

Should a `failed` outcome be replayed? It depends on the failure class. A *deterministic* failure (card declined, validation error) should be replayed — retrying will only decline again, and replaying gives a stable answer. A *transient* failure (downstream timeout, 503) should **not** be cached as terminal, because the retry might succeed. Mark transient failures so the key can be re-attempted:

| Failure type | Cache as terminal? | On retry |
|--------------|-------------------|----------|
| Validation / business rule | Yes | Replay stored error |
| Card declined | Yes | Replay stored decline |
| Downstream timeout | No | Re-execute |
| 5xx from dependency | No | Re-execute |

## Lifecycle and storage concerns

Idempotency records are not forever. A reasonable retention window is 24 hours to a few days — long enough to cover any realistic retry storm, short enough to bound storage. Stripe expires keys after 24 hours, after which the same key starts a brand-new operation.

```sql
CREATE TABLE idempotency_keys (
  key           TEXT PRIMARY KEY,
  request_hash  TEXT NOT NULL,
  state         TEXT NOT NULL,      -- started | succeeded | failed
  response      JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL
);
CREATE INDEX ON idempotency_keys (expires_at);
```

Run a background sweep on `expires_at` to reclaim space. Scope keys per-account when relevant, so one tenant cannot collide with or probe another's keys; the primary key becomes `(account_id, key)`.

## Scope: what counts as "the same" operation

A frequent design error is scoping idempotency too broadly or too narrowly. The key should identify exactly one logical mutation. If a client wants to make ten distinct payments, that is ten keys, not one. If a client retries one payment ten times over a flaky connection, that is one key reused ten times. Make this explicit in your documentation, because clients will get it wrong otherwise — and a client that recycles a single key for everything will see every payment after the first silently deduplicated into the first.

## Client responsibilities

Idempotency is a contract, and the client holds up one end:

- Generate the key **before** the first send, so all retries of the same logical action share it. Generating a new UUID inside the retry loop defeats the entire mechanism.
- Persist the key alongside the pending operation, so even a client crash-and-restart reuses the same key.
- Retry with backoff and a cap, treating `409 still processing` as "wait and retry," not "give up."

## Conclusion

Idempotency keys turn the unreliable, response-may-vanish reality of networks into a safe, retryable API. The mechanism is conceptually small — a client token plus server-side deduplication — but correctness hides in the details: claim the key atomically before doing work, fingerprint the request body to catch misuse, commit the side effect and its recorded outcome in one transaction, and distinguish deterministic failures from transient ones. Get those right and your clients can retry as aggressively as they like, confident that "send it again" never means "do it twice."
