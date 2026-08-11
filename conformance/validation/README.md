# Validation Conformance Fixtures

Cross-implementation fixtures for the rules in [`../../docs/workflow-validation.md`](../../docs/workflow-validation.md).

```
valid/<case>.json               a bundle that must produce no violations
invalid/<case>.json             a bundle that must produce violations
invalid/<case>.expected.json    the violations it must produce
```

Fixtures are `WorkflowBundle` documents in proto3 JSON — the built form, not authored source — so
they exercise the rules rather than any particular front-end.

An `expected.json` lists `code` and `path` pairs. Order is not significant; the set must match
**exactly**, with no extra violations and none missing. Message text is deliberately absent from
the fixtures so implementations can word errors idiomatically, and improve that wording, without
breaking conformance.

```json
{ "issues": [ { "code": "UTOS-B003", "path": "entryPoint" } ] }
```

Each invalid fixture is written to trip exactly one rule wherever practical, so a failure names
the rule that broke rather than requiring the reader to work out which of several is at fault.

## Running them

Each SDK runs this directory as part of its own test suite. `sdk-dotnet` copies it in alongside
the protos during release and drives it from `Utos.Workflow.Validation.Tests`.

## Adding a case

Add the pair, keeping the fixture minimal — just enough structure for the target rule to be
reachable and for no other rule to fire. Every rule in `workflow-validation.md` should eventually
have at least one case here.
