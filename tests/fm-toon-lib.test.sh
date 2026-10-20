#!/usr/bin/env bash
# Behavior tests for bin/fm-toon-lib.sh's fm_toon_render: every TOON form it
# owns (scalars, nested objects, empty arrays, scalar arrays, tabular object
# arrays), the quoting rules, and a nonzero exit on input it cannot render.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "jq is required for TOON rendering tests" >&2; exit 1; }

# shellcheck source=bin/fm-toon-lib.sh
. "$ROOT/bin/fm-toon-lib.sh"

render() {  # <json>
  printf '%s\n' "$1" | fm_toon_render
}

test_scalars_and_nesting() {
  local out expected
  out=$(render '{"home":"fm","count":3,"ok":true,"none":null,"meta":{"schema":"v1","n":0}}') \
    || fail "scalar render failed"
  expected=$(printf '%s\n' 'home: fm' 'count: 3' 'ok: true' 'none: null' 'meta: ' '  schema: v1' '  n: 0')
  [ "$out" = "$expected" ] || fail "scalar/nested render mismatch: $out"
  pass "scalars and nested objects render as indented key lines"
}

test_arrays() {
  local out expected
  out=$(render '{"empty":[],"help":["Run x --json","plain"],"rows":[{"id":"a","status":"ok"},{"id":"b","status":"warn"}]}') \
    || fail "array render failed"
  expected=$(printf '%s\n' 'empty: []' 'help[2]: Run x --json,plain' 'rows[2]{id,status}:' '  a,ok' '  b,warn')
  [ "$out" = "$expected" ] || fail "array render mismatch: $out"
  pass "empty, scalar, and object arrays use their TOON forms"
}

test_quoting() {
  local out expected
  out=$(render '{"a":"","b":" pad","c":"true","d":"12","e":"x,y","f":"say \"hi\"","g":"line\nbreak","h":"-flag","i":["a:b","ok"]}') \
    || fail "quoting render failed"
  expected=$(printf '%s\n' 'a: ""' 'b: " pad"' 'c: "true"' 'd: "12"' 'e: "x,y"' 'f: "say \"hi\""' 'g: "line\nbreak"' 'h: "-flag"' 'i[2]: "a:b",ok')
  [ "$out" = "$expected" ] || fail "quoting mismatch: $out"
  pass "ambiguous strings are quoted and escaped"
}

test_unrenderable_input_fails() {
  if render 'not json' >/dev/null 2>&1; then
    fail "invalid JSON rendered successfully"
  fi
  pass "input jq cannot parse exits nonzero"
}

test_scalars_and_nesting
test_arrays
test_quoting
test_unrenderable_input_fails
