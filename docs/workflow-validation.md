# Workflow Bundle Validation Rules

Defines the rules a `utos.workflow.v1.WorkflowBundle` (`workflow/v1/bundle.proto`) must satisfy,
each with a stable code. These are **spec-level** rules: every implementation that accepts or
produces a bundle — CLI, daemon, any SDK — must enforce the same set, or the same document will
be accepted by one tool and rejected by another.

## Scope

These rules apply to the **built bundle**. Errors in the authored source format — unresolvable
dependency aliases, missing files, cycles — are listed in
[`workflow-source-format.md`](workflow-source-format.md) under the `UTOS-S###` range, because
they are detected while producing a bundle rather than by inspecting one.

Rules here are **structural and referential**. They do not evaluate template expressions, reach
the network, or reason about what a workflow will do at run time.

## Reporting

An implementation reports each violation as a triple:

| Part | Purpose |
|---|---|
| `code` | The stable identifier from this document, e.g. `UTOS-M003` |
| `path` | Where in the bundle, e.g. `workflows["acme/greet:1.0.0"].spec.activities["send"].http.url` |
| `message` | Human-readable explanation |

**`code` and `path` are the contract; `message` is not.** Conformance fixtures assert the first
two only, so implementations are free to word errors idiomatically and to improve that wording
without breaking anyone. Paths use the canonical lowerCamelCase field names of
[`canonical-bundle-digest.md`](canonical-bundle-digest.md), with map keys as bracketed quoted
strings and repeated fields as bracketed indices.

Validation is **exhaustive, not fail-fast**: report every violation found, so one run surfaces
every problem rather than one problem per run.

## Name comparison

Activity-name references resolve by **ordinal (case-sensitive)** comparison. Protobuf map keys
are ordinal, so any looser rule would let a document validate and then fail to find its target at
run time.

Reserved terminal keywords (`end`, `error`) are matched **case-insensitively**, both when
rejecting them as activity names and when recognizing them as transition targets. They are a
closed two-word vocabulary, and `End` can only have been meant as the keyword.

> The reference daemon currently resolves activity names with `OrdinalIgnoreCase`, which diverges
> from this rule and from its own runtime lookup. Adopting these rules corrects it.

---

## `UTOS-B###` — Bundle

| Code | Rule |
|---|---|
| `UTOS-B001` | `entryPoint` is required and non-empty |
| `UTOS-B002` | `workflows` must contain at least one workflow |
| `UTOS-B003` | `entryPoint` must be a key of `workflows` |
| `UTOS-B004` | Every `workflows` key must be non-empty |
| `UTOS-B005` | Every `workflows` key must equal the canonical identity derived from that workflow's own `metadata` — `[registry/][namespace/]name:version` |
| `UTOS-B006` | Every `WorkflowActivityConfig.workflow` in the bundle must be a key of `workflows` |
| `UTOS-B007` | `spec.dependencies` must be empty in a built bundle |

`UTOS-B005` is what makes a bundle self-describing: the key and the metadata cannot disagree
about what a workflow is. `bundle.proto` states the invariant; this gives it a code.

The comparison is made against the identity **formatted from `metadata` verbatim**, without
requiring the parts to be individually valid. A workflow whose name breaks `UTOS-M003` therefore
reports that one violation, rather than also reporting `UTOS-B005` because its identity could not
be derived. Each rule reports its own problem exactly once.

`UTOS-B006` closes the loop opened by the source format. Aliases are resolved to canonical
identities at build time, so by the time a bundle exists every sub-workflow reference must point
at something inside it — a bundle is self-contained by definition.

`UTOS-B007` keeps builds deterministic. `dependencies` has no meaning after resolution, and
leaving it populated would make two builds of the same logical workflow produce different content
digests.

## `UTOS-D###` — Document envelope

| Code | Rule |
|---|---|
| `UTOS-D001` | `apiVersion` must equal `utos.io/v1` |
| `UTOS-D002` | `kind` must equal `Workflow` |
| `UTOS-D003` | `metadata` is required |
| `UTOS-D004` | `spec` is required |
| `UTOS-D005` | `spec.activities` must contain at least one activity |

## `UTOS-M###` — Metadata

| Code | Rule |
|---|---|
| `UTOS-M001` | `name` is required and non-empty |
| `UTOS-M002` | `name` must be at most 63 characters |
| `UTOS-M003` | `name` must match `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` — lowercase alphanumeric and hyphens, not starting or ending with a hyphen |
| `UTOS-M004` | `version` is required and non-empty |
| `UTOS-M005` | `version` must be a valid semantic version, **without** a `v` prefix |
| `UTOS-M006` | `description` must be at most 500 characters |
| `UTOS-M007` | `namespace`, when present, must be non-empty and contain no `/` or `:` |
| `UTOS-M008` | `registry`, when present, must be non-empty and contain no `/` |
| `UTOS-M009` | `registry`, when present, requires `namespace` |

