---
title: "Bloom Filters and HyperLogLog in Practice"
date: 2026-05-13T10:51:00-04:00
draft: false
featured: false
tags: [backend, data-structures, algorithms, databases, performance]
---

## Trading exactness for scale

Some questions are cheap to answer approximately and ruinously expensive to answer exactly. "Have I seen this item before?" and "How many distinct items have I seen?" are two of them. Answer them exactly and you store every item, which costs memory proportional to the data. Answer them approximately and you can use a fixed, tiny amount of memory regardless of scale, accepting a controlled, quantifiable error.

Bloom filters and HyperLogLog are the two probabilistic data structures you'll meet most often in real backend systems. They power database query optimizers, caches, CDNs, analytics pipelines, and distributed systems. This post covers how each works, how to size them, where they show up in production, and the failure modes that bite people who treat them as exact.

## Bloom filters: probabilistic set membership

A Bloom filter answers one question: "is this element *possibly* in the set, or *definitely* not?" It can give false positives (saying "maybe present" when the element was never added) but never false negatives (it will never say "not present" for something you added). This asymmetry is the whole game.

The structure is a bit array of `m` bits, all initially zero, plus `k` independent hash functions.

To **add** an element, hash it with all `k` functions, each producing an index into the bit array, and set those `k` bits to 1.

To **query** an element, hash it the same way and check those `k` bits. If *any* is 0, the element was definitely never added. If *all* are 1, the element is *probably* present, but those bits might have been set by other elements, hence the false positive.

```python
class BloomFilter:
    def __init__(self, m, k, hashes):
        self.bits = bytearray(m // 8 + 1)
        self.m = m
        self.k = k
        self.hashes = hashes        # k hash functions

    def _set(self, i):
        self.bits[i // 8] |= (1 << (i % 8))

    def _get(self, i):
        return (self.bits[i // 8] >> (i % 8)) & 1

    def add(self, item):
        for h in self.hashes:
            self._set(h(item) % self.m)

    def __contains__(self, item):
        # False means DEFINITELY not present.
        # True means PROBABLY present (could be a false positive).
        return all(self._get(h(item) % self.m) for h in self.hashes)
```

{{< mermaid >}}
graph TD
  A["Add 'apple'"] --> B["hash1 -> set bit 2"]
  A --> C["hash2 -> set bit 5"]
  A --> D["hash3 -> set bit 9"]
  E["Query 'apple'"] --> F["bits 2,5,9 all set?"]
  F -->|"any zero"| G["Definitely NOT present"]
  F -->|"all set"| H["Probably present"]
{{< /mermaid >}}

### Sizing a Bloom filter

The false positive rate is tunable and determined by three parameters: the number of elements `n` you'll insert, the number of bits `m`, and the number of hash functions `k`. The relationships are well known.

The optimal number of hash functions for a given `m` and `n` is:

```
k = (m / n) * ln(2)
```

And the resulting false positive probability is approximately:

```
p ≈ (1 - e^(-k*n/m))^k
```

In practice you work backwards: you decide on an acceptable false positive rate `p` and the expected `n`, then solve for the required bits:

```
m = -(n * ln(p)) / (ln(2)^2)
```

| Target false positive rate | Bits per element | Hash functions |
|----------------------------|------------------|----------------|
| 10% | ~4.8 | 3 |
| 1% | ~9.6 | 7 |
| 0.1% | ~14.4 | 10 |
| 0.01% | ~19.2 | 13 |

The striking result: even a 1% false positive rate costs under 10 bits per element. To store a million elements with 1% error you need roughly 1.2 MB, regardless of how large each element actually is. Compare that to a hash set storing the full items, which could be hundreds of megabytes. That compression is why Bloom filters are everywhere.

### Where Bloom filters earn their keep

The dominant use case is **avoiding expensive lookups**. The pattern: before doing a costly operation (a disk read, a network call, a database query), check a Bloom filter. If it says "definitely not present," skip the expensive operation entirely. False positives just mean you occasionally do the expensive lookup unnecessarily, which is harmless; false negatives would be catastrophic, and the filter guarantees there are none.

Concrete deployments:

- **LSM-tree databases** (Cassandra, RocksDB, LevelDB, HBase) keep a Bloom filter per SSTable. Before reading an SSTable from disk to find a key, they check its Bloom filter. Most SSTables don't contain the key, so the filter eliminates the vast majority of disk reads.
- **CDNs and caches** use Bloom filters to track "have we ever cached this URL," avoiding origin fetches for one-hit-wonder content (the "cache only on second request" trick).
- **Distributed systems** use them to reduce cross-node chatter: a node can check locally whether a peer *might* have data before sending a request.
- **Web crawlers** track visited URLs in a Bloom filter to avoid recrawling, accepting that a few unvisited URLs (false positives) get skipped.

### The deletion problem and variants

A standard Bloom filter cannot support deletion. You can't simply clear an element's bits, because those same bits might be shared with other elements still in the set; clearing them would create false negatives, breaking the core guarantee.

Two variants solve this:

A **counting Bloom filter** replaces each bit with a small counter (say 4 bits). Adding increments the counters; deleting decrements them. This restores deletion at roughly 4x the memory cost.

A **scalable Bloom filter** chains multiple filters with growing capacity, letting the structure expand when it fills up rather than requiring you to know `n` in advance.

| Variant | Supports delete | Memory cost | Notes |
|---------|-----------------|-------------|-------|
| Standard | No | Baseline | Fixed capacity |
| Counting | Yes | ~4x | Counters can overflow |
| Scalable | No | Grows | Unknown n |
| Cuckoo filter | Yes | Comparable | Better at low FP rates |

