# Workflow Schemas

Defines what a workflow may declare about the data crossing its boundaries: the dialect, the
authoring form and its compilation, the types that may be declared, where declarations are
checked, and what a failure reports. These are **spec-level** rules, each with a stable code, for
the same reason as [`workflow-validation.md`](workflow-validation.md): a contract that one
implementation enforces and another ignores is not a contract.

Until now a workflow said nothing about what it takes or returns. A caller learned the shape by
running it, a bad input failed somewhere in the middle rather than at the door, and a registry had
nothing to show. A declaration closes that, and it is also what makes anything further possible:
without one, every value is "some JSON" and there is nothing for a tool to reason about.

## What is declared, and where

| Slot | Declares | Wire |
|---|---|---|
| `spec.activities[…].schema.input` | What that activity accepts | `ActivitySchema.input` (`workflow/v1/activity.proto`) |
| `spec.output` | What the workflow returns | `WorkflowSpec.output` (`workflow/v1/workflow.proto`) |
| `spec.emits` | One value the workflow emits | `WorkflowSpec.emits` |
| `spec.env` | The ambient environment the workflow requires | `WorkflowSpec.env` |

Every slot is a `google.protobuf.Struct`, because a JSON Schema is arbitrary JSON and no new value
type is needed for one.

**Every slot is optional, and an absent slot is the empty schema** — anything the wire can carry
satisfies it. Every workflow written before this document keeps working, unchanged and unchecked,
which is the only migration story a feature like this can afford.

**Input is declared on activities; output is declared on the workflow.** The asymmetry is not an
oversight. A run is scheduled with a start activity and its input goes to *that* activity, so a
document with three entry points has three input shapes and one workflow-level input schema would
be a fiction. A result is one shape whatever the entry, so it belongs to the workflow. **There is
no `spec.input`.**

Which makes an activity's `input` the only input schema in the system. Everything that supplies an
activity with data is checked against it: the run input for the start activity, a transition's
rendered `input` for the target, a sub-workflow's input for the callee's start activity.

**Only `input` is declarable on an activity.** An activity's output shape follows from its kind —
an `http` activity's is the parsed JSON body or `null`, a `timer`'s is its input, a
`workflow.call`'s is the callee's `spec.output` — so it is derived, and authoring it would be a
second place to disagree.

## The dialect

**JSON Schema 2020-12**, pinned. Not a format of our own: authors, editors, generators and every
second implementation already know it, and it exports to OpenAPI.

A bundle carries **plain JSON Schema**. The short authoring form below is a front end, compiled
away by whatever reads the source format, so nothing downstream has to learn ours.

Three refinements to stock 2020-12, each stated because an off-the-shelf validator does not make
them on its own:

1. **`format` is asserted, not annotated.** 2020-12 treats `format` as an annotation unless a
   validator opts in, so a typo'd `date-tim` silently checks nothing. Here the vocabulary is
   assertive and an unlisted name is a load error (`UTOS-H007`).
2. **`integer` means an integer the expression language can hold** — the same bound `UTOS-E104`
   draws, at most ±2⁵³ (`template-expressions.md` § Numbers). Stock 2020-12 would accept `1e100`,
   and a schema that accepted one would be declaring a value no expression could ever read. The
   bound is stated by reference rather than restated, so the two cannot drift apart; exceeding it
   fails **`type`**, because the bound is part of what `integer` means here and not a separate
   constraint an author could have written.
3. **`$ref` reaches two places and no others** — this schema's own `$defs`, and the types this
   spec publishes (§ The type registry). Nothing is ever fetched over the network or off the disk
   while a schema is evaluated.

`$schema` must be `https://json-schema.org/draft/2020-12/schema` wherever it appears, and a
compiler **drops it**: the dialect is pinned by this document, so carrying it in every bundle is
noise that would also have to be kept identical for two builds to hash alike. `UTOS-H004` is
nonetheless a bundle rule and not a source one, because a bundle can be written by hand or by
another front end, and one carrying a different dialect URI is claiming to be something this spec
does not define.

## Authoring

An **activity** declares what it takes; the **workflow** declares what it produces and what it
needs from its environment:

