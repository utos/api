# Binary Data

Defines how a workflow handles bytes: the `Blob` and `File` values, how a blob is carried and
stored, what the HTTP activity does with a binary response or request body, how bytes get into and
out of a run, how long a stored blob lives, and the `BlobService` a daemon exposes for all of this
(`daemon/v1/blob.proto`). These are **spec-level** rules: an image fetched by one implementation's
activity has to be something the next activity can upload, whichever implementation runs it.

This document is written for three readers. An **SDK** author needs § A blob as a value, § Codes
and the conformance corpora. A **daemon** author needs all of it. A **client** author needs § Into
a run, § Out of a run, § The BlobService and § Implementing. The expression surface —
what `Blob` and `File` offer inside `{{ }}` — belongs to the language, so it is specified in
[`template-expressions.md` § Blob and File](template-expressions.md#blob-and-file) and only
summarized here.

**In this document.** [At a glance](#at-a-glance) is the summary;
[The types](#the-types) and [A blob as a value](#a-blob-as-a-value) are what a blob *is*;
[The HTTP activity](#the-http-activity), [Moving blobs](#moving-blobs), [Into a run](#into-a-run)
and [Out of a run](#out-of-a-run) are how bytes travel; [Retention](#retention) and
[History](#history) are how long they live and what is recorded;
[The BlobService](#the-blobservice) and [Storage](#storage) are the daemon's side;
[Limits and configuration](#limits-and-configuration), [Codes](#codes) and
[Implementing](#implementing) close it.

## The problem, and the constraints on any answer

Before 0.20.0 a workflow could read an HTTP response's bytes as a `Buffer`, and could do nothing
else with them. A `Buffer` cannot leave an expression, so an image fetched by one activity could
not be uploaded by the next, handed to a sub-workflow, taken as a run's input, or returned as its
result.

Three constraints shape every part of what follows.

1. **A value is persisted, replayed, and passed between executions.** Whatever a value holds is
   written to the run's history, read back after a restart, and possibly handed to an activity on
   another node. A live stream therefore cannot be a value. And bytes placed *in* a value are copied
   at every hop.
2. **The engine has payload limits.** An orchestration engine carries activity inputs and results
   as messages. Dapr, for example, uses gRPC, whose default message limit is a few megabytes.
   Megabytes of bytes in a value hit that limit, and long before they do, they multiply the size of
   the history.
3. **Expressions are synchronous, bounded, and replayed.** They run under a statement budget, a
   memory limit and a timeout. They are not where gigabytes should move.

The answer is to put a **handle** in the value and keep the bytes in **object storage**. Bytes
small enough not to matter ride inline, where copying them costs nothing. Nothing moves bytes
unless a workflow asked for it.

## At a glance

- **`Blob`** is the value: an immutable sequence of bytes with a media type. **`File`** is a
  `Blob` with a name. **`Buffer`** is bytes in memory inside an expression, and cannot leave
  one.
- `response.body` is a `Blob`. A blob crosses every boundary a value crosses: transitions,
  sub-workflows, promise branches, handlers, emitted values, results, and a run's input.
- A blob is **inline** (bytes in the value) or **stored** (a handle to an object in storage). The
  two behave identically. Which one a daemon produces is its own configuration.
- Stored bytes live in **object storage** that every node can reach. A client uploads to and
  downloads from the store directly, at locations the daemon has the store sign. The daemon never
  proxies a client's bytes.
- A blob is **durable** when somebody asked for it: a client's upload, or something a run
  returned or emitted. Otherwise it is **intermediate**, and the daemon removes it once no run can
  reach it.
- Every stored blob has a **history**: who uploaded or produced it, and which workflows attached,
  read or downloaded it.
- There are no streams, ranges or transfer jobs in values or in expressions. The one place parts
  appear is a client's upload, which is multipart and resumable above what a store takes in one
  request. How a particular store does multipart (part sizes, receipts) stays the store driver's
  business.

## The types

Three types, with Node's names and meanings, because the language stays as close to Node as it
can ([`template-expressions.md` § Node.js globals](template-expressions.md#nodejs-globals)):

| Type | What it is | Leaves an expression? |
|---|---|---|
| `Buffer` | Bytes in memory: indexable, sliceable, hashable, decodable. The type an expression manipulates | **No.** Wrap it: `new Blob([buf], { type })` |
| `Blob` | An immutable sequence of bytes with a media type. Its bytes are read on demand, and asynchronously | **Yes.** It is a value |
| `File` | A `Blob` with a `name` and `lastModified`. Every `File` is a `Blob` | **Yes** |

**Why `Blob` and not a `Buffer` value.** A `Buffer` is all its bytes, in memory, now. A response
body may be larger than memory, and a value is copied at every hop. A `Blob` is the promise of
bytes: its `size` and `type` are known at once, and its bytes are fetched only when someone reads
them. Node and the browser draw the same line, and `fetch`'s `response.blob()` is exactly what
`response.body` is here.

**Immutability is the property everything else rests on.** Nothing in any interface writes, fills,
appends to, or truncates a blob. Because of that, two executions reading one blob can never
disagree, a replay reads the same bytes the original run did, and a retry can reopen what the first
attempt read.

### In an expression

The full surface is in `template-expressions.md` § Blob and File. In brief:

```js
response.body.size                             // bytes, always known
response.body.type                             // media type, '' when unknown
await response.body.text()                     // UTF-8 text, bounded by the materialization limit
await response.body.bytes()                    // a Buffer, bounded likewise
response.body.slice(0, 1024)                   // a new Blob over a range; reads nothing
new Blob([buf, 'trailer'], { type: 'application/pdf' })
new File([buf], 'report.pdf', { type: 'application/pdf' })
x instanceof Blob                              // true of a File too
```

## A blob as a value

On the wire a blob is `WorkflowValue.blob_value`, a `utos.workflow.v1.Blob` (`workflow/v1/value.proto`).
Its type is structure, never content ([`workflow-values.md`](workflow-values.md)), so no key in
any map is reserved.

| Field | Inline | Stored |
|---|---|---|
| `data` | the bytes | — |
| `id` | — | an opaque identifier the daemon minted |
| `offset` | `0` | where the blob starts within the stored object |
| `size` | `len(data)` | the blob's length |
| `media_type` | media type, `''` when unknown | the same |
| `name` | present ⇔ the blob is a `File` | the same |
| `last_modified` | a `File`'s modification time | the same |

**Invariants.** `size ≥ 0`. For an inline blob, `offset = 0` and `size = len(data)`. For a stored
blob, `offset ≥ 0` and `offset + size` is at most the stored object's length. A blob that breaks one
of these is malformed.

**Both backings are one type.** In an expression the two are indistinguishable: `size`, `type` and
every method behave the same way, and no property reveals which backing a blob has. An author
cannot write a document that works with one and fails with the other. Which backing a blob gets is
decided by whoever creates it, against the daemon's **inline threshold**
(§ Limits and configuration). A client reading values off the wire must accept both.

**An `id` is not an address.** It is not a storage key, a URL, or a content digest. A daemon
resolves it by lookup in its own records, and only within the run trees the blob belongs to
(§ Access). Knowing an id grants nothing.

**Slicing a stored blob copies nothing.** A slice is the same object at a different `offset` and
`size`. Slicing an inline blob produces an inline blob holding the sliced bytes. A slice is always a
`Blob`, never a `File`, even when sliced from one, as in Node.

**A `File`'s `last_modified`** is set by whoever creates the `File`: the client at upload, an
expression from its options or the captured instant, or a daemon from the completion time. When it
is absent, `lastModified` reads as `0`. That value is deterministic, where "now" would not be.

## The HTTP activity

### Reading a response

When a response arrives:

1. **`response.body` is a `Blob` holding the body's bytes** exactly as the server sent the
   representation. The only bytes removed are those of a content coding the implementation
   requested *itself*. A daemon that adds `accept-encoding: gzip` on its own initiative decompresses
   before creating the blob. If the author declared `accept-encoding`, the author gets the coded
   bytes. An empty body is a blob of size `0`.
2. **Its media type** is the response's `content-type`, serialized as a MIME type (type and subtype
   lowercased, parameters kept), or `''` when the header is absent or unparsable. The body is a
   `Blob`, not a `File`, whatever `content-disposition` says.
3. **`output` is the parsed JSON body when the media type's essence is `application/json` or ends
   in `+json`**, and `null` otherwise. An empty or unparsable JSON body is also `null`. `output` never
   holds a blob. A JSON body is **also** available in
   `response.body`, unchanged. That is what a webhook signature check needs, because re-serializing
   the parsed value would change the bytes that were signed.
4. **The body is capped at the implementation's maximum body size.** A response that exceeds it is
   aborted and the activity fails with `UTOS-F101`. That failure goes down the `onFailure` path with
   `response.status` and `response.headers` set and `response.body` `null`.

`content-length` is a hint only. It is missing on chunked responses and sometimes wrong. The count
of bytes actually read decides both the threshold and the cap.

The **inline or stored** decision is made while reading, and it is invisible. A body that ends at
or below the inline threshold becomes an inline blob. A body that crosses it is written to storage
as it streams, so nothing is read twice and nothing larger than a buffer's worth is held in memory.
A daemon with no store configured fails a response that crosses the threshold with `UTOS-F102`.

`response` is `{ status, headers, body }`. The `bodyText` key that existed before 0.20.0 is
**retired**. It was eagerly decoded text, which cannot exist for a body larger than memory. See
[`template-expressions.md` § Migrating from 0.19](template-expressions.md#migrating-from-019).

### Sending a request body

`HttpActivityConfig.body` is a text template
([`template-expressions.md`](template-expressions.md#where-expressions-appear)), with one exception:

- **A whole-field `body` whose value is a `Blob` sends that blob's bytes.** For example,
  `body: "{{ input.photo }}"`. An inline blob is written from memory. A stored blob is streamed
  from the store, with `content-length` taken from its `size`, so nothing is buffered.
- **The request's `content-type`** is the author's declared header when there is one, the blob's
  `type` when it is not empty, and `application/octet-stream` otherwise. For a body that is not a
  blob, the default is `application/json`.
- **Any other value renders as text.** That includes a string, and an object or
  array rendered as JSON.
- **A blob anywhere else in a text field is `UTOS-E103`.** That covers a blob interpolated into a
  larger body, into a URL or into a header, and a blob nested inside an object that renders as
  JSON. Bytes have no text form an author did not choose.

**A retry reopens the blob.** A stored blob is a handle, so a second attempt opens a fresh stream
from the store rather than rewinding a spent one. This is why streams are not values and handles
are. If the bytes cannot be read, the activity fails with `UTOS-F103`.

## Moving blobs

A blob goes wherever a value goes, and nothing about it changes on the way:

| Path | How |
|---|---|
| Between activities of one execution | A transition's `input` carries it |
| Into a sub-workflow, promise branch or handler | The invocation's `input` carries it |
| Out of a sub-workflow | The callee's result carries it to the caller's `output` |
| Out of an activity kind that passes input through | A `timer`'s output is its input, blob included |
| Out of a run | The run's result, or a value it emitted |
| Into a run | A client puts a handle, or small inline bytes, in `ScheduleExecutionRequest.input` |
| Into a spawned run | The `workflow.spawn` activity's `input` carries it, and it is attached to the new run tree |

### Run trees

A **run tree** is a root execution together with every execution started beneath it by
`workflow.call`, a promise branch, or a rule's `workflow.call` effect. `workflow.spawn` starts a **new** run
tree: the spawned execution is an independent top-level run, as it is everywhere else in the spec.

A stored blob **belongs to** every run tree that produced it or had it attached.

### Access

**An execution may read a stored blob only if the blob belongs to its run tree.** A handle naming
any other object is not read. It fails with `UTOS-F103`, exactly as a blob that no longer exists
does. This is why an id proves nothing: forging one gets an attacker a failure, not bytes. It also
means the spec needs no signature on a handle.

A stored blob joins a run tree in exactly three ways:

- **It is produced there.** An activity in the tree wrote it: a response body or an
  expression-built blob that crossed the inline threshold.
- **A client attaches it at `ScheduleExecution`.** It must be durable (§ Into a run).
- **A `workflow.spawn` attaches it to the tree it starts.** It must belong to the spawning tree, and
  it then belongs to both. If it cannot be attached, the spawn activity fails with `UTOS-F104`.

The spec defines no per-caller authorization for blobs, just as it defines none for executions.
Every caller a daemon admits may attach any durable blob. Restricting that is a deployment's
concern.

## Into a run

A client puts a blob into `ScheduleExecutionRequest.input` in one of two forms.

- **Stored**, which works for any size. `CreateBlob`, upload to the signed location, `CompleteBlob`,
  then place the returned handle in the input. One upload can start any number of runs.
- **Inline**, for small bytes with no round trip. Place a blob with `data` in the input. This works
  without a store, and is refused when larger than the daemon's inline threshold.

Before anything is scheduled, the daemon checks every blob in the input. A failure is
`INVALID_ARGUMENT` with `UTOS-F104`, carrying one `google.rpc.BadRequest` `FieldViolation` per
failing blob. `field` is the blob's JSON Pointer into the input, and `reason` is one of:

| `reason` | Meaning |
|---|---|
| `not_found` | No blob has this `id` |
| `not_ready` | The blob is `PENDING`: its upload was never completed |
| `deleted` | The blob is `DELETED` |
| `intermediate` | The blob belongs to another run and was not carried out of it. Only a durable blob may be attached |
| `out_of_range` | `offset + size` exceeds the stored object's length |
| `malformed` | An invariant of § A blob as a value does not hold |
| `too_large` | An inline blob exceeds the inline threshold. Upload it instead |

They are the second of the three stages a schedule request passes
([`workflow-values.md` § Well-formed values](workflow-values.md#well-formed-values)): after the
values are checked well-formed, before the schemas (`UTOS-H101`), which then see blobs as blobs. Each accepted
stored blob is **attached** to the new run tree and recorded in its history.

## Out of a run

A run's result and its emitted values carry blobs as they are. `GetExecution` and `WatchOutput`
return them unchanged, inline or stored. A client reads a stored blob's bytes by calling `GetBlob`
with `include_download`, then fetching the signed location. If the handle's `offset` and `size`
cover only part of the object, the client requests that range (`range: bytes=<offset>-<offset +
size - 1>`).

**A blob that reaches a root execution's output stream becomes durable** (§ Retention). A root
execution is the root of any run tree, spawned runs included. A blob reaches that stream as an
emitted value when the value is appended, or in the result when the run returns. What a run hands
to its caller or to a client is exactly what somebody asked for.

## Retention

### Two classes

| Class | What it is | Removed by |
|---|---|---|
| **durable** | A client's upload, or a blob that reached a root execution's output stream | `DeleteBlob`, `PruneBlobs`, or `DeleteExecution` with `delete_blobs` — only ever on request |
| **intermediate** | A blob a run produced that nothing carried out of it | The daemon, once no run tree it belongs to can reach it |

**Where a blob came from is metadata, not a class.** An upload and a returned result are both
things a person will look for later, both deserve a history, and both are removed the same way. The
distinction worth keeping is between blobs somebody asked for and blobs nobody did. A run that
fetches five things and returns one made four that nobody asked for, and those are what fill a
bucket without anyone noticing.

**Promotion** from intermediate to durable is irreversible and never copies bytes. A blob's class
cannot be known when it is written, because nothing knows yet whether it will be returned. A design
that kept the two classes in separate places would turn promotion into a server-side copy of an
object that may be gigabytes (§ Storage).

### What an implementation must guarantee

1. **A blob stays readable while a run can read it.** A daemon must not remove a blob while any run
   tree it belongs to is not terminal, unless it can prove that no execution in those trees can read
   it again. That includes a **retry**, which re-runs an activity from its recorded input and so
   re-reads bytes that a later transition no longer mentions. Removing a blob earlier than this is
   permitted, and is an optimization rather than a requirement.
2. **Durable blobs are removed only on request.** `DeleteBlob`, `PruneBlobs`, or `DeleteExecution`
   with `delete_blobs`, and nothing else.
3. **A removed blob stays answerable.** `GetBlob` answers `DELETED` for an id it issued for as long
   as the daemon keeps the record. It should keep the record at least as long as any execution
   record that mentions the id. Otherwise, reading an old run's result would look like corruption
   rather than cleanup.

### When intermediates go

These rules are recommended rather than required. The durations are configuration.

- **When every tree it belongs to has completed**, an intermediate can go at once. Nothing will
  read it again.
- **When a tree failed or was cancelled**, its intermediates should be kept for a configured window,
  or until the execution is deleted. They are exactly what an operator wants to look at, and
  deleting them at the moment of failure is how the evidence is lost.
- **A periodic sweep** catches what those two miss: uploads created but never completed, the
  intermediates of runs interrupted before they reached a terminal state, and anything past the
  failed-run window.
- **`DeleteExecution`** removes the tree's intermediates immediately. With `delete_blobs` it also
  deletes the durable blobs the tree produced. It never deletes a client's upload, which may have
  started other runs. Blobs that a non-terminal execution can still reference are skipped.

## History

Every stored blob keeps a timeline of events, which is what `GetBlobHistory` returns and what a
tool shows when asked about a blob:

| Event | When |
|---|---|
| `uploaded` | A client created it with `CreateBlob` |
| `produced` | An activity wrote it. Records the execution, its root, the workflow with its bundle digest, and the activity |
| `attached` | It arrived as a run tree's input, at `ScheduleExecution` or through `workflow.spawn` |
| `read` | An execution opened its bytes, by streaming them into a request or materializing them in an expression. Slicing is not a read, and neither is passing the value on |
| `downloaded` | A client was issued a download location |

**Events are about the handle, not the bytes.** "This workflow used this blob" is worth keeping.
"This activity read bytes 50 to 60" is not, and would grow without bound.

**Rows are aggregated by (event, root execution, workflow).** Recording an event that already has a
row updates that row's `last_at` and adds to its `executions` count, rather than adding a row. The
effect is that a loop reading a blob five thousand times in one execution is one row, and so is a
loop calling five thousand sub-workflows that each read it. The number of rows is bounded by how
many distinct documents touched the blob, which is small and predictable, rather than by fan-out,
which is neither. What is lost is which individual child execution read the blob, and nothing needs
that. `uploaded` and `downloaded` involve no execution and are one row each.

**The workflow is recorded with its bundle digest.** A name and version stop identifying what ran
once a bundle is rebuilt. The digest does not, and it is already computed at load
([`canonical-bundle-digest.md`](canonical-bundle-digest.md)).

**Execution ids are recorded as data, not as references.** A durable blob outlives its run, and
deleting the execution must not erase the provenance that made the blob worth keeping.

`BlobInfo.last_used_at` is the newest event. `usage_count` is the number of `attached` and `read`
rows.

## The BlobService

`utos.daemon.v1.BlobService` (`daemon/v1/blob.proto`). Every call is unary and **no call carries
bytes**. A daemon with no store configured answers every call `FAILED_PRECONDITION`.

### Uploading

An upload is **single** or **multipart**, and the daemon decides which. A client sends the size,
follows the answer, and needs no knowledge of the store behind the daemon.

A single upload, for a body the store accepts in one request:

```
client                         daemon                        store
  │ CreateBlob(type, name, size) ─►│                              │
  │                                │── sign an upload ───────────►│
  │◄── { PENDING, location } ──────│                              │
  │ PUT location.url, location.headers, the bytes ──────────────►│
  │ CompleteBlob(id) ─────────────►│── stat the object ──────────►│
  │◄── { READY, handle } ──────────│                              │
```

A multipart upload, for anything larger:

```
client                         daemon                        store
  │ CreateBlob(type, name, size) ─►│── begin a multipart upload ─►│
  │◄── { PENDING, multipart:       │                              │
  │      part_size, part_count } ──│                              │
  │ SignUploadParts(id, [1..100]) ►│── sign parts ───────────────►│
  │◄── 100 locations ──────────────│                              │
  │ PUT part 1 … part 100, concurrently ────────────────────────►│
  │ SignUploadParts(id, [101..]) ─►│   … until every part is sent │
  │ CompleteBlob(id) ─────────────►│── list parts, assemble ─────►│
  │◄── { READY, handle } ──────────│                              │
```

- **`CreateBlob`** records a `PENDING` blob with the given media type, optional `name` (which makes
  it a `File`), and optional `last_modified`, and answers with `location` or `multipart`.
  **`size` decides it**: without a size, the answer is always a single location, and so is bounded
  by what the store takes in one request (5 GiB on S3). A client that knows the size must send it.
  A daemon refuses a size larger than it will store.
- **A single upload** sends exactly `location.method` to `location.url` with every header in
  `location.headers`, before `expires_at`. The headers must be sent verbatim, because a signature
  may cover them.
- **A multipart upload** splits the body into `part_count` parts of `part_size` bytes each (the
  last part holds the rest), numbered from 1. `SignUploadParts` signs any parts on request, and a
  daemon may cap how many one call signs. Parts may be sent in any order, concurrently, and more
  than once: a failed part is simply sent again, and an expired signature simply re-signed. The
  daemon chooses the part size to fit its store's rules, for example S3's minimum of 5 MiB and
  maximum of 10,000 parts. A client never sees those rules.
- **Resuming.** A client that restarts mid-upload calls `GetBlob`. `uploaded_parts` lists what the
  store has received, and the client sends the rest. The whole upload must complete before
  `multipart.expires_at`, after which the sweep aborts it and discards the parts.
- **`CompleteBlob`** asks the store what was actually written. For a multipart upload it lists the
  parts and assembles them itself, so a client never tracks the store's per-part receipts (S3's
  entity tags, Azure's block ids). It records the real size and marks the blob `READY`, **durable**,
  with origin `uploaded`. It returns the handle to place in a run's input: the stored form,
  covering the whole object. It is idempotent on a `READY` blob. It returns `FAILED_PRECONDITION`
  when nothing was uploaded or a part is missing, and `NOT_FOUND` for an unknown id.

**Why signing is a call of its own, not a list in `CreateBlob`'s answer.** A multipart upload can
have ten thousand parts, and ten thousand signed URLs do not fit in one gRPC message under the
default limit. An upload of that size also takes longer than any signature should live. Signing on
demand covers both, and resuming after a restart falls out of it for free.

**The size a client claimed is never trusted, and neither is any digest it might claim.** A client
that uploads directly has hashed nothing the daemon saw, and a store's entity tag is not a content
hash for multipart objects. `BlobInfo.digest` is present only when the daemon hashed the bytes
itself as they passed through it, which happens for blobs a run produced.

### Downloading

`GetBlob` with `include_download` returns a `SignedLocation` for a `GET`, and records a
`downloaded` event. A client may add a `range` header to download part of the object.

### Inspecting and removing

- **`GetBlob`** returns the metadata and, for a `READY` blob, the whole-object handle. It answers
  `DELETED` rather than `NOT_FOUND` for a removed blob (§ Retention, guarantee 3).
- **`ListBlobs`** returns blobs newest first, filtered by class, origin, state, run tree, creation
  time and last use, one page at a time.
- **`GetBlobHistory`** returns the events of § History, oldest first.
- **`DeleteBlob`** removes a blob's bytes and leaves a `DELETED` record. It refuses with
  `FAILED_PRECONDITION` while a non-terminal execution can reference the blob: a run failing for a
  reason its author cannot see is worse than a refused delete. It is idempotent on a `DELETED`
  blob.
- **`PruneBlobs`** deletes every blob matching a filter, skipping those a non-terminal execution can
  reference. It requires at least one filter, so that an empty request cannot delete everything,
  and it offers a `dry_run`.

## Storage

What a daemon's blob store must provide. The first two requirements are what make a stored blob a
value that any node can read.

1. **Shared.** Every node that runs activities reaches the same objects. This is why there is no
   local-disk driver: a blob produced on one node must be readable by an activity scheduled on
   another.
2. **Immutable objects, read after write.** An object, once written, is never modified, and a read
   that follows a completed write sees it.
3. **Signed locations.** The store can issue short-lived, pre-authorized upload and download URLs,
   so that clients move bytes without the daemon relaying them and without holding store
   credentials. A daemon never signs anything itself.
4. **Streaming writes and reads**, so that neither a spilled response nor a streamed request body is
   held in memory.

Object storage satisfies all four. A filesystem satisfies none of 1, 3 and 4 without a daemon-hosted
signer that puts the daemon back into the data path. Development uses an S3-compatible server such
as MinIO instead.

## Limits and configuration

| Setting | Spec | Effect |
|---|---|---|
| **Inline threshold** | Configuration, invisible to authors | The largest blob carried inline, whether a response body, a blob built by an expression, or a client's inline input. Larger ones are stored |
| **Maximum body** | Configuration | The largest response body read. Past it, `UTOS-F101` |
| **Materialization limit** | Configuration, **at least 1 MiB** | The most bytes a single `bytes()` or `text()` call, or a single constructor, may bring into an expression's memory. Past it, `UTOS-E111` |
| Location expiry | Configuration | How long a signed location stays valid |
| Failed-run window | Configuration | How long a failed or cancelled tree's intermediates are kept |
| Sweep interval | Configuration | How often § When intermediates go runs |

**The materialization limit is the one portability floor.** A document that verifies a webhook
signature reads the body in an expression, and it must work on every daemon. A limit of at least
1 MiB (1,048,576 bytes) per read makes that true for any reasonable webhook. Above the floor, the
ceiling is the deployment's choice.

**The inline threshold needs no floor, because it is invisible.** No document can tell which
backing a blob has. Its value is a trade-off: it keeps small payloads out of storage, but every
inline byte is copied at every hop and written to history. A few hundred kibibytes is a reasonable
starting point, and it should be measured against the engine's real payload limits.

## Codes

`UTOS-F1##` codes are reported as a `WorkflowError`, carrying the code, the activity, and a message.
Every one of them is catchable by `onFailure` at the activity where it occurs, except where the
table says otherwise. The HTTP activity has no error-code taxonomy for HTTP statuses, and these
codes are not one. They name the failures that are **not** an HTTP status, which an `onFailure` rule
could not otherwise tell apart.

| Code | Rule |
|---|---|
| `UTOS-F101` | A response body exceeded the maximum body size. `response.status` and `response.headers` are set; `response.body` is `null` |
| `UTOS-F102` | A blob had to be stored and no store is configured — a response body or an expression-built blob over the inline threshold |
| `UTOS-F103` | A blob's bytes could not be read: it was deleted, it does not belong to this run tree, or the store failed after the implementation's own retries |
| `UTOS-F104` | A blob in a new run's input cannot be attached. At `ScheduleExecution` this is `INVALID_ARGUMENT` with `google.rpc.BadRequest` (§ Into a run); at a `workflow.spawn`, the spawn activity fails |

Four codes from the expression language cover the rest — three existing ones that gain a blob
case, and one new static rule:

| Code | Blob case |
|---|---|
| `UTOS-E103` | A `Buffer` or a promise leaving an expression, and a blob in a text field or in an error's `details` |
| `UTOS-E111` | A read beyond the materialization limit |
| `UTOS-E120` | Converting a blob to text implicitly: `toString`, `valueOf`, `toJSON`, a template literal, `JSON.stringify` |
| `UTOS-E070` | A retired member of a scope name, such as `response.bodyText`, read in an expression. A static rule |

A **transient** store failure, such as a timeout or throttling, is not `UTOS-F103` on the first
occurrence. An implementation retries it as it retries any activity-level I/O, and reports
`UTOS-F103` only when it gives up.

## Conformance

- **`evaluation/`**: a blob in scope, inline and stored; `size`, `type`, `slice` (including that a
  slice reads only its range); `text()` and `bytes()`; the materialization limit; constructing
  `Blob` and `File`; `instanceof`; a blob leaving an expression as a value; a blob refusing implicit
  conversion;
  and `response.bodyText` being retired. A case holding a blob is written in the wire form,
  as protobuf JSON of `WorkflowMap` and `WorkflowValue`, with the stored bytes beside it.
- **`schema/`**: `utos:blob` and `utos:file`, `mediaType` including wildcards and lists, `maxSize`,
  and how a blob fares against the ordinary keywords.
- **`source/`**: `type: blob` and `type: file` in the short form, `maxSize` with units, and
  `UTOS-S015`.
- **`validation/`**: `UTOS-E070`, `UTOS-H015`, and `await` accepted by the grammar.

The storage, HTTP and service behaviour is not in a corpus, since it needs a store, a server and a
daemon. The reference daemon's integration suite covers it.

## Implementing

### An SDK

- The generated `WorkflowValue` and `Blob` types, and the JSON conversions and well-formedness
  checks of [`workflow-values.md`](workflow-values.md).
- The static rules: `UTOS-E070`; `await`, `async` arrows and `instanceof` admitted by the grammar;
  `new Blob` and `new File` admitted by `UTOS-E040`'s allow-list.
- The schema compiler: `type: blob` and `type: file`, `mediaType`, and `maxSize` with units.
- The schema load rules: `UTOS-H015`.
- If the SDK evaluates schemas against data, the blob-aware evaluation in `workflow-schemas.md`.

### A daemon

- Values as `WorkflowValue` end to end, with an unambiguous internal encoding.
- A blob store meeting § Storage, with a driver per provider.
- The HTTP activity as § The HTTP activity describes: the inline-or-spill read, the maximum body,
  the JSON rule, and blob request bodies streamed from storage.
- In the expression engine: `Blob` and `File` host objects, reads that go through a store, the
  materialization limit, and `await`.
- Access checks by run tree; attaching at schedule and at spawn; promotion at a root output stream.
- Metadata and history (§ History), retention and the sweep (§ Retention), and the `BlobService`.
- `ScheduleExecution`'s blob checks, and `DeleteExecution`'s `delete_blobs`.

### A client

Put a file into a run:

1. `CreateBlob` with the media type (inferred from the extension if not given), the file name, and
   the size.
2. Upload as answered. For `location`, send the whole body to `location.url` with
   `location.method` and exactly `location.headers`. For `multipart`, cut the body into
   `part_size` pieces, sign them in batches with `SignUploadParts`, and send each piece to its
   location, several at a time. Retry a failed part, and re-sign when a signature expires.
3. `CompleteBlob`, and take `handle`. If the client restarted in between, `GetBlob` first tells it
   which parts still need sending.
4. Place the handle at its path in the input, as a `blob_value`, and call `ScheduleExecution`.
5. If `CreateBlob` answers `FAILED_PRECONDITION` (no store) and the file is small, the client may
   send it inline instead. The daemon refuses it with `too_large` if it is not small enough.

Get a file out:

1. Read the result or an emitted value (`GetExecution`, `WatchOutput`) and find `blob_value`
   nodes.
2. For an inline blob, the bytes are `data`. For a stored blob, call `GetBlob(id,
   include_download)`, then `GET` the location, adding `range` if `offset` and `size` don't cover
   the whole object.

A client must never construct a handle itself. It uses the handle `CompleteBlob` or the daemon
returned. A client must also never spell a blob in JSON: `$blob`, or any other key, is data
([`workflow-values.md` § JSON](workflow-values.md#json)).

The reference CLI's surface, for orientation. It is not normative:

```
utos blob put ./cat.png                 # create, upload direct, complete; prints the handle
utos blob get <id> -o ./cat.png         # download direct
utos blob ls                            # id, name, size, type, class, created, last used, usage
utos blob inspect <id>                  # metadata and history
utos blob rm <id>                       # refused while a live execution can reference it
utos blob prune [--until 30d] [--unused] [--class intermediate] [--dry-run]
utos run wf.yaml --start fetch --blob photo=./cat.png --input '{"width": 640}'
utos execution output <id> [--download ./out]
utos execution rm <id> [--blobs]
```

## Recorded, not specified

- **A response larger than one activity's timeout** is not resumable. A retry starts from the
  beginning. Resuming would need either ranged requests driven by the workflow or a transfer job
  owned by the daemon. Both were rejected for this version as a new concept disproportionate to a
  rare case.
- **Importing an object that already exists in the bucket**, such as a nightly drop. This needs an
  answer for objects that change underneath a run, since replay assumes immutability.
- **Signed locations handed to activities**, so that a third party reads or writes an object
  directly.
- **Hashing a blob without materializing it**, e.g. `crypto.hash('sha256', blob)` over a stored
  object. Useful for large downloads, and not Node's API.
- **A response body as a `File`**, named from `content-disposition`.
- **Reclaiming an intermediate before its run ends.** § Retention permits it and does not require
  it. The mechanism would be counting the live frames that name a blob, not counting references.