`UTOS-M007` through `UTOS-M009` exist so canonical identity round-trips. A `/` inside a namespace
would make `[registry/][namespace/]name:version` ambiguous to parse back apart, and a registry
without a namespace produces `registry/name:version` — indistinguishable from
`namespace/name:version`.

Implementations should refine `UTOS-M003` and `UTOS-M005` messages to name the actual problem —
"must be lowercase", "cannot contain underscores (use hyphens instead)", "should not include 'v'
prefix", "incomplete semantic version (must be MAJOR.MINOR.PATCH)" — rather than restating the
pattern. The code stays the same either way.

## `UTOS-A###` — Activities

| Code | Rule |
|---|---|
| `UTOS-A001` | An activity name must be non-empty and contain no leading or trailing whitespace |
| `UTOS-A002` | An activity name must be at most 63 characters |
| `UTOS-A003` | An activity name must not be a reserved terminal keyword (`end`, `error`) |
| `UTOS-A004` | An activity name must match `^[a-zA-Z0-9_-]+$` |
| `UTOS-A005` | An activity name must not begin with a digit, `-`, or `_` |
| `UTOS-A006` | An activity name must not end with `-` or `_` |
| `UTOS-A007` | An activity must have exactly one configuration set |

`UTOS-A007` covers the `config` oneof being unset. It cannot be set twice — protobuf enforces
that structurally — but it can easily be omitted, and an activity that does nothing is
malformed rather than trivially successful.

## `UTOS-T###` — Transitions

| Code | Rule |
|---|---|
| `UTOS-T001` | A transition rule must carry exactly one action — `transition` or `result` |
| `UTOS-T002` | A `TransitionTarget.name` must be non-empty |
| `UTOS-T003` | A `TransitionTarget.name` must resolve to an activity in the same workflow, or to a reserved terminal keyword |

`UTOS-T003` applies at **every** `TransitionTarget` site: `onSuccess`, `onFailure`, and
`PromiseBranch.target`. The `path` identifies which. Resolution is scoped to the workflow that
declares the transition — a target never crosses into a sub-workflow.

> The reference daemon currently checks `onSuccess` targets only. Applying `UTOS-T003` uniformly
> closes that gap.

## `UTOS-C1##` — HTTP configuration

| Code | Rule |
|---|---|
| `UTOS-C101` | `url` is required and non-empty |
| `UTOS-C102` | `url` must be an absolute `http` or `https` URL |
| `UTOS-C103` | `method` is required and non-empty |

`UTOS-C102` is **deferred when the value contains a `{{` template expression**, because the
scheme or host may come from `env` and is unknowable until the run supplies it. Implementations
that execute workflows re-apply the same check to the rendered URL, so a bad value still fails
with this diagnostic rather than as a raw HTTP client error.

## `UTOS-C2##` — Timer configuration

| Code | Rule |
|---|---|
| `UTOS-C201` | `duration` is required |
| `UTOS-C202` | `duration` must be positive |

There is deliberately no maximum. A long wait is legitimate.

## `UTOS-C3##` — Promise configuration

| Code | Rule |
|---|---|
| `UTOS-C301` | `mode` must be one of `all`, `any`, `race`, `count` |
| `UTOS-C302` | `requiredCount` must be greater than zero when `mode` is `count` |
| `UTOS-C303` | `branches` must contain at least one branch |
| `UTOS-C304` | A branch `name` is required |
| `UTOS-C305` | A branch `target` is required |
| `UTOS-C306` | `forEach.collection` and `forEach.alias` are both required when `forEach` is present |

Branch `target.name` is covered by `UTOS-T002` and `UTOS-T003`.

## `UTOS-C4##` — Sub-workflow configuration

| Code | Rule |
|---|---|
| `UTOS-C401` | `workflow` is required and non-empty |
| `UTOS-C402` | `startActivity` is required and non-empty |
| `UTOS-C403` | `startActivity` must name an activity in the referenced sub-workflow |

`UTOS-C403` is checkable precisely because a bundle is self-contained — the referenced workflow
is present, by `UTOS-B006`.

---

## Struct values

`google.protobuf.Struct` values — `TransitionRule.result`, `TransitionTarget.input`,
`WorkflowActivityConfig.input` — are not otherwise inspected, with one exception:

| Code | Rule |
|---|---|
| `UTOS-V001` | A `Struct` must not contain `NaN` or `±Infinity` |

Neither is representable in JSON, so either would make the bundle unserializable and its content
digest uncomputable. `canonical-bundle-digest.md` requires rejecting them at build time.

## Conformance

`conformance/validation/` holds the cross-implementation fixtures:

```
valid/<case>.json                  a bundle that must produce no violations
invalid/<case>.json                a bundle that must produce violations
invalid/<case>.expected.json       the violations it must produce
```

Each `expected.json` lists `code` and `path` pairs, unordered:

```json
{ "issues": [ { "code": "UTOS-B003", "path": "entryPoint" } ] }
```

A conforming implementation reports exactly that set — no more, no fewer. Message text is
deliberately absent.

Fixtures are bundles in canonical JSON form rather than source YAML, so they test the rules
themselves and not a particular front-end.
