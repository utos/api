# Utos API Specification

The Utos workflow specification: the protobuf API and the documents that define what it means.
Utos is a specification, not a platform — implementations conform to it, and the conformance
corpus in this repository is how they show it.

## Packages

| Package | Holds |
|---------|-------|
| `utos.workflow.v1` | What a workflow is: `Workflow`, activities, `WorkflowBundle`, and the values a run carries (`WorkflowValue`, `Blob`) |
| `utos.daemon.v1` | How workflows are run: `DefinitionService`, `ExecutionService`, `ObservabilityService`, `BlobService` |

There is no registry package. Workflows are published to OCI registries, which already define
distribution and content addressing for what they store.

## Specifications

Behaviour that the `.proto` files cannot express on their own is specified in `docs/`. These are
normative — every implementation is expected to conform. Each document owns one subject, and the
others refer to it rather than restating it.

**Authoring and building**

| Document | Owns |
|----------|------|
| [Workflow source format](docs/workflow-source-format.md) | What authors write, and its mapping onto `utos.workflow.v1.Workflow` and a `WorkflowBundle` |
| [Bundle validation rules](docs/workflow-validation.md) | Every structural and referential rule a `WorkflowBundle` must satisfy |
| [Canonical bundle digest](docs/canonical-bundle-digest.md) | The byte form behind `WorkflowReference.digest` |

**The language**

| Document | Owns |
|----------|------|
| [Template expressions](docs/template-expressions.md) | The `{{ }}` and `condition` language — a JavaScript subset — the names in scope, the Node.js globals, and the guarantees every evaluator makes |

**Data**

| Document | Owns |
|----------|------|
| [Workflow values](docs/workflow-values.md) | What a run carries (`WorkflowValue`), and how tools convert it to and from JSON |
| [Workflow schemas](docs/workflow-schemas.md) | What a workflow declares about its input, output, emissions and environment, and where each declaration is checked |
| [Binary data](docs/binary-data.md) | `Blob` and `File`: bytes inline or in object storage, HTTP bodies, getting bytes into and out of a run, retention, provenance, and `BlobService` |

**Execution**

| Document | Owns |
|----------|------|
| [Execution output streams](docs/execution-output-stream.md) | What `emit`, `onEmitted` and `WatchOutput` guarantee: ordering, durability, back-pressure |

A newcomer reads the source format first, then template expressions, then whichever of the rest
their work touches.

## Rule codes

Every rule has a stable code, `UTOS-` plus a family letter and three digits. The **code is the
contract and the message text is not**: fixtures assert codes, and implementations word messages
as they like. A retired code is never reused.

| Family | Checked | Defined in |
|--------|---------|------------|
| `S###` | While a source document is read and built | [source format](docs/workflow-source-format.md#building-a-bundle) |
| `B`, `D`, `M`, `A`, `T`, `C`, `V0##` | On a bundle, at load | [bundle validation](docs/workflow-validation.md) |
| `E0##` | On a bundle, at load — the expression grammar | [template expressions](docs/template-expressions.md#grammar) |
| `H0##` | On a bundle, at load — its schemas | [workflow schemas](docs/workflow-schemas.md) |
| `V1##` | On a run's input, at schedule | [workflow values](docs/workflow-values.md#well-formed-values) |
| `E1##` | While an expression is evaluated | [template expressions](docs/template-expressions.md#runtime-guarantees) |
| `H1##` | While a run crosses a declared boundary | [workflow schemas](docs/workflow-schemas.md) |
| `F1##` | While a run handles binary data | [binary data](docs/binary-data.md#codes) |

Load-time codes are reported as `code` + `path`. Codes raised while a run proceeds are reported as
a `WorkflowError`, and those raised at schedule as `INVALID_ARGUMENT` carrying
`google.rpc.BadRequest`.

## Conformance

[`conformance/`](conformance/) holds cross-implementation fixtures, one corpus per question:

| Corpus | Asks | Run by |
|--------|------|--------|
| [`validation/`](conformance/validation/) | Does this bundle validate? | Every implementation of the bundle rules |
| [`source/`](conformance/source/) | What does this document map to? | Every front end that reads the source format |
| [`evaluation/`](conformance/evaluation/) | What does this expression evaluate to? | Every expression evaluator |
| [`schema/`](conformance/schema/) | Does this value satisfy this schema? | Every implementation that checks data against schemas |

## Versioning

One version line runs through every Utos repository: **the minor is the contract, the patch is the
repository's own**. `0.20.x` anywhere means *implements spec 0.20*. This repository releases
`0.MINOR.0` for a change to the spec and `0.MINOR.PATCH` for a correction that changes no
behaviour. See [`CHANGELOG.md`](CHANGELOG.md).

## Implementations

- [utos/sdk-dotnet](https://github.com/utos/sdk-dotnet) — the .NET SDK on nuget.org:
  `Utos.Workflow` (the message types and the content digest), `Utos.Workflow.Source` (the source
  format), `Utos.Workflow.Validation` (the bundle rules), `Utos.Daemon.Client` and
  `Utos.Daemon.Server`. SDKs are generated and published from their own repositories, which
  subscribe to this repository's `v{version}` tags; no Buf Schema Registry account is needed.
- [utos/dapr-daemon](https://github.com/utos/dapr-daemon) — the reference daemon.
- [utos/cli](https://github.com/utos/cli) — the `utos` command.

## License

[Apache 2.0](LICENSE)
