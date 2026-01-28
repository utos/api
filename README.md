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

## Using the API

Generated SDKs are available via [Buf Schema Registry](https://buf.build/utos/api):

### .NET
```bash
dotnet nuget add source "https://buf.build/gen/nuget" --name "BSR"
dotnet add package Buf.Build.Gen.Utos.Api.Grpc.Csharp
```

### Local Generation
```bash
npm install @bufbuild/buf
npx buf generate
```

## Related Projects

- [utos/daemon](https://github.com/utos/daemon) - Reference daemon implementation (planned)
- [utos/cli](https://github.com/utos/cli) - Command-line interface (planned)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[Apache 2.0](LICENSE)
