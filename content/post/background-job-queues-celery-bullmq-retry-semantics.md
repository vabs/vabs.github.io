---
title: "Background Job Queues (Celery / BullMQ) Retry Semantics"
date: 2026-04-01T10:07:55-04:00
draft: false
featured: false
tags: [backend, queues, celery, bullmq, retries]
---

Background job queues are where the optimistic assumptions of synchronous code go to die. A job runs in a worker that can crash, against a network that can partition, talking to services that can time out. The entire value proposition of a queue is that it will *try again* when things fail — but "try again" hides a thicket of decisions: how many times, with what delay, whether the retry might run the job twice, and what happens to jobs that never succeed. This post compares how Celery and BullMQ handle retries, the semantics you must understand to avoid corrupting data, and the patterns that keep a queue healthy under failure.

## At-Least-Once Is the Default, and It's a Trap

Both Celery and BullMQ, like virtually every durable queue, provide **at-least-once** delivery. A job that is picked up but whose completion is not acknowledged — because the worker crashed, or the ack was lost — will be redelivered. This means your job handlers can and will run more than once for the same logical task.

The implication is non-negotiable: **job handlers must be idempotent**, or at least guarded against duplicate execution. A job that charges a credit card, run twice, charges twice. The queue cannot fix this for you; it is a property your handler must provide.

{{< mermaid >}}
graph TD
  A["Job enqueued"] --> B["Worker picks up job"]
  B --> C["Handler executes"]
  C --> D{"Success?"}
  D -->|"Yes, ack received"| E["Job removed"]
  D -->|"Worker crashes before ack"| F["Job redelivered"]
  D -->|"Handler raises"| G{"Retries left?"}
  F --> B
  G -->|"Yes"| H["Re-enqueue with backoff"]
  G -->|"No"| I["Dead-letter / failed set"]
  H --> B
{{< /mermaid >}}

## Celery Retry Semantics

Celery tasks retry by raising a retry from inside the task, either explicitly or automatically.

```python
@app.task(
    bind=True,
    autoretry_for=(requests.RequestException,),
    retry_backoff=True,
    retry_backoff_max=600,
    retry_jitter=True,
    max_retries=5,
)
def fetch_report(self, report_id):
    resp = requests.get(f"https://api.example.com/reports/{report_id}")
    resp.raise_for_status()
    store(report_id, resp.json())
```

The important knobs:

| Option | Effect |
|--------|--------|
| `autoretry_for` | Exception types that trigger an automatic retry |
| `max_retries` | Cap on retry attempts before the task gives up |
| `retry_backoff` | Exponential delay (`True` = 2^n seconds) |
| `retry_backoff_max` | Ceiling on the backoff delay |
| `retry_jitter` | Randomize the delay to avoid synchronized retries |
| `acks_late` | Ack only after the task completes, not just before it starts |

`acks_late` deserves emphasis. By default Celery acks a task *just before the worker starts executing it*. If the worker then dies mid-execution, the task is **not** redelivered — it's lost. Setting `acks_late=True` defers the ack until the task finishes, so a crash triggers redelivery. The catch: late acks plus a non-idempotent task means a crash *after the side effect but before the ack* causes a re-run that repeats the side effect. There is no free lunch; you trade lost-task risk for double-run risk, and idempotency is what makes the latter safe.

### Explicit retry with control

```python
@app.task(bind=True, max_retries=3)
def process(self, item_id):
    try:
        do_work(item_id)
    except TransientError as exc:
        raise self.retry(exc=exc, countdown=2 ** self.request.retries)
```

`self.request.retries` tells you which attempt you're on, letting you compute backoff manually or branch behavior on the final attempt.

## BullMQ Retry Semantics

BullMQ (Redis-backed, Node.js) configures retries per-job or per-queue via options.

```javascript
await queue.add(
  "sendEmail",
  { to, subject, body },
  {
    attempts: 5,
    backoff: { type: "exponential", delay: 1000 },
    removeOnComplete: 1000,
    removeOnFail: 5000,
  }
);
```

| Option | Effect |
|--------|--------|
| `attempts` | Total tries including the first (so `5` = 1 + 4 retries) |
| `backoff.type` | `"fixed"` or `"exponential"` |
| `backoff.delay` | Base delay in ms |
| `removeOnComplete` | Keep N completed jobs, then trim |
| `removeOnFail` | Keep N failed jobs for inspection |

A frequent off-by-one bug: `attempts` is the *total* number of executions, not the number of *retries*. `attempts: 1` means no retries at all. Celery's `max_retries` counts retries *after* the first run. The two libraries number this differently, so a migration that copies the value verbatim changes behavior.

### Custom backoff strategies

BullMQ lets you define a custom backoff function, which is where you can implement jittered exponential to avoid the thundering herd:

