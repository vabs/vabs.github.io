---
title: "Binary Protocol Parsing"
date: 2026-04-30T10:51:27-04:00
draft: false
featured: false
tags: [backend, networking, protocols, parsing, performance]
---

## When Text Is Not Enough

Most application developers spend their careers parsing text: JSON bodies, HTTP headers, CSV files. But underneath all of that runs a layer of **binary protocols** — formats where meaning is encoded in the exact arrangement of bytes rather than human-readable characters. TCP/IP headers, TLS records, MySQL's wire protocol, Kafka's protocol, Redis's RESP, MessagePack, and Protobuf are all binary. If you build network servers, parsers, or high-throughput data pipelines, you eventually have to read bytes directly.

Binary parsing is exacting work. There is no whitespace to forgive a mistake, no closing brace to resynchronize on. One miscounted byte and every subsequent field is garbage. This post covers the building blocks: framing, endianness, length-prefixing, parsing state machines, and the security pitfalls that turn a sloppy parser into a vulnerability.

## The Fundamental Problem: Where Does a Message End?

TCP gives you a **stream of bytes**, not messages. It makes no promise that one `write` on the sender maps to one `read` on the receiver. A single `read` might return half a message, one and a half messages, or three messages glued together. The first job of any binary parser is **framing**: determining message boundaries within the byte stream.

There are three classic framing strategies.

| Strategy | How a message ends | Used by |
|----------|-------------------|---------|
| Fixed length | Every message is N bytes | Simple sensor protocols |
| Delimiter | A sentinel byte/sequence | RESP (`\r\n`), text protocols |
| Length prefix | A header states the body length | Most binary protocols |

**Length-prefixing** dominates serious binary protocols because it is unambiguous and allows the body to contain any byte value (delimiters require escaping). The message starts with a fixed-size header containing the length of what follows:

```text
+--------+--------+------------------------+
| length (4 bytes)| payload (length bytes) |
+--------+--------+------------------------+
```

The parser reads the 4-byte length first, then reads exactly that many bytes for the payload. Simple in concept, but the stream nature of TCP makes the *control flow* the hard part.

## Endianness: The Byte-Order Trap

A multi-byte integer can be laid out two ways. **Big-endian** (network byte order) stores the most significant byte first; **little-endian** (most CPUs) stores the least significant byte first. The number `0x12345678` becomes:

```text
Big-endian:    12 34 56 78
Little-endian: 78 56 34 12
```

Network protocols almost universally use **big-endian** — it is literally called "network byte order." If you read a length field with the wrong endianness, a 5-byte message looks like an 83-million-byte message, and your parser hangs waiting for bytes that will never come (or tries to allocate gigabytes). Every integer read from the wire must use explicit, agreed-upon byte order:

```python
import struct

def read_u32_be(buf, offset):
    # ">" forces big-endian; "I" is unsigned 32-bit.
    return struct.unpack_from(">I", buf, offset)[0]

# Wrong endianness silently produces a garbage length:
#   bytes 00 00 00 05  ->  big-endian = 5      (correct)
#                          little-endian = 83886080  (disaster)
```

The lesson: **never rely on the host's native byte order.** Always specify it explicitly when serializing and parsing.

## A Length-Prefixed Parser as a State Machine

The right mental model for a streaming binary parser is a **state machine**. Because data arrives in arbitrary chunks, the parser must remember what it is waiting for across multiple reads. It cannot assume a full message is available.

{{< mermaid >}}
graph TD
  A["READING_HEADER<br/>need 4 length bytes"] --> B{"Have 4 bytes<br/>buffered?"}
  B -- "No" --> A
  B -- "Yes" --> C["Parse length L<br/>validate L <= MAX"]
  C --> D["READING_BODY<br/>need L bytes"]
  D --> E{"Have L bytes<br/>buffered?"}
  E -- "No" --> D
  E -- "Yes" --> F["Emit message"]
  F --> A
{{< /mermaid >}}

The implementation buffers incoming bytes and only advances state when enough have accumulated. Note how it loops — a single chunk may contain several complete messages, so it drains the buffer fully before reading more.

```python
MAX_FRAME = 16 * 1024 * 1024   # hard cap: refuse absurd lengths

class FrameParser:
    def __init__(self):
        self.buf = bytearray()
        self.state = "HEADER"
        self.need = 4
        self.body_len = 0

    def feed(self, chunk):
        """Append bytes; yield each complete message found."""
        self.buf.extend(chunk)
        while True:
            if len(self.buf) < self.need:
                return                      # wait for more bytes
            if self.state == "HEADER":
                self.body_len = read_u32_be(self.buf, 0)
                if self.body_len > MAX_FRAME:
                    raise ValueError("frame too large")  # DoS guard
                del self.buf[:4]
                self.state, self.need = "BODY", self.body_len
            else:  # BODY
                msg = bytes(self.buf[:self.body_len])
                del self.buf[:self.body_len]
                self.state, self.need = "HEADER", 4
                yield msg
```