```yaml
spec:
  env:
    RESIZER:                             # required
    QUALITY_PRESET?: { default: web }     # optional, with a default

  output:
    thumbnail: { type: string, format: uri }
    bytes:     { type: integer }

  activities:
    resize:
      type: http
      schema:
        input:
          photo:      { type: string, format: uri }
          quality?:   { type: integer, min: 1, max: 100, default: 80 }
          watermark?: { type: string, nullable: true }
          tags?:      { type: array, items: { type: string } }
      method: POST
      url: "{{ env.RESIZER }}/resize"
```

**The declaration nests under `schema:` because `input:` is taken.** On a `workflow.call` activity
`input` is the *child's* input, and the same holds for a promise branch and a handler dispatch, so
an activity's own declaration cannot live there. `schema:` also leaves room for whatever else turns
out to be declarative.

`resize.schema.input` compiles to:

```json
{
  "type": "object",
  "required": ["photo"],
  "properties": {
    "photo": { "type": "string", "format": "uri" },
    "quality": { "type": "integer", "minimum": 1, "maximum": 100, "default": 80 },
    "watermark": { "type": ["string", "null"] },
    "tags": { "type": "array", "items": { "type": "string" } }
  },
  "unevaluatedProperties": false
}
```

### The three forms a slot may take

A slot's value is read as exactly one of these, decided mechanically and in this order:

| # | When | Read as |
|---|---|---|
| 1 | it has a `$schema` key | **raw JSON Schema**, copied through with `$schema` removed |
| 2 | it has a `type` key whose value is the **string** `object` | an **object declaration** (the long form) |
| 3 | otherwise | a **field map** (the short form), meaning `{ type: object, properties: <the map> }` |

The discriminator is total because the short form's values are always mappings: a field genuinely
named `type` is written `type: { type: string }`, whose value is a mapping, so a `type:` with a
*string* value can only be the long form. Nothing has to be guessed and no key is ambiguous.

**An empty field map is not an absent schema.** `input: {}` is form 3 with no properties, which
compiles to a closed object declaring nothing — a value must be `{}` to satisfy it. That is a
useful thing to say about an activity that takes no input, and it is emphatically not what
"declare nothing" means. **Omit the slot** to declare nothing; the two are as different as an
empty list and no list.

Form 1 is the escape hatch, for `oneOf`, `if`/`then`, `patternProperties`, tuples and everything
else the short form does not reach. **The short form is a front end, not a ceiling**, and it stays
short precisely because there is somewhere else to go.

```yaml
# 3 — the short form, which is what almost everything should be
input:
  orderId: { type: string }

# 2 — the long form, when the object itself needs a constraint
input:
  type: object
  open: true
  properties:
    orderId: { type: string }

# 1 — raw JSON Schema, for what the short form does not reach
input:
  $schema: https://json-schema.org/draft/2020-12/schema
  type: object
  properties:
    payment: { oneOf: [ { $ref: "#/$defs/Card" }, { $ref: "#/$defs/Invoice" } ] }
  $defs: { ... }
```

### Rules the short form follows

- **Required by default.** A property is required unless its key ends in `?`. JSON Schema's own
  default is the opposite, and silently accepting a payload that is missing a field is the failure
  this feature exists to prevent.
- **Optional is spelled `?` on the key**, as in TypeScript and Zod. `?` is an ordinary character in
  a YAML plain scalar, so `quality?:` parses as the key `quality?` — only a `?` that *starts* a
  token and is followed by a space is YAML's explicit-key indicator. A quoted `"quality?"` means
  the same thing. A property whose real name ends in `?` is not expressible here; use form 1.
- **Error paths use the clean name.** A failure on `quality?` reports `quality`, and `?` never
  appears in a JSON Pointer.
- **Declaring both `quality` and `quality?` is a duplicate property**, rejected by the source
  format (`UTOS-S012`). The two keys differ as text and mean one property, which is exactly the
  case a duplicate-key check does not catch.
- **`default` requires the `?`.** A default on a required property is a contradiction — the value
  is always supplied, so the default can never be reached — and rejecting it beats guessing which
  half the author meant (`UTOS-H009`).
- **`nullable: true` is separate from `?`.** A property may be absent (`?`) or hold `null`
  (`nullable`), and the system already distinguishes them: `undefined` omits a field and `null` is
  carried (`template-expressions.md` § Results). JSON APIs return `null` for "known to be absent"
  constantly, so both are needed and neither implies the other.