```javascript
const worker = new Worker("emails", processor, {
  settings: {
    // only used for jobs added with backoff: { type: "custom" }
    backoffStrategy: (attemptsMade) => {
      const base = Math.pow(2, attemptsMade) * 1000;
      return base + Math.random() * 1000; // jitter
    },
  },
});
```

### Stalled jobs

BullMQ's analog to Celery's late-ack problem is **stalled job detection**. A job is "stalled" if a worker grabbed it but stopped renewing its lock (because it crashed or blocked the event loop). The `stalledInterval` and `maxStalledCount` settings control how aggressively BullMQ reclaims and retries such jobs. Critically, a job that blocks the event loop for longer than the lock duration (so the lock cannot be renewed) can be falsely declared stalled and run concurrently in two workers — a self-inflicted double execution. CPU-heavy jobs must either yield to the event loop, run in a sandboxed processor, or be broken into smaller pieces.

## Backoff Strategy Comparison

The shape of your backoff curve determines how the queue behaves when a dependency goes down and everything starts failing at once.

| Strategy | Curve | Risk |
|----------|-------|------|
| Fixed | Constant delay | Synchronized retry waves hammer recovering service |
| Linear | n × base | Better, still partially synchronized |
| Exponential | 2^n × base | Spreads retries out, good for outages |
| Exponential + jitter | 2^n × base + random | Best; breaks up synchronized waves |

Without jitter, a thousand jobs that all failed at the same instant (because a database went down) will all retry at the same instant when the backoff elapses — re-creating the exact load spike that may have caused the outage. Jitter is not optional for any queue under real failure load; it is the difference between a graceful recovery and a retry storm that keeps the dependency pinned down.

## Dead-Letter Handling

When a job exhausts its retries, it must go somewhere. Silently dropping it loses data; retrying forever wedges the queue.

{{< mermaid >}}
stateDiagram-v2
  [*] --> Pending
  Pending --> Active: worker picks up
  Active --> Completed: success
  Active --> Retrying: fail, attempts remain
  Retrying --> Active: backoff elapsed
  Active --> Failed: attempts exhausted
  Failed --> DeadLetter: moved for inspection
  DeadLetter --> Pending: manual / automated requeue
  Completed --> [*]
{{< /mermaid >}}

In Celery, a dead-letter exchange (configured at the broker, e.g. RabbitMQ) catches messages that are rejected or expire. In BullMQ, exhausted jobs land in the *failed* set, retained per `removeOnFail`, where you can inspect, fix the root cause, and requeue. Either way, the dead-letter queue should be **monitored and alerted on** — it is your early warning that a class of jobs is systematically broken, and a growing failed set is a signal that something downstream is wrong, not a place for jobs to quietly accumulate forever.

## Poison Messages

A poison message is a job that fails *deterministically* — bad input, a bug, a permanently missing resource. Retrying it accomplishes nothing except burning worker capacity. The defense is to distinguish *transient* failures (network blip, retry helps) from *permanent* failures (malformed payload, retry never helps):

```python
@app.task(bind=True, max_retries=5)
def handle(self, payload):
    try:
        validate(payload)          # raises PermanentError on bad data
        result = call_service(payload)   # raises TransientError on timeout
    except PermanentError:
        dead_letter(payload)       # do NOT retry
        return
    except TransientError as exc:
        raise self.retry(exc=exc)
```

Categorizing exceptions so that only transient ones trigger retries is what keeps a single bad message from consuming a worker through five exponential-backoff cycles before finally dying. Retry the retryable; dead-letter the rest immediately.

## Operational Guidance

- **Make every handler idempotent** — use an idempotency key, a dedup table, or conditional writes. This is the foundation that makes at-least-once safe.
- **Always add jitter** to backoff. Plain exponential still synchronizes.
- **Cap retries and dead-letter the rest.** Infinite retries hide bugs and clog queues.
- **Distinguish transient from permanent failures** so poison messages die fast.
- **Monitor the dead-letter / failed set.** A growing one is a paging-worthy signal.
- **Mind the ack timing** (`acks_late`, stalled detection). It trades lost jobs for possible double-runs, which idempotency must cover.

## Conclusion

Retries are the reason queues are reliable and also the reason they corrupt data when handled carelessly. Celery and BullMQ give you the same fundamental guarantees with different vocabularies — `max_retries` vs. `attempts`, late acks vs. stalled jobs — but the underlying discipline is identical: assume jobs run more than once, make them safe to do so, back off with jitter, separate the retryable from the doomed, and give exhausted jobs a monitored place to land. The queue handles the mechanics of trying again; what it cannot do is decide whether trying again is safe. That decision is yours, and it lives in the idempotency of your handlers.
