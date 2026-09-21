# Template Expressions

Defines the language of the `{{ }}` templates and `condition` strings in a
`utos.workflow.v1.WorkflowBundle`: what may be written, what it evaluates to, and what every
implementation must guarantee while evaluating it. These are **spec-level** rules, each with a
stable code, for the same reason as [`workflow-validation.md`](workflow-validation.md): a
workflow must mean the same thing on every implementation, and an expression that one daemon
accepts cannot be one another rejects or computes differently.

## What this document covers

Expressions are **JavaScript**, by reference to ECMAScript, restricted to the subset in
[§ Grammar](#grammar) and evaluated under the guarantees in [§ Runtime](#runtime-guarantees).
This document defines only what Utos adds to ECMAScript: which strings are expressions, the
scope they see, the subset, the values that cross in and out, the Node.js globals that are
available and how the non-deterministic ones are made deterministic, and the guarantees.
Everything else — operator semantics, coercion, the behaviour of `map` or of `Buffer` — is
ECMAScript's or Node's, and is not restated here.

The rules split into two kinds, reported differently:

| Kind | When | Reported as |
|---|---|---|
| **Static** (`UTOS-E0##`) | While a bundle is validated or loaded, by parsing the expression text | `code` + `path`, exactly like the rules in `workflow-validation.md` |
| **Evaluation** (`UTOS-E1##`) | While an execution runs | A `WorkflowError` carrying the code, the activity, and the field path |

Static rules are part of bundle validation and belong to the shared validator: an
implementation applies them wherever it applies `workflow-validation.md`, and never assumes
another tool has. Evaluation rules are enforced by the executor on every evaluation.

## Where expressions appear

| Field | Form |
|---|---|
| `TransitionRule.condition`, `EmissionRule.condition`, `PromiseBranch.condition` | **Condition** — the whole string is one expression, no delimiters, must be boolean |
| `PromiseForEach.collection` | **Whole-field value** — `{{ }}`, must evaluate to an array; anything else — a string, an object, a number, `null`, `undefined` — is `UTOS-E105` |
| Leaf strings of `TransitionTarget.input`, `EmitAction.value`, `TransitionRule.result`, `EmissionRule.result`, `WorkflowActivityConfig.input`, `HandlerDispatch.input`, `PromiseBranch.input` | **Value** — whole-field or interpolation |
| `HttpActivityConfig.url`, `.headers` values; `PromiseBranch.name`; `WorkflowError.message` | **Text** — whole-field or interpolation, always rendered to a string |
| `HttpActivityConfig.body` | **Text**, with one exception: a whole-field template whose value is a `Blob` sends that blob's bytes ([`binary-data.md` § Sending a request body](binary-data.md#sending-a-request-body)) |
| Leaf strings of `WorkflowError.details` | **Value**, restricted to plain data — a blob there is `UTOS-E103`, because details stay JSON ([`workflow-values.md`](workflow-values.md#values-and-templates)) |

A string containing no `{{` is a literal in every position except a condition, where it is an
expression (`condition: "true"` is valid; `condition: "{{ true }}"` is not — `UTOS-E061`).

## Forms

### Condition

```yaml
condition: "output.status === 'ready'"
condition: "response.status === 429 || response.status >= 500"
```

The string is one program (§ Programs). Its value **must be exactly `true` or `false`**; any
other value — including JavaScript's truthy `0`, `""`, `[]` and `{}` — is `UTOS-E101`, not a
branch taken. `output.missing?.deep === 'x'` is `false`; `output.items` alone is an error.

### Whole-field value

The trimmed string starts with `{{`; a parser consumes **one complete program** from after it;
and the remaining text is exactly `}}`. The program's value is the field's value, **typed**:
an object stays an object, an array an array, a number a number.

```yaml
messages: "{{ [...new Set(output.history.flatMap(h => h.messagesAdded ?? []).map(m => m.message.id))] }}"
body: |
  {{
    const parts = output.payload.parts ?? [output.payload];
    const flat = parts.flatMap(p => [p, ...(p.parts ?? [])]);
    flat.find(p => p.mimeType === 'text/plain' && p.body?.data)?.body.data ?? ''
  }}
```

No scanning for the closing delimiter takes place, so `{{ {a: {b: 1}} }}` is one program
containing an object literal. The "remaining text is exactly `}}`" condition is what separates
this form from interpolation: `{{ a }} and {{ b }}` also starts with `{{` and ends with `}}`,
but the program ends at the first `}}` with text left over.

### Interpolation

`{{ }}` inside other text. Each segment is found the same way — at `{{`, one expression is
parsed and the next non-space token must be `}}` (`UTOS-E062` otherwise) — and rendered to
text in place. Rendering: a string as itself; a number in its shortest round-trip decimal form
(`5`, not `5.0`; `2.5`); `true`/`false`; `null` and `undefined` as the empty string; an object
or array as its JSON serialization; a blob, nowhere (`UTOS-E103`, § Results). A **text** field
(URL, header, body, branch name) is always rendered, even in whole-field form — except a
whole-field `body` holding a blob.

```yaml
url: "{{ env.GMAIL_API ?? 'https://gmail.googleapis.com' }}/gmail/v1/users/me/messages/{{ input.id }}"
body: '{"emails": {{ input.emails }}}'
```

### Programs

A program is a sequence of statements; its value is the **completion value** of the last one,
which must be an expression statement (`UTOS-E063` if the program is empty or ends in a
declaration). Every program runs in **its own function scope**: a `const` in one expression is
invisible to every other, and no expression can define anything another one sees. Within one
activity, expressions are evaluated in document order.

**`await` is permitted at a program's top level**, as though the program were the body of an
async arrow, so a condition can read a body directly:

```yaml
condition: "(await response.body.text()).includes('rate limit')"
```

The program's value is its completion value **after** every `await` in it has resumed — never a
promise. An expression that ends in a promise it did not await is `UTOS-E103`.

## Scope

What an expression can see, and what each name holds. This is the one place scope is defined; the
source format's § Templates only shows how authors use it.

| Name | Holds | In scope for |
|---|---|---|
| `input` | What this activity received: on a run's start activity, the run's input; on a sub-workflow's start activity, the invoking construct's rendered `input`; otherwise the rendered `input` of the transition that led here — or, where that transition declared none, the previous activity's `output`, passed through unchanged | every expression |
| `env` | The run's ambient environment, `string → string`, supplied with the run (`ScheduleExecutionRequest.env`) and inherited by every sub-workflow. A document does not set it; it may declare what it requires (`spec.env`, [`workflow-schemas.md`](workflow-schemas.md)) | every expression |
| `output` | What the activity a rule is leaving produced. For `http`, the parsed JSON body or `null` ([`binary-data.md` § Reading a response](binary-data.md#reading-a-response)); for `timer`, its input; for `workflow.call`, the callee's result; for `workflow.spawn`, `{ "execution_id": … }`; for a promise, a map keyed by branch `name`. **In an `onEmitted` rule, the emitted value.** `null` after a failure | every rule, and everything the rule renders |
| `error` | Why the activity failed — `{ code, message, details }`. `null` after a success and in an `onEmitted` rule | every rule, and everything the rule renders |
| `response` | An `http` activity's response — `{ status, headers, body }` — on **both** paths | every rule, and everything the rule renders |
| a `PromiseForEach.alias` | The collection item this branch was expanded for | the branch it is declared on: `name`, `condition`, `input` |

"Everything the rule renders" is its `condition`, `transition.input`, `emit`, `result` and
`error` — and, for an `onEmitted` rule, `handle.input`.

**`output`, `error` and `response` are always defined, and so is every key within `error` and
`response`**, with `null` where they do not apply: `response`, and each of its keys, is `null` when
there was no request or no response. A condition may therefore name `response.status` on an
activity that made no request and evaluate `false`. Implementations must not leave these undefined:
the failure that would raise is raised *while a failure is already being handled*, which is the
worst moment for it.

**`error` is separate from `output`** rather than replacing it on the failure path, so that a
condition written for the success path can never silently read error fields.

**`output`, `error` and `response` describe the activity a rule is leaving**, and are not in scope
when the *target* activity's own `url`, `headers` or `body` are rendered — that is a fresh scope of
`input` and `env`. What the target needs is carried across in the transition's `input`
(`workflow-source-format.md` § Templates shows the pattern).

`response` is `{ status, headers, body }`: `headers` with **lowercased names**
(`response.headers['retry-after']` — HTTP header names are case-insensitive and a JavaScript
property lookup is not, so one spelling is chosen, Node's), and `body` the response's bytes as a
**`Blob`** (§ Blob and File), whatever its media type — the same bytes `output` was parsed from,
when it was. What the HTTP activity reads, and when a body is stored rather than held inline, is
[`binary-data.md` § The HTTP activity](binary-data.md#the-http-activity).

`error` is `{ code, message, details }`: the failure's identifier and explanation, and `details`,
the structured details it carried — what an `error` action's `details` rendered to, including one
a failed sub-workflow raised — or `null` when it carried none. Every key is present on the failure
path, so `error.details?.orderId` reads through or is `undefined`, and never fails for want of a
`details` key.

A name outside its row does not exist: reading it is a `ReferenceError`, reported as
`UTOS-E120`. A missing **member** of a name that does exist is `undefined`, as in JavaScript,
and `?.` and `??` are the idioms for optional data — with the one exception of a retired member,
below.

**Every value in scope is deep-frozen.** Assigning to it, adding to it, or calling a mutating
method on it (`push`, `sort`, `splice`, `fill`, `reverse`, `length = n`) is a `TypeError`
(`UTOS-E120`). `toSorted`, `toSpliced`, `with`, spread and `concat` produce copies and are the
idioms. Locals an expression creates itself are freely mutable.

### Retired members

A member removed from a scope name is **retired**, not merely absent: reading it is an error, where
reading any other missing member is `undefined`. The difference matters exactly where a member used
to exist — `response.bodyText ?? ''` would otherwise keep evaluating, to `''`, and change what a
condition decides without a word.

| Member | Retired in | Instead |
|---|---|---|
| `response.bodyText` | 0.20.0 | `await response.body.text()` — see § Migrating from 0.19 |

A retired member is refused twice. **Statically**, `UTOS-E070` refuses a member expression on the
scope name naming it — `response.bodyText`, `response?.bodyText`, `response['bodyText']` — and an
object pattern destructuring it from the scope name, `const { bodyText } = response`; this catches
every document that spells it, at load, before anything runs. **At evaluation**, reading it by any
spelling the static rule cannot see — `response['body' + 'Text']` — throws a `TypeError`
(`UTOS-E120`). The static rule applies only where the name refers to the scope name, not to a local
that shadows it.

## Values

### Numbers

There is **one number type**, the IEEE double, the same type a value's `number_value` carries
([`workflow-values.md`](workflow-values.md)).
`5` and `5.0` are the same number; `10 / 4` is `2.5`; `3 / 4 * 100` is `75`; `%` and `**`
behave as ECMAScript defines. Consequences an implementation must honour:

- A whole-valued number renders as `5`, never `5.0`, wherever it is rendered to text. On the
  wire every number is a double; a value carries no separate integer type.
- A non-finite result — `x / 0`, `0 / 0`, overflow — is `UTOS-E102`, never a value.
- **An integer beyond ±2⁵³ in scope is `UTOS-E104`**, refused before evaluation rather than
  rounded. A double cannot hold it exactly, and a snowflake-style id that came back changed
  would be worse than an error. Such ids travel as strings.
- `+` on a string concatenates: `'12345' + 1` is `'123451'`. This is ECMAScript, cannot be
  caught statically, and is named here because ids frequently arrive as strings.

### Results

A value leaving an expression must be a **value** ([`workflow-values.md`](workflow-values.md)):
`null`, a boolean, a number, a string, a **`Blob`** (a `File` included), or an array or plain
object of those, finitely nested and acyclic. Anything else is `UTOS-E103`: a function, an object
with an accessor property, a `Map`, a `Set`, a `Buffer`, a `Date`, a `URL`, a **promise** — the
result of a `text()` or `bytes()` that was not awaited — a cycle, or nesting deeper than the
implementation's limit. `undefined` as a **whole result** means the field is **omitted**; `null`
is carried as `null`. Symbol-keyed properties are dropped.

Everything but a blob leaves as the data the author chose, and explicit beats a silent conversion:
bytes as a `Blob` (`new Blob([buffer], { type })`) or as text (`buffer.toString('base64')`), a date
as `.toISOString()` or `.getTime()`. A `Blob` leaves as itself, with its `type` and, for a `File`,
its `name`; which backing it has on the far side is the daemon's choice and cannot be observed.

Two places narrow this:

- **A text field** — a URL, a header, a body, a branch name, an error's message — renders to a
  string, and a blob has no text an author did not choose: a blob there is `UTOS-E103`, whether
  it is the whole value, interpolated, or nested in an object rendered as JSON. The one exception
  is a whole-field `HttpActivityConfig.body`, which sends the blob's bytes.
- **An error's `details`** stay plain JSON (`workflow/v1/common.proto`), so a blob there is
  `UTOS-E103`. An error explains a failure; it does not carry a payload.

## Grammar

The language is the subset of ECMAScript given by this **allow-list** of syntax-tree node
types. Anything not listed — including whatever a future ECMAScript edition adds — is refused
with the code shown, and its position. The subset is chosen as the smallest language that
expresses a workflow transition: loose on data access, with **no loops, no classes, no
prototypes, and no functions other than arrows.** Two properties follow, and are the point:
iteration can only happen over data that already exists, so work is proportional to input
size; and no expression can build a prototype chain.

Programs are parsed as **strict mode** scripts **with `await` permitted at the top level** (§
Programs) — as the body of an async arrow is. A parse failure is `UTOS-E060` — which is also where
a `return` outside an arrow body, `with`, an `await` inside an arrow that is not `async`, a `yield`
outside a generator, and the other things strict mode refuses end up, before any grammar rule sees
them.

| In the language | | Refused | Code |
|---|---|---|---|
| `const`, `let`; `if`/`else`; blocks; `;` | | `var` | `UTOS-E010` |
| arrow functions, as callbacks and as `const` helpers, with expression or block bodies; `return` inside them; `async` arrows | | `for`, `for…of`, `for await…of`, `for…in`, `while`, `do` | `UTOS-E001` |
| `await`, at a program's top level and inside an `async` arrow | | | |
| `null`, booleans, numbers, strings, template literals, regex literals | | `function` declarations and expressions | `UTOS-E002` |
| array and object literals, spread, computed keys | | `class` | `UTOS-E003` |
| destructuring with defaults and rest, in declarations and parameters | | `try`, `throw`, `switch`, labels, `with`, `debugger` | `UTOS-E004` |
| `.`, `[]`, `?.` member access | | array holes `[1, , 3]` | `UTOS-E012` |
| calls; `new Set`, `new Map`, `new Date`, `new URL`, `new URLSearchParams`, `new Blob`, `new File` | | | |
| `===` `!==` `==` `!=` `<` `<=` `>` `>=` `+` `-` `*` `/` `%` `**` `in` `instanceof` | | getters, setters, methods in object literals | `UTOS-E020` |
| `&` `\|` `^` `<<` `>>` `>>>` | | `__proto__` as an object-literal key | `UTOS-E021` |
| `&&` `\|\|` `??`, `? :` | | `this` | `UTOS-E030` |
| `!`, `~`, unary `-`/`+`, `typeof` | | | |
| every assignment operator (`=`, `+=`, `\|=`, `??=`…), `++`, `--` | | `import`, `import.meta` | `UTOS-E032` |
| | | comma expressions | `UTOS-E035` |
| | | `new` of anything but the seven above | `UTOS-E040` |
| | | calling `Array`, `Object`, `Function`, `eval` | `UTOS-E041` |
| | | `delete`, `void` | `UTOS-E050` |
| | | any other node type | `UTOS-E099` |

Codes that no longer refuse anything are **retired, not reused** — a code is what an implementation
suppresses, cites and asserts on, so giving an old one a new meaning would change behaviour
silently:

| Code | Refused | Why it is gone |
|---|---|---|
| `UTOS-E011` | — | Never allocated: what it would have refused is a strict-mode parse error, `UTOS-E060` |
| `UTOS-E031` | `async`, `await`, generators, `yield` | Retired in 0.20.0. `await` and `async` arrows are in the language so a blob's bytes can be read as Node reads them (§ Awaiting), and the rest is caught earlier: a generator is a `function*` (`UTOS-E002`) or a method (`UTOS-E020`), `yield` outside one is `UTOS-E060`, `for await` is a loop (`UTOS-E001`), an `async function` a function (`UTOS-E002`) |
| `UTOS-E051` | `instanceof` | Retired in 0.20.0. `value instanceof Blob` is how Node recognises a blob. "No prototypes" is about *building* or *changing* a chain; `instanceof` only reads one, as `Object.getPrototypeOf` can, over chains that are all frozen (§ Runtime guarantees 3). A `Symbol.hasInstance` an author writes makes it call an arrow, which an expression can already do. A right-hand side that is not a constructor is a `TypeError` (`UTOS-E120`) |
| `UTOS-E052` | compound assignment operators | Retired in 0.0.16, when every assignment operator was admitted — and bitwise and shift operators with them, pure integer arithmetic that `Buffer` work is written with |

Recursion through a `const` helper (`const f = n => … f(n - 1) …`) is in the language and is
bounded at evaluation time (`UTOS-E113`). `==`/`!=` are in the language; implementations may
warn on them.

Three static rules sit alongside: `{{` inside a `condition` (`UTOS-E061`), an interpolation
segment that does not close with `}}` after one expression (`UTOS-E062`), and a read of a retired
member of a scope name (`UTOS-E070`, § Retired members).

## Runtime guarantees

What an implementation **must** provide while evaluating, whoever produced the bundle. Each is
a conformance fixture; none may be assumed from a validating client.

1. **Nothing but the subset runs.** The grammar is checked on the tree the engine will run,
   before it runs it — by the executor, not only by a validating client.
2. **The surface is an allow-list.** Only the globals, prototype members, statics and Node.js
   globals in [§ Surface](#surface) and [§ Node.js globals](#nodejs-globals) exist. There is no
   `Proxy`, `Reflect`, `Promise` — promises exist only as what an async member returns and are
   only awaited (§ Awaiting) — `WeakRef`, no `RegExp` constructor (regex literals remain), no
   `Function.prototype.constructor`, no `Object.create` or `setPrototypeOf`, no `Array.from`,
   no `repeat`/`padStart`/`padEnd`, and no route from data to code: `eval` and the `Function`
   constructor are absent and string-to-code compilation is disabled. Everything that remains
   is frozen; the global object is unreachable.
3. **Scope values are deep-frozen copies**, never live host objects (§ Scope), **made in the
   evaluation's own realm**: an array in scope is an `Array` of the engine that evaluates it, so
   `input.items instanceof Array` is `true` and `Array.isArray` agrees. Every constructor in the
   surface — standard and Node.js globals alike — has a frozen `prototype`, and the host ones
   form Node's chains: a `File` is `instanceof Blob`, and a blob is an instance of the same `Blob`
   whichever backing it has.
4. **Evaluation is deterministic given its inputs.** Invariant culture, UTC, one function scope
   per program, document order within an activity — and the four sources of non-determinism
   Node has are replaced by values the executor captures **once per activity evaluation**: an
   instant and a seed (§ Node.js globals). Every expression of the activity sees the same time
   and the same sequence of ids, and so does a retry or a replay.
5. **Limits exist, are captured when the execution is scheduled, and are invisible to
   script.** Each fires as its own code:

   | Limit | Code |
   |---|---|
   | statement budget (counts callback invocations too) | `UTOS-E110` |
   | memory, and the **materialization limit** on one read of a blob's bytes — at least 1 MiB (§ Blob and File) | `UTOS-E111` |
   | wall-clock timeout | `UTOS-E112` |
   | recursion depth | `UTOS-E113` |
   | native stack exhausted (`JSON.stringify` or `flat` on a deep structure) | `UTOS-E114` — an error, never a process exit |
   | array size | `UTOS-E115` |
   | `JSON.parse` depth | `UTOS-E116` |
   | regex timeout, on literals compiled at parse time as well as at match time | `UTOS-E117` |
   | cancellation of the execution | `UTOS-E118` |

   Values are implementation configuration, not spec; the spec requires that each exists and
   is reported as above, with the actual number in the message. The materialization limit is the
   one with a floor, because a document that checks a webhook signature has to run everywhere.
   Time spent reading a blob counts toward the timeout like any other work.
6. **A script error is an evaluation error**, `UTOS-E120`: a `ReferenceError`, a `TypeError`
   from mutating a frozen value or calling a name that does not exist, a thrown value. It fails
   the evaluation; it never fails the executor.

An in-process sandbox is a mitigation, not an operating-system boundary: memory limits are
sampled between operations, and native-code paths have been found (and fixed) that no probe
covered. Implementations serving untrusted authors run evaluation in a separate process.

## Surface

Everything that exists in scope besides the names in § Scope. Anything not listed does not.

**Globals:** `undefined`, `NaN`, `Infinity`, `Array`, `String`, `Number`, `Boolean`, `Object`,
`Math`, `JSON`, `Set`, `Map`, `Symbol`, `parseInt`, `parseFloat`, `isNaN`, `isFinite`,
`encodeURIComponent`, `decodeURIComponent`, `encodeURI`, `decodeURI`, and the Node.js globals
`Buffer`, `Blob`, `File`, `crypto`, `Date`, `URL`, `URLSearchParams` (§ Node.js globals).

**`Array.prototype`:** `map` `filter` `find` `findIndex` `findLast` `findLastIndex` `some`
`every` `flatMap` `flat` `reduce` `reduceRight` `includes` `indexOf` `lastIndexOf` `slice`
`concat` `join` `at` `toSorted` `toReversed` `toSpliced` `with` `forEach` `keys` `values`
`entries` `push` `pop` `shift` `unshift` `splice` `sort` `reverse` `fill` `copyWithin`
`length`.

**`String.prototype`:** `includes` `indexOf` `lastIndexOf` `slice` `at` `trim` `trimStart`
`trimEnd` `toLowerCase` `toUpperCase` `startsWith` `endsWith` `split` `replace` `replaceAll`
`substring` `charAt` `charCodeAt` `codePointAt` `concat` `normalize` `match` `matchAll`
`search` `localeCompare` `length`.

**`Object.prototype`:** `hasOwnProperty` `toString` `valueOf`. **`Number.prototype`:**
`toFixed` `toString` `valueOf`. **`Boolean.prototype`:** `toString` `valueOf`.
**`Function.prototype`:** `call` `apply` `bind` `length` `name`. `Set` and `Map` keep their
standard prototypes.

**Statics:** `Array.isArray` `Array.of`; `Object.keys` `values` `entries` `fromEntries`
`assign` `freeze` `hasOwn` `getPrototypeOf` `getOwnPropertyNames`; `Number.isInteger`
`isFinite` `isNaN` `isSafeInteger` `parseFloat` `parseInt` `MAX_SAFE_INTEGER`
`MIN_SAFE_INTEGER` `EPSILON` `MAX_VALUE` `MIN_VALUE` `POSITIVE_INFINITY` `NEGATIVE_INFINITY`
`NaN`; `String.fromCharCode` `fromCodePoint`; `JSON.parse` `stringify`; `Math` — every
function and constant, `random` as § Node.js globals defines it.

## Node.js globals

Rather than a library of its own, the language exposes a **subset of Node.js's globals** under
their Node names and semantics, so that what an author already knows is what works. The subset is
chosen by three criteria: it cannot be written in the language itself (bytes, hashing), or its
cost is proportional to data the author does not control (a response body, where a script version
would spend the statement budget per byte), and it does no I/O — with the one exception of reading
the bytes of a blob the run already holds, which reaches nothing the author can name. Where Node's
behaviour is non-deterministic, ours is deterministic per activity, as follows.

**`Buffer`** — the bytes primitive, and the only one: there is no `ArrayBuffer`, `Uint8Array`,
`TextEncoder` or `atob`/`btoa`. A minimal `Buffer`, not a `Uint8Array` subclass:
`Buffer.from(string[, encoding])`, `Buffer.from(buffer)`, `Buffer.concat(list)`,
`Buffer.byteLength(string[, encoding])`, `Buffer.isBuffer`; on an instance `toString([encoding[,
start[, end]]])`, `length`, `slice`/`subarray(start[, end])`, `equals`, `compare`, `indexOf`,
`includes`, `at(i)` and `buffer[i]`, `readUInt8`, `readUInt16LE/BE`, `readUInt32LE/BE`,
`readInt8/16/32` likewise, `toJSON` (Node's `{ type: 'Buffer', data: [...] }`). Encodings:
`utf8`/`utf-8`, `base64`, `base64url` (the unpadded URL-safe alphabet Gmail, JWTs and OAuth use),
`hex`, `latin1`/`binary`, `ascii`, `utf16le`. A `Buffer` is what an expression computes with; it
is never in scope and cannot leave an expression (§ Results). A blob's bytes become one with
`await blob.bytes()`, and one becomes a value with `new Blob([buffer], { type })`.

**`crypto`** — `createHash(algorithm)` and `createHmac(algorithm, key)` with `update(data)` and
`digest(encoding)`; one-shot `hash(algorithm, data[, encoding])`; `randomUUID()`;
`timingSafeEqual(a, b)`. Algorithms: `sha256`, `sha512`, `sha1`, `md5`. Digest encodings:
`hex`, `base64`, `base64url`; `data` and `key` are strings or `Buffer`s. These are the
`node:crypto` module's synchronous functions placed on the global `crypto` (Node's own global
`crypto` is WebCrypto, whose API is asynchronous); there are no modules, so this is where they
live. Deliberately absent: `pbkdf2`, `scrypt`, ciphers, `sign`/`verify`, `subtle`.

**`Date`** — the full ECMAScript `Date` (`new Date(value)`, `Date.parse`, `Date.UTC`, every
getter, setter and formatter, `toISOString`, `getTime`), in UTC, with one rule: **`Date.now()`
and `new Date()` return the instant the executor captured for this activity evaluation**, for
every expression of the activity, on every retry and replay. Date arithmetic is therefore pure.

**`Math.random()`** — the *n*-th call (n from 0) returns the first 53 bits of
`SHA-256(seed ‖ n)` as a fraction in [0, 1), where `seed` is the 16 bytes of the captured seed
UUID and `n` an 8-byte big-endian integer. Deterministic given the seed, distinct per call.

**`crypto.randomUUID()`** — the *n*-th call (n from 0) returns UUID version 5 with the captured
seed as namespace and the decimal string of *n* as name. Deterministic given the seed, distinct
per call — which is what an idempotency key wants: identical on retry, different per activity.

**`URL`** and **`URLSearchParams`** — the WHATWG classes as Node exposes them: parsing, the
components, `searchParams` with `get`/`getAll`/`has`/`set`/`append`/`delete`/`toString`, and
`URLSearchParams` from a string, an object or entries. Pure; `href`/`toString()` is how one
leaves an expression.

The executor captures the instant and the seed once per activity evaluation and supplies them
to the engine. **The seed MUST be 128 bits drawn from a cryptographically secure random source,
fresh for every activity evaluation, and recorded so that a retry or replay of that evaluation
reuses it.** It must never be derived from anything an observer can know or guess — an
execution id, a timestamp, a counter, or a replay-safe id generator such as Durable Task's
`NewGuid()`, which hashes exactly those. With such a seed the derivations above are a hash-based
DRBG: earlier outputs reveal neither the seed nor later outputs, and one activity's values say
nothing about another's. (Node's own `Math.random()` is xorshift128+, whose state is recoverable
from a few outputs; this is deliberately not that.) What is *not* provided, by design, is a new
draw on retry: an evaluation's values are decided once. A conformance case supplies the instant
and seed as `clock` and `seed`. Calling `Math.random()` or `crypto.randomUUID()` counts across
all expressions of the activity in document order, so two expressions never draw the same value.

Recorded for later, each waiting on a named need: `Uint8Array` and `ArrayBuffer`, with `Buffer`
as a `Uint8Array` subclass and `blob.arrayBuffer()` (adding them breaks no document);
`TextDecoder` with a fixed label set (non-UTF-8 mail bodies); `crypto.verify` with JWK keys
(signed webhooks and ID tokens, keys fetched by an HTTP activity); `zlib` with an output cap;
`path.posix`; `Object.groupBy`. Never: anything with I/O or an event loop, `console`, `Intl`
(output differs by ICU build), `process` beyond what `env` already is.

### Blob and File

**`Blob`** — Node's `Blob`: an immutable sequence of bytes with a media type, and the one way bytes
leave an expression (§ Results). How a blob is carried, stored and kept is
[`binary-data.md`](binary-data.md); this is what an expression sees.

| Member | Behaviour |
|---|---|
| `new Blob([parts[, options]])` | `parts` an array of strings (encoded as UTF-8), `Buffer`s and `Blob`s, concatenated; `options.type` the media type, lowercased, `''` when absent or not printable ASCII — as Node. Other options are ignored |
| `size` | Length in bytes. Known at once, whatever the backing |
| `type` | Media type; `''` when unknown |
| `slice([start[, end[, contentType]]])` | A new `Blob` over a range, with Node's arithmetic: negative indices count from the end, both are clamped, and `contentType` defaults to `''`. **Reads nothing** — a slice of a stored blob is the same object at another offset |
| `bytes()` | A promise of the bytes as a **`Buffer`** — Node gives a `Uint8Array`, and `Buffer` is this language's only byte type |
| `text()` | A promise of the bytes decoded as UTF-8, as Node decodes them: a leading byte-order mark removed, an invalid sequence replaced with U+FFFD |

**`File`** — a `Blob` with a name, as Node's:

| Member | Behaviour |
|---|---|
| `new File(parts, name[, options])` | As `new Blob`, plus `name`; `options.lastModified` in epoch milliseconds, defaulting to the **captured instant**, so it is deterministic as `Date.now()` is |
| `name`, `lastModified` | As given. `lastModified` is `0` on a file whose value carried none ([`binary-data.md`](binary-data.md#a-blob-as-a-value)) |

A `File` is a `Blob` in every respect: it is `instanceof Blob`, it goes wherever a `Blob` goes,
and its `slice` returns a plain `Blob`, as in Node. **`value instanceof Blob` is how a blob is
recognised**, exactly as in Node, and an inline and a stored blob answer it the same way. A map
that merely looks like a blob, such as one with `size` and `type` keys, is not an instance, since
a blob's type is its structure and never its content ([`workflow-values.md`](workflow-values.md)).

**Reading bytes is bounded.** `bytes()` and `text()` bring the whole blob into memory, and so does
`new Blob` or `new File` for every `Blob` among its parts. Each such read beyond the
**materialization limit** is `UTOS-E111`, refused before anything is read — a blob's `size` is
always known. The limit is configuration with a **floor of 1 MiB** (1,048,576 bytes) per read,
which every implementation must accept, so that reading a webhook body works on every daemon.
Slicing first is how a large blob is read in part: `await blob.slice(0, 64).bytes()` reads 64
bytes of a 2 GiB blob. A read that fails for want of the bytes — the blob was deleted, or storage
failed — fails the evaluation with `UTOS-F103`.

**Absent, deliberately:** `arrayBuffer()`, since there is no `ArrayBuffer`; `stream()`, which needs
an event loop and back-pressure an expression has neither of; anything that writes — a blob is
immutable, and there is no surface through which it could change.

**A blob has no implicit text.** `toString`, `valueOf`, `toJSON` and `Symbol.toPrimitive` on a
`Blob` throw a `TypeError` (`UTOS-E120`), so `` `${blob}` ``, `'' + blob`, `String(blob)` and
`JSON.stringify(blob)` all fail. **Node differs**, returning `'[object Blob]'` and `'{}'`, and that
difference is the point: before 0.20.0 `response.body.toString('utf8')` was how a body was read,
and on a `Blob` it would otherwise return the literal text `[object Blob]` — a wrong value where an
error belongs.

### Awaiting

`bytes()` and `text()` are asynchronous, as Node's are, so `await` and `async` arrows are in the
language (§ Grammar). No concurrency comes with them:

- **A read happens when the member is called**, and the promise it returns is already settled. An
  expression's reads therefore happen in program order, whatever it awaits and when; two
  evaluations of one expression read the same bytes in the same order, which a blob's immutability
  makes the same bytes. Replay needs nothing more.
- **A failed read fails the evaluation** with its code — `UTOS-E111`, `UTOS-F103` — whether or not
  its promise is ever awaited. There is no `try`, so nothing could have handled it.
- **A promise can only be awaited.** There is no `Promise` global, so no `Promise.all` or `race`,
  and a promise's own members are not in the surface (§ Runtime guarantees 2). `await` of a value
  that is not a promise is that value, as in ECMAScript.
- **A promise is not a value.** One left un-awaited as a result is `UTOS-E103`; an `async` arrow's
  result is a promise too, and is awaited like one.

Reading several blobs is a sequence, which `reduce` expresses:

```js
await input.attachments.reduce(async (acc, f) => [...await acc, await f.text()], [])
```

The statement budget, the memory limit and the timeout apply unchanged.

## Conformance

Two corpora under [`../conformance/`](../conformance/) concern this language (a third,
`source/`, covers the source-format mapping):

- **`validation/`** — the static rules, as bundle fixtures with `code` + `path`, exactly as for
  every other rule.
- **`evaluation/`** — the evaluation rules, as cases of the form below. An implementation is
  conformant when every case produces the expected value (compared as JSON) or the expected
  code.

```json
{
  "form": "condition | value | text | collection",
  "expression": "output.items.map(i => i.id)",
  "scope": { "output": { "items": [ { "id": "a" } ] } },
  "expect": { "value": ["a"] }
}
```

```json
{ "form": "condition", "expression": "output.items", "scope": { "output": { "items": [] } }, "expect": { "error": "UTOS-E101" } }
```

A case whose scope or result holds a blob is written in the wire form, as `scopeWire` and
`expect.wire`: protobuf JSON of `WorkflowMap` and `WorkflowValue`, with the bytes of stored blobs
beside it. The corpus's README defines how a harness sets one up.

## Reference implementation

Non-normative. The reference daemon evaluates with [Jint](https://github.com/sebastienros/jint)
4.16.x: strict mode, string compilation disabled, no CLR or module access, statement, memory,
timeout, recursion, array-size and JSON-depth constraints, a cancellation token, the regex
timeout set on both the engine and the parsing options, and `StackOverflowGuard` enabled — off
by default in Jint 4.x, and the difference between `UTOS-E114` and a dead process. The surface
is produced by deleting everything not listed and freezing what remains, scope values are
frozen host-side as they are copied in, and one engine serves all the expressions of one
activity. `Buffer`, `crypto`, `URL` and `URLSearchParams` are host objects installed on the
engine; `Date.now`, the zero-argument `Date` constructor, `Math.random` and `crypto.randomUUID`
are overridden with the captured instant and seed. The instant comes from the orchestration
runtime's replay-safe clock; the seed is generated with the platform CSPRNG inside the activity
that evaluates the expressions, whose result the runtime persists, so a replay never re-draws it.
The grammar is checked with Acornima, the same parser the engine uses, on the tree the engine then
runs, with top-level `await` enabled in both.

`Blob` and `File` are to be host objects too. Jint runs `async` code and can drain its promise
jobs synchronously, so `bytes()` and `text()` can be host functions that read — from the inline bytes, or
by a blocking read from the store — and return a promise already resolved; `await` is then syntax
rather than concurrency. `Promise` is removed from the global object after the engine is built,
which leaves the intrinsic that `await` uses in place.

## Migrating

Non-normative. What changes for a document written against an earlier version, newest first.

### Migrating from 0.19

`response.body` became a `Blob` and `response.bodyText` was retired in 0.20.0, so
every document that read a body changes. None changes silently: `response.bodyText` is refused at
load (`UTOS-E070`), and every `Buffer` method called on a `Blob` is a `TypeError` (`UTOS-E120`) —
`toString` included, which is deliberate (§ Blob and File).

| 0.19 | 0.20 |
|---|---|
| `response.bodyText` | `await response.body.text()` |
| `response.body.toString()`, `.toString('utf8')` | `await response.body.text()` |
| `response.body.toString('base64')`, `'hex'`, `'latin1'`… | `(await response.body.bytes()).toString('base64')` |
| `response.body.length` | `response.body.size` |
| `response.body[i]`, `.readUInt8(i)`, `.slice(a, b)` on the bytes | `(await response.body.bytes())[i]` — or slice the blob first, `await response.body.slice(a, b).bytes()`, which reads only that range |
| Returning `response.body.toString('base64')` to carry bytes onward | Returning `response.body` itself — a blob is a value now, and the next activity can send it as a request body |

**Two differences in meaning**, neither of which raises an error:

- **`bodyText` honoured the response's declared charset; `text()` is always UTF-8**, as in Node. A
  body in another charset is read with `(await response.body.bytes()).toString('latin1')` or the
  matching encoding.
- **`output` is now parsed for any `+json` media type**, not only `application/json`. A document
  that tested `output === null` to detect, say, an `application/problem+json` error body now finds
  it parsed.

### Migrating from Scriban

Before this document the reference implementation evaluated `{{ }}` with
Scriban, unspecified. Existing documents change as follows; every Scriban form not listed is a
syntax error under the grammar, so a stale document fails to load rather than running
differently.

| Scriban | JavaScript |
|---|---|
| `condition: "{{ x == y }}"` | `condition: "x === y"` |
| `object.has_key input 'cursor'` | `input.cursor !== undefined` |
| `object.has_key env 'API' ? env.API : 'https://…'` | `env.API ?? 'https://…'` |
| `v = ''; for h in output.headers; if h.name == 'From'; v = h.value; end; end; v` | `output.headers.findLast(h => h.name === 'From')?.value ?? ''` |
| `ids = []; for h in …; ids = array.add ids …; end; array.uniq ids` | `[...new Set(output.history.flatMap(h => h.messagesAdded ?? []).map(m => m.message.id))]` |
| `object.to_json x` | `JSON.stringify(x)` |
| `html.url_encode x` | `encodeURIComponent(x)` |
| `object.values output` | `Object.values(output)` |
| `string.base64_decode` with manual `-`/`_` swap and padding | `Buffer.from(data, 'base64url').toString()` |
| `utos.base64UrlDecode(data)` (0.0.15 only) | `Buffer.from(data, 'base64url').toString()` — `utos.*` was withdrawn in 0.0.16 in favour of the Node globals |

Behaviour that changes without an error: a missing member is `undefined` rather than a fatal
error; a condition must be boolean where Scriban accepted any truthy value; `10.0 / 4` is `2.5`
on every path; division by zero is an error rather than `Infinity`.
