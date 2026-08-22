# Execution Output Streams

Every execution has exactly one **output stream**: an ordered, durable, cursor-addressable
sequence of the values it produced. A workflow appends to it with the `emit` transition action
(`workflow/v1/activity.proto`); a caller consumes it with `CallActivityConfig.on_emitted`; anyone
else reads it with `ExecutionService.WatchOutput` (`daemon/v1/execution.proto`).

This exists because a sub-workflow could previously say something to its caller exactly once, at
termination. That makes "watch a mailbox and hand me each new message" inexpressible as a
sub-workflow: the loop has to move into the caller, and with it the poll interval, the backoff,
the pagination, the cursor — everything the sub-workflow was supposed to encapsulate. Its internal
state becomes its public return contract, and it can no longer change how it works without
breaking every caller.

## The stream

An execution's stream is **zero or more `value` entries followed by exactly one terminal entry**.
The terminal entry is the `result` a `result` action returned, or an `error` if the execution
failed or was cancelled. It is always last, and it always exists once the execution is terminal —
a path that ended without returning anything terminates the stream with an empty structure, not
with nothing.

Entries carry a **sequence**: dense, monotonic, starting at 0. A cursor is the sequence of the
last entry consumed; "resume after N" is therefore a pure function of recorded history, which is
what makes replay, reconnection, and daemon restart all the same operation.

The stream is **durable**, in the sense the rest of this spec has been quietly assuming: an entry
that has been appended survives a daemon restart and is replayed rather than recomputed. A
consumer that has recorded a cursor can always resume from it. This is a stronger promise than the
spec makes about anything else, and it is deliberate — it is what lets an implicit binding between
a parent and a child survive the orchestrator restarts a long-running poller will provoke.

Delivery to a consumer is **at-least-once**; observation is exactly-once by cursor dedup. An
implementation may deliver an entry twice; it may not deliver entry N+1 before entry N, skip an
entry, or renumber one.

## Producing

`emit` appends a value and transitions; `result` appends the terminal entry and ends the path.
They are the same operation differing in what comes after, which is why a generator reads
naturally: emit N times, return once.

Emitting is not conditional on anyone listening. An execution with no consumer — a
`workflow.spawn`, or a top-level run — still records everything it emits, and those entries are
readable over `WatchOutput` for as long as the daemon retains the execution.

## Consuming, and back-pressure

A `workflow.call` activity that declares `on_emitted` is that execution's **privileged consumer**.
There is at most one, and it is the only reader that can affect the producer:

> While an execution has a privileged consumer, an `emit` does not complete until that consumer's
> cursor has advanced past the entry it appended.

Everyone else is an **observer**. `WatchOutput` clients, tooling, dashboards — they read freely,
fall as far behind as they like, and never gate anything.

The point of gating is not to slow the world down. A blocked mailbox poller does not receive fewer
emails; it returns a bigger batch on its next poll, and the work is conserved. What gating bounds
is **how much has been written down but not yet dealt with**. A producer that is not
externally paced — draining a large backlog a page at a time, say — would otherwise append
thousands of durable entries while its consumer is still on the third, and that is unbounded
persisted state of exactly the kind an execution history is supposed to avoid.

So gating bounds the *count* of unconsumed entries, at one. It does not bound the *size* of any
single entry: one emission carrying five thousand records is still one emission. That is correct
rather than a gap — batch size is pagination policy, and pagination policy belongs to the producer,
which is the encapsulation this feature exists to enable.

Consuming is a loop, and the handler is its body. The handler is a **document**, dispatched once
per entry: its execution terminating is what finishes one iteration, and control then returns to
the call activity for the next entry. Re-entering the call activity while a subscription is live
consumes the next entry rather than starting a second child.

### A handler's emissions relay

A handler's terminal result is discarded, and an `emit` inside a handler is appended to the
**consumer's** own stream and handed to the consumer's caller.

That is not a new rule so much as the preservation of an old one. A handler used to run inside the
consumer's own execution, so a value it emitted was already the consumer's — the three-level relay
that behaviour supports is load-bearing, and moving the handler into its own execution would have
broken it silently. Relaying across the new boundary keeps it, and needs no keyword: emit in the
handler, it comes out of the consumer.

Mechanically the consumer dispatches the handler as a consuming call of its own, so per entry:
take V from the producer → dispatch the handler → the handler emits E → append E to our stream,
hand it to our caller, wait for that acknowledgement → acknowledge the handler → the handler
terminates → acknowledge the producer → take the next entry. Every wait is on something further
*up* the chain, never back down it, so the chain cannot close into a cycle and cannot deadlock.

A consumer therefore holds two subscriptions at once — the producer's, and the current handler's.
One handler runs at a time, so one slot suffices, but it is live state and must survive a
continue-as-new the way the producer subscription does.

**Promise branches do not relay.** For a handler this preserves existing behaviour; for a branch
it would change it, and N branches run concurrently, so interleaving their emissions into one
stream would order them nondeterministically — which costs the single-ordered-stream property
everything above depends on. A branch's emissions stay on the branch execution's own stream, where
`WatchOutput` can still read them.

The same rule covers a handler that declines a value. An `on_emitted` rule list where no condition
matches is exhausted, so the value is skipped and the next one taken — a filtering consumer, not an
abandoned loop.

## Subscription lifetime

A subscription ends when the consuming path terminates — `end` or a `result` — or when the
consuming execution is cancelled or fails. Running out of transitions inside a handler is not
leaving: it is how one iteration of the loop finishes.

**When a subscription ends, the producer is cancelled** (`EXECUTION_STATUS_CANCELLED`). Nothing
will observe it again, and a gated producer would otherwise block forever on a cursor that will
never advance. This is why cancellation is a prerequisite for this feature rather than an
independent nicety.

The already-recorded entries are unaffected: cancelling the producer stops it emitting, it does
not retract what it emitted.

## Ordering

There is no ordering rule to state, and that is the design working rather than an omission.

Emitted values and the terminal result are entries in a single ordered stream, walked by a single
cursor. Dispatch is by entry kind — `value` to `on_emitted`, `result` to `on_success`, `error` to
`on_failure` — so "all emissions are handled before the result" is arithmetic, not a constraint
somebody has to enforce. A producer that emits and immediately returns cannot have its result
overtake its own last value, because the two are adjacent entries in one log.

## Bounding

The spec does not bound stream length. A poller is an intentionally infinite loop, and its stream
grows for as long as it runs.

Bounding an **unconsumed** stream — retention, truncation, a cap on total entries — is daemon
runtime policy, consistent with the existing position that bounding total spawned work "is a
daemon responsibility, not a constraint of this spec"
(`PromiseActivityConfig`). A gated stream needs no such policy, since it never holds more than one
unconsumed entry.

## What this does not do

- **Fan-in.** One call activity is parked on one producer. Consuming two producers into one
  ordered sequence is not expressible, and is close to the concurrent handling that promise
  deliberately does not offer for streams.
- **Attaching to an existing stream** from inside a workflow — a `spawn` started earlier, or an
  execution somebody else started. `WatchOutput` covers this for observers; workflows cannot.
- **Pushing into a running execution.** This carries values *out* of an execution. The inbound
  direction — a webhook or human decision waking a parked run — is what
  `EXECUTION_STATUS_SUSPENDED` remains reserved for, and is not addressed here.

All three are additive later. Nothing in this document forecloses them.
