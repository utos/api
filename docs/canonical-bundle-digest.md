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

The bundle graph is favorable: it contains **no enums, no `bytes`, and no 64-bit integers** at
the project level (`Duration` has a string JSON form), so proto3 JSON's trickier cases do not
arise. The rules:

1. **Field names — lowerCamelCase.** Use the proto3 JSON default `json_name` (e.g. `apiVersion`,
   `entryPoint`, `onSuccess`, `startActivity`). No field overrides `json_name`, so this is
   deterministic, and it matches the k8s-style authored YAML.
2. **Presence / defaults — per proto3 JSON.** Omit implicit-presence scalars at their default
   (`detached:false`, `requiredCount:0`, `""`), omit unset `optional` fields, and omit empty maps
   and empty repeated fields. An explicitly-set `optional` field is emitted even at its default
   value (presence is tracked). *(This also means the built bundle's emptied `dependencies` map is
   simply absent from the digest.)*
3. **Maps → JSON objects, keys sorted by JCS.** Applies to `workflows`, `dependencies`,
   `activities`, `headers`, and every `google.protobuf.Struct.fields` — recursively.
4. **Order-significant lists → JSON arrays, order preserved.** JCS never reorders arrays. Applies
   to `on_success` and `on_failure` (evaluated in order, first match wins),
   `PromiseActivityConfig.branches`, and `ListValue` arrays inside any `Struct`.
5. **`Struct` / `Value`.** Object/scalar per proto3 JSON. `number_value` (a `double`) is
   canonicalized by JCS (ECMAScript shortest round-trip). `NullValue` → JSON `null`. `NaN` and
   `±Infinity` are not representable as JSON numbers and are **forbidden** in bundle `Struct`
   values — reject at build time.
6. **`Duration` → proto3 JSON string** (`"3s"`, `"3.500s"`; up to nanosecond precision, fractional
   digits in groups of 0/3/6/9). The only `Duration` in the graph is `TimerActivityConfig.duration`.
7. **Numbers — RFC 8785 §3.2.2.3.** Covers `int32 requiredCount` and `Struct` doubles.
8. **Output.** `sha256`, lowercase hex, `"sha256:"`-prefixed — matching the `WorkflowReference.digest`
   field format.

## Worked example (structure)

A small bundle, shown as its canonical JSON. Note: **shown pretty-printed for readability; the
bytes that are actually hashed are JCS-minified** (no insignificant whitespace).

Source (informal), authored with `activities` in the order `start`, then `done`; a
`detached:false` on an activity; and an empty `dependencies`:

```json
{
  "entryPoint": "acme/greet:v1",
  "workflows": {
    "acme/greet:v1": {
      "apiVersion": "utos.io/v1",
      "kind": "Workflow",
      "metadata": {
        "name": "greet",
        "namespace": "acme",
        "version": "v1"
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
              { "condition": "{{ output.ok }}", "transition": { "name": "done" } },
              { "transition": { "name": "retry" } }
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
- **Defaults / empties omitted:** `dependencies` (empty), `on_failure` (empty), `done`'s empty
  `onSuccess`, the unset `optional` `description`/`registry`, and any `detached:false` are all
  absent.
- **`Duration`** as the string `"5s"`.

Digest: `sha256:` `TBD (reference impl)` — see Conformance.

## Conformance

This document pins the rules, but a prose spec alone can drift on an edge case (a double's
formatting, a default-omission). The format is **finalized** — i.e. locked so every SDK provably
agrees — by:

1. a single small **reference implementation** of the algorithm, and
2. committed **golden vectors**: `(WorkflowBundle input → expected sha256)` fixtures that become
   the cross-SDK source of truth, run as conformance tests in each SDK repo.

Both are **deferred** until a reference implementation exists (in the daemon or `sdk-dotnet`).
Until then the daemon should leave `WorkflowReference.digest` empty rather than emit a hash that
has not been conformance-checked.
