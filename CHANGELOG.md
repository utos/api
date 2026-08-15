# Changelog

All notable changes to the Utos API specification will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.13]

### Fixed
- `CallActivityConfig.on_emitted` cited `UTOS-C405` for the rule that every handler rule must carry a `transition` action. That code does not exist — the rule shipped as `UTOS-C404`, which is what `docs/workflow-validation.md`, the `on-emitted-with-result` conformance fixture and the 0.0.12 changelog all name. `C405` was left over from the numbering used before the rule was folded, and the proto was the one place it survived. Comment-only, but the validation document states that the **code and path are the contract and the message text deliberately is not**, so a wrong code in a normative proto is the spec contradicting itself about the part implementers are told to rely on

## [0.0.12] - 2026-08-12

### Added
- **Execution output streams** (`docs/execution-output-stream.md`) — every execution now has one ordered, durable, cursor-addressable stream of the values it produced. A workflow appends to it with the new `emit` transition action; a caller consumes it with `CallActivityConfig.on_emitted`; anyone else reads it with `ExecutionService.WatchOutput`. This makes a continuously-producing sub-workflow expressible for the first time: previously a sub-workflow could say something to its caller exactly once, at termination, so "watch a mailbox and hand me each new message" forced the loop — and with it the poll interval, backoff, pagination and cursor — into the caller, turning the sub-workflow's internal state into its public return contract
- `TransitionRule.emit` (`EmitAction`) — append a value to this execution's output stream and continue. `result` is emit-and-terminate; `emit` is emit-and-continue, so a workflow can yield N times and then return once. `emit.transition` is required (`UTOS-T004`), since an emit is the one non-terminal action and would otherwise be a dead end
- `CallActivityConfig.on_emitted` — transitions evaluated once per value the sub-workflow emits, in stream order. Consuming is a loop built from the transitions that already exist: the handler path transitions back to the call activity to take the next value. Leaving it any other way ends the subscription and cancels the producer, because nothing will observe it again
- **Back-pressure**: while an execution has a privileged consumer (a `workflow.call` with `on_emitted`), an `emit` does not complete until that consumer's cursor passes the entry. `WatchOutput` clients are observers and never gate. This does not shed load — a blocked poller returns a bigger batch next time and the work is conserved — but it bounds the *unconsumed* buffer to one entry, so a producer that outpaces its consumer cannot grow the durable stream without limit. It bounds the count of unconsumed entries, not the size of any one; batch size is the producer's pagination policy, which is where it belongs
- `ExecutionService.WatchOutput` — stream an execution's output from a cursor (`tail`/`after`, mirroring `WatchExecution`). Deliberately separate from `ObservabilityService.WatchExecution`: emitted values are what a workflow *produced*, not a record of what it did, and folding them into a filterable log stream would let a `level` filter drop them
- `GetExecutionResponse.result` — what a completed execution returned. Closes a pre-existing gap: there was **no result field anywhere in `utos.daemon.v1`**, so a finished execution's value had nowhere to go over the wire
- Ordering needs no rule and none is stated: emitted values and the terminal result are entries in one stream walked by one cursor, so `on_emitted` fires for every value before `on_success` sees the result, and a fast-terminating producer cannot overtake its own output
- `ExecutionService.CancelExecution` — stop a `SCHEDULED` or `ACTIVE` execution, which reaches the new terminal status `EXECUTION_STATUS_CANCELLED` (enum value `12`, previously reserved). This closes a hole the spec already depended on: `TransitionTarget` documents an infinite polling loop as running "until the execution is cancelled", while `DeleteExecution` documented cancellation as "a separate concern, not yet defined". Cancellation is idempotent, and an execution that already reached `COMPLETED` or `FAILED` stays there and returns `FAILED_PRECONDITION` — the first terminal state wins, because daemon delivery is at-least-once and a late cancel must not rewrite history
- `ExecutionSummary.cancellation_reason` — why an execution was cancelled, set only when the status is `CANCELLED`. Kept separate from `error`, which stays reserved for genuine failures: a poller cancelled on purpose has not failed
- Cancellation cascade semantics: an awaited sub-workflow is cancelled with its parent, since its result can no longer be observed, while a detached execution is not — it is an independent top-level execution and must be cancelled by id, consistent with the existing detached-lifecycle rule

