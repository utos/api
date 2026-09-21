# Schema Conformance Cases

Cross-implementation cases for the data rules in
[`../../docs/workflow-schemas.md`](../../docs/workflow-schemas.md): given a schema and a value,
does the value satisfy it, and what is filled if it does.

Where [`../validation/`](../validation/) asks "is this schema well-formed?" (`UTOS-H0##`, a bundle
rule), this directory asks "does this value satisfy that schema?" (`UTOS-H1##`, what a daemon
decides at a boundary). The two are separate because they are enforced by different things at
different times, and an implementation may well have only one of them.

```
<case>.json     a schema, a value, and what must happen
```

```json
{
  "boundary": "input",
  "schema": { ... },
  "value": { ... },
  "expect": { "valid": true, "filled": { ... } }
}
```

| Field | Meaning |
|---|---|
| `boundary` | `input`, `env`, `output` or `emits` — which declaration is being applied. Optional; `input` when absent. It decides whether defaults are filled: `input` and `env` fill, `output` and `emits` never do |
| `schema` | A **compiled** JSON Schema 2020-12 document — the built form, as it appears in a bundle, not the source format's short form. Compilation of the short form is covered by [`../source/`](../source/) |
| `value` | The value being checked, as plain JSON — read by the JSON → `WorkflowValue` conversion, so it never holds a blob and a `$blob` key in it is an ordinary key |
| `valueWire` | In place of `value`, for a value that holds a blob: a `utos.workflow.v1.WorkflowMap` in protobuf JSON, the wire form (see [`../evaluation/`](../evaluation/README.md#blobs)). No `store` is needed — a schema judges a blob's metadata and never reads its bytes |
| `expect.valid` | Whether the value satisfies the schema |
| `expect.filled` | The value after declared defaults are filled. Present only on a valid case at a filling boundary; absent means the value must be unchanged |
| `expect.errors` | On an invalid case, the failures that must be reported |

An `errors` entry is `instanceLocation` (a JSON Pointer into the value, `""` for the value
itself) and `keyword` (the keyword that failed). The set must match **exactly** — no extra
failures and none missing — because reporting every failure rather than the first is the point of
the format.

`keywordLocation` is deliberately **not** asserted, though an implementation should report it:
more than one schema location can legitimately produce the same failure, and pinning one would
make a correct implementation fail for choosing the other. Message text is never part of a case,
for the same reason it is absent from every other corpus here.

## Running them

Each implementation that validates data against a workflow's schemas runs this directory as part
of its own test suite — the reference daemon, and any SDK that offers the check client-side.

## Adding a case

One behaviour per case, named for it. Keep the schema minimal: just enough for the target rule to
be reachable and for nothing else to fire, so a failure names what broke.
