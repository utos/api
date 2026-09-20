# Utos API Specification

Protocol Buffer definitions for the Utos workflow specification.

## Overview

This repository contains the canonical API definitions for:
- **Workflow format** - How workflows are defined
- **Daemon API** - How workflows are executed
- **Registry API** - How workflows are stored and shared (planned)

## Packages

| Package | Description |
|---------|-------------|
| `utos.workflow.v1` | Workflow definitions, activities, bundles |
| `utos.daemon.v1` | gRPC service for workflow execution |
| `utos.registry.v1` | Registry service (planned) |

## Specifications

Behaviour that the `.proto` files cannot express on their own is specified in `docs/`. These are
normative — every implementation is expected to conform.

| Document | Defines |
|----------|---------|
| [Workflow source format](docs/workflow-source-format.md) | What authors write, and its mapping onto `utos.workflow.v1.Workflow` |
| [Bundle validation rules](docs/workflow-validation.md) | Every rule a `WorkflowBundle` must satisfy, with stable error codes |
| [Template expressions](docs/template-expressions.md) | The language of `{{ }}` and `condition` strings — a JavaScript subset — its scope, values, and the guarantees every evaluator makes |
| [Workflow schemas](docs/workflow-schemas.md) | What a workflow declares about its input, output, emissions and environment — JSON Schema 2020-12, the short authoring form, and where each declaration is checked |
| [Canonical bundle digest](docs/canonical-bundle-digest.md) | The deterministic byte form behind `WorkflowReference.digest` |
| [Execution output streams](docs/execution-output-stream.md) | What `emit`, `onEmitted` and `WatchOutput` guarantee: ordering, durability, back-pressure |

Cross-implementation fixtures live in [`conformance/`](conformance/) — bundle validation,
expression evaluation, the source-format mapping, and schema checking — and are run as tests by
each SDK, so conformance is demonstrable rather than assumed.

## SDKs

Generated SDKs are published per language from their own repositories (each
subscribes to this repo's `vX.Y.Z` release tags). Install them from the native
package registry for your language — no Buf Schema Registry account or custom
source required.

- **.NET** — [utos/sdk-dotnet](https://github.com/utos/sdk-dotnet) on nuget.org: `Utos.Workflow`
  (the message types), `Utos.Workflow.Source` (reads the source format), `Utos.Workflow.Validation`
  (the bundle rules), `Utos.Daemon.Client` and `Utos.Daemon.Server`

## Related Projects

- [utos/daemon](https://github.com/utos/daemon) - Reference daemon implementation (planned)
- [utos/cli](https://github.com/utos/cli) - Command-line interface (planned)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[Apache 2.0](LICENSE)
