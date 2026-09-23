#!/usr/bin/env bash
# Regenerates the expression-*.json / .expected.json pairs for the UTOS-E0## rules of
# docs/template-expressions.md, plus the action fixtures of 0.0.16. Each fixture trips exactly one
# rule. Run from this directory.
set -euo pipefail

W='workflows[\"greet:1.0.0\"].spec.activities[\"say-hello\"]'

bundle() { # $1=url $2=onSuccess-json
cat <<EOF
{
  "entryPoint": "greet:1.0.0",
  "workflows": {
    "greet:1.0.0": {
      "apiVersion": "utos.io/v1",
      "kind": "Workflow",
      "metadata": { "name": "greet", "version": "1.0.0" },
      "spec": {
        "activities": {
          "say-hello": {
            "http": { "method": "GET", "url": "$1" },
            "onSuccess": $2
          }
        }
      }
    }
  }
}
EOF
}
expected() { printf '{ "issues": [ { "code": "%s", "path": "%s" } ] }\n' "$2" "$3" > "$1.expected.json"; }

cond() { # $1=name $2=condition $3=code
  bundle "https://api.example.com/hello" "[ { \"condition\": \"$2\", \"result\": {} } ]" > "$1.json"
  expected "$1" "$3" "$W.onSuccess[0].condition"
}
url() {
  bundle "$2" "[]" > "$1.json"
  expected "$1" "$3" "$W.http.url"
}
leaf() { # a struct leaf on a transition back to the same activity (a back-edge is legal)
  bundle "https://api.example.com/hello" "[ { \"transition\": { \"name\": \"say-hello\", \"input\": { \"value\": \"$2\" } } } ]" > "$1.json"
  expected "$1" "$3" "$W.onSuccess[0].transition.input.value"
}

rm -f expression-*.json transition-to-keyword*.json error-without-code*.json

cond expression-loop                    "let n = 0; while (false) { n = 1 } n === 0"        UTOS-E001
cond expression-function                "const f = function () { return 1; }; f() === 1"    UTOS-E002
cond expression-class                   "(class {}) !== null"                                 UTOS-E003
cond expression-try                     "try { 1 } catch (e) { 2 } true"                     UTOS-E004
cond expression-var                     "var x = 1; x > 0"                                    UTOS-E010
cond expression-array-hole              "[1, , 3].length === 3"                               UTOS-E012
cond expression-getter                  "({ get x() { return 1 } }).x === 1"                 UTOS-E020
cond expression-proto-key               "({ __proto__: null }) !== null"                      UTOS-E021
cond expression-this                    "this === undefined"                                  UTOS-E030
cond expression-import                  "import('x') !== null"                               UTOS-E032
cond expression-comma                   "(1, true)"                                           UTOS-E035
cond expression-new                     "new Proxy({}, {}) !== null"                          UTOS-E040
cond expression-new-function            "new Function('return 1')() === 1"                    UTOS-E040
cond expression-forbidden-call          "Array(3).length === 3"                               UTOS-E041
cond expression-eval                    "eval('true')"                                        UTOS-E041
cond expression-function-constructor    "Function('return true')()"                           UTOS-E041
cond expression-unary-operator          "void 0 === undefined"                                UTOS-E050
cond expression-syntax-error            "output.status ==="                                   UTOS-E060
cond expression-delimited-condition     "{{ output.status === 'ready' }}"                    UTOS-E061
cond expression-unknown-node            "String.raw\`x\`.length > 0"                          UTOS-E099
url  expression-unclosed                "https://api.example.com/orders/{{ input.id"         UTOS-E062
leaf expression-no-value                "{{ const a = 1; }}"                                  UTOS-E063
leaf expression-interpolation-statement "id-{{ const a = 1; a }}-x"                          UTOS-E062

# 0.20.0: a retired member of a scope name is refused at load, by every spelling a parser can see.
cond expression-retired-member          "response.bodyText === ''"                        UTOS-E070
cond expression-retired-member-pattern  "const { bodyText } = response; bodyText === ''"    UTOS-E070

# 0.0.16 actions: the former keywords are ordinary unresolved names, and an error needs a code.
bundle "https://api.example.com/hello" '[ { "transition": { "name": "end" } } ]' > transition-to-keyword-end.json
expected transition-to-keyword-end UTOS-T003 "$W.onSuccess[0].transition.name"
bundle "https://api.example.com/hello" '[ { "transition": { "name": "error" } } ]' > transition-to-keyword-error.json
expected transition-to-keyword-error UTOS-T003 "$W.onSuccess[0].transition.name"
bundle "https://api.example.com/hello" '[ { "error": { "message": "no code" } } ]' > error-without-code.json
expected error-without-code UTOS-T005 "$W.onSuccess[0].error.code"