- **`required` is emitted sorted** (ordinal), not in declaration order. `properties` is a JSON
  object whose keys the digest sorts anyway, so leaving `required` order-sensitive would make it
  the one place a reordering of unrelated keys changed a workflow's identity.

### Constraint keys

| Key | Applies to | Compiles to |
|---|---|---|
| `type` | every declaration | `type`, or a `$ref` for a published type |
| `$ref` | every declaration, in place of `type` | `$ref` |
| `description` | every declaration | `description` |
| `nullable` | every declaration | widens `type` with `"null"`, or wraps a `$ref` in an `anyOf` with `{ "type": "null" }` |
| `const`, `enum` | every declaration | unchanged |
| `default` | an optional property | `default` |
| `format` | `string` | `format` |
| `minLength`, `maxLength`, `pattern` | `string` | unchanged |
| `min`, `max` | `number`, `integer` | `minimum`, `maximum` |
| `exclusiveMin`, `exclusiveMax` | `number`, `integer` | `exclusiveMinimum`, `exclusiveMaximum` |
| `multipleOf` | `number`, `integer` | unchanged |
| `items` | `array` | `items` — one nested declaration |
| `minItems`, `maxItems`, `uniqueItems` | `array` | unchanged |
| `properties` | `object` | `properties` — a nested field map |
| `open` | `object` | `true` omits `unevaluatedProperties: false` |

`min`/`max` are shortened because they are the two that appear on nearly every numeric field; the
rest keep their JSON Schema names so that what an author learns here transfers. A key outside this
table, or one that does not apply to the declared `type`, is `UTOS-S014`.

### Closed objects, and the one that is not

**An object is closed.** An undeclared property is an error — not something to ignore, and not
something to strip. Stripping is a transform, and it silently discards a typo'd key, which is the
failure mode worth catching. `open: true` is the explicit opt-in for the genuinely open case.

**Closed compiles to `unevaluatedProperties: false`, never `additionalProperties: false`.**
`additionalProperties` only sees properties declared in the *same* schema object, so paired with a
`$ref` it rejects everything the reference brought in — the oldest trap in JSON Schema, and what
2020-12 added `unevaluatedProperties` to fix. A short form that compiled to the wrong one would
break the moment a published type was used.

**`spec.env` is the exception: it is never closed.** `env` is ambient — it is supplied per run,
shared across a run tree, and a sub-workflow inherits its parent's. Closing it would mean a child
rejecting every variable its parent needed and it did not, and would make an operator's shared
deployment variable an error in every document that did not name it. `spec.env` declares what a
workflow *requires*, not the whole of what it will be given.

### `spec.env`

The short form, restricted to strings, because `ScheduleExecutionRequest.env` is
`map<string, string>`:

```yaml
spec:
  env:
    API_BASE:                                  # required
    REGION?:    { default: us-east-1 }         # optional, with a default
    LOG_LEVEL?: { enum: [debug, info, warn] }  # optional, constrained
```

```json
{
  "type": "object",
  "required": ["API_BASE"],
  "properties": {
    "API_BASE": { "type": "string" },
    "REGION": { "type": "string", "default": "us-east-1" },
    "LOG_LEVEL": { "type": "string", "enum": ["debug", "info", "warn"] }
  }
}
```

A **null value is a required string with no further constraints** — `API_BASE:` with nothing after
it — which is the common case and deserves the short spelling. `type` may be written and must be
`string` if it is; every property of a compiled `spec.env` is `string`-typed (`UTOS-H011`).

Every workflow we have documents its variables in a comment today and nothing checks them. A run
missing a required variable is now rejected at schedule, before anything executes.

## The type registry

Two lists that have to line up: what a schema may declare, and what an expression may hold. The
spec owns both, and adding a type is a spec release.

| Declared | On the wire | In an expression | Notes |
|---|---|---|---|
| `string` | string | string | |
| `number` | number | number | Any number, floating point included |
| `integer` | number | number | Whole and safe: `10.0` passes, `10.5` and `1e100` do not |
| `boolean` | boolean | boolean | |
| `object` | object | object | Frozen in scope |
| `array` | array | array | Frozen in scope |
| `null` | null | `null` | Distinct from absent |

