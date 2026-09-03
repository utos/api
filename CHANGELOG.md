# Changelog

All notable changes to the Utos API specification will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.15]

## [0.0.14] - 2026-09-03

### Added
- **A consumer can stop consuming.** `CallActivityConfig.on_emitted` rules gain `transition` and `result` alongside the dispatch, so a rule can say "stop, and continue at this activity in my own flow" or "stop, and finish with this value". Until now a rule could only hand the value to a document and come back for the next one, which left the consuming loop exactly one exit: the producer terminating. For the intentionally endless poller this feature exists to serve, that never happens — so `docs/execution-output-stream.md` described a lifecycle (*"a subscription ends when the consuming path terminates — `end` or a `result`"*) that no author could reach, because `on_success` and `on_failure` are both only evaluated *after* the producer has finished. The only way to stop early was to make a handler fail, which ends the run as an error and loses the distinction between finishing early on purpose and breaking
- This is a regression being repaired rather than a new capability. Before 0.0.13 a handler was a chain of activities in the consumer's own graph and transitioning out of it ended the subscription. Making handlers documents removed that, and the 0.0.13 note recording the removal — *"there is no longer any such thing to leave for"* — is true of a handler and does not follow for the loop. It was a consequence taken for a decision
- A `transition` in an `on_emitted` rule is safe where the same thing inside a handler is not, and the difference is which execution evaluates it. The rule is evaluated by the **consumer**, in the consumer's own execution, so its target is an ordinary activity in the consumer's own graph (`UTOS-T003`). A dispatched handler runs in an execution of its own holding no subscription, which is why it still cannot name the consumer's flow at all (`UTOS-S011`, unchanged)

### Changed
- **`DispatchRule` becomes `EmissionRule`, and its dispatch fields nest under `handle`.** With three possible actions the old name was wrong and the old shape was worse: `condition`, `workflow` and `startActivity` sat at one level doing two different jobs — one a guard, two an action — beside a `transition:` block that owned its whole action. Nesting makes a rule self-describing, an optional condition and exactly one named action, and it moves "exactly one action" into the wire format: a `oneof` cannot express two, so `UTOS-C504` only has to catch a rule with none, exactly as `UTOS-T001` does for a transition rule. Named `handle` rather than `dispatch` because the spec already says handler throughout
- **`PromiseBranch` keeps its dispatch fields flat**, so the two constructs are no longer spelled identically. Deliberate: a branch has no alternative action, so a wrapper would disambiguate nothing and add a level saying nothing. What the two still share is the dispatch's *content* — `workflow`, `startActivity`, `input`, checked by the same `UTOS-C501`–`UTOS-C503` wherever it appears — and what differs is that a rule wraps it because a rule can do other things
- `UTOS-C504` is added for a rule with no action, and `UTOS-T003` applies to an `on_emitted` rule that carries a `transition`. 0.0.13 stated that promise branches and `onEmitted` rules are *not* transition sites; that stays true of dispatches and stops being true of transitions, so what a site is is now decided per action rather than per construct
- **`self` is legal only on a promise branch** (`UTOS-S011`, `docs/workflow-source-format.md`, `PromiseBranch.workflow`, `HandlerDispatch.workflow`). 0.0.13 introduced it as "a reserved value wherever a document is named", which was broader than the reason for having it. The reason is that recursive fan-out is otherwise inexpressible — a document reaching itself through an alias is a cycle under `UTOS-S005` — and that argument applies to a promise branch and nowhere else. A `workflow.call`, a `workflow.spawn` and an `onEmitted` rule can all say what they mean with an ordinary dependency, so there `self` only saved a document
- In one of those places it did worse than save a document. **An `onEmitted` rule naming `self` puts the handler back inside the consumer's own graph**, where a transition can reach the call activity that dispatched it — and in the handler's own execution, which holds no subscription, that does not resume the producer, it starts another one, once per value, without bound. That is a transition *inside the handler document*, evaluated in the handler's own execution — not the `transition` action this same release adds to an emission rule, which the consumer evaluates in its own execution and which is safe for exactly that reason. `CallActivityConfig.on_emitted` has claimed since 0.0.13 that a handler "cannot transition into the consumer's flow"; that claim was false while `self` was permitted there, and is now true by construction rather than by rule. This is a shape authors arrive at by *leaving old text alone*: before handlers became documents, transitioning back to the call activity was how the loop was closed, so every consumer written against 0.0.12 carries one
- Restricting it costs no expressiveness. An awaited self-call is a single-branch `promise.all`; a handler is per-value work, which having a document of its own is the entire point of. What it does cost is a file per handler, and that cost is accepted rather than mitigated: letting several documents share one file was considered and rejected, since it buys back a file at the price of a permanent addition to the source format

