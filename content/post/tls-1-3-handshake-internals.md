---
title: "TLS 1.3 Handshake Internals"
date: 2026-01-08T14:40:00-04:00
draft: false
featured: false
tags: [backend, tls, security, cryptography, networking]
---

## What TLS 1.3 changed and why it matters

TLS 1.3 (RFC 8446) is not an incremental tweak of TLS 1.2. It is a redesign that removed a decade of accumulated insecurity and shaved a full round trip off connection setup. The two headline numbers: a full handshake costs one round trip (1-RTT) instead of two, and resumed connections can send application data immediately (0-RTT). To understand how it achieves this, you need to follow the messages and the key derivation in lockstep.

The redesign also took an opinionated stance on cryptography. TLS 1.2 was a museum of negotiable options, many of them broken: RSA key exchange, CBC mode ciphers vulnerable to padding oracles, RC4, compression (CRIME), renegotiation. TLS 1.3 deleted all of it. The only public-key exchange is ephemeral Diffie-Hellman (PSK modes aside), the only bulk ciphers are AEAD constructions, and the cipher suite no longer bundles the key exchange and signature algorithm together.

## The 1-RTT full handshake

The central insight is that TLS 1.2 wasted a round trip negotiating which key exchange group to use before doing the key exchange. TLS 1.3 makes the client guess. In its very first message, the client sends not just the list of groups it supports, but an actual ephemeral public key (a `key_share`) for the group it thinks the server will pick.

{{< mermaid >}}
sequenceDiagram
    participant C as Client
    participant S as Server
    C->>S: ClientHello + key_share + supported groups
    Note over S: Pick group, compute shared secret
    S->>C: ServerHello + key_share
    Note over S: Now encrypted under handshake keys
    S->>C: EncryptedExtensions, Certificate
    S->>C: CertificateVerify, Finished
    Note over C: Verify cert + signature
    C->>S: Finished + Application Data
{{< /mermaid >}}

Walk through it message by message:

1. **ClientHello** carries supported cipher suites, the `supported_groups` extension, the `key_share` extension (one or more ephemeral DH public keys), `signature_algorithms`, and a random nonce.
2. The server picks a group it supports from the offered shares. If the client guessed right, the server can immediately compute the shared secret. The **ServerHello** returns the server's matching `key_share` and the chosen cipher suite.

At this point both sides can compute the same Diffie-Hellman shared secret. Everything after ServerHello is encrypted. That is a major change from TLS 1.2, where the certificate was sent in the clear.

