# Changelog

All notable changes to the Utos API specification will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.10]

### Added
- Documented the canonical workflow identity key — `[registry/][namespace/]name:version`, derived from `WorkflowMetadata` — used to key `WorkflowBundle.workflows`, and clarified that `WorkflowActivityConfig.workflow` is a source-format dependency alias resolved to that identity key in the built bundle (`WorkflowSpec.dependencies` documented as source-format alias declarations)
- Structured execution errors: `GetExecutionResponse`, `ExecutionSummary`, and `WatchExecutionResponse` now carry a `WorkflowError error` field (`WatchExecutionResponse.error` is set on the transition to `FAILED`). `WorkflowError` was previously defined but unreferenced

### Changed
- **BREAKING**: Execution failures are now structured — the `error_message` string on `GetExecutionResponse` and `ExecutionSummary` is replaced by a `WorkflowError error` field (old field numbers and names reserved)
- **BREAKING**: `WatchExecutionRequest.tail` and `.after` are now grouped in a `oneof position`, enforcing their documented mutual exclusivity (setting one clears the other; neither remains valid)
- **BREAKING**: `WorkflowError.details` is now `google.protobuf.Struct` instead of a JSON-encoded `string` (wire-incompatible field type change), consistent with the structured types used elsewhere in the API
- Reserved the planned `ExecutionStatus` slots `3` (`SUSPENDED`) and `12` (`CANCELLED`) — numbers and names — replacing the commented-out placeholders, so the slots are protoc-protected from accidental reuse
- **BREAKING**: `GetExecutionResponse` now embeds `ExecutionSummary summary` instead of re-declaring the execution's identity/status/timing/error fields. The flat fields (`id`, `status`, `workflow`, `created_at`, `scheduled_at`, `started_at`, `completed_at`, `failed_at`, `error`) are removed and read via `summary`; `bundle`, `input`, and `env` remain. Terminal time is now the single `summary.finished_at` (with `status` distinguishing success vs failure), replacing `completed_at`/`failed_at`

## [0.0.9] - 2026-07-17

### Added
- `TimerActivityConfig` activity type (durable timer) for time-based delays and polling loops
- `WorkflowActivityConfig.detached` flag for fire-and-forget sub-workflow invocation (start without awaiting)
- Documented the back-edge loop pattern (transition targeting an already-visited activity) on `TransitionTarget`
- Clarified that promise branches may loop/nest into promise or ancestor activities, each promise invocation being an isolated scope
- `DefinitionService` (`daemon/v1/definition.proto`) for pushing workflow definitions to the daemon's local store: `LoadWorkflow`, `ListWorkflows`, `GetWorkflow`, `UnloadWorkflow`
- `WorkflowReference` message (`daemon/v1/shared.proto`) — structured `[registry/][namespace/]name:version` reference to a loaded definition (registry, namespace, and version all optional; version omitted means "latest loaded")
- `WorkflowMetadata.namespace` and `WorkflowMetadata.registry` (both `optional`) — Docker-style addressing prefixes, omitted for local/unpublished workflows
- `ListExecutionsRequest.workflow` filter for grouping executions by workflow identity
- Per-run environment: `map<string,string> env` on `ScheduleExecutionRequest` (echoed back on `GetExecutionResponse`) — ambient, non-secret config available to all activities via `{{ env.x }}` template expressions, distinct from `input` (which reaches only the start activity)

### Changed
- **BREAKING**: `ScheduleExecution` is now reference-based — `ScheduleExecutionRequest.bundle` (inline `WorkflowBundle`) is replaced by `workflow` (`WorkflowReference`). Workflows must be loaded via `DefinitionService.LoadWorkflow` before they can be scheduled
- **BREAKING**: `ExecutionSummary` and `GetExecutionResponse` now carry workflow identity as an embedded `WorkflowReference workflow` field, replacing the flat `workflow_name`/`workflow_version` fields (consistent with the `DefinitionService` responses)

## [0.0.8] - 2026-06-11

### Changed
- Distribution moved off the Buf Schema Registry. `buf push` is removed from the
  release workflow; a release is now the `v{version}` git tag plus a
  `repository_dispatch` notification (`spec-released`) to the auto-discovered
  `utos/sdk-*` repos, which regenerate and publish per language — .NET via
  [utos/sdk-dotnet](https://github.com/utos/sdk-dotnet) (`Utos.Workflow`,
  `Utos.Daemon.Client`, `Utos.Daemon.Server` on nuget.org). `buf lint` and
  breaking-change detection are unchanged. Local `buf.gen.yaml`/`gen/` removed
  (generation now lives in the SDK repos).

## [0.0.7] - 2026-03-04

### Added
- `WorkflowActivityConfig` activity type for single sub-workflow invocation
- `PromiseActivityConfig` activity type for concurrent fan-out (`all`, `any`, `race`, `count` modes)
- `PromiseBranch` message with conditional (`condition`) and dynamic (`for_each`) fan-out support
- `ForEachConfig` message for dynamic branch expansion over a collection
- `WorkflowActivity.on_failure` field for general failure handling across all activity types
- `TransitionRule.return` action to return data and end an execution path

### Changed
- **BREAKING**: Renamed `Transition` to `TransitionRule`
- **BREAKING**: `TransitionRule` now uses `oneof action` with `transition` (TransitionTarget) or `return` (Struct) instead of a direct `target` field

## [0.0.6] - 2026-02-12

### Changed
- **BREAKING**: Simplified `WatchExecution` streaming to log-centric model
- **BREAKING**: Flattened `WatchExecutionResponse` into a single log message structure with optional `ExecutionStatus` field for state transitions
- **BREAKING**: Removed `EventType` enum, `ExecutionEvent`, `LogEvent`, and `OutputEvent` messages from `observability.proto`
- **BREAKING**: Removed `type` filter from `WatchExecutionRequest`

## [0.0.5] - 2026-02-12

### Added
- `TransitionTarget.input` field (`google.protobuf.Struct`) for data transforms between activities
- Template expression context documentation on `Transition.condition` and `HttpActivityConfig` fields

## [0.0.4] - 2026-02-10

### Changed
- **BREAKING**: Split `WorkflowExecutionService` into `ExecutionService` and `ObservabilityService`
- **BREAKING**: Merged `HealthService` into `ObservabilityService`
- Reorganized `daemon/v1/`: `service.proto` replaced by `shared.proto`, `execution.proto`, `observability.proto`
- Replaced `HttpMethod` enum with `string` field on `HttpActivityConfig` for better JSON/YAML ergonomics and to avoid C# naming collision with `System.Net.Http.HttpMethod`

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
