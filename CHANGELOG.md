# Changelog

All notable changes to the Utos API specification will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **BREAKING**: Split `WorkflowExecutionService` into `ExecutionService` and `ObservabilityService`
- **BREAKING**: Merged `HealthService` into `ObservabilityService`
- Reorganized `daemon/v1/`: `service.proto` replaced by `shared.proto`, `execution.proto`, `observability.proto`

## [0.0.3] - 2026-02-09

### Changed
- **BREAKING**: Refactored `WorkflowActivity` into a base activity type with `oneof config` for sub-type selection
- Renamed `HttpActivityType` enum to `HttpMethod` (values: `HTTP_METHOD_*`)
- Moved HTTP method into `HttpActivityConfig` (new `method` field)

### Fixed
- Use `buf push` default label instead of deprecated `--tag` flag for BSR publishing

## [0.0.2] - 2026-01-28

### Fixed
- Use BSR tags (immutable) instead of labels for version releases

## [0.0.1] - 2026-01-28

### Added
- Initial workflow specification (`workflow/v1/`)
  - `Workflow`, `WorkflowSpec`, `WorkflowMetadata` definitions
  - `WorkflowActivity` with HTTP activity support
  - `WorkflowBundle` built format for daemon execution
- Daemon gRPC API (`daemon/v1/`)
  - `WorkflowExecutionService` for scheduling and watching executions
  - `HealthService` for daemon health checks
- Buf.build module configuration
- GitHub Actions CI/CD workflows
  - CI: lint, breaking change detection, changelog enforcement
  - Release: version extraction, git tagging, BSR publishing

### Changed
- Disabled breaking change detection until API is stable (1.0.0+)
