# Workflow Source Format

Defines the **source format** — what people author — and its normative mapping onto
`utos.workflow.v1.Workflow` (`workflow/v1/workflow.proto`). The daemon never sees this format: a
**front end** reads it, resolves dependencies, and produces a `WorkflowBundle`
(`workflow/v1/bundle.proto`), which is what crosses the wire. The reference CLI is one front end;
`Utos.Workflow.Source` in `utos/sdk-dotnet` implements the mapping for any .NET tool, and the
`conformance/source/` corpus is how another proves it reads a document the same way.

Two formats exist because they answer to different masters. The built bundle is optimized for
machines — flat, fully resolved, content-addressable. The source format is optimized for people,
and follows Kubernetes manifest conventions so it reads the way the rest of a modern
infrastructure repo reads.

## Serialization

The source format is defined over the **YAML 1.2 data model**, and JSON — being a YAML subset —
is therefore accepted unchanged. Nothing in this document depends on YAML-specific syntax; a
conforming implementation may accept any serialization that yields the same node graph.

Parser requirements:

1. **Duplicate mapping keys are an error.** YAML 1.2 says duplicate keys are invalid, but many
   parsers silently take last-wins. A workflow where `activities` declares `send` twice must be
   rejected, not quietly halved.
2. **Both field-name spellings are accepted.** proto3 JSON accepts a field's original proto name
   and its lowerCamelCase `json_name`, so `on_success` and `onSuccess` are equally valid. Emitters
   should prefer lowerCamelCase, matching the canonical bundle form.
3. **Unknown fields are rejected.** A misspelled key is a mistake, not a comment.

## Document shape

The top level is exactly the four Kubernetes envelope keys — `apiVersion`, `kind`, `metadata`,
`spec` — and nothing else.

```yaml
apiVersion: utos.io/v1
kind: Workflow
metadata:
  name: order-fulfilment
  version: 1.2.0
  namespace: acme            # optional
  registry: registry.utos.dev # optional
  description: Ships an order and notifies the customer  # optional
spec:
  dependencies: {}
  activities: {}
  # env, output and emits are optional — see workflow-schemas.md
```

- `apiVersion` — must be `utos.io/v1`. A group/version pair mirroring the proto package major,
  not a semver, and distinct from `metadata.version`.
- `kind` — must be `Workflow`.
- `metadata.name` + `metadata.version` are required; together with the optional `namespace` and
  `registry` they form the workflow's **canonical identity**,
  `[registry/][namespace/]name:version` — the key under which this workflow appears in a built
  bundle.
- `spec.env`, `spec.output` and `spec.emits` are the workflow's **contract** — what it requires
  from its environment, what it returns, and what it emits. All three are optional and all three
  are schemas; [`workflow-schemas.md`](workflow-schemas.md) defines them and the short form they
  are written in. What an *activity* accepts is declared on the activity, under `schema:`.

`dependencies` lives under `spec`, not beside it. Everything describing the desired workflow
belongs in `spec`; a fifth top-level key would break the convention this format adopts.

## Dependencies

`spec.dependencies` binds a local **alias** to a sub-workflow reference. Aliases are private to
the workflow that declares them.

```yaml
spec:
  dependencies:
    emailer: registry.utos.dev/acme/send-email:1.0.0
    validator: ./shared/validate-address.yaml
```

A reference beginning with `./` or `../` is a **local file**, resolved relative to the directory
of the file that declares it. Anything else is a **registry reference** of the form
`{registry}/{namespace}/{name}:{version}`. The registry is always explicit — never inferred from
ambient configuration — so a reference means the same thing on every machine and typosquatting on
an implied default registry is impossible.

### `self`

`self` is a reserved value meaning *this document*. It needs no `dependencies` entry, and
`UTOS-S004` excepts it.

**It is legal in exactly one place: a promise branch's `workflow`** (`UTOS-S011`). Everywhere else
a document is named — a `workflow.call` or `workflow.spawn` activity, an `onEmitted` rule — it is
rejected.

It exists because requiring a document would otherwise make recursive fan-out inexpressible: a
document that dispatched itself through an alias would be a document depending on itself, which
`UTOS-S005` rejects as a cycle. `self` sidesteps that check rather than relaxing it — it never
enters the dependency graph, so there is nothing to detect.

