# Evaluation Conformance Cases

Cross-implementation cases for the **evaluation** rules (`UTOS-E1##`) and the value semantics
in [`../../docs/template-expressions.md`](../../docs/template-expressions.md). Where
[`../validation/`](../validation/) asks "does this bundle validate?", this directory asks "what
does this expression evaluate to?" — the question a second implementation on another engine
has to answer identically.

```
<case>.json     one expression, one scope, one expected outcome
```

```json
{
  "form": "value",
  "expression": "output.items.map(i => i.id)",
  "scope": { "output": { "items": [ { "id": "a" } ] } },
  "expect": { "value": ["a"] }
}
```

| Field | Meaning |
|---|---|
| `form` | `condition` (bare, must be boolean), `value` (whole-field, typed), `text` (rendered to a string), or `collection` (whole-field, typed, and must be an array — a `PromiseForEach.collection`, where anything else is `UTOS-E105`) |
| `expression` | The program, exactly as it would appear inside `{{ }}` — the delimiters are not part of the case |
| `scope` | The names in scope and their values, as **plain JSON**, read by the JSON → `WorkflowValue` conversion of [`workflow-values.md`](../../docs/workflow-values.md#json) — so it never holds a blob, and a `$blob` key in it is an ordinary key. Names absent here are absent in scope |
| `scopeWire` | In place of `scope`, for a case whose scope holds a blob: the scope as the **wire form**, a `utos.workflow.v1.WorkflowMap` in protobuf JSON whose fields are the names in scope |
| `store` | Optional, with `scopeWire`: the stored objects its blobs name, as blob id → the whole object's bytes in base64 |
| `clock`, `seed` | Optional: the instant (ISO 8601) and the seed (a UUID) the executor captured for the evaluation — what `Date.now()`, `new Date()`, `Math.random()` and `crypto.randomUUID()` derive from |
| `before` | Optional: a program evaluated first, on the same engine and scope, as two expressions of one activity are — for cases about what one expression can and cannot leave behind for the next |
| `limits` | Optional: limits the case needs set, by name — see § Running them |
| `expect` | Exactly one of `value` (plain JSON, compared as JSON), `wire` (a `WorkflowValue` in protobuf JSON, for a result that holds a blob), `omitted` (`true`: the whole result was `undefined`, so the field is omitted), or `error` (a `UTOS-E1##` code, or a `UTOS-F1##` one from [`binary-data.md`](../../docs/binary-data.md)) |

Values are compared **as JSON**: `75` and `75.0` are the same number, key order is not
significant, and a `text` result is a JSON string. Message text is never part of a case.

### Blobs

A case that involves a blob is written in the **wire form**, because that is what a daemon receives
and what an evaluator has to accept. Plain JSON has no way to hold a blob, and the spec deliberately
gives it none ([`workflow-values.md`](../../docs/workflow-values.md)).

```json
{
  "form": "value",
  "expression": "await input.part.text()",
  "scopeWire": { "fields": { "input": { "mapValue": { "fields": {
    "part": { "blobValue": { "id": "b_1", "offset": "2", "size": "3", "mediaType": "text/plain" } }
  } } } } },
  "store": { "b_1": "YWJjZGVmZ2g=" },
  "expect": { "value": "cde" }
}
```

A harness sets up a case as follows. It puts every `store` object into a blob store under its id,
belonging to the run tree the evaluation runs in (`docs/binary-data.md` § Access). It then parses
`scopeWire` exactly as a daemon parses a value off the wire, and hands the result to the evaluator.
An inline blob carries its bytes in `data`. A stored one carries `id`, `offset` and `size`, and its
bytes are fetched from the store, so the case exercises reads that go through storage. The two
field names, `scope` and `scopeWire`, are how a case says which form it is in. Nothing in a case is
recognized by its content.

An expected blob in `expect.wire` **matches** when its `size`, `mediaType`, `name` and
`lastModified` (each present or absent) and its **bytes** equal the result's. The backing (inline
or stored, and with what `id` and `offset`) is never compared: which one a blob has after an
expression is the implementation's choice (`docs/binary-data.md` § A blob as a value). A harness
resolves a stored result's bytes through the same store.

Cases exercise only what this document adds to ECMAScript. There is no case for what `map`
does; there is a case for the number rule, the boolean rule, the frozen scope, the host
library, and each evaluation error code.

## Running them

Every expression evaluator runs this directory as part of its own test suite — the reference
daemon's is where it runs today — with the limits at their defaults. A case that needs a specific limit says so in a `limits` object with
the same names as the codes it exercises (`statements`, `memory`, `timeout`…), and
`materialization` for the bytes one read of a blob may bring into memory. A case that sets
`materialization` below the spec's 1 MiB floor does so to make a small case exercise the limit; an
evaluator must allow configuring it that low for tests, and `blob-read-at-the-floor` checks the
default admits the floor.

## Adding a case

One rule or one semantic per case, named for it. Keep the scope minimal — enough for the
expression to be meaningful and nothing that could trip a different rule.