**`number` and `integer` are two declared types and one runtime type.** Zod makes the same split —
`z.number()` and `z.int()` are separate schemas over one JavaScript `number` — and it is the right
one here: a declared type says what a boundary accepts, while the language has one numeric type
(`template-expressions.md` § Numbers) and keeps it.

`integer` is JSON Schema's own definition — *any number with a zero fractional part* — so it checks
the value and not the spelling. `10.0` passes because it **is** `10`; it could not do otherwise,
since `10.0` and `10` are one value in JSON and in JavaScript alike and the text that distinguished
them is gone once parsed. That is also what you want when a server may serialise a whole number
either way. What is added is the bound: past it a double stops holding consecutive integers
exactly, and a snowflake-style id that came back changed would be worse than an error. It is the
same bound `UTOS-E104` draws on a value entering an expression, so a declared `integer` and a
readable one are the same set. Such ids travel as strings.

**Expression-only types are not declarable, because they cannot be values.** `Buffer`, `Date`,
`URL`, `URLSearchParams`, `Set` and `Map` exist inside an expression and must be turned back into
data before the value leaves (`UTOS-E103`). A schema therefore never mentions them, and there is no
declared type whose values an expression could not produce.

**Each type defines four things** — its authoring spelling, its JSON Schema form, its wire form and
its runtime type in an expression — and the conformance corpus carries a case for each.

**The table is the whole list**, and a `type` outside it is `UTOS-S013`. That is a source-format
code rather than an `UTOS-H0##` one because the registry is a feature of the short form: `type` in
a compiled schema is JSON Schema's own keyword, whose legal values the meta-schema already fixes
(`UTOS-H002`), so an unknown *declared* type is a defect only a source document can have.

### Published types

`$ref` resolves against a **built-in registry of schemas this spec publishes**, addressed
`utos:<name>` and never fetched: an implementation ships them, so a schema is evaluated without
I/O and a registry outage cannot stop a workflow loading.

**The registry is empty in this version.** The mechanism is specified now because the first two
entries — `blob` and `file` — arrive with binary data, and a type whose *values* do not yet exist
would be a declaration no run could ever satisfy. Until then every `$ref` names a JSON Pointer into
the same schema's `$defs`, and a `utos:` name is `UTOS-H005`.

Sibling keywords beside a `$ref` are legal in 2020-12 and are how a published type will carry a
constraint, which is the other reason closed means `unevaluatedProperties`.

### Formats

Asserted, from this list, and an unknown name is a load error (`UTOS-H007`) rather than something
ignored:

`date-time`, `date`, `time`, `duration`, `uuid`, `email`, `uri`, `hostname`

The list grows by spec release. **A format validates; it does not convert.**
`{ type: string, format: date-time }` checks the text and leaves a string in scope — a declared
`date-time` does not arrive as a `Date`, because that would be a coercion and because a `Date`
cannot leave an expression anyway (`UTOS-E103`). The author writes `new Date(input.when)`.

### No transforms, no coercion

A schema **judges** a value; it does not rewrite one. A string where a number was declared is an
error, not a conversion. Filling a declared default is the single, bounded exception, and it is
bounded as follows.

## Defaults

Filling a default is the one place a schema touches data. The rules that keep it honest:

- **Inbound boundaries only.** A default is filled wherever an activity's declared `input` is
  applied — scheduling a run, a transition into that activity, and an invocation of it — and, at
  the one inbound boundary that is not an activity input, against `spec.env` at schedule. A
  default therefore means the same thing whichever way the activity is reached. An optional property that is absent and has
  a `default` is present, holding it, from that point on.
- **Output schemas never fill.** An absent required property in a result or an emitted value is a
  failure, not something to complete. A workflow that did not produce a field did not produce it.
- **The filled value is what is recorded.** A replay sees exactly what the run saw, and an operator
  reading an execution's input sees what the activity actually received.
- **A default must itself validate** against the schema that declares it, checked at load
  (`UTOS-H008`), so a default can never be the thing that fails a boundary it was meant to satisfy.
- **`null` is a value, not an absence.** A property explicitly holding `null` is present, and its
  default is not filled. This is the same distinction `?` and `nullable` draw.

## Where a declaration is checked