That argument is what confines it. A recursive branch is the one construct with no other way to say
what it means, and it terminates on its data: a `forEach` over an empty collection starts nothing,
so a leaf ends the recursion without a depth rule. Nowhere else is `self` load-bearing — it would
only save a document — and in one place it actively costs something:

> An `onEmitted` rule naming `self` puts the handler back inside the consumer's own graph, where a
> transition can reach the call activity that dispatched it. In a separate execution that does not
> resume the producer, it starts **another** one — once per value, without bound. The handler is a
> document precisely so that cannot happen, and `self` would undo it.

That is not a hypothetical mistake. Before handlers became documents, transitioning back to the
call activity was how a consumer's loop was closed, so the hazard is one an author arrives at by leaving
old text alone rather than by writing something new.

Reserving the word breaks nothing that was previously legal. Bare `self` has no `./` prefix and no
`{registry}/{namespace}/{name}:{version}` shape, so it was already a malformed reference
(`UTOS-S002`).

Two things it is not:

- **Not re-entry.** `workflow: self` starts a **fresh child execution** of this document from the
  named activity. It does not resume, re-enter or loop the current one; a back-edge transition is
  what does that.
- **Not a pin.** It resolves to whatever this document's canonical identity is at build time, so a
  version bump carries automatically and cannot be forgotten in one place.

Resolution happens in the CLI like any alias: the build rewrites `self` to this document's own
canonical identity, so **the daemon never sees the word.**

## Activities

`spec.activities` maps an activity name to its definition. No name is reserved: ending a path
and failing it are actions (`return`, `error`), not activities.

Every activity has a `type` naming its kind, the fields belonging to that kind alongside it,
optional `onSuccess` / `onFailure` transition lists, and an optional `schema` declaring what it
accepts.

```yaml
spec:
  activities:
    fetch-order:
      type: http
      schema:
        input:
          orderId: { type: string }
      method: GET
      url: "{{ env.API_BASE }}/orders/{{ input.orderId }}"
      headers:
        accept: application/json
      onSuccess:
        - condition: "output.status === 'paid'"
          transition:
            name: notify
            input:
              to: "{{ output.customer.email }}"
        - transition: { name: wait }
      onFailure:
        - condition: "response.status === 404"
          error:
            code: ORDER_NOT_FOUND
            message: "order {{ input.orderId }} does not exist"
        - error: { code: ORDER_FETCH_FAILED, message: "{{ error.message }}" }

    wait:
      type: timer
      duration: 30s
      onSuccess:
        - transition: { name: fetch-order }   # back-edge: a polling loop

    notify:
      type: workflow.call                     # await it; `workflow.spawn` to fire and forget
      workflow: emailer                       # a dependency alias
      startActivity: send
      input:
        recipient: "{{ input.to }}"
      onSuccess:
        - return:
            delivered: true
```

### The `type` discriminator

`type` selects which activity configuration applies. Its legal values are **derived from the
proto**, not from a list maintained here: they are the field names of the `config` oneof on
`utos.workflow.v1.WorkflowActivity`, and — where the selected configuration message declares a
oneof of its own — a `.`-separated path through those too. Today that is:

| `type` | Configuration message(s) | Fields |
|---|---|---|
| `http` | `HttpActivityConfig` | `method`, `url`, `headers`, `body` |
| `timer` | `TimerActivityConfig` | `duration` |
| `workflow.call` | `WorkflowActivityConfig` + `CallActivityConfig` | `workflow`, `startActivity`, `input` |
| `workflow.spawn` | `WorkflowActivityConfig` + `SpawnActivityConfig` | `workflow`, `startActivity`, `input` |
| `promise.all` | `PromiseActivityConfig` + `PromiseAllConfig` | `branches` |
| `promise.any` | `PromiseActivityConfig` + `PromiseAnyConfig` | `branches` |
| `promise.race` | `PromiseActivityConfig` + `PromiseRaceConfig` | `branches` |
| `promise.count` | `PromiseActivityConfig` + `PromiseCountConfig` | `branches`, `requiredCount` |

Deriving the set from the descriptor rather than hard-coding it means a new activity kind added
to the spec becomes authorable with no change to the mapping logic — the table above is
documentation, not the source of truth.