### Changed
- **BREAKING**: Sub-workflow invocation mode is now a nested oneof instead of a flag. `WorkflowActivityConfig.detached` is removed (number and name reserved) in favour of `oneof mode { CallActivityConfig call; SpawnActivityConfig spawn; }`. The flag changed the activity's **output contract** — the child's result when false, a `{"execution_id": …}` handle when true — and its failure semantics, since `on_failure` catches the child's runtime failures only in the awaited case. A boolean that reshapes what a message returns is better expressed as two kinds, where the difference is visible in the type rather than in a comment
- **BREAKING**: Promise completion mode is now a nested oneof instead of a string. `PromiseActivityConfig.mode` and `.required_count` are removed (numbers and names reserved) in favour of `oneof completion { PromiseAllConfig all; PromiseAnyConfig any; PromiseRaceConfig race; PromiseCountConfig count; }`, with `required_count` moved onto `PromiseCountConfig` — the only mode that has ever used it. This makes an unknown mode unrepresentable, and makes it structurally impossible to set `requiredCount` on a mode that ignores it
- **BREAKING**: The source format's `type` discriminator is now a **dot-separated path** through nested config oneofs: `workflow.call`, `workflow.spawn`, `promise.all`, `promise.any`, `promise.race`, `promise.count`. `http` and `timer` are unchanged, since neither declares a nested oneof. Bare `type: workflow` and `type: promise` are no longer legal and report `UTOS-S007` — there is deliberately no implicit default, because both choices change what the activity does. Legal values remain **derived from the descriptor**, so this generalizes the existing rule rather than excepting it: the walk simply continues while the message it reaches still declares a oneof
- **BREAKING**: `UTOS-A007` ("exactly one configuration set") now applies **at every level**, covering a `WorkflowActivityConfig` with neither `call` nor `spawn` and a `PromiseActivityConfig` with no `completion`. The reported `path` names the level that is unset
- `UTOS-C302` (`requiredCount` must be greater than zero) is no longer conditional on the mode, since `requiredCount` now exists only on `PromiseCountConfig`
- `CancelExecution` and `DeleteExecution` now describe their sub-workflow scope in terms of `workflow.call` and `workflow.spawn` rather than the removed "detached" flag
- `UTOS-T001` admits the third action: exactly one of `transition`, `result`, or `emit`. `UTOS-T003` (target resolution) now also applies at `onEmitted` and `emit.transition` sites
- New `UTOS-C404`: every `call.onEmitted` rule's action must be a `transition`. A `result` there would end the parent mid-stream while values were still arriving, and an `emit` would republish a child's value onto the parent's own stream from inside the handler consuming it. Otherwise `onEmitted` is an ordinary transition list, so `UTOS-T001`–`UTOS-T004` apply to its rules and report under their own codes
- `DeleteExecution` now admits `CANCELLED` alongside `COMPLETED` and `FAILED` as a deletable terminal state, and its comment points at `CancelExecution` instead of describing cancellation as undefined
- `ExecutionSummary.finished_at` is documented as the moment any terminal status was reached, cancellation included

### Removed
- `UTOS-C301` (`mode` must be one of `all`, `any`, `race`, `count`) is **retired**. An unknown mode is no longer representable, so the rule has nothing to check; an unset completion oneof is `UTOS-A007`. The code stays burned rather than being reused — codes are a stable contract, and recycling one would silently change the meaning of a suppression somebody had already written down

