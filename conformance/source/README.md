# Source-Format Conformance Cases

Cross-implementation cases for the normative mapping in
[`../../docs/workflow-source-format.md`](../../docs/workflow-source-format.md): what a source
document must become, or why it must be refused. Where [`../validation/`](../validation/) asks
"does this bundle validate?", this directory asks "does this front-end read a document the way
the reference one does?" — the question the hub's upload path, an IDE plugin or a second SDK has
to answer identically.

```
<case>.yaml             a source document
<case>.expected.json    what it must map to, or the issues it must produce
```

```json
{ "workflow": { "apiVersion": "utos.io/v1", "kind": "Workflow", "metadata": { ... }, "spec": { ... } } }
```

```json
{ "issues": [ { "code": "UTOS-S009", "path": "spec.activities[\"fetch\"].onSuccess[0]" } ] }
```

| Field | Meaning |
|---|---|
| `workflow` | The `utos.workflow.v1.Workflow` the document maps to, in proto3 JSON — the **document-level** mapping only: `spec.dependencies` is kept exactly as authored, aliases are not resolved and no bundle is built. Resolution needs files and registries, which every front-end reaches differently; the mapping does not |
| `issues` | `code` + `path` pairs, exactly as the validation corpus; `path` in the same notation, rooted at the document |

Compared as JSON: key order is not significant, and absent optional fields and empty maps are
not distinguished from omitted ones. Message text is never part of a case.

One rule per case, named for it: the `type` discriminator, `return` with and without a value,
the `error` action with and without fields, a `result` key in source (an unknown field),
duplicate keys, an unknown activity kind.

The `schema-*` and `spec-contract` cases cover the other half of this mapping: the short form of
[`../../docs/workflow-schemas.md`](../../docs/workflow-schemas.md) compiling to plain JSON Schema.
That compilation happens **only here** — a bundle carries the standard form — so a front end that
gets it wrong produces a workflow that means something else, and nothing downstream can tell.


## Running them

Each implementation of the source format runs this directory as part of its own test suite. The
reference implementation is `Utos.Workflow.Source` in `utos/sdk-dotnet`, which the CLI uses.