A dotted path is required whenever the message reached still declares a oneof: bare
`type: workflow` and bare `type: promise` are not legal values, because neither says which mode
was meant. The path exists precisely so a choice that changes an activity's contract cannot be
expressed as an optional field that is easy to leave unset — `workflow.call` and
`workflow.spawn` return different things, and `promise.count` is the only mode that has a
`requiredCount` at all.

### Normative mapping

For each entry of `spec.activities`, given `A = utos.workflow.v1.WorkflowActivity`:

1. Read the `type` key and split it on `.` into one or more segments. Walk them from `A`: each
   segment must equal the name of a field in the current message's `config`-style oneof, and the
   walk continues into that field's message type. **Synthetic oneofs are excluded** — proto3
   `optional` fields generate one oneof each, and they are not activity kinds. The walk ends when
   the segments run out; if the message reached still declares a non-synthetic oneof, the path is
   incomplete. If `type` is absent, unmatched, or incomplete, reject, listing the legal paths
   derived from the descriptor.
2. Keys that name a field of `A` **outside** any oneof stay at activity level. Today those are
   `on_success` / `onSuccess`, `on_failure` / `onFailure`, and `schema`.
3. Every remaining key — `type` excluded — is placed on the message **along the resolved path**
   that declares a field of that name, nested under the oneof field names that reach it.
4. In every rule — `onSuccess`, `onFailure`, `onEmitted` — a `return` key is renamed to
   `result`, and a `return` with no value becomes an empty struct, `result: {}`. "No value" is
   `return:` with nothing after it, `return: ~` or `return: null`; in flow style, the entry
   without a value, `{ condition: output.done, return }`; and, for a rule with no condition, the
   bare list item `- return`, which YAML reads as the string `return` and this mapping reads as
   the whole rule. A block-style `return` line without a colon under a `condition:` is not YAML,
   and no mapping can read it. The wire keeps the name `result` because `return` is a reserved
   word in several target languages (a generated `msg.return` is a syntax error in Python), and
   proto3 JSON reads `"result": null` as *unset* — which would be a rule with no action — so
   "no value" has to be spelled as an empty struct by the time it reaches the bundle. The source
   format accepts `return` only; `result` in a source document is an unknown field.

   An `error` with no fields is read the same way and becomes an empty `WorkflowError`,
   `error: {}` — the re-raise: `error:`, `error: ~`, `error: null`, the flow-style
   `{ condition: x, error }`, and the bare list item `- error`. `error` keeps its name on the wire.
5. `schema.input` is **compiled** from the short form of
   [`workflow-schemas.md`](workflow-schemas.md) into plain JSON Schema, and so are `spec.env`,
   `spec.output` and `spec.emits`. These four slots are the only places in this format where the
   source tree is not structurally the proto tree: a bundle carries standard JSON Schema, so `?`,
   `min`/`max` and the closed-by-default rule are resolved here and nothing downstream learns
   them. A `schema` with no `input` is omitted rather than emitted as `{}`.
6. The result is parsed as proto3 JSON. Unrecognized keys inside the configuration surface here
   as ordinary unknown-field errors, so no separate check is needed.

So the `wait` activity above becomes:

```json
{ "timer": { "duration": "30s" },
  "onSuccess": [ { "transition": { "name": "fetch-order" } } ] }
```

and a two-segment path distributes its keys across both messages on the path — `branches` is
declared by `PromiseActivityConfig`, `requiredCount` by `PromiseCountConfig`:

```yaml
fan-out:
  type: promise.count
  requiredCount: 2
  branches: [ ... ]
```
```json
{ "promise": { "branches": [ ... ], "count": { "requiredCount": 2 } } }
```

A mode that carries no fields of its own still appears, as the empty object that records the
choice — `type: promise.all` yields `{ "promise": { "branches": [ ... ], "all": {} } }`.

Outside activities, the source tree is structurally identical to the proto, so no other
restructuring occurs — apart from the three schema slots of step 5, `spec.env`, `spec.output` and
`spec.emits`, which are compiled rather than copied.

> Step 3 is only unambiguous because of a constraint on the proto itself: **no field name may be
> declared at two levels of the same resolvable path.** If `PromiseCountConfig` also declared
> `branches`, an authored `branches:` key would have two homes. This is mechanically checkable
> against the descriptor, so implementations should assert it as a test rather than trust review.