| When | What | Against | On failure |
|---|---|---|---|
| Load | Every schema in the bundle is well-formed and resolvable | the rules below | `UTOS-H0##` at the schema's path |
| Load | A `transition.input` / invocation `input` property set | the target's declared `input` | `UTOS-H013`, `UTOS-H014` |
| Schedule | The run input | the **start activity's** `input`, then defaults filled | `UTOS-H101`, as `INVALID_ARGUMENT` |
| Schedule | The run's environment | `spec.env`, then defaults filled | `UTOS-H102`, as `INVALID_ARGUMENT` |
| Transition | The rendered `input` | the target activity's `input`, then defaults filled | `UTOS-H103`, and the run fails |
| Invocation | The rendered `input` | the callee's **start activity's** `input`, then defaults filled | `UTOS-H104`, and the invocation fails |
| Return | The result | `spec.output` | `UTOS-H105`, and the run fails |
| Emit | Each emitted value | `spec.emits` | `UTOS-H106`, and the run fails |

**"Invocation" is every construct that starts a document with an input**: a `workflow.call` or
`workflow.spawn` activity, a promise branch, and an `onEmitted` rule's `handle`.

The word is not *dispatch*, deliberately. `workflow-validation.md` defines a dispatch narrowly —
a promise branch and a `handle` block, the two that name a document and have no activity of their
own — and holds a `workflow.call` apart from it, which is the whole reason `UTOS-C401`–`C403` sit
beside `UTOS-C501`–`C503`. That distinction is about *whose flow the work belongs to*, and it is
worth keeping. This boundary does not care: all four supply a document's start activity with a
value, and the check is the same one. A second word is cheaper than overloading a term another
rule set depends on.

**Which `spec.emits` an emitted value is checked against is the workflow that declares the
`emit`.** A handler's emissions relay onto the consumer's output stream
([`execution-output-stream.md`](execution-output-stream.md)), so a relayed value is checked
**twice**: once against the handler's own `spec.emits`, and again against the consumer's, because
the consumer's caller depends on the consumer's declaration and has never heard of the handler.
Both are contracts and both are relied upon; a value that satisfies one and not the other is a
disagreement between two documents, which is exactly what a contract exists to surface.

**A `workflow.call`'s output needs no check of its own.** The callee already validated its result
against its own `spec.output` before returning it, so the value the caller receives has been
checked once, by the workflow that declared its shape.

**Validation runs where the value crosses**, inside the activity that is already running — the
schedule path, the transition evaluation, the result write. It is therefore deterministic given the
bundle and the value, and its outcome is recorded like any other activity result, so a replay does
not re-derive it.

### What a failure can be caught by

| Code | Catchable |
|---|---|
| `UTOS-H101`, `UTOS-H102` | No run exists yet. `ScheduleExecution` returns `INVALID_ARGUMENT` |
| `UTOS-H103` | **No.** The run fails |
| `UTOS-H104` | Yes, by the invoking construct — a `workflow.call` or `workflow.spawn` activity's `onFailure`, a promise branch failing its promise, a `handle` failing its consumer |
| `UTOS-H107` | As the boundary it occurred at: at schedule it is `INVALID_ARGUMENT`, elsewhere it is that boundary's failure |
| `UTOS-H105`, `UTOS-H106` | **No.** The run fails |

**A transition failure is not catchable** because the transition is the act of leaving: the source
activity's `onFailure` rules describe *that activity* failing, and routing a successful activity's
bad transform into them would conflate two different things and could route straight back into the
transform that failed.

**An output failure is not catchable, and that is not a policy an author opts into.** A workflow
that returns the wrong shape is broken, and the caller that trusted its contract is the one that
would otherwise carry the damage. The same argument applies to an emitted value: a consumer's
`onEmitted` rules depend on `spec.emits` exactly as a caller depends on a result.

## What a failure reports

**Every failure is reported, not the first.** JSON Schema 2020-12 defines output formats for this,
and its *basic* form is a flat list. A rejected input comes back as the complete list, so fixing
one problem does not reveal the next.

Each entry is that output narrowed to three fields:

| Field | Meaning |
|---|---|
| `instanceLocation` | A JSON Pointer into the value, rooted at the value itself (`""` is the whole value) |
| `keyword` | The keyword that failed — `required`, `type`, `maximum`, `format`, `unevaluatedProperties` |
| `keywordLocation` | A JSON Pointer into the schema, as 2020-12 defines it |

