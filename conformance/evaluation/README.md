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
| `form` | `condition` (bare, must be boolean), `value` (whole-field, typed), or `text` (rendered to a string) |
| `expression` | The program, exactly as it would appear inside `{{ }}` — the delimiters are not part of the case |
| `scope` | The names in scope and their values, as JSON. Names absent here are absent in scope |
| `before` | Optional: a program evaluated first, on the same engine and scope, as two expressions of one activity are — for cases about what one expression can and cannot leave behind for the next |
| `expect` | Exactly one of `value` (compared as JSON), `omitted` (`true`: the whole result was `undefined`, so the field is omitted), or `error` (a `UTOS-E1##` code) |

Values are compared **as JSON**: `75` and `75.0` are the same number, key order is not
significant, and a `text` result is a JSON string. Message text is never part of a case.

Cases exercise only what this document adds to ECMAScript. There is no case for what `map`
does; there is a case for the number rule, the boolean rule, the frozen scope, the host
library, and each evaluation error code.

## Running them

Each SDK runs this directory against its evaluator as part of its own test suite, with the
limits at their defaults. A case that needs a specific limit says so in a `limits` object with
the same names as the codes it exercises (`statements`, `memory`, `timeout`…).

## Adding a case

One rule or one semantic per case, named for it. Keep the scope minimal — enough for the
expression to be meaningful and nothing that could trip a different rule.
