# Canonical `WorkflowBundle` Serialization for Content Digests

Defines the deterministic byte form used to compute the content digest of a
`WorkflowBundle` (`workflow/v1/bundle.proto`). The digest is carried by
`WorkflowReference.digest` (`daemon/v1/shared.proto`) and lets the daemon and every SDK derive
**identical** content identities for the same bundle — so an execution records exactly what it
ran, drift under a mutable `name:version` is detectable, and references can be pinned by content.

## Why a spec is needed

Protobuf binary is **not** canonical across implementations: `map` entry order is unspecified,
and protobuf's own "deterministic" marshaling mode is explicitly documented as *not* stable
across languages or library versions. Hashing raw protobuf bytes would make two independent
builds of the same logical bundle disagree. This spec pins one form so they always agree.

## Two different digests (scope)

- **Bundle digest — this document.** A hash of the fully-resolved, self-contained
  `WorkflowBundle` (the "built" form the daemon executes). This is what `WorkflowReference.digest`
  records on executions and loaded definitions.
- **OCI artifact / source digest — not this document.** When a workflow is published to an OCI
  registry, the OCI artifact (source graph with dependencies as references) is content-addressed
  natively by OCI over its canonical-JSON manifests. That is a separate, registry-side identity.

## Algorithm

```
digest = "sha256:" + lowerhex( sha256( JCS( proto3json( WorkflowBundle ) ) ) )
```

1. `proto3json` — serialize the `WorkflowBundle` using the standard **proto3 JSON mapping**.
2. `JCS` — canonicalize that JSON per **RFC 8785 (JSON Canonicalization Scheme)**: object keys
   sorted, canonical number formatting, minimal whitespace, UTF-8.
3. `sha256` — hash the resulting UTF-8 bytes; format as `"sha256:"` + lowercase hex.

Leaning on these two published standards keeps bespoke rules to a minimum. RFC 8785 does the hard
parts (key sorting, number formatting) uniformly, and — importantly — **JCS sorts object *keys*
but never reorders *arrays***, which gives the map-vs-list distinction for free.

## Pinned rules

The bundle graph is favorable: it contains **no enums, no `bytes`, no 64-bit integers** and no
well-known types beyond `Struct`, so proto3 JSON's trickier cases do not arise. The rules:

1. **Field names — lowerCamelCase.** Use the proto3 JSON default `json_name` (e.g. `apiVersion`,
   `entryPoint`, `onSuccess`, `startActivity`). No field overrides `json_name`, so this is
   deterministic, and it matches the k8s-style authored YAML.
2. **Presence / defaults — per proto3 JSON.** Omit implicit-presence scalars at their default
   (`requiredCount:0`, `""`), omit unset `optional` fields, and omit empty maps and empty repeated
   fields. An explicitly-set `optional` field is emitted even at its default value (presence is
   tracked). *(This also means the built bundle's emptied `dependencies` map is simply absent from
   the digest.)*
   **A set message field is emitted even when it has no fields of its own** — presence is what it
   carries. The mode discriminators (`CallActivityConfig`, `SpawnActivityConfig`, `PromiseAllConfig`,
   `PromiseAnyConfig`, `PromiseRaceConfig`) are all empty messages, so a `workflow.call` activity
   serializes `"call": {}` and a `workflow.spawn` serializes `"spawn": {}`. An implementation that
   "prunes empty objects" as a tidiness pass would erase the distinction and make two activities
   with different behavior hash identically.
3. **Maps → JSON objects, keys sorted by JCS.** Applies to `workflows`, `dependencies`,
   `activities`, `headers`, and every `google.protobuf.Struct.fields` — recursively.
4. **Order-significant lists → JSON arrays, order preserved.** JCS never reorders arrays. Applies
   to `onSuccess`, `onFailure` and `onEmitted` (evaluated in order, first match wins),
   `PromiseActivityConfig.branches`, and `google.protobuf.ListValue` arrays inside any `Struct`.
5. **`google.protobuf.Struct` / `Value`.** Object/scalar per proto3 JSON. `number_value` (a `double`) is
   canonicalized by JCS (ECMAScript shortest round-trip). `NullValue` → JSON `null`. `NaN` and
   `±Infinity` are not representable as JSON numbers and are **forbidden** in bundle `Struct`
   values — reject at build time.
6. **No `Duration`s.** A duration is an ordinary string in the unit shorthand
   ([`workflow-source-format.md` § Durations](workflow-source-format.md#durations)), so it
   canonicalizes as any string does. `TimerActivityConfig.duration` was the only
   `google.protobuf.Duration` in the graph and became a string in 0.20.0.
7. **Numbers — RFC 8785 §3.2.2.3.** Covers `int32 requiredCount` and `Struct` doubles.
8. **Output.** `sha256`, lowercase hex, `"sha256:"`-prefixed — matching the `WorkflowReference.digest`
   field format.

## Worked example (structure)

A small bundle, shown as its canonical JSON. Note: **shown pretty-printed for readability; the
bytes that are actually hashed are JCS-minified** (no insignificant whitespace).

Source (informal), authored with `activities` in the order `start`, then `done`; a
`requiredCount:0` left at its default; and an empty `dependencies`:

```json
{
  "entryPoint": "acme/greet:1.0.0",
  "workflows": {
    "acme/greet:1.0.0": {
      "apiVersion": "utos.io/v1",
      "kind": "Workflow",
      "metadata": {
        "name": "greet",
        "namespace": "acme",
        "version": "1.0.0"
      },
      "spec": {
        "activities": {
          "done": {
            "timer": { "duration": "5s" }
          },
          "start": {
            "http": {
              "method": "GET",
              "url": "https://api.example.com"
            },
            "onSuccess": [
              { "condition": "output.ok", "transition": { "name": "done" } },
              { "result": {} }
            ]
          }
        }
      }
    }
  }
}
```

What this demonstrates:
- **camelCase** field names (`entryPoint`, `apiVersion`, `onSuccess`).
- **Map keys sorted:** `done` precedes `start` even though `start` was authored first; object keys
  everywhere are alphabetical (`http` before `onSuccess`, `name`/`namespace`/`version`).
- **List order preserved:** the two `onSuccess` rules keep their authored order (the conditional
  rule stays first, the fallback second) — sorting them would break first-match-wins.
- **Defaults / empties omitted:** `dependencies` (empty), `onFailure` (empty), `done`'s empty
  `onSuccess`, the unset `optional` `description`/`registry`, and any `requiredCount:0` are all
  absent.
- **Empty messages kept:** the fallback rule's `"result": {}` — a `return` with no value — is a
  set message field with nothing inside it, and it survives because presence is the whole
  payload. A `workflow.call` activity's `"call": {}` is the same case.
- **A duration** as the ordinary string `"5s"`.

Digest: not yet pinned — see Conformance.

## Conformance

This document pins the rules, but a prose spec alone can drift on an edge case (a double's
formatting, a default-omission). The format is **finalized** — i.e. locked so every SDK provably
agrees — by:

1. a single small **reference implementation** of the algorithm, and
2. committed **golden vectors**: `(WorkflowBundle input → expected sha256)` fixtures that become
   the cross-SDK source of truth, run as conformance tests in each SDK repo.

The first exists: `ComputeContentDigest()` in `Utos.Workflow` (`utos/sdk-dotnet`), which the
reference daemon uses. The golden vectors do not yet. Until they are committed the format is
**provisional**: a digest compares bundles digested by the same implementation, and a tool may
display one, but a client must not send a digest *it computed* as a guard on a daemon request
(`WorkflowReference.digest`), since the daemon may have been built against another implementation.
A digest the daemon itself returned is always safe to send back.
