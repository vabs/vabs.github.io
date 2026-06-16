---
title: "OAuth2 Token Introspection vs JWT Validation"
date: 2026-02-18T11:40:00-04:00
draft: false
tags: [backend, oauth2, jwt, security, authentication]
---

## Mental model

When a resource server receives an OAuth2 access token, it must answer one question before doing anything else: *is this token valid, and what does it authorize?* There are two fundamentally different ways to answer it.

The first is **local JWT validation**: the token is a self-contained, signed JSON Web Token. The resource server verifies the signature with the authorization server's public key and reads the claims directly. No network call.

The second is **token introspection** (RFC 7662): the token is opaque — a random string with no inherent meaning — and the resource server calls the authorization server's introspection endpoint to ask "what is this token?" The authorization server looks it up in its store and returns the metadata.

These represent a classic distributed-systems tradeoff: cached/replicated state (JWT) versus authoritative lookup (introspection). Latency versus freshness. Everything else follows from that.

{{< mermaid >}}
graph TD
    A["Resource server gets token"] --> B{"Token format?"}
    B -->|"Self-contained JWT"| C["Verify signature locally"]
    C --> D["Read claims, no network call"]
    B -->|"Opaque token"| E["POST to introspection endpoint"]
    E --> F["Authz server looks up token"]
    F --> G["Returns active + metadata"]
{{< /mermaid >}}

## JWT validation, step by step

A JWT access token has three base64url parts: header, payload, signature. The resource server's job:

1. Parse the header, read `alg` and `kid` (key ID).
2. Fetch the matching public key from the authorization server's JWKS endpoint (`/.well-known/jwks.json`), cached locally.
3. Verify the signature over `header.payload`.
4. Validate the standard claims: `exp` (not expired), `nbf` (not before), `iss` (expected issuer), `aud` (this resource server is an intended audience).
5. Apply authorization from `scope`/`roles`/custom claims.

```python
import jwt  # PyJWT
from jwt import PyJWKClient

jwks = PyJWKClient("https://issuer.example.com/.well-known/jwks.json")

def validate(token: str):
    signing_key = jwks.get_signing_key_from_jwt(token).key
    claims = jwt.decode(
        token,
        signing_key,
        algorithms=["RS256"],          # pin the algorithm
        audience="https://api.example.com",
        issuer="https://issuer.example.com",
        options={"require": ["exp", "iss", "aud"]},
    )
    return claims
```

The decisive property: **steps 3-5 are pure local computation.** Once the JWKS is cached, validating a token is microseconds of CPU with zero network dependency. Your API stays up even if the authorization server is down.

### The security footguns of JWT

JWTs are powerful and dangerous in equal measure.

- **`alg` confusion.** Never trust the token's own `alg` header to choose the verification algorithm. The infamous attack: server expects RS256 (asymmetric), attacker sends a token with `alg: HS256` and signs it using the *public* key as the HMAC secret. If your library naively uses the header's algorithm, it verifies. Always pin `algorithms=[...]` to an allowlist.
- **`alg: none`.** Some libraries historically accepted unsigned tokens. Reject `none` explicitly.
- **Skipping `aud`.** A token minted for service A must not be accepted by service B. Validate the audience.
- **Clock skew.** `exp`/`nbf` checks need a small leeway (e.g. 60s) or legitimate requests fail at boundaries.
- **Key rotation.** Cache JWKS but honor `kid` so you can fetch a new key when the issuer rotates without a deploy.

## Introspection, step by step

With opaque tokens, the resource server holds no secret material. It calls the introspection endpoint, authenticating itself as a client:

```http
POST /introspect HTTP/1.1
Host: issuer.example.com
Authorization: Basic <client_id:client_secret>
Content-Type: application/x-www-form-urlencoded

token=mF_9.B5f-4.1JqM&token_type_hint=access_token
```

The response is the authoritative current state:

```json
{
  "active": true,
  "scope": "read write",
  "client_id": "svc-orders",
  "sub": "user-42",
  "aud": "https://api.example.com",
  "exp": 1718900000
}
```

The single field that matters most is `active`. Per RFC 7662 a token is active only if it has been issued, has not expired, and has **not been revoked**. That last word is the whole point of introspection.

