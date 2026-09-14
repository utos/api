# Template Expressions

Defines the language of the `{{ }}` templates and `condition` strings in a
`utos.workflow.v1.WorkflowBundle`: what may be written, what it evaluates to, and what every
implementation must guarantee while evaluating it. These are **spec-level** rules, each with a
stable code, for the same reason as [`workflow-validation.md`](workflow-validation.md): a
workflow must mean the same thing on every implementation, and an expression that one daemon
accepts cannot be one another rejects or computes differently.

## Scope

Expressions are **JavaScript**, by reference to ECMAScript, restricted to the subset in
[§ Grammar](#grammar) and evaluated under the guarantees in [§ Runtime](#runtime-guarantees).
This document defines only what Utos adds to ECMAScript: which strings are expressions, the
scope they see, the subset, the values that cross in and out, the host library, and the
guarantees. Everything else — operator semantics, coercion, the behaviour of `map` — is
ECMAScript's, and is not restated here.

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
| `PromiseForEach.collection` | **Whole-field value** — `{{ }}`, must evaluate to an array |
| Leaf strings of `TransitionTarget.input`, `EmitAction.value`, `TransitionRule.result`, `EmissionRule.result`, `CallActivityConfig.input`, `HandlerDispatch.input`, `PromiseBranch.input` | **Value** — whole-field or interpolation |
| `HttpActivityConfig.url`, `.headers` values, `.body`; `PromiseBranch.name` | **Text** — whole-field or interpolation, always rendered to a string |

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
or array as its JSON serialization. A **text** field (URL, header, body, branch name) is always
rendered, even in whole-field form.

```yaml
url: "{{ env.GMAIL_API ?? 'https://gmail.googleapis.com' }}/gmail/v1/users/me/messages/{{ input.id }}"
body: '{"emails": {{ input.emails }}}'
```

### Programs

A program is a sequence of statements; its value is the **completion value** of the last one,
which must be an expression statement (`UTOS-E063` if the program ends in a declaration). Every
program runs in **its own function scope**: a `const` in one expression is invisible to every
other, and no expression can define anything another one sees. Within one activity, expressions
are evaluated in document order.

## Scope

| Name | In scope for |
|---|---|
| `input`, `env` | every expression |
| `output`, `error`, `response` | every transition rule and everything it renders — `condition`, `transition.input`, `emit`, `result` — on **both** paths. **Always defined**, with `null` where they do not apply: `output` is `null` after a failure, `error` is `null` after a success, `response` and every key within `error` and `response` are `null` when there was no request or no response. A condition may name `response.status` on an activity that made no request and evaluate `false` rather than fail — the failure that would otherwise raise is raised while a failure is already being handled |
| a `PromiseForEach.alias` | the branch it is declared on: `name`, `condition`, `input` |
| dependency aliases | `PromiseBranch` and `EmissionRule` fields, as `workflow-source-format.md` defines them |
| `utos` | every expression — the host library, § Host library |

The meaning of each context — what `input` is on the start activity, why `error` is separate
from `output`, that `error` and `response` describe the activity a transition is *leaving* and
are not in scope when the target's own `url`, `headers` and `body` are rendered — is defined in
[`workflow-source-format.md` § Templates](workflow-source-format.md#templates); this document
does not restate it.

A name outside its row does not exist: reading it is a `ReferenceError`, reported as
`UTOS-E120`. A missing **member** of a name that does exist is `undefined`, as in JavaScript,
and `?.` and `??` are the idioms for optional data.

**Every value in scope is deep-frozen.** Assigning to it, adding to it, or calling a mutating
method on it (`push`, `sort`, `splice`, `fill`, `reverse`, `length = n`) is a `TypeError`
(`UTOS-E120`). `toSorted`, `toSpliced`, `with`, spread and `concat` produce copies and are the
idioms. Locals an expression creates itself are freely mutable.

## Values

### Numbers

There is **one number type**, the IEEE double, the same type `google.protobuf.Value` carries.
`5` and `5.0` are the same number; `10 / 4` is `2.5`; `3 / 4 * 100` is `75`; `%` and `**`
behave as ECMAScript defines. Consequences an implementation must honour:

- A result that is a whole number in range is delivered as an integer (`int64`), anything else
  as a double; a whole-valued result renders as `5`, never `5.0`.
- A non-finite result — `x / 0`, `0 / 0`, overflow — is `UTOS-E102`, never a value.
- **An integer beyond ±2⁵³ in scope is `UTOS-E104`**, refused before evaluation rather than
  rounded. A double cannot hold it exactly, and a snowflake-style id that came back changed
  would be worse than an error. Such ids travel as strings.
- `+` on a string concatenates: `'12345' + 1` is `'123451'`. This is ECMAScript, cannot be
  caught statically, and is named here because ids frequently arrive as strings.

### Results

A value leaving an expression must be **plain data**: `null`, a boolean, a number, a string, or
an array or plain object of those, finitely nested and acyclic. Anything else is `UTOS-E103`:
a function, an object with an accessor property, a `Map`, a `Set`, a cycle, or nesting deeper
than the implementation's limit. `undefined` as a **whole result** means the field is
**omitted**; `null` is carried as `null`. Symbol-keyed properties are dropped.

## Grammar

The language is the subset of ECMAScript given by this **allow-list** of syntax-tree node
types. Anything not listed — including whatever a future ECMAScript edition adds — is refused
with the code shown, and its position. The subset is chosen as the smallest language that
expresses a workflow transition: loose on data access, with **no loops, no classes, no
prototypes, and no functions other than arrows.** Two properties follow, and are the point:
iteration can only happen over data that already exists, so work is proportional to input
size; and no expression can build a prototype chain.

Programs are parsed as **strict mode** scripts. A parse failure is `UTOS-E060`.

| In the language | | Refused | Code |
|---|---|---|---|
| `const`, `let`; `if`/`else`; blocks; `;` | | `var` | `UTOS-E010` |
| arrow functions, as callbacks and as `const` helpers, with expression or block bodies; `return` inside them | | `for`, `for…of`, `for…in`, `while`, `do` | `UTOS-E001` |
| `null`, booleans, numbers, strings, template literals, regex literals | | `function` declarations and expressions | `UTOS-E002` |
| array and object literals, spread, computed keys | | `class` | `UTOS-E003` |
| destructuring with defaults and rest, in declarations and parameters | | `try`, `throw`, `switch`, labels, `with`, `debugger` | `UTOS-E004` |
| `.`, `[]`, `?.` member access | | `return` outside an arrow body | `UTOS-E011` |
| calls; `new Set`, `new Map` | | array holes `[1, , 3]` | `UTOS-E012` |
| `===` `!==` `==` `!=` `<` `<=` `>` `>=` `+` `-` `*` `/` `%` `**` `in` | | getters, setters, methods in object literals | `UTOS-E020` |
| `&&` `\|\|` `??`, `? :` | | `__proto__` as an object-literal key | `UTOS-E021` |
| `!`, unary `-`/`+`, `typeof` | | `this` | `UTOS-E030` |
| `=` `+=` `-=` `*=` `/=`, `++`, `--` | | `async`, `await`, generators, `yield` | `UTOS-E031` |
| | | `import`, `import.meta` | `UTOS-E032` |
| | | comma expressions | `UTOS-E035` |
| | | `new` of anything but `Set`/`Map` | `UTOS-E040` |
| | | calling `Array`, `Object`, `Function`, `eval` | `UTOS-E041` |
| | | `delete`, `void`, `~` | `UTOS-E050` |
| | | `instanceof`, bitwise and shift operators | `UTOS-E051` |
| | | other compound assignments (`\|=`, `**=`, `??=`…) | `UTOS-E052` |
| | | any other node type | `UTOS-E099` |

Recursion through a `const` helper (`const f = n => … f(n - 1) …`) is in the language and is
bounded at evaluation time (`UTOS-E113`). `==`/`!=` are in the language; implementations may
warn on them.

Two form-level static rules sit alongside: `{{` inside a `condition` (`UTOS-E061`), and an
interpolation segment that does not close with `}}` after one expression (`UTOS-E062`).

## Runtime guarantees

What an implementation **must** provide while evaluating, whoever produced the bundle. Each is
a conformance fixture; none may be assumed from a validating client.

1. **Nothing but the subset runs.** The grammar is checked on the tree the engine will run,
   before it runs it — by the executor, not only by a validating client.
2. **The surface is an allow-list.** Only the globals, prototype members, statics and host
   functions in [§ Surface](#surface) exist. There is no `Date`, no `Math.random`, no `Proxy`,
   `Reflect`, `Promise`, `WeakRef`, no `RegExp` constructor (regex literals remain), no
   `Function.prototype.constructor`, no `Object.create` or `setPrototypeOf`, no `Array.from`,
   no `repeat`/`padStart`/`padEnd`, and no route from data to code: `eval` and the `Function`
   constructor are absent and string-to-code compilation is disabled. Everything that remains
   is frozen; the global object is unreachable.
3. **Scope values are deep-frozen copies**, never live host objects (§ Scope).
4. **Evaluation is deterministic**: no time, no randomness, invariant culture, one function
   scope per program, document order within an activity.
5. **Limits exist, are captured when the execution is scheduled, and are invisible to
   script.** Each fires as its own code:

   | Limit | Code |
   |---|---|
   | statement budget (counts callback invocations too) | `UTOS-E110` |
   | memory | `UTOS-E111` |
   | wall-clock timeout | `UTOS-E112` |
   | recursion depth | `UTOS-E113` |
   | native stack exhausted (`JSON.stringify` or `flat` on a deep structure) | `UTOS-E114` — an error, never a process exit |
   | array size | `UTOS-E115` |
   | `JSON.parse` depth | `UTOS-E116` |
   | regex timeout, on literals compiled at parse time as well as at match time | `UTOS-E117` |
   | cancellation of the execution | `UTOS-E118` |

   Values are implementation configuration, not spec; the spec requires that each exists and
   is reported as above, with the actual number in the message.
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
`encodeURIComponent`, `decodeURIComponent`, `encodeURI`, `decodeURI`, `utos`.

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
function and constant except `random`.

## Host library

`utos.*` is spec surface: each function is a conformance fixture, so the list stays short.

| Function | Behaviour |
|---|---|
| `utos.base64Decode(s)` | Standard alphabet, padding required; UTF-8 text |
| `utos.base64UrlDecode(s)` | URL-safe alphabet (`-`/`_`), padding optional — what Gmail, JWTs and OAuth use |
| `utos.base64Encode(s)` | UTF-8 text to the standard alphabet with padding |

Each takes a string and returns a string; any other argument is a `TypeError` (`UTOS-E120`).

## Conformance

Two corpora under [`../conformance/`](../conformance/):

- **`validation/`** — the static rules, as bundle fixtures with `code` + `path`, exactly as for
  every other rule.
- **`evaluation/`** — the evaluation rules, as cases of the form below. An implementation is
  conformant when every case produces the expected value (compared as JSON) or the expected
  code.

```json
{
  "form": "condition | value | text",
  "expression": "output.items.map(i => i.id)",
  "scope": { "output": { "items": [ { "id": "a" } ] } },
  "expect": { "value": ["a"] }
}
```

```json
{ "form": "condition", "expression": "output.items", "scope": { "output": { "items": [] } }, "expect": { "error": "UTOS-E101" } }
```

## Reference implementation

Non-normative. The reference daemon evaluates with [Jint](https://github.com/sebastienros/jint)
4.16.x: strict mode, string compilation disabled, no CLR or module access, statement, memory,
timeout, recursion, array-size and JSON-depth constraints, a cancellation token, the regex
timeout set on both the engine and the parsing options, and `StackOverflowGuard` enabled — off
by default in Jint 4.x, and the difference between `UTOS-E114` and a dead process. The surface
is produced by deleting everything not listed and freezing what remains, scope values are
frozen host-side as they are copied in, and one engine serves all the expressions of one
activity. The grammar is checked with Acornima, the same parser the engine uses, on the tree
the engine then runs.

## Migrating from Scriban

Non-normative. Before this document the reference implementation evaluated `{{ }}` with
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
| `string.base64_decode` with manual `-`/`_` swap and padding | `utos.base64UrlDecode(data)` |

Behaviour that changes without an error: a missing member is `undefined` rather than a fatal
error; a condition must be boolean where Scriban accepted any truthy value; `10.0 / 4` is `2.5`
on every path; division by zero is an error rather than `Infinity`.
