---
title: "Actor Model vs Shared-Memory Concurrency"
date: 2026-02-26T14:08:00-04:00
draft: false
featured: false
tags: [backend, concurrency, actors, distributed-systems, architecture]
---

Concurrency is hard because two independent activities can touch the same data at the same time and corrupt it. Two broad philosophies have emerged to tame this. **Shared-memory concurrency** lets threads access common data and uses locks to coordinate. The **actor model** forbids shared mutable state entirely, replacing it with message passing between isolated entities. Understanding the trade-offs between these approaches shapes how you design everything from a single-process service to a globally distributed system.

## Shared Memory: The Default Model

In the shared-memory model, multiple threads run inside one address space and can read and write the same objects. When two threads might touch the same data, you protect it with a synchronization primitive: a mutex, a read-write lock, an atomic variable, or a concurrent data structure.

```java
class Counter {
    private long value = 0;
    private final Object lock = new Object();

    void increment() {
        synchronized (lock) {   // only one thread inside at a time
            value++;
        }
    }
    long get() {
        synchronized (lock) { return value; }
    }
}
```

This model is fast and direct: threads communicate by writing to memory the others can read, which is the cheapest communication a computer offers. But it is famously error-prone. The hazards are well known and deeply unpleasant to debug:

- **Race conditions** when you forget to lock something, producing corruption that appears only under specific timing.
- **Deadlocks** when two threads each hold a lock the other wants.
- **Lock contention** that serializes threads and destroys the scalability you were trying to achieve.
- **Memory visibility bugs** where one thread's write isn't seen by another due to caching and reordering, requiring careful use of memory barriers and `volatile`.

The deeper problem is that correctness is *non-local*. Whether your code is correct depends on the locking discipline of every other piece of code that touches the same data. You can't reason about a class in isolation.

## The Actor Model: Isolation by Default

The actor model attacks the problem at its root: it eliminates shared mutable state. An **actor** is an independent unit of computation that owns its private state. No other actor can read or write that state directly. Actors communicate **only** by sending immutable messages to each other's mailboxes.

Each actor processes the messages in its mailbox **one at a time**, sequentially. Because only the actor itself ever touches its state, and because it processes one message at a time, there are no data races within an actor, by construction. There are no locks because there is nothing to lock; no other thread can reach the state.

{{< mermaid >}}
graph LR
  A["Actor A"] -->|"message"| MB["Actor B Mailbox"]
  MB --> B["Actor B (single-threaded)"]
  B -->|"reply message"| MA["Actor A Mailbox"]
  B -->|"spawn"| C["Actor C"]
  B -->|"private state"| S["B's State (isolated)"]
{{< /mermaid >}}

An actor, in response to a message, can do three things:

1. Send messages to other actors (including itself).
2. Create new actors.
3. Change how it will handle the *next* message (its behavior/state).

That's the entire model. Its power comes from its simplicity and from a property that the shared-memory model lacks: **location transparency**. Because actors only ever interact via messages, it doesn't matter whether the recipient actor is on the same thread, the same machine, or a machine across the world. The same message-send code works for all three. This is why the actor model is the foundation of distributed systems toolkits.

## A Side-by-Side Comparison

| Property | Shared-Memory | Actor Model |
|---|---|---|
| Communication | Read/write shared data | Asynchronous messages |
| State protection | Locks, atomics | Isolation (no sharing) |
| Failure mode | Races, deadlocks | Lost messages, mailbox overflow |
| Reasoning | Non-local, global | Local, per-actor |
| Performance ceiling | Very high (no message overhead) | Message-passing overhead |
| Scales across machines? | No (single address space) | Yes (location transparency) |
| Backpressure | Implicit via blocking | Explicit (bounded mailboxes) |
| Best for | Tight in-process hot paths | Distributed, fault-tolerant systems |

## The Counter, Rewritten as an Actor

Here's the same counter as an actor (pseudocode in a Scala/Akka-like style):

