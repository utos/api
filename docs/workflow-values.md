# Workflow Values

Defines the values a run carries: its input, what one activity hands the next, what a sub-workflow
returns, what a workflow emits, and its result. The wire form is `utos.workflow.v1.WorkflowValue`
(`workflow/v1/value.proto`). These are **spec-level** rules, for the same reason as every other
document here: a value one implementation writes has to be read by the next as the same value.

## Why a value type of its own

Until 0.20.0 a run carried `google.protobuf.Struct`, which is JSON. JSON has six types, and a
workflow needs a seventh: bytes, as a blob ([`binary-data.md`](binary-data.md)). JSON offers
only two ways to carry a type it doesn't have, and both are wrong.

- **Inside the value, under a reserved key.** For example, `{ "$blob": { "id": … } }`. Data can
  always contain the same key: an API response, a client's input, a value a child returned. The
  receiver then has to decide whether that key is a type or just data. It can decide by rule, which
  needs an escaping scheme on every path data takes (MongoDB's Extended JSON has exactly this
  problem). Or it can decide by trust, which turns every place untrusted JSON enters a run into a
  place it can forge a handle.
- **Beside the value, as a list of the paths that are blobs.** This works, but every new type
  needs another list, and the list and the value can disagree.

So the type goes **in the structure**. A `WorkflowValue` is a `oneof`, and a blob is a case of it just as
a string is. A map may hold any key. `{ "$blob": … }` in a response is an ordinary map with one
entry, everywhere, with no escaping.

**Type is structure, never content.** This is the rule this document exists to state, and it holds
for every type added after `blob`. Nothing in any implementation may decide a value's type by
looking at its keys, its string content, or its shape. The only rules that assign types are the
ones below.

## The kinds

| Kind | `WorkflowValue` case | JSON | In an expression |
|---|---|---|---|
| null | `null_value` | `null` | `null` |
| boolean | `bool_value` | `true` / `false` | boolean |
| number | `number_value` | number | number |
| string | `string_value` | string | string |
| list | `list_value` | array | array, frozen |
| map | `map_value` | object | plain object, frozen |
| blob | `blob_value` | *none* | `Blob`, or `File` when it has a name |

A `WorkflowValue` has exactly one case set. A value with none set is malformed (`UTOS-V101`).

