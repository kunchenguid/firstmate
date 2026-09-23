#!/usr/bin/env bash
# Behavior tests for bin/fm-harness.sh codex-max-models, the single read of the
# installed Codex model catalog behind Codex max effort validation and launch.
#
# Every case points CODEX_HOME (or HOME) at a fixture directory, so the
# developer's real catalog never decides a verdict.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-codex-catalog)
code='' out='' err=''

# run <exit-var> <out-var> <err-var> <codex-home>: the helper with CODEX_HOME set.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  _out=$(CODEX_HOME="$4" "$TOOL" codex-max-models 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

write_catalog() {  # <codex-home>
  mkdir -p "$1"
  cat > "$1/models_cache.json" <<'JSON'
{
  "client_version": "0.155.0",
  "models": [
    { "slug": "gpt-6-sol", "supported_reasoning_levels": [
      { "effort": "low" }, { "effort": "high" }, { "effort": "xhigh" }, { "effort": "max" }, { "effort": "ultra" } ] },
    { "slug": "gpt-5.5", "supported_reasoning_levels": [
      { "effort": "low" }, { "effort": "medium" }, { "effort": "high" }, { "effort": "xhigh" } ] },
    { "slug": "gpt-5.6-terra", "supported_reasoning_levels": [
      { "effort": "medium" }, { "effort": "max" } ] },
    { "slug": "no-levels" },
    { "supported_reasoning_levels": [ { "effort": "max" } ] }
  ]
}
JSON
}

# --- max advertised, and only for the models that advertise it --------------
write_catalog "$TMP_ROOT/advertised"
run code out err "$TMP_ROOT/advertised"
expect_code 0 "$code" "a readable catalog exits 0"
assert_equals '["gpt-6-sol","gpt-5.6-terra"]' "$out" "only models whose catalog entry lists max are printed"
assert_equals '' "$err" "a readable catalog is silent on stderr"
pass "codex-max-models lists exactly the catalog models that advertise max"

# --- max not advertised anywhere yields an empty list -------------------------
mkdir -p "$TMP_ROOT/none"
printf '%s\n' '{"models":[{"slug":"gpt-5.5","supported_reasoning_levels":[{"effort":"xhigh"}]}]}' > "$TMP_ROOT/none/models_cache.json"
run code out err "$TMP_ROOT/none"
expect_code 0 "$code" "a catalog without max still exits 0"
assert_equals '[]' "$out" "a catalog without max advertises no model"
pass "a catalog that never advertises max yields an empty list"

# --- HOME fallback when CODEX_HOME is unset -----------------------------------
write_catalog "$TMP_ROOT/user-home/.codex"
out=$(env -u CODEX_HOME HOME="$TMP_ROOT/user-home" "$TOOL" codex-max-models 2>/dev/null)
code=$?
expect_code 0 "$code" "the HOME fallback catalog is read"
assert_equals '["gpt-6-sol","gpt-5.6-terra"]' "$out" "an unset CODEX_HOME falls back to ~/.codex"
pass "codex-max-models falls back to ~/.codex when CODEX_HOME is unset"

# --- catalog missing ------------------------------------------------------------
mkdir -p "$TMP_ROOT/missing"
run code out err "$TMP_ROOT/missing"
expect_code 1 "$code" "a missing catalog exits 1"
assert_equals '' "$out" "a missing catalog prints nothing on stdout"
assert_contains "$err" "error: Codex model catalog not readable: $TMP_ROOT/missing/models_cache.json" "a missing catalog is named"
pass "a missing catalog is an error with no model list"

# --- catalog unreadable ---------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  write_catalog "$TMP_ROOT/unreadable"
  chmod 000 "$TMP_ROOT/unreadable/models_cache.json"
  run code out err "$TMP_ROOT/unreadable"
  chmod 600 "$TMP_ROOT/unreadable/models_cache.json"
  expect_code 1 "$code" "an unreadable catalog exits 1"
  assert_equals '' "$out" "an unreadable catalog prints nothing on stdout"
  assert_contains "$err" 'error: Codex model catalog not readable' "an unreadable catalog is named"
  pass "an unreadable catalog is an error with no model list"
fi

# --- catalog malformed ----------------------------------------------------------
mkdir -p "$TMP_ROOT/malformed"
printf '%s\n' '{"models":[' > "$TMP_ROOT/malformed/models_cache.json"
run code out err "$TMP_ROOT/malformed"
expect_code 1 "$code" "malformed JSON exits 1"
assert_equals '' "$out" "malformed JSON prints nothing on stdout"
assert_contains "$err" "error: Codex model catalog is malformed: $TMP_ROOT/malformed/models_cache.json" "malformed JSON is named"
printf '%s\n' '{"models":{"slug":"gpt-6-sol"}}' > "$TMP_ROOT/malformed/models_cache.json"
run code out err "$TMP_ROOT/malformed"
expect_code 1 "$code" "a catalog without a models array exits 1"
assert_equals '' "$out" "a catalog without a models array prints nothing on stdout"
assert_contains "$err" 'error: Codex model catalog is malformed' "a catalog without a models array is malformed"
pass "a malformed catalog is an error with no model list"

printf '# all fm-harness-codex-catalog tests passed\n'