### Fixed
- **A `UTOS-S###` code names a defect in a document**, and an implementation's own limitations are not rules and take no code (`docs/workflow-source-format.md`). The test is whether a conforming implementation that *had* built the thing could ever report it — if not, the document was never wrong, and a code says it was. `UTOS-S010` is recorded as unallocated and not to be reused: the reference CLI shipped it for "registry resolution is not implemented yet", which is exactly that case, and versions carrying it are in the wild. The rule is stated rather than the one code quietly removed, because the drift it comes from is not hypothetical — `UTOS-S009` was also shipped by the CLI and absent from this table, which is how the `self` rule nearly took a code already in use, and is why it is `UTOS-S011`
- **`PromiseBranch.name` overstated the ordinal rule.** 0.0.13 said implementations "must not disambiguate by appending an ordinal" and that rendered names "must be distinct", which taken literally breaks every `forEach` branch with a plain `name: item` — a literal name renders to itself, so an expansion over three items claims one key three times. Worse, it breaks them at *run time*, on documents the shared validator accepts, which is the divergence 0.0.13 existed to close. The ordinal is now specified as what it should always have been: a **fallback**, applied per expansion when the rendered names within it are not distinct. A templated name that is already distinct is used exactly as written, which was the point of the change; a collision *between* branches is still refused rather than renamed

## [0.0.13] - 2026-08-22

### Added
- **`error` and `response` template contexts** (`docs/workflow-source-format.md`). `error` — `code` and `message` — is what an `on_failure` rule reads. It is a sibling of `output` rather than a replacement: a failed activity produced no output, and overloading one name with the other's meaning would let a condition written for the success path silently read error fields on the failure path. `response` — `status`, `headers`, `bodyText` — carries an HTTP activity's transport facts on **both** paths, and is what lets a failure rule tell a 429 from a 401 without an error-code taxonomy. Folding those into `output` instead would have made `output` mean structurally different things per activity kind — wrapped for `http`, a child's result for `workflow.call`, a branch map for `promise` — so `{{ output.messages }}` would work after a sub-workflow but need `{{ output.body.messages }}` after a request
- **Every context, and every key within `error` and `response`, is always defined**, with null values where they do not apply, so a condition may name `response.status` on an activity that made no request and evaluate `false`. Normative rather than an implementation nicety: the failure it otherwise raises is raised *while a failure is already being handled*
- Both describe the activity a transition is **leaving**, and are deliberately not in scope when the target activity's own `url`, `headers` or `body` are rendered — that is a fresh scope of `input` and `env`. Anything a handler needs must be carried across in the transition's `input` transform