### Fixed
- `docs/canonical-bundle-digest.md` no longer uses the removed `detached:false` as its worked example of an omitted implicit-presence default, and now states explicitly that **a set message field is emitted even when empty**. All five mode discriminators are empty messages, so a `workflow.call` activity serializes `"call": {}`; an implementation that pruned empty objects as a tidiness pass would erase the mode and make two activities with different behaviour hash identically

## [0.0.11] - 2026-08-11

### Added
- Specified the **workflow source format** — what authors write — and its normative mapping onto `utos.workflow.v1.Workflow` (`docs/workflow-source-format.md`). Kubernetes-style envelope (`apiVersion: utos.io/v1`, `kind: Workflow`, `metadata`, `spec`, and nothing else at the top level), with each activity carrying a `type` discriminator whose legal values are **derived from the `config` oneof on `WorkflowActivity`** rather than hard-coded, so a new activity kind becomes authorable with no change to mapping logic. Also pins parser requirements (duplicate mapping keys are an error; both `snake_case` and `lowerCamelCase` field spellings accepted; unknown fields rejected) and the `UTOS-S###` range for source-resolution errors
- Specified the **workflow bundle validation rules** (`docs/workflow-validation.md`) — every rule a `WorkflowBundle` must satisfy, each with a stable code, so the CLI, the daemon and every SDK enforce one set. Violations are reported as `code` + `path` + `message`, of which **`code` and `path` are the contract and message text deliberately is not**, leaving implementations free to word errors idiomatically. Validation is exhaustive rather than fail-fast
- Cross-implementation **conformance fixtures** for those rules (`conformance/validation/`), as bundles in canonical JSON with expected `{code, path}` sets. Fixtures are built-form bundles rather than authored source, so they exercise the rules and not any particular front-end
- New rules with no prior implementation: a `workflows` key must equal the canonical identity derived from its own metadata (`UTOS-B005`); every `WorkflowActivityConfig.workflow` must be a key of `workflows` (`UTOS-B006`); `spec.dependencies` must be empty in a built bundle, since leaving it populated would make two builds of the same workflow hash differently (`UTOS-B007`); an activity must have exactly one configuration set (`UTOS-A007`); `apiVersion`/`kind` must be correct (`UTOS-D001`/`UTOS-D002`); a sub-workflow's `startActivity` must exist in the workflow it names (`UTOS-C403`)

### Changed
- **C# namespace for `utos.workflow.v1` is now `Utos.Workflows.V1`** (plural), via `option csharp_namespace`. The singular form declared a namespace `Utos.Workflow` that shadowed the `Workflow` message type for any consumer whose own namespace sits under `Utos.` — and C# resolves a simple name through enclosing namespaces *before* using-directives, so a `using X = ...` alias cannot fix it; only full qualification can. The plural form cannot collide with a type named `Workflow`. **This changes no wire format**: the proto package remains `utos.workflow.v1` and message full names are unchanged, so encoded bytes, canonical JSON and content digests are all identical. Only the .NET binding moves; `utos.daemon.v1` is unaffected and the NuGet package ids are unchanged. Consumers update their `using` directives; `utos/daemon` picks this up when it bumps off `0.0.10.1`
- Pinned activity-name reference resolution as **ordinal (case-sensitive)**. Protobuf map keys are ordinal, so a looser rule would let a document validate and then fail to find its target at run time. Reserved terminal keywords (`end`, `error`) remain case-insensitive. The reference daemon currently resolves with `OrdinalIgnoreCase` and diverges from this
- Transition-target resolution (`UTOS-T003`) applies at **every** `TransitionTarget` site — `onSuccess`, `onFailure` and `PromiseBranch.target`. The reference daemon currently checks `onSuccess` only

### Fixed
- Corrected the worked example in `docs/canonical-bundle-digest.md`: it used `"version": "v1"`, which the semantic-version rule (`UTOS-M005`) rejects for its `v` prefix, and transitioned to an activity `retry` that the example never defines (`UTOS-T003`)