**Numbers.** There is one number type, the IEEE 754 double. It must be finite (`UTOS-V102`). What
an expression does with numbers, and the bound on integers it can hold, are in
[`template-expressions.md` § Numbers](template-expressions.md#numbers). This document doesn't
restate them.

**Lists and maps** nest to any depth an implementation accepts. A map's keys are arbitrary strings,
none reserved, and their order carries no meaning.

**Blobs** are defined in [`binary-data.md`](binary-data.md): an immutable sequence of bytes with a
media type, either inline or naming an object the daemon stored. A blob holds bytes, never values,
so a blob never contains another value.

`undefined`, dates, `Buffer`, sets and maps-with-non-string-keys are **not** kinds. They exist
inside an expression and must be turned into one of the kinds above before a value leaves it
([`template-expressions.md` § Results](template-expressions.md#results)).

## Values and templates

A bundle contains no values. It contains **templates**: a transition's `input`, a `result`, an
`emit` value, an error's `details`, a schema. Each is a `google.protobuf.Struct` that an author
wrote (`workflow/v1/activity.proto`). A run **renders** a template into a value once, when the
rule that carries it fires. After that, the value is never rendered again. A string holding
`{{ env.SECRET }}` that arrives in a response body is a string, not an expression.

This is the same principle as "type is structure, never content", applied to expressions: only
the bundle is interpreted, and data never is.

Because of this, a bundle can never contain a blob, and the `Struct`s in `utos.workflow.v1` stay
`Struct`s. The one exception on the daemon wire is `WorkflowError.details`. That message is both
the authored `error` action and the error a run reports, so it stays a `Struct`, and its details
are plain JSON. A blob rendered into them is `UTOS-E103`.

## Where values appear

On the daemon wire (`daemon/v1`):

| Carrier | Type |
|---|---|
| `ScheduleExecutionRequest.input`, `GetExecutionResponse.input` | `ExecutionPayload`: `map<string, WorkflowValue>` |
| `GetExecutionResponse.result` | `WorkflowMap` |
| `WatchOutputResponse.value`, `WatchOutputResponse.result` | `WorkflowMap` |

**Every carrier's top level is a map.** A run's input, its result and every emitted value are
objects with named keys. The same rule appears as `UTOS-H003` for their declarations
([`workflow-schemas.md`](workflow-schemas.md)). Whether a run could take or return a bare scalar is
a separate question, and it is not opened here.

Inside an implementation, values are also carried between activities, into sub-workflows, and in
the durable history. How an implementation encodes them there is its own business, **as long as
the encoding is unambiguous**, so that a value read back has the kind it had when written. The
protobuf binary and JSON forms of `WorkflowValue` both qualify, because every node is wrapped in its case.
A plain-JSON encoding with blobs tagged by a key does not, for the reason at the top of this
document.

## JSON

People and tools write JSON: `utos run --input '{…}'`, a fixture, an HTTP API in front of a
daemon. Two conversions are defined, and every tool that offers them must implement them exactly
as follows, so that a document one tool accepts means the same thing in another.

**JSON → WorkflowValue** is total and never produces a blob. `null`, booleans, strings, arrays and objects
map to their kinds. A number maps to the nearest double. An object holding the key `$blob`, or any
other key, is a map. A blob in a client's input is placed there as a blob, by the client's own API
(see [`binary-data.md` § Into a run](binary-data.md#into-a-run)). It is never spelled in JSON.

**WorkflowValue → JSON** is lossless for a value that contains no blob. Numbers are written in shortest
round-trip form (`5`, not `5.0`), as interpolation renders them. **A value that contains a blob has
no plain-JSON form.** A tool that has to write one as text uses the protobuf JSON mapping of
`WorkflowValue`, which is unambiguous and round-trips:

```json
{ "mapValue": { "fields": {
    "photo": { "blobValue": { "id": "b_01JB8…", "size": "10342", "mediaType": "image/png", "name": "cat.png" } },
    "width": { "numberValue": 640 } } } }
```

A tool may also *display* a value in a friendlier form. The reference CLI prints a blob as
`<blob b_01JB8… image/png 10342 B "cat.png">`. A display form is presentation and must never be
accepted back as input.

## Well-formed values

A value received from outside a daemon must be well-formed. At `ScheduleExecution`, that means the
run input. A malformed value is refused before anything is recorded: `INVALID_ARGUMENT`, carrying
the failures as `google.rpc.BadRequest`, with `field` the JSON Pointer of the failing node and
`reason` the code.

| Code | Rule |
|---|---|
| `UTOS-V101` | A `WorkflowValue` must have exactly one case set |
| `UTOS-V102` | A `number_value` must be finite — not `NaN`, not `±Infinity` |

The blob-specific rules are `UTOS-F104` ([`binary-data.md` § Codes](binary-data.md#codes)).
`UTOS-V001`, the bundle rule refusing `NaN` in a `Struct`, is the same rule applied to templates.
`V0##` codes cover templates and `V1##` codes cover run-time values, following the `E0##`/`E1##`
and `H0##`/`H1##` split elsewhere.

A daemon never *produces* a malformed value: every value it writes came out of an expression, a
response, or a check like this one.

## Implementation notes

Non-normative.

**The conversions belong in the SDK.** JSON → `WorkflowValue`, `WorkflowValue` → JSON and the
well-formedness check are small, and every tool needs them identically. The .NET SDK ships them
beside the generated types.

**The names are prefixed on purpose.** `WorkflowValue`, `WorkflowList` and `WorkflowMap` mirror
`google.protobuf.Value`, `ListValue` and `Struct` in shape, but not in name. Code that handles a
bundle's templates and a run's values imports both packages, and in C# two types called `Value`
in two imported namespaces are a compile error in every such file. The oneof case names
(`map_value`, `blob_value`…) do follow Google's, so the protobuf JSON of the two reads alike.

**Converting into an expression engine** follows the table above. Lists and maps become frozen
arrays and plain objects. A blob becomes a host `Blob` or `File` object. Numbers go through the
same narrowing as before. Converting back is § Results in `template-expressions.md`.