Three shapes worth pinning, because implementations otherwise differ and a fixture would fail an
implementation for being right:

- An `unevaluatedProperties` failure reports **the offending property** as its `instanceLocation`
  (`/oderId`), not the object containing it. The property is what is wrong, and naming it is the
  whole value of the diagnostic — a typo'd key reported against `""` says only that something,
  somewhere, was not expected.
- A `required` failure is **one entry for the object**, whatever the number of missing properties,
  because the entry is per failing keyword and `required` is one keyword. Which properties are
  missing belongs in the message.
- **A property a schema declared is evaluated, whether or not its subschema accepted it.** So a
  declared property that fails its own constraint reports that constraint and nothing else; it is
  never *also* reported as unevaluated. This is the one place the dialect takes a position where
  2020-12 is read two ways. The strict reading — annotations from a failing schema object are
  dropped, so `properties` contributes nothing and every property becomes unevaluated — is
  defensible as text and indefensible as a diagnostic: one wrong number in a ten-field object
  would report one `maximum` failure and nine spurious "unexpected property" failures, in a
  document whose whole purpose is that fixing one problem does not reveal the next. `unevaluated`
  here means *no schema was applied to it*, which is also what the keyword's name says.

**That triple is the contract; the wording beside it is not.** An entry may carry an `error` string
and implementations are encouraged to make it good, but no fixture asserts on it — the same
division `workflow-validation.md` draws between `code` + `path` and `message`. `keyword` is
derivable from the last segment of `keywordLocation` and is named anyway, so an assertion does not
have to parse a pointer to make it.

A cap of **100 entries** keeps a pathological payload from producing a pathological error; beyond
it the list is truncated and carries the number dropped.

At schedule the list is the `INVALID_ARGUMENT` status' details. At run time it is the failure's
`details`, under a `schema` key, which puts it in scope for an `onFailure` rule as
`error.details.schema`:

```json
{
  "schema": {
    "boundary": "input",
    "errors": [
      { "instanceLocation": "/quality", "keyword": "maximum",
        "keywordLocation": "/properties/quality/maximum" },
      { "instanceLocation": "", "keyword": "required",
        "keywordLocation": "/required" }
    ],
    "truncated": 0
  }
}
```

`boundary` is one of `input`, `env`, `output`, `emits`, naming which declaration was applied.

---

## `UTOS-H0##` — Schemas, checked at load

Part of bundle validation, reported as `code` + `path` exactly like every rule in
[`workflow-validation.md`](workflow-validation.md), and belonging to the same shared validator. An
implementation applies them wherever it applies that document, and never assumes another tool has.

| Code | Rule |
|---|---|
| `UTOS-H001` | A schema must be a JSON object or a boolean |
| `UTOS-H002` | A schema must be valid against the JSON Schema 2020-12 meta-schema |
| `UTOS-H003` | A schema's top level must declare `"type": "object"` |
| `UTOS-H004` | `$schema`, where present, must be `https://json-schema.org/draft/2020-12/schema` |
| `UTOS-H005` | A `$ref` must be a JSON Pointer into this schema's own `$defs`, or a published `utos:` type |
| `UTOS-H006` | Every `$ref` must resolve, and the reference graph must be acyclic |
| `UTOS-H007` | A `format` must be one of those listed in § Formats |
| `UTOS-H008` | A `default` must validate against the schema that declares it |
| `UTOS-H009` | A `default` may only be declared on a property that is not `required` |
| `UTOS-H010` | A `pattern` must be a valid regular expression |
| `UTOS-H011` | Every property of `spec.env` must be of type `string` |
| `UTOS-H012` | A schema must be within the limits of § Limits |
| `UTOS-H013` | A `transition.input` must supply every property the target activity's declared input requires, and none it does not declare |
| `UTOS-H014` | An invocation's `input` must do the same against the invoked start activity's declared input |

`UTOS-H001` catches a value that is not a schema at all — a string, a number, an array — where one
belongs. A `Struct` will carry any of those happily, so `properties: { x: "string" }` is a thing a
bundle can say and nothing else would object to. The boolean form **is** a schema in 2020-12 and
stays legal: `unevaluatedProperties: false` is exactly that, and is what this spec's own compiler
emits. A slot's *top level* is narrower still (`UTOS-H003`).