Three properties make this correct: it never assumes a message arrives in one read, it drains multiple messages from one chunk, and it **validates the declared length before trusting it** — which leads directly to the security discussion.

## The TLV Pattern for Extensible Records

Inside a framed message, fields are often encoded as **TLV — Type, Length, Value**. Each field announces what it is, how long it is, then its bytes. This makes a format self-describing and extensible: a parser that does not recognize a type can skip exactly `length` bytes and continue, ignoring unknown fields gracefully.

```text
+------+--------+----------------+------+--------+--------+
| type | length | value (L bytes)| type | length | value  |
+------+--------+----------------+------+--------+--------+
```

```python
def parse_tlv(buf):
    fields, off = {}, 0
    while off < len(buf):
        ftype = buf[off]
        flen = read_u32_be(buf, off + 1)
        if off + 5 + flen > len(buf):
            raise ValueError("TLV length exceeds buffer")  # bounds check
        value = buf[off + 5 : off + 5 + flen]
        fields[ftype] = value
        off += 5 + flen
    return fields
```

TLV is everywhere — TLS extensions, DNS records, many IoT protocols — precisely because it tolerates forward/backward evolution: add a new type and old parsers simply skip it.

## Variable-Length Integers (Varint)

Fixed-width integers waste space when most values are small. **Varint** encoding (used by Protobuf, QUIC, and others) uses the high bit of each byte as a continuation flag: if set, more bytes follow; the low 7 bits carry the value, little-endian across bytes.

```python
def read_varint(buf, off):
    result, shift = 0, 0
    while True:
        byte = buf[off]
        off += 1
        result |= (byte & 0x7F) << shift
        if not (byte & 0x80):          # high bit clear => last byte
            return result, off
        shift += 7
        if shift >= 64:                 # guard against malformed input
            raise ValueError("varint too long")
```

A value under 128 takes one byte; the encoding pays for size only as values grow. The guard on `shift` matters — without it, a malicious stream of bytes all with the continuation bit set could loop indefinitely or overflow.

## Security: Where Binary Parsers Go Wrong

Binary parsers are a classic source of serious vulnerabilities because they operate on attacker-controlled lengths and offsets. The recurring failure mode is **trusting a length field from the wire**.

| Pitfall | Consequence | Mitigation |
|---------|------------|------------|
| Unbounded length prefix | Memory exhaustion / DoS | Hard cap (`MAX_FRAME`) before allocating |
| No bounds check on offset | Buffer over-read, info leak | Validate `offset + len <= buffer_len` |
| Signed length read as positive | Negative wraps to huge value | Treat lengths as unsigned, validate range |
| Trusting nested lengths | Recursive over-read | Bound every nested field |
| Unbounded recursion depth | Stack overflow | Cap nesting depth |

The infamous **Heartbleed** bug was exactly this category: a TLS heartbeat message declared a payload length, the parser trusted it without checking against the actual received bytes, and copied memory beyond the real payload back to the attacker — leaking private keys. The fix was a single bounds check.

The discipline is non-negotiable:

```python
def safe_read(buf, offset, length):
    if length < 0 or offset < 0:
        raise ValueError("negative length/offset")
    if offset + length > len(buf):
        raise ValueError("read beyond buffer")     # the missing Heartbleed check
    return buf[offset : offset + length]
```

**Never allocate or copy based on a length you have not validated against (a) a sane maximum and (b) the bytes you actually hold.**

## Performance Considerations

Once correct and safe, binary parsers can be made fast:

- **Avoid copies.** Parse over a view/slice of the receive buffer rather than copying each field out. Zero-copy parsing (returning offsets into the original buffer) is dramatically faster for large messages.
- **Minimize allocations.** Reuse buffers across messages; allocation churn dominates the cost of a hot parser.
- **Read aligned and batched.** Pulling multi-byte integers with a single `struct.unpack` beats byte-by-byte shifting in interpreted languages.
- **Validate cheaply first.** Check the length cap before doing any work, so malicious inputs are rejected before they cost anything.

## Closing Thought

Binary protocol parsing is unforgiving but mechanical. The whole discipline reduces to a few invariants: frame messages explicitly (length-prefixing wins), fix your byte order and never assume the host's, model the parser as a state machine because TCP hands you arbitrary chunks, and — above all — never trust a length or offset from the wire without bounding it against a maximum and against the bytes you actually have. Get those right and you can parse anything from a Redis command to a TLS record correctly, quickly, and safely. Get the bounds check wrong and you get Heartbleed.