> Because step 3 claims every unrecognized key, `type` is effectively reserved inside an activity
> body. A future non-oneof field on `WorkflowActivity` named `type` would collide; the spec must
> not add one.

### Transitions

`onSuccess` and `onFailure` are ordered lists evaluated top to bottom — **first match wins**, so
their order is significant and is preserved through to the bundle digest. A rule with no
`condition` always matches and therefore acts as a fallback; anything after it is unreachable.

Each rule carries exactly one action:

- `transition` — go to another activity. `name` is an activity in the same workflow — never a
  keyword. The optional `input` is a transform producing the target's `input` context; leaf
  strings may contain `{{ }}` expressions. Omitted, the source activity's output passes through
  unchanged.
- `return` — end this execution path. With a value, that structure is the path's result; with no
  value (`- return`), the path simply ends. Written `result` in the bundle — see the mapping.
- `error` — end this execution path as a failure. Shaped as the `WorkflowError` the run will
  report: `code` (a literal identifier, required), `message` (a text template) and `details` (a
  struct template), all rendered in the rule's scope, so a failure carries the reason the author
  gave it. **With no fields** (`- error`, `error:`), on `onFailure`, it re-raises the failure being handled
  as it is — the same `code`, `message` and `details` — which is how a rule forwards a failure it
  has no reason to rename, such as a sub-workflow's. `onSuccess` and `onEmitted` have no failure
  in scope to re-raise, so there an `error` must carry a `code` (`UTOS-T005`). A `code` stays a
  literal either way: the rethrow is what forwarding is for, and an upstream service's own code
  belongs in `details`.
- `emit` — append `value` to this execution's output stream, then take `transition`. Where
  `return` is emit-and-terminate, `emit` is emit-and-continue, so a workflow can produce many
  values over its lifetime instead of exactly one at the end.

Failing a path is deliberately an action rather than something an expression does: a rule whose
condition detects the bad shape and an `error` that names it are both visible in the document,
where a `throw` inside a value would not be. The language has no `throw` for that reason.

A transition may name an already-visited activity. That back-edge is a loop, and is the intended
way to express polling.

### Fanning out

A promise branch dispatches a document, with the same three keys an `onEmitted` rule uses —
`workflow`, `startActivity`, `input`. That sameness is the point: dispatching work is one shape to
learn, whichever construct is doing it.

```yaml
fan-out:
  type: promise.all
  branches:
    - name: "addon-{{ item.sku }}"
      forEach: { collection: "{{ input.addons }}", alias: item }
      workflow: pricer                # a dependency alias, or `self`
      startActivity: quote
      input: { sku: "{{ item.sku }}" }
  onSuccess:
    - return: { quotes: "{{ output }}" }
```

`branch.name` keys the promise output map and is unrelated to the document named. It is rendered
in the branch scope, so a `forEach` expansion can be named after the item it processes —
`addon-SKU-123` rather than `item_0`, which is the difference between a failure report that
identifies itself and one that does not. **The rendered names must be distinct within one
promise**; that is a run-time failure, not a validation error, because rendering needs the
collection and validation does not evaluate templates.

A branch names a document rather than an activity in the current one. `workflow: self` covers
fanning out over this same document — including a branch that re-enters the promise activity
itself, which is how recursive fan-out is written.

### Emitting and consuming values

A workflow that emits is a producer; a `workflow.call` activity that declares `onEmitted` is its
consumer. Together they express "watch something and hand each result to my caller" without the
caller having to know how the watching works.

```yaml
# In the producer — poll, hand each batch to the caller, wait, repeat.
poll:
  type: http
  method: GET
  url: "{{ env.MAIL_API }}/messages?since={{ input.cursor }}"
  onSuccess:
    - condition: "output.messages.length > 0"
      emit:
        value:
          messages: "{{ output.messages }}"
        transition:
          name: wait
          input: { cursor: "{{ output.cursor }}" }
    - transition:
        name: wait
        input: { cursor: "{{ input.cursor }}" }
```