The **cuckoo filter** is a modern alternative that supports deletion, often uses less space than a counting Bloom filter at low false-positive rates, and has better cache locality. It's worth knowing when deletion is a hard requirement.

## HyperLogLog: counting distinct elements

The second question, "how many *distinct* items have I seen," is cardinality estimation. Exactly counting distinct items in a 10-billion-row stream means tracking every distinct value, which needs memory proportional to the cardinality. HyperLogLog (HLL) estimates it using a fixed, tiny amount of memory, typically a few kilobytes, with a standard error around 2% for the common configuration. That's astonishing: a few KB to count billions of distinct items.

### The core intuition

HLL rests on a beautiful probabilistic observation. Hash each element to a uniformly random bit string. In a stream of random bit strings, the more distinct values you see, the more likely you are to have encountered one with a long run of leading zeros. Seeing a hash with `k` leading zeros suggests you've probably observed around `2^k` distinct values, because a leading-zero run of length `k` occurs with probability `2^(-k)`.

A single such observation is wildly noisy. HLL's contribution is to reduce that variance by *averaging across many independent estimators*. It splits the hash: the first few bits select one of `2^p` "registers" (buckets), and the remaining bits provide the leading-zero count for that bucket. Each register tracks the maximum leading-zero count it has ever seen.

```python
import math

class HyperLogLog:
    def __init__(self, p=14):           # p register-index bits
        self.p = p
        self.m = 1 << p                 # number of registers, e.g. 16384
        self.registers = [0] * self.m

    def add(self, hashed):              # hashed: a 64-bit hash of the item
        idx = hashed >> (64 - self.p)   # top p bits select the register
        rest = (hashed << self.p) & ((1 << 64) - 1)
        rank = (64 - self.p) - rest.bit_length() + 1  # leading zeros + 1
        self.registers[idx] = max(self.registers[idx], rank)

    def count(self):
        alpha = 0.7213 / (1 + 1.079 / self.m)        # bias correction
        z = sum(2.0 ** -r for r in self.registers)
        return alpha * self.m * self.m / z           # harmonic mean estimate
```

To produce the final estimate, HLL takes the *harmonic mean* of `2^register` across all registers, scaled by a bias-correction constant. The harmonic mean is key: it dampens the influence of outlier registers that happened to see an unusually long zero run.

{{< mermaid >}}
graph LR
  A["Item"] --> B["64-bit hash"]
  B --> C["Top p bits: register index"]
  B --> D["Remaining bits: count leading zeros"]
  C --> E["Update register to max rank"]
  D --> E
  E --> F["Estimate = harmonic mean of registers"]
{{< /mermaid >}}

### Accuracy and memory

The standard error of HLL is approximately `1.04 / sqrt(m)` where `m = 2^p` is the register count. More registers means more accuracy and more memory, and the trade is gentle because error shrinks with the square root.

| Precision p | Registers (m) | Memory | Standard error |
|-------------|---------------|--------|----------------|
| 10 | 1,024 | ~768 B | ~3.25% |
| 12 | 4,096 | ~3 KB | ~1.62% |
| 14 | 16,384 | ~12 KB | ~0.81% |
| 16 | 65,536 | ~48 KB | ~0.41% |

Redis uses `p = 14`, giving roughly 0.81% standard error in about 12 KB, which is the widely cited "count billions of things in 12 KB" figure.

### The killer feature: mergeability

HLL's most powerful property in distributed systems is that two HLL sketches are **mergeable**. To combine the cardinality estimates of two streams, you take the element-wise maximum of their register arrays. The result is exactly the HLL you'd get from processing both streams together.

This means you can compute distinct counts in a fully distributed, parallel fashion: each node maintains its own HLL over its shard of the data, then you merge all the sketches at the end with cheap element-wise max operations. No data shuffling, no central bottleneck. This is why HLL underpins distinct-count queries in analytics systems like Redis (`PFCOUNT`/`PFMERGE`), Presto/Trino, BigQuery (`APPROX_COUNT_DISTINCT`), and Druid.

```python
def merge(a, b):
    # Mergeability: element-wise max of registers.
    return [max(x, y) for x, y in zip(a.registers, b.registers)]
```

### Where HLL falls down

HLL estimates cardinality, not membership. It cannot tell you *whether* a specific element was seen, only roughly how many distinct elements there were. Don't confuse it with a Bloom filter.

Its accuracy degrades at very low cardinalities, which is why production implementations (like Redis's) use a sparse linear-counting representation for small sets and switch to dense HLL only once the count grows. And the error is statistical: any single estimate could be off by more than the standard error. For billing or anything requiring exactness, HLL is the wrong tool.

## Choosing between them

These structures answer different questions, and the most common mistake is reaching for the wrong one.

| Question | Tool | Error mode |
|----------|------|------------|
| "Is X in the set?" | Bloom filter | False positives only |
| "How many distinct items?" | HyperLogLog | Statistical estimate |
| "How many times did X appear?" | Count-Min Sketch | Overestimates |

They compose well too. A common analytics pipeline uses a Bloom filter to deduplicate at ingestion (skip already-seen events) and HyperLogLog to report distinct user counts downstream, each operating in kilobytes where the exact equivalents would demand gigabytes.

## The takeaway

Probabilistic data structures trade a small, quantifiable error for enormous memory savings and, in HLL's case, trivial distributed merging. Bloom filters answer membership with one-sided error and shine at skipping expensive lookups. HyperLogLog answers cardinality with bounded statistical error and mergeable sketches that make distributed distinct-counting nearly free. Size them deliberately, respect their error models, and never use an approximate structure where the business needs an exact answer.