`UTOS-H003` is decision 5 of the design: **every declared value is an object with named keys**, at
the top of every slot. Not an array, not a scalar. The wire slots are already `Struct`s, so this
costs nothing and buys one shape for a tool to render, one place for a property to be named, and
room to add a key without changing the type of everything that reads it.

`UTOS-H005` is what keeps schema evaluation offline. A `$ref` to `https://…` or to a file is
refused at load rather than fetched, so a workflow's meaning does not depend on what some host
served at build time and a registry outage cannot stop one loading.

`UTOS-H013` and `UTOS-H014` are the checks that fire **before a run starts**, and they are
deliberately narrow: they compare **property sets**, not values. An input transform's keys are
always literal — only its leaf *values* may be templates — so "this transform can never satisfy
that activity" is knowable with certainty at load, while "this template will produce a string" is
not. A check that only sometimes fires teaches people to distrust it, so what is certain is a hard
error here and what is inferred is a CLI warning with a file and a line, blocking nothing.

Both are skipped where the transform is omitted, since then the source activity's output passes
through unchanged and there is no key set to compare.

## `UTOS-H1##` — Data, checked while a run proceeds

Reported as a `WorkflowError` carrying the code, the activity, and the detail structure above —
the same split `template-expressions.md` draws between its `UTOS-E0##` and `UTOS-E1##` ranges.

| Code | Rule |
|---|---|
| `UTOS-H101` | The run input does not satisfy the start activity's declared `input` |
| `UTOS-H102` | The run's environment does not satisfy `spec.env` |
| `UTOS-H103` | A transition's rendered `input` does not satisfy the target activity's declared `input` |
| `UTOS-H104` | An invoked document's `input` does not satisfy its start activity's declared `input` |
| `UTOS-H105` | A result does not satisfy `spec.output` |
| `UTOS-H106` | An emitted value does not satisfy `spec.emits` |
| `UTOS-H107` | Evaluating a schema exceeded its time or step budget |

`UTOS-H107` covers what `UTOS-H010` cannot: a `pattern` that is a valid regular expression and
still backtracks catastrophically on an adversarial string. Implementations evaluate `pattern`
under a time bound, as `template-expressions.md` § Runtime guarantees already requires of the
expression engine, and report exceeding it rather than hanging.

## Limits

A schema is data in a bundle, so a pathological one is a denial of service on validation rather
than on a run: nesting thousands deep, tens of thousands of properties, a reference graph that
fans out exponentially. The bounds are checked **at load**, so the cost is paid once rather than at
every schedule, and exceeding one is `UTOS-H012`.

Actual values are implementation configuration, as they are for the expression engine. What the
spec fixes is that each limit exists, that exceeding it is reported rather than survived, and a
**floor** every implementation must accept, so that a schema written against one is not refused by
another:

| Limit | Floor |
|---|---|
| Nesting depth of one schema | 32 |
| Properties across one schema | 1024 |
| `$ref`s in one schema | 128 |
| `$defs` entries in one schema | 128 |
| Length of one `pattern` | 1024 characters |

`UTOS-H012` is the one rule here with no conformance fixture, and deliberately: the numbers are
configuration, so a fixture would assert one implementation's choice rather than the spec's. What
is testable is the floor, and a schema at the floor must *pass* everywhere — which every valid
fixture already demonstrates, being far below it.

## Reuse

Two workflows that both take a `Customer` copy the schema today. Three levels, and only the first
is in this version:

1. **`$defs` within one schema**, which is standard JSON Schema and needs nothing from us. A `$ref`
   into it is a JSON Pointer, and the graph must be acyclic (`UTOS-H006`).
2. **A type declared in another document** — `$ref: "billing#/$defs/Customer"`, resolved through the
   dependency alias a bundle already resolves. Additive, and it drags dependency resolution into
   schema evaluation, so it waits for a reason to exist.
3. **A published registry of types**, which is a registry's business rather than this document's.

## Identity

**Schemas are ordinary bundle content, so they are part of its content digest**
([`canonical-bundle-digest.md`](canonical-bundle-digest.md)). Changing a declaration changes the
workflow's identity, which is correct: a document that accepts a different shape is a different
document, and a caller that pinned a digest pinned the contract along with the behaviour.