## [0.0.10] - 2026-07-19

### Added
- Documented the canonical workflow identity key — `[registry/][namespace/]name:version`, derived from `WorkflowMetadata` — used to key `WorkflowBundle.workflows`, and clarified that `WorkflowActivityConfig.workflow` is a source-format dependency alias resolved to that identity key in the built bundle (`WorkflowSpec.dependencies` documented as source-format alias declarations)
- Structured execution errors: `GetExecutionResponse`, `ExecutionSummary`, and `WatchExecutionResponse` now carry a `WorkflowError error` field (`WatchExecutionResponse.error` is set on the transition to `FAILED`). `WorkflowError` was previously defined but unreferenced
- Documented the invariant that each `WorkflowBundle.workflows` key must equal the canonical identity derived from its value's `WorkflowMetadata`
- `WorkflowReference.digest` — optional OCI-style content digest (e.g. `"sha256:<hex>"`) alongside the mutable `name:version` key. On resolved references (execution records, `DefinitionService` responses) the daemon populates it with the exact bundle content identity, so an execution records what it actually ran and snapshot-vs-store drift is detectable; on requests it is an optional exact-content guard (resolve by name/version, then assert digest). Detached sub-workflows run the parent's snapshotted content (recorded digest derives from the snapshot), and `UnloadWorkflow` is documented as safe against running/finished executions
- Documented that `end`/`error` are reserved terminal keywords and may not be used as activity names (resolving the `TransitionTarget.name` activity-vs-keyword collision)
- Documented the canonical `WorkflowBundle` serialization used for content digests (`docs/canonical-bundle-digest.md`): proto3 JSON → RFC 8785 (JCS) → sha256, with the map-sorting/list-preserving rules `WorkflowReference.digest` depends on. Golden conformance vectors + a reference implementation are deferred as the finalization gate
- `ExecutionService.DeleteExecution` — remove a terminal (`COMPLETED`/`FAILED`) execution's record; a non-terminal run returns `FAILED_PRECONDITION` and must be cancelled first (cancellation remains out of scope). Detached sub-workflow executions are unaffected

### Changed
- **BREAKING**: Execution failures are now structured — the `error_message` string on `GetExecutionResponse` and `ExecutionSummary` is replaced by a `WorkflowError error` field (old field numbers and names reserved)
- **BREAKING**: `WatchExecutionRequest.tail` and `.after` are now grouped in a `oneof position`, enforcing their documented mutual exclusivity (setting one clears the other; neither remains valid)
- **BREAKING**: `WorkflowError.details` is now `google.protobuf.Struct` instead of a JSON-encoded `string` (wire-incompatible field type change), consistent with the structured types used elsewhere in the API
- Reserved the planned `ExecutionStatus` slots `3` (`SUSPENDED`) and `12` (`CANCELLED`) — numbers and names — replacing the commented-out placeholders, so the slots are protoc-protected from accidental reuse
- **BREAKING**: `GetExecutionResponse` now embeds `ExecutionSummary summary` instead of re-declaring the execution's identity/status/timing/error fields. The flat fields (`id`, `status`, `workflow`, `created_at`, `scheduled_at`, `started_at`, `completed_at`, `failed_at`, `error`) are removed and read via `summary`; `bundle`, `input`, and `env` remain. Terminal time is now the single `summary.finished_at` (with `status` distinguishing success vs failure), replacing `completed_at`/`failed_at`
- **BREAKING**: Renamed `TransitionRule.return` to `result` to avoid a reserved word in target languages (notably Python); field number unchanged, binary-compatible
- **BREAKING**: `Workflow.api_version` and `Workflow.kind` are now `string` following the k8s GroupVersionKind convention (e.g. `"utos.io/v1"`, `"Workflow"`); the `WorkflowApiVersion`/`WorkflowKind` enums are removed

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