```scala
object Counter {
  sealed trait Command
  case object Increment extends Command
  case class GetValue(replyTo: ActorRef[Long]) extends Command

  def apply(value: Long = 0): Behavior[Command] =
    Behaviors.receiveMessage {
      case Increment =>
        Counter(value + 1)              // new behavior with updated state
      case GetValue(replyTo) =>
        replyTo ! value                 // send the value back as a message
        Behaviors.same
    }
}
```

Notice there is no lock and no `volatile`. The `value` is captured in the behavior, and because the actor processes one message at a time, increments can never race. State updates happen by *returning a new behavior* carrying the new value. To read the value, you don't reach into the actor; you send it a `GetValue` message with a reference to reply to, and it sends the answer back.

## Performance: There's No Free Lunch

The actor model's safety comes at a cost. Sending a message is more expensive than dereferencing a pointer. It involves enqueuing onto a mailbox, scheduling the actor to run, and copying or referencing an immutable message. For an in-process hot loop doing millions of tiny operations per second, raw shared-memory with fine-grained atomics will crush an actor system on throughput.

So the actor model is not the right tool for, say, a high-frequency in-memory counter on a hot path. It *is* the right tool when:

- The operations are coarse-grained enough that message overhead is negligible.
- You need to distribute work across machines.
- You need fault isolation, where one component's failure shouldn't corrupt others.
- The complexity of correct lock-based code would otherwise be unmanageable.

## Fault Tolerance and Supervision

The actor model's killer feature isn't just concurrency safety; it's fault tolerance. Because actors are isolated, the failure of one actor doesn't corrupt the state of another. This enables **supervision hierarchies**: each actor has a supervisor (its parent) that decides what to do when the child crashes, typically restart it, restart it and its siblings, or escalate.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Running
  Running --> Failed: exception while processing message
  Failed --> Restarting: supervisor decides: restart
  Failed --> Stopped: supervisor decides: stop
  Restarting --> Running: fresh state, mailbox preserved
  Stopped --> [*]
{{< /mermaid >}}

This embodies the **"let it crash"** philosophy, popularized by Erlang. Instead of defensively guarding every operation against every conceivable error, you let a faulty actor crash and rely on its supervisor to restart it into a known-good state. A crashed actor's isolated state is simply discarded and recreated, with no risk of half-updated shared structures left behind, because there are none. This makes systems remarkably resilient: a corrupted in-flight operation is contained to one actor rather than poisoning the whole process.

Compare this to shared-memory: when a thread throws an exception while holding a lock and mutating shared state, you can be left with that state half-updated and the lock potentially held, a far harder situation to recover from cleanly.

## Backpressure and Mailbox Overflow

Actors trade one set of problems for another. Because message sends are asynchronous and mailboxes can grow, a fast producer can overwhelm a slow consumer, filling its mailbox until you run out of memory. The actor model doesn't give you backpressure for free; you have to design for it with bounded mailboxes, explicit acknowledgment protocols, or flow-control schemes. This is the actor-world analog of lock contention: the place where naive designs fall over under load.

## Choosing in Practice

These models aren't mutually exclusive, and the best systems often combine them. A common architecture uses actors for the coarse-grained structure of the system, where you want isolation, distribution, and fault tolerance, while using shared-memory concurrency *inside* a single actor's processing or in a performance-critical library that the actors call into.

Reach for **shared-memory** when you have tight, in-process, performance-critical code where message-passing overhead would dominate, and you have the discipline to manage locking carefully (or can use lock-free data structures).

Reach for the **actor model** when you're building systems that must scale across machines, tolerate partial failures gracefully, and remain comprehensible as they grow, where the ability to reason about each actor in isolation is worth the message-passing cost.

## Conclusion

Shared-memory concurrency and the actor model represent two answers to the same question: how do independent activities coordinate without corrupting each other? Shared memory says "share carefully, with locks," offering maximum performance at the cost of global, fragile reasoning. The actor model says "don't share at all, send messages instead," offering local reasoning, location transparency, and fault tolerance at the cost of message-passing overhead. Knowing which question your system is really asking, raw in-process speed versus distributed resilience, tells you which model to reach for, and the most robust systems are usually the ones that know when to use each.