```yaml
# In the consumer — one handler per emitted value, then back for the next.
watch:
  type: workflow.call
  workflow: mailbox
  startActivity: poll
  onEmitted:
    # This is what we were waiting for: stop, and finish with it.
    - condition: "output.subject === 'approved'"
      return: { approvedBy: "{{ output.from }}" }

    # Stop, but carry on with the rest of this workflow.
    - condition: "output.subject === 'cancelled'"
      transition: { name: release-hold }

    # Anything else: hand it to a document and come back for the next value.
    - handle:
        workflow: ingester          # a dependency alias; `self` is not legal here
        startActivity: ingest
        input: { messages: "{{ output.messages }}" }
  onSuccess:
    - return: { done: true }        # reached only when the mailbox itself ends
```

An `onEmitted` rule is an optional `condition` and exactly one action. What each does to **this**
workflow and to the **producer** it is consuming:

| Action | This workflow | The producer |
|---|---|---|
| `handle` | Runs the named document for this value and waits for it to finish, then takes the next value. | Stays parked until the handler finishes, so values arrive one at a time and never pile up. |
| `transition` | Continues at the named activity, in this workflow. | Cancelled. |
| `return` | Ends, with that value as its result. | Cancelled. |
| `error` | Fails, with that error. A bare `error` has nothing to re-raise here — `error` is `null` in an `onEmitted` rule — so it must carry a `code` (`UTOS-T005`). | Cancelled. |

Only `handle` continues consuming. The other three leave the loop, and leaving it cancels the
producer **at that point** rather than when this workflow eventually ends — nothing will observe it
again, and a gated producer left running would sit on an acknowledgement that is never coming,
holding an execution and a stream for as long as this workflow keeps going.

Without them a consumer has no way to stop consuming at all: its only exit is the producer
terminating, which for an intentionally endless poller never happens.

Note the two `return`s above mean the same thing and are reached differently: the one in
`onEmitted` fires on a value while the mailbox is still running, the one in `onSuccess` only once
the mailbox has finished on its own. An action's meaning does not change with the list it appears
in; what changes is when the list is evaluated.

```yaml
# In the handler document — only handler work, because that is all it can hold.
ingest:
  type: http
  method: POST
  url: https://api.example.com/ingest
  body: '{"messages": {{ input.messages }}}'
```

What follows from this being one ordered stream rather than a side channel:

- **Order is structural.** Emitted values and the final result are entries in one stream walked by
  one cursor, so `onEmitted` fires for every value before `onSuccess` sees the result. A
  fast-terminating producer cannot overtake its own output.
- **The consumer sets the pace.** An `emit` does not complete until its consumer has moved past
  it, so a producer cannot run ahead and pile up unconsumed values. A poller simply returns a
  larger batch next time, which is the desired behaviour — see
  [`execution-output-stream.md`](execution-output-stream.md).
- **A finished handler goes back for the next value.** The handler is a document, and its
  execution terminating is what completes one iteration; control then returns to the call activity
  for the next value. A rule list that matches nothing skips that value and takes the next, which
  is how a filtering consumer is written.
- **A handler's result is discarded, and its emissions relay.** A handler has one way to say
  something, and it is to `emit`: a value emitted inside a handler is appended to the *consumer's*
  own output stream and handed to the consumer's caller. That preserves what happened when the
  handler ran inline in the consumer, and needs no keyword. A terminal `result` in a handler has
  nowhere to go and is dropped — two ways to surface a value would be one too many.
- **A subscription outlives nothing.** It ends when a rule leaves the loop, and also when the
  consuming execution terminates by any other route — a `return` or an `error` on some other
  path, cancellation, failure. The producer is cancelled either way, because nothing will observe it
  again. Only the first of those is reachable *while consuming*, which is why it exists: `onSuccess`
  and `onFailure` are evaluated after the producer has finished, so a consumer with only those has
  no way to stop early.

A `workflow.call` without `onEmitted` ignores emissions and simply awaits the result, and
`workflow.spawn` has no consumer at all. Emitted values are still recorded either way, readable
over `ExecutionService.WatchOutput`.

### Templates

String values may embed `{{ }}` expressions, and `condition` fields are bare expressions. The
language — JavaScript, restricted to a subset — the names an expression can see (`input`,
`output`, `error`, `response`, `env`) and what each holds are defined in
[`template-expressions.md`](template-expressions.md), § Scope in particular. This section shows how
a document uses them.

`env` is supplied by whoever starts the run (`ScheduleExecutionRequest.env`; `utos run --env` in
the reference CLI), the analogue of `docker run -e`. A document does not set it, but it should
**declare what it requires** in `spec.env`, so that a run missing a variable is refused at
schedule instead of rendering a URL with a hole in it
([`workflow-schemas.md`](workflow-schemas.md)).

