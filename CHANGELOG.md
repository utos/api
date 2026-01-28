# Changelog

All notable changes to the Utos API specification will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
