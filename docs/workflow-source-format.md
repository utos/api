# Workflow Source Format

Defines the **source format** — what people author — and its normative mapping onto
`utos.workflow.v1.Workflow` (`workflow/v1/workflow.proto`). The daemon never sees this format:
the CLI reads it, resolves dependencies, and produces a `WorkflowBundle`
(`workflow/v1/bundle.proto`), which is what crosses the wire.

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
```

- `apiVersion` — must be `utos.io/v1`. A group/version pair mirroring the proto package major,
  not a semver, and distinct from `metadata.version`.
- `kind` — must be `Workflow`.
- `metadata.name` + `metadata.version` are required; together with the optional `namespace` and
  `registry` they form the workflow's **canonical identity**,
  `[registry/][namespace/]name:version` — the key under which this workflow appears in a built
  bundle.

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

## Activities

`spec.activities` maps an activity name to its definition. The names `end` and `error` are
reserved terminal keywords and may not be used.

Every activity has a `type` naming its kind, the fields belonging to that kind alongside it, and
optional `onSuccess` / `onFailure` transition lists.

```yaml
spec:
  activities:
    fetch-order:
      type: http
      method: GET
      url: "{{ env.API_BASE }}/orders/{{ input.orderId }}"
      headers:
        accept: application/json
      onSuccess:
        - condition: "{{ output.status == 'paid' }}"
          transition:
            name: notify
            input:
              to: "{{ output.customer.email }}"
        - transition: { name: wait }
      onFailure:
        - transition: { name: error }

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
        - result:
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
   `on_success` / `onSuccess` and `on_failure` / `onFailure`.
3. Every remaining key — `type` excluded — is placed on the message **along the resolved path**
   that declares a field of that name, nested under the oneof field names that reach it.
4. The result is parsed as proto3 JSON. Unrecognized keys inside the configuration surface here
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
restructuring occurs.

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

- `transition` — go to another activity. `name` is an activity in the same workflow, or the
  terminal keyword `end` or `error`. The optional `input` is a transform producing the target's
  `input` context; leaf strings may contain `{{ }}` expressions. Omitted, the source activity's
  output passes through unchanged.
- `result` — end this execution path, returning the given structure.
- `emit` — append `value` to this execution's output stream, then take `transition`. Where
  `result` is emit-and-terminate, `emit` is emit-and-continue, so a workflow can produce many
  values over its lifetime instead of exactly one at the end.

A transition may name an already-visited activity. That back-edge is a loop, and is the intended
way to express polling.

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
    - condition: "{{ output.messages | array.size > 0 }}"
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
    - transition: { name: handle }
  onSuccess:
    - result: { done: true }

handle:
  type: http
  method: POST
  url: https://api.example.com/ingest
  body: '{"messages": {{ input.messages }}}'
  # No transition. The handler is finished, so the next value is taken.
```

Three things follow from this being one ordered stream rather than a side channel:

- **Order is structural.** Emitted values and the final result are entries in one stream walked by
  one cursor, so `onEmitted` fires for every value before `onSuccess` sees the result. A
  fast-terminating producer cannot overtake its own output.
- **The consumer sets the pace.** An `emit` does not complete until its consumer has moved past
  it, so a producer cannot run ahead and pile up unconsumed values. A poller simply returns a
  larger batch next time, which is the desired behaviour — see
  [`execution-output-stream.md`](execution-output-stream.md).
- **A finished handler goes back for the next value.** When the handler path runs out of
  transitions it has completed one iteration, and control returns to the call activity — the same
  way a promise branch returns to its promise. Transitioning back by name is still allowed and
  means the same thing; it is simply no longer required, so the last activity of a handler chain
  does not have to know which call activity dispatched it. A rule list that matches nothing skips
  that value and takes the next.
- **Terminating ends the subscription.** `end` or a `result` finishes the consuming execution,
  which cancels the producer, because nothing will observe it again. That is how a consumer stops
  early.

A `workflow.call` without `onEmitted` ignores emissions and simply awaits the result, and
`workflow.spawn` has no consumer at all. Emitted values are still recorded either way, readable
over `ExecutionService.WatchOutput`.

### Templates

String values may embed `{{ }}` expressions. Five context objects are available:

| Context | Meaning |
|---|---|
| `input` | What this activity received — the workflow input for the start activity, or the preceding transition's transform result |
| `output` | The raw output of the activity the transition is leaving. Meaningful on the success path; an activity that failed produced none |
| `error` | Why the activity failed — `code` and `message`. Meaningful on the `onFailure` path |
| `response` | The HTTP response, when the activity was `http` — `status`, `headers`, `bodyText`. Available on **both** paths |
| `env` | The run's ambient environment, supplied per execution (`utos run --env`) |

`env` is deliberately not declared in the workflow document. It is per-run ambient state, the
analogue of `docker run -e`, and is always `string → string`.

`error` is kept separate from `output` rather than replacing it, because a failed activity produced
no output and overloading one name with the other's meaning would let a condition written for the
success path silently read error fields on the failure path.

**Every context is always defined, and so is every key within `error` and `response`** — with null
values where they do not apply. A condition may therefore name `response.status` on an activity that
made no request, or after a request that never got a response at all, and evaluate `false` rather
than failing. Implementations must not leave these undefined: the failure that would raise is raised
*while a failure is already being handled*, which is the worst moment for it.

`error` and `response` describe the activity a transition is **leaving**. Neither is in scope when
the *target* activity's own `url`, `headers` or `body` are rendered — that is a fresh scope of
`input` and `env`. Anything a handler needs must be carried across in the transition's `input`
transform:

```yaml
onFailure:
  - condition: "{{ response.status == 429 }}"
    transition:
      name: backoff
      input:
        retryAfter: "{{ response.headers['Retry-After'] }}"   # or it is gone
```

## Building a bundle

The CLI turns a source document into a `WorkflowBundle`:

1. Parse the entry document and, recursively, every dependency.
2. Compute each workflow's canonical identity from its own `metadata`.
3. Rewrite every sub-workflow activity's `workflow` field — `workflow.call` and `workflow.spawn`
   alike, since both carry it on the same `WorkflowActivityConfig` — from the **alias** to the
   **canonical identity** of what that alias resolved to.
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
| `UTOS-S004` | A sub-workflow activity names an alias that is not declared in `spec.dependencies` |
| `UTOS-S005` | The dependency graph contains a cycle |
| `UTOS-S006` | Two documents resolve to the same canonical identity with differing content |
| `UTOS-S007` | An activity's `type` is missing, is not a known activity kind, or stops short of a mode the kind requires (e.g. bare `workflow` rather than `workflow.call`) |
| `UTOS-S008` | A mapping contains duplicate keys |

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