`output`, `error` and `response` describe the activity a rule is **leaving**. None of them is in
scope when the *target* activity's own `url`, `headers` or `body` are rendered — that is a fresh
scope of `input` and `env`. Anything the target needs is carried across in the transition's
`input` transform:

```yaml
onFailure:
  - condition: "response.status === 429"
    transition:
      name: backoff
      input:
        retryAfter: "{{ response.headers['retry-after'] }}"   # or it is gone
```

The same holds for bytes. A body is carried to the next activity as a value, and a whole-field
`body` that evaluates to a blob sends it — the pattern for fetching a file and uploading it
somewhere else:

```yaml
activities:
  fetch:
    type: http
    method: GET
    url: "{{ input.source }}"
    onSuccess:
      - transition:
          name: upload
          input:
            photo: "{{ response.body }}"     # a Blob, inline or stored — the same either way
  upload:
    type: http
    method: PUT
    url: "https://storage.example.com/photos/{{ input.photo.size }}.png"
    body: "{{ input.photo }}"                # sends the bytes; content-type from the blob
```

See [`binary-data.md`](binary-data.md) for what a blob is, where its bytes live, and how a client
puts one into a run or takes one out.

## Building a bundle

A front end turns a source document into a `WorkflowBundle`:

1. Parse the entry document and, recursively, every dependency.
2. Compute each workflow's canonical identity from its own `metadata`.
3. Rewrite every place a document is named — a `workflow.call` or `workflow.spawn` activity's
   `workflow`, a promise branch's `workflow`, and an `onEmitted` rule's `handle.workflow` — from
   the **alias** to the **canonical identity** of what it resolved to, and `self` to this
   document's own. A bundle names documents only by canonical identity (`UTOS-B006`).
4. Empty each `spec.dependencies` map. Aliases have served their purpose, and leaving them would
   make two builds of the same logical workflow hash differently.
5. Set `entryPoint` to the entry document's canonical identity and key every workflow in
   `workflows` by its own.

Source-format errors detected during this pass — as distinct from the bundle rules in
[`workflow-validation.md`](workflow-validation.md), which apply to the result:

| Code | Rule |
|---|---|
| `UTOS-S001` | A dependency alias is empty, or declared twice |
| `UTOS-S002` | A dependency reference is malformed |
| `UTOS-S003` | A local dependency file does not exist or cannot be read |
| `UTOS-S004` | A `workflow` value names an alias that is not declared in `spec.dependencies`. `self` is excepted — it names this document and needs no entry |
| `UTOS-S005` | The dependency graph contains a cycle |
| `UTOS-S006` | Two documents resolve to the same canonical identity with differing content |
| `UTOS-S007` | An activity's `type` is missing, is not a known activity kind, or stops short of a mode the kind requires (e.g. bare `workflow` rather than `workflow.call`) |
| `UTOS-S008` | A mapping contains duplicate keys |
| `UTOS-S009` | A document is not well-formed, or does not match the workflow schema |
| ~~`UTOS-S010`~~ | *Unallocated, and not to be reused.* See below |
| `UTOS-S011` | `self` is used anywhere other than a promise branch's `workflow` |
| `UTOS-S012` | A schema declares one property twice, once required and once optional — `x` alongside `x?` |
| `UTOS-S013` | A schema declares a `type` that is not in the type registry |
| `UTOS-S014` | A schema uses a constraint key that is unknown, or that does not apply to the declared type |
| `UTOS-S015` | A schema's `maxSize` is neither a non-negative integer nor a size with a recognised unit, or does not come to a whole number of bytes |