Two consequences for whatever compiles the short form: `required` is emitted sorted (§ Rules the
short form follows) and `$schema` is dropped (§ The dialect), so that two builds of one document
agree byte for byte. An `ActivitySchema` with no `input` is omitted rather than emitted as `{}`,
for the same reason.

## Conformance

Three corpora under [`../conformance/`](../conformance/) concern this document:

- **`schema/`** — the data rules: a schema, a value, and whether it validates, with the defaults
  that were filled. The format is below.
- **`source/`** — the short form's compilation, as ordinary source-format cases: a document and the
  `Workflow` it must map to, or the `UTOS-S###` it must produce.
- **`validation/`** — the `UTOS-H0##` rules, as bundle fixtures with `code` + `path`, exactly as
  for every other rule.

A `schema/` case. `boundary` is `input`, `env`, `output` or `emits`, and is `input` when absent;
it decides whether defaults are filled, since `input` and `env` fill and the other two never do:

```json
{
  "boundary": "input",
  "schema": {
    "type": "object",
    "required": ["photo"],
    "properties": {
      "photo": { "type": "string" },
      "quality": { "type": "integer", "minimum": 1, "maximum": 100, "default": 80 }
    },
    "unevaluatedProperties": false
  },
  "value": { "photo": "https://example.com/cat.png" },
  "expect": { "valid": true, "filled": { "photo": "https://example.com/cat.png", "quality": 80 } }
}
```

```json
{
  "schema": { "type": "object", "properties": { "n": { "type": "integer" } },
              "unevaluatedProperties": false },
  "value": { "n": 10.5 },
  "expect": { "valid": false, "errors": [ { "instanceLocation": "/n", "keyword": "type" } ] }
}
```

`filled` is the value after defaults, and is present only where the case is at a filling boundary
— `input` or `env`; a case with no `filled` asserts the value is unchanged. `errors` is compared as an unordered set on
`instanceLocation` and `keyword` — `keywordLocation` is not asserted, because more than one schema
location can legitimately produce the same failure. Message text is never part of a case.

## Implementation notes

Non-normative.

**Who validates what.** The **daemon** validates *data* against a workflow's schemas — run input,
an invocation's input, a result, an emitted value — and has no ahead-of-time compilation constraint,
so any 2020-12 evaluator will do. The **shared validator** checks the *schema document* at load:
well-formed against the meta-schema, references known and acyclic, formats known, limits kept. One
of its rules — `UTOS-H008`, a default validating against its own schema — needs an evaluator too,
against a schema that is not known until a bundle is read; implementations that publish a
NativeAOT binary should confirm their evaluator works without run-time reflection before adopting
it, which is the one place this feature reaches into how a tool is built.

**`utos inspect` shows the contract** — the start activity's input, `spec.output`, `spec.emits`,
`spec.env` — which is also what a registry renders on a workflow's page.

**A CLI can warn where it cannot refuse.** With a target shape, `{{ input.oderId }}` is knowably
wrong, which is the most common authoring mistake and is invisible today. It is a warning with a
file and a line rather than a rule, because reaching it means reading an expression and the answer
is not always certain.

## Recorded, not specified

Deliberately absent from this version, each waiting on something named:

- **`blob` and `file` as published types**, with `mediaType` and `maxSize` constraints. They are
  the first two entries of the registry and arrive with binary data, when values of those types
  exist to declare.
- **`spec.errors`** — the codes a workflow can fail with, as `[{ code, description }]`, with the
  validator checking that an `error` action's code is declared and that a caller comparing
  `error.code === 'X'` names one the callee declares. The last piece of a workflow's contract, and
  separable from the rest. One question is open first: a bare `error` re-raise passes a callee's
  codes through its caller, so a caller's contract includes what it re-raises, and whether that is
  declared explicitly or inferred from the call graph decides whether a contract depends on
  resolution.
- **Checking a consumer against a producer's `spec.emits`** — an `onEmitted` condition reading a
  field the producer never emits is wrong before the run starts. It needs static analysis of an
  expression rather than of a property set, which is why `UTOS-H013` and `UTOS-H014` stop where
  they do.
- **Local input checking in the CLI.** `utos run --input` is not validated before the call. The
  daemon rejects it at schedule with every failing path, which is fast enough and is the only
  place that can be authoritative anyway.