### Changed
- **An `on_emitted` handler completes one iteration by finishing, and control returns to the call activity for the next value** (`docs/execution-output-stream.md`, `docs/workflow-source-format.md`, `CallActivityConfig.on_emitted`). Consuming was previously a loop the author had to close by hand, transitioning back to the call activity by name. Omitting that back-edge ended the subscription, cancelled the producer and completed the run — so a workflow written to poll for weeks would exit after one value, reporting success, with nothing indicating the loop had been abandoned. A handler is now the body of the loop and behaves like one, exactly as a promise branch already returns to its promise without being told to. A handler is a document, so what "finishing" means is its execution terminating — see the dispatch entry below, which settles the same question for both constructs at once
- **A rule list where nothing matches skips that value rather than ending the subscription.** Same rule as above, and the case that made a *filtering* consumer unwritable: `on_emitted` conditions that all miss exhaust the list, which previously meant the run was over. One uninteresting value silently shut the producer down
- **A subscription now ends only when the consuming execution terminates** — `end` or a `result` — **or is cancelled or fails.** "Leaving for an unrelated part of the graph" is no longer a way out, because there is no longer any such thing to leave for: a handler is a document of its own, so nothing it does can wander into the consumer's flow. Stopping early is `end` or a `result` in the consumer, which is what the one existing escape already did
- **Dispatched work is its own document.** A promise branch and an `onEmitted` rule both name a *document* now — `workflow`, `startActivity`, `input` — instead of pointing at an activity in the dispatching one. `PromiseBranch.target` is retired and `CallActivityConfig.on_emitted` changes element type from `TransitionRule` to the new `DispatchRule`. Both are field changes, and both land here rather than in a 0.0.14 because 0.0.13 is unreleased. The problem was that `spec.activities` is one flat map: an activity existing only to serve a branch or a handler sat beside the main flow with nothing to mark it, and what it *meant* depended on where it was used — running out of transitions ends a run on the main path but finishes one iteration inside a handler. A reader had to find the use site to understand the definition. Naming a document removes the intermediary entirely, so `spec.activities` in any document is only that document's own flow, with no exceptions to remember. Identical in both constructs deliberately: dispatching work is one shape to learn, and the daemon already ran every branch as a child execution — what changes is that arranging it stops being the author's job
- **`self`** — a reserved value wherever a document is named, meaning *this document*, requiring no `dependencies` entry. Without it, requiring a document would make recursion inexpressible: a document dispatching itself through an alias is a document depending on itself, which `UTOS-S005` rejects as a cycle. `self` sidesteps that check rather than relaxing it — it never enters the dependency graph, so there is nothing to detect. It is resolved to this document's canonical identity by the CLI, so the daemon never sees the word, and it starts a **fresh child execution** rather than re-entering the current one. Reserving it breaks nothing: bare `self` has no `./` prefix and no `{registry}/{namespace}/{name}:{version}` shape, so it was already malformed under `UTOS-S002`
- **A handler's emissions propagate to the consumer's stream**, and its terminal result is discarded (`docs/execution-output-stream.md`). This preserves existing behaviour across the new boundary rather than inventing a rule: a handler used to run inside the consumer's execution, so a value it emitted was already the consumer's, and the three-level relay that supports is load-bearing. Emit in the handler, it comes out of the consumer — no keyword. **Promise branches deliberately do not relay:** for a handler this preserves behaviour, for a branch it would change it, and N concurrent branches interleaving into one stream would order them nondeterministically, costing the single-ordered-stream property the rest of the spec rests on
- **A promise branch `name` is rendered**, and implementations must not append an ordinal. It has always been documented as supporting `{{ alias.x }}` with `forEach` — and `all-activity-kinds.json` authored exactly that — while the reference daemon built the key from the raw string plus `_{index}`, so that fixture produced output-map keys of the literal text `addon-{{ item.sku }}_0`. The claim is now honoured instead of withdrawn, because `item_0` says nothing about which expansion failed and `addon-SKU-123` says everything. The rendered names must be distinct within one promise; that is a **run-time** failure, since rendering needs the collection and validation does not evaluate templates
- **`UTOS-C501`–`UTOS-C503` — a new dispatch range** shared by promise branches and `onEmitted` rules: `workflow` required, `startActivity` required, `startActivity` must name an activity in the dispatched workflow. One range rather than each construct borrowing its own, because two identical rules with different codes would duplicate everything a code is *for* — suppression, citation, test assertions. `UTOS-C307` is added for two branches of one promise declaring the same literal `name`, which is the statically knowable half of the uniqueness requirement
- **`UTOS-C305` and `UTOS-C404` are retired, not renumbered.** `target` no longer exists, and an `onEmitted` rule is no longer a transition rule, so neither has anything left to check. Codes stay burned because a code is a stable contract — the same reasoning that retired `UTOS-C301`. What `UTOS-C404` protected against now holds by construction: a handler is a document, so it cannot transition into the consumer's flow and has no `result` to end the consumer with. Promise branches and `onEmitted` rules also stop being `TransitionTarget` sites, so `UTOS-T003` no longer applies to them
- On the divergence this closes: the reference daemon used to throw unless a branch `target` named a `workflow.call`, while no `UTOS-*` rule constrained the kind — so it rejected bundles the shared validator accepts, which is the one thing the two must not do. That could have been fixed by relaxing the daemon; it is fixed instead by putting the rule in the spec, where it was always missing. Nothing is lost by choosing that direction: fanning out over work in the current document is `workflow: self`
- **A settled promise cancels the branches it did not wait for** (`PromiseActivityConfig.completion`). `any`, `race` and `count` resolve on a subset of their branches and `all` fails on the first failure, and the spec said nothing about the rest — which left "abandoned" and "stopped" indistinguishable, and an implementation free to read the silence either way. A branch is arbitrary workflow content, so the difference is not bookkeeping: a losing `race` branch that POSTs an order does so whether or not its result can still be read. One rule covers every mode, the failure path included, and it holds before the activity completes, so a resolved promise means no branch of it is still spending
- `HttpActivityConfig.headers` states that **content headers belong there too**: a `content-type` declared by the author is the body's media type, defaulting to `application/json` when absent. Previously the field said only that values support templates, which left an implementation free to send every body as JSON — and a form-encoded body is what an OAuth token refresh needs, so a workflow that cannot express one cannot renew its own credential
- `HttpActivityConfig` states that a non-2xx response is a failure, and that `response` remains readable across it
- `TransitionTarget.input` defines its pass-through on the failure path: with no transform, the target receives the **failing activity's own input**. The success-path rule — pass the source's output through — has no meaning where there is no output, and leaving it undefined invites an implementation to resolve it to nothing and rewind a failure handler to the run's original input

### Fixed
- `docs/workflow-validation.md` carried two "the reference daemon currently diverges" notes that were no longer true — it resolves activity names ordinally, and the shared validator walks `onSuccess`, `onFailure`, `onEmitted` and `PromiseBranch.target` alike. A note describing a divergence that has been closed is worse than none, since a reader takes it as the current state of the world
- `CallActivityConfig.on_emitted` cited `UTOS-C405` for the rule that every handler rule must carry a `transition` action — a code that never existed; the rule shipped as `UTOS-C404`. (`UTOS-C404` is itself retired later in this release, but the citation was wrong for as long as it stood, and `C405` stays burned rather than being recycled into the new dispatch range for exactly the reason below.) Comment-only, but the validation document states that the **code and path are the contract and the message text deliberately is not**, so a wrong code in a normative proto is the spec contradicting itself about the part implementers are told to rely on

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