`UTOS-S004` covers every place a document is named — a `workflow.call` or `workflow.spawn`
activity, a promise branch, and an `onEmitted` rule — because they all resolve the same way.
`UTOS-S011` is the exception to that symmetry: only a promise branch may write `self`. See
[`self`](#self) for why the one place it is load-bearing is also the only place it is safe.

**A `UTOS-S###` code names a defect in a document.** An implementation's own limitations are not
rules and take no code: a feature it has not built, a reference kind it cannot yet resolve, a
backend it lacks. The test is whether a conforming implementation that *had* built the thing could
ever report it — if not, the document was never wrong, and a code would say it was. Such a problem
is still worth reporting, and should be reported clearly; it just does not belong in a range that
every implementation shares and every author may rely on.

`UTOS-S010` is therefore **unallocated and should stay so**. The reference CLI briefly used it for
"registry resolution is not implemented yet", which is precisely the case above, and versions
carrying that code are in the wild. Allocating it to a real rule later would give one identifier
two meanings.

`UTOS-S012`–`UTOS-S015` belong to the **short form** of
[`workflow-schemas.md`](workflow-schemas.md), which exists only here: a bundle carries plain JSON
Schema, so these are defects a bundle can no longer express and the rules therefore have to live
in this range. Everything a bundle *can* still get wrong about a schema — a bad `$ref`, an unknown
`format`, a `default` that does not validate — is `UTOS-H0##`, checked on the built form like every
other bundle rule.

`UTOS-S012` catches what a duplicate-key check cannot. `x` and `x?` differ as text, so no parser
objects, and they mean one property: the document says it is both required and optional and there
is no reading that is more likely than the other.

## Worked example

Two files, and the bundle they produce.

`order-fulfilment.yaml`:

```yaml
apiVersion: utos.io/v1
kind: Workflow
metadata:
  name: order-fulfilment
  version: 1.0.0
  namespace: acme
spec:
  dependencies:
    emailer: ./send-email.yaml
  activities:
    fetch:
      type: http
      method: GET
      url: https://api.example.com/orders/1
      onSuccess:
        - transition: { name: notify }
    notify:
      type: workflow.call
      workflow: emailer
      startActivity: send
```

`send-email.yaml`:

```yaml
apiVersion: utos.io/v1
kind: Workflow
metadata:
  name: send-email
  version: 2.1.0
  namespace: acme
spec:
  activities:
    send:
      type: http
      method: POST
      url: https://mail.example.com/send
```

Built bundle, in the canonical JSON form of
[`canonical-bundle-digest.md`](canonical-bundle-digest.md):

```json
{
  "entryPoint": "acme/order-fulfilment:1.0.0",
  "workflows": {
    "acme/order-fulfilment:1.0.0": {
      "apiVersion": "utos.io/v1",
      "kind": "Workflow",
      "metadata": { "name": "order-fulfilment", "namespace": "acme", "version": "1.0.0" },
      "spec": {
        "activities": {
          "fetch": {
            "http": { "method": "GET", "url": "https://api.example.com/orders/1" },
            "onSuccess": [ { "transition": { "name": "notify" } } ]
          },
          "notify": {
            "workflow": {
              "call": {},
              "startActivity": "send",
              "workflow": "acme/send-email:2.1.0"
            }
          }
        }
      }
    },
    "acme/send-email:2.1.0": {
      "apiVersion": "utos.io/v1",
      "kind": "Workflow",
      "metadata": { "name": "send-email", "namespace": "acme", "version": "2.1.0" },
      "spec": {
        "activities": {
          "send": { "http": { "method": "POST", "url": "https://mail.example.com/send" } }
        }
      }
    }
  }
}
```

Note the alias `emailer` is gone — replaced by `acme/send-email:2.1.0` — and `dependencies` with
it.

## Migrating

Non-normative. What changes for a document written against an earlier version.

### A consumer written before 0.0.13

**This one is silent.** `onEmitted` has had three shapes. Before 0.0.13 a rule was an ordinary transition rule, the same thing `onSuccess` carries,
and `- transition: { name: process }` meant *handle this value at `process`, then come back* — that
was how the consuming loop was closed. 0.0.13 made a rule a flat dispatch naming a document, which
turned that spelling into an unknown field and rejected the document. 0.0.14 makes it **legal
again, meaning the opposite**: stop consuming, and cancel the producer.

So a pre-0.0.13 consumer does not fail against 0.0.14. It validates cleanly and quietly becomes a
one-shot — handling the first value, cancelling its producer and finishing, where it used to loop
indefinitely. 0.0.13 caught this by refusing the document; 0.0.14 cannot, and no rule code can,
because the old spelling and the new one are the same word applied to the same field. It is worth
grepping for, since nothing else will tell you.

The migration is not textual. The activity the old rule transitioned to has to move into a document
of its own, because `handle` names a document and `self` is not legal there (`UTOS-S011`).