{{< mermaid >}}
sequenceDiagram
    participant C as Client
    participant RS as "Resource server"
    participant AS as "Authz server"
    C->>RS: "Request + opaque token"
    RS->>AS: "POST /introspect (token)"
    AS->>AS: "Look up + check revocation"
    AS-->>RS: "{active:true, scope, sub}"
    RS-->>C: "200 with protected resource"
{{< /mermaid >}}

## The core tradeoff: revocation vs latency

This is the entire decision in one sentence: **a JWT is valid until it expires; an introspected token is valid until the authority says otherwise.**

A signed JWT cannot be un-signed. Once you issue a JWT with a 1-hour `exp`, any resource server will accept it for that hour. If the user logs out, is fired, or the token is stolen, you cannot recall it through pure local validation — the signature still verifies. Your only mitigations are short lifetimes plus refresh tokens, or a revocation list that you check (which reintroduces a network/lookup dependency and erodes the "stateless" benefit).

Introspection has no such gap. The authorization server checks revocation on every call, so a revoked token stops working immediately. The price is a network round trip per request (or per cache window) and a hard runtime dependency on the authorization server.

| Dimension | Local JWT validation | Introspection |
|-----------|---------------------|---------------|
| Per-request latency | ~microseconds (CPU only) | network round trip |
| Authz server dependency | only for JWKS refresh | every request (or cache TTL) |
| Instant revocation | No (valid until exp) | Yes |
| Token size on wire | large (full claims) | small (random string) |
| Leak exposure window | until exp | until revoked |
| Offline operation | Yes | No |
| Where authority lives | issue time | request time |

## Caching introspection: the pragmatic middle

The latency cost of introspection is usually mitigated by caching results for a short TTL. This is a deliberate weakening: you trade some revocation immediacy for throughput. Cache the `active:true` result for, say, 30-60 seconds keyed by the token. Now revocation takes effect within one TTL window instead of instantly, but you avoid hammering the introspection endpoint.

```python
# cache active introspection results briefly
entry = cache.get(token)
if entry and entry.expires > now():
    return entry.claims
resp = introspect(token)
if resp["active"]:
    cache.set(token, resp, ttl=min(45, resp["exp"] - now()))
    return resp
raise Unauthorized()
```

Never cache `active:false` for long, and never cache past the token's own `exp`. This pattern converges the two models: introspection-with-cache behaves like JWT-with-short-TTL, just with the freshness knob on the server side instead of the issue side.

## Hybrid and phantom-token patterns

Real systems often combine both. A common architecture (the *phantom token* pattern) puts an API gateway at the edge:

1. Clients carry **opaque** tokens externally — small, leak-resistant, revocable.
2. The gateway introspects (or exchanges) the opaque token and forwards a short-lived **JWT** to internal services.
3. Internal services do fast local JWT validation, trusting the gateway's exchange.

This gives you external revocability and small public tokens *plus* internal statelessness and low latency. The revocation surface is concentrated at the gateway, and internal JWTs are so short-lived that their non-revocability barely matters.

## Choosing

- Pick **JWT validation** when you need horizontal scale, low latency, offline tolerance, and you can live with revocation that is bounded by short token lifetimes. Good for high-throughput microservice meshes.
- Pick **introspection** when revocation must be near-instant, tokens may be long-lived, or you cannot trust resource servers to validate signatures correctly. Good for sensitive operations and B2B APIs.
- Pick the **hybrid** when you want both — opaque outside, JWT inside.

Whatever you choose, get the boring details right: pin algorithms, validate `aud` and `iss`, honor `exp` with leeway, rotate keys via `kid`, and never trust a token's self-declared algorithm. The format debate is interesting; the validation discipline is what actually keeps you secure.

## Takeaways

JWT validation and introspection answer the same question with opposite architectures: replicate authority to the edge versus consult authority on demand. JWT wins on latency and availability but cannot instantly revoke. Introspection wins on revocation and control but adds a per-request dependency. Caching and the phantom-token pattern let you dial in a point between them. The right answer is whichever places the revocation/latency tradeoff where your threat model needs it.
