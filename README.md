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

## SDKs

Generated SDKs are published per language from their own repositories (each
subscribes to this repo's `vX.Y.Z` release tags). Install them from the native
package registry for your language — no Buf Schema Registry account or custom
source required.

- **.NET** — [utos/sdk-dotnet](https://github.com/utos/sdk-dotnet) (`Utos.Workflow`, `Utos.Daemon.Client`, `Utos.Daemon.Server` on nuget.org)

## Related Projects

- [utos/daemon](https://github.com/utos/daemon) - Reference daemon implementation (planned)
- [utos/cli](https://github.com/utos/cli) - Command-line interface (planned)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[Apache 2.0](LICENSE)