3. The server sends **EncryptedExtensions**, its **Certificate**, a **CertificateVerify** (a signature over the entire handshake transcript proving it holds the certificate's private key), and a **Finished** message (an HMAC over the transcript proving the handshake was not tampered with).
4. The client verifies the certificate chain and the CertificateVerify signature, sends its own **Finished**, and can append application data in the same flight.

That is one round trip from the client's perspective before it sends real data.

### What if the client guesses the group wrong?

If the client offered no `key_share` for any group the server is willing to use, the server responds with a **HelloRetryRequest** telling the client which group to use. The client retries with a correct `key_share`. This costs an extra round trip, so it falls back to effectively 2-RTT, but it only happens on a mismatch.

## Key derivation: the HKDF schedule

TLS 1.3's security rests on a structured key derivation tree built from HKDF (HMAC-based Key Derivation Function). Every key in the connection descends from this schedule. The schedule takes inputs at three stages and chains them.

```text
            0
            |
PSK ----> HKDF-Extract = Early Secret
            |
            +--> derive binder / early traffic keys
            |
         Derive-Secret
            |
(EC)DHE -> HKDF-Extract = Handshake Secret
            |
            +--> client_handshake_traffic_secret
            +--> server_handshake_traffic_secret
            |
         Derive-Secret
            |
            0 -> HKDF-Extract = Master Secret
            |
            +--> client_application_traffic_secret
            +--> server_application_traffic_secret
            +--> resumption_master_secret
```

Two HKDF operations do all the work:

- **HKDF-Extract(salt, input)** mixes a new entropy source (a PSK or the DH output) into the running secret.
- **HKDF-Expand-Label(secret, label, context, length)** derives a specific, named key for a specific purpose from a secret.

The labels matter for security. Because each derived key is bound to a unique label and to a hash of the handshake transcript so far, keys for different purposes can never collide, and any tampering with handshake messages changes the transcript hash and therefore every subsequent key. This is how the Finished message can authenticate the entire conversation.

The chaining also gives **forward secrecy**. The handshake secret depends on the ephemeral DH output, which is discarded after the handshake. Compromising the server's long-term certificate private key later does not let an attacker decrypt past sessions, because that key only signs; it never participates in deriving the traffic keys.

## Session resumption and PSKs

After a successful handshake, the server can send one or more **NewSessionTicket** messages. A ticket encodes (or references) a pre-shared key (PSK) derived from the `resumption_master_secret`. On a later connection, the client offers this PSK in its ClientHello via the `pre_shared_key` extension, and the two sides can skip certificate exchange entirely, because the PSK already authenticates the relationship.

| Mode | Round trips before app data | Authentication | Forward secrecy |
|------|----------------------------|----------------|-----------------|
| Full handshake | 1-RTT | Certificate + signature | Yes (ephemeral DH) |
| HelloRetryRequest | 2-RTT | Certificate + signature | Yes |
| PSK resumption | 1-RTT | PSK | Yes if combined with DHE |
| PSK + 0-RTT | 0-RTT for early data | PSK | No for early data |

## 0-RTT and its sharp edge

0-RTT is the most exciting and most dangerous feature. When resuming with a PSK, the client can encrypt application data using the early traffic secret and send it in the very first flight, alongside the ClientHello, before the server has responded at all.

{{< mermaid >}}
sequenceDiagram
    participant C as Client
    participant S as Server
    C->>S: ClientHello + PSK + early_data (0-RTT app data)
    Note over S: Decrypt early data with early secret
    S->>C: ServerHello + EncryptedExtensions
    S->>C: Finished
    C->>S: Finished + more application data
{{< /mermaid >}}

The danger is **replay**. The early data is not protected by the fresh handshake nonce exchange, so a network attacker can capture the 0-RTT flight and resend it. A malicious replay of `GET /page` is harmless, but a replay of `POST /transfer?amount=1000` is not. The protocol cannot prevent replay by itself; it pushes the responsibility to the application.

The practical rule: only put **idempotent, non-state-changing** requests in 0-RTT data. In HTTP terms, allow 0-RTT for safe methods like GET and reject it for anything that mutates state, or implement server-side anti-replay (single-use tickets, a bounded replay-detection window). Many servers expose this as a config flag, and frameworks let you read whether a given request arrived as early data so you can decide per-route.

## Operational implications

A few internals translate directly into operational choices:

```text
- Prefer X25519 in supported_groups for fast, side-channel-resistant DH.
- Keep session ticket lifetimes short; long-lived tickets widen the 0-RTT
  replay window and weaken forward secrecy of resumption.
- Rotate the ticket-encryption key (STEK) regularly across your fleet,
  and share it carefully so resumption works behind a load balancer.
- Disable 0-RTT for non-idempotent endpoints.
```

The certificate is now encrypted, which improves privacy but means passive middleboxes that used to inspect the server cert no longer can. That same property is what motivated Encrypted Client Hello (ECH), which extends the design to also encrypt the SNI in the ClientHello.

The throughline of TLS 1.3 is that it removed choices that could be wrong and reorganized the message flow so that the client commits to a key exchange immediately. The HKDF schedule ties every key to the full transcript, giving both authentication and forward secrecy for free, and resumption layers a PSK on top of the same machinery. Understanding the key schedule is the single most useful thing, because every property of the protocol, from forward secrecy to 0-RTT replay, falls out of which secrets feed into which derived keys.
