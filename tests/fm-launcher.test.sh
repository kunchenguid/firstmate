#!/usr/bin/env bash
# Executable-interface tests for the root Firstmate Pi launcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-launcher)
PROJECT="$TMP_ROOT/project with spaces"
FAKEBIN="$TMP_ROOT/fakebin"
MISSING_PATH="$TMP_ROOT/no-pi"
CAPTURE="$TMP_ROOT/capture"

mkdir -p "$PROJECT/.pi/extensions/nested" "$PROJECT/.pi/extensions/fm-directory.ts" \
  "$PROJECT/.agents/skills" "$PROJECT/skills" "$PROJECT/state" "$FAKEBIN" \
  "$MISSING_PATH" "$CAPTURE"
cp "$ROOT/fm" "$PROJECT/fm"
chmod +x "$PROJECT/fm"
for extension in fm-branch-supervision.ts fm-calm.ts fm-future.ts \
  fm-primary-pi-watch.ts fm-primary-turnend-guard.ts fm-zeta.ts; do
  printf 'extension\n' >"$PROJECT/.pi/extensions/$extension"
done
printf 'nested\n' >"$PROJECT/.pi/extensions/nested/fm-nested.ts"
printf 'not a Firstmate extension\n' >"$PROJECT/.pi/extensions/other.ts"
printf 'worker-only\n' >"$PROJECT/state/fm-worker-turnend.ts"
printf 'internal skill\n' >"$PROJECT/.agents/skills/internal.md"
printf 'public skill\n' >"$PROJECT/skills/public.md"

cat >"$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
set -eu
: "${FM_CAPTURE:?FM_CAPTURE is required}"
printf '%s\n' "$PWD" >"$FM_CAPTURE/cwd"
printf '%s\n' "$#" >"$FM_CAPTURE/count"
i=0
for arg in "$@"; do
  printf '%s' "$arg" >"$FM_CAPTURE/arg-$i"
  i=$((i + 1))
done
SH
chmod +x "$FAKEBIN/pi"

assert_arg() {
  local index=$1 expected=$2 expected_file
  expected_file="$TMP_ROOT/expected-$index"
  printf '%s' "$expected" >"$expected_file"
  cmp -s "$expected_file" "$CAPTURE/arg-$index" \
    || fail "argument $index was not preserved (expected '$expected')"
}

assert_invocation() {
  local -a expected=("$@")
  local index=0 expected_arg
  assert_equals "$PROJECT" "$(cat "$CAPTURE/cwd")" \
    "launcher did not start Pi from the checkout"
  assert_equals "${#expected[@]}" "$(cat "$CAPTURE/count")" \
    "launcher passed an unexpected number of Pi arguments"
  for expected_arg in "${expected[@]}"; do
    assert_arg "$index" "$expected_arg"
    index=$((index + 1))
  done
}

run_launcher() {
  (cd "$TMP_ROOT" && PATH="$FAKEBIN:$PATH" FM_CAPTURE="$CAPTURE" \
    "$PROJECT/fm" "$@") || fail "launcher did not complete through fake Pi"
}

test_launcher_defaults_and_isolation() {
  local -a caller_args expected
  caller_args=(--mode text $'message\nwith newline' '' '* [glob]')
  expected=(
    --no-extensions
    --no-skills
    --skill "$PROJECT/.agents/skills"
    --model openai-codex/gpt-5.6-sol
    --thinking low
    -e "$PROJECT/.pi/extensions/fm-branch-supervision.ts"
    -e "$PROJECT/.pi/extensions/fm-calm.ts"
    -e "$PROJECT/.pi/extensions/fm-future.ts"
    -e "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
    -e "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
    -e "$PROJECT/.pi/extensions/fm-zeta.ts"
    "${caller_args[@]}"
  )

  run_launcher "${caller_args[@]}"
  assert_invocation "${expected[@]}"
  invocation_args=$(cat "$CAPTURE"/arg-* 2>/dev/null || true)
  assert_not_contains "$invocation_args" 'nested/fm-nested.ts' \
    "launcher loaded a nested extension"
  assert_not_contains "$invocation_args" 'other.ts' \
    "launcher loaded an unapproved extension"
  assert_not_contains "$invocation_args" 'fm-worker-turnend.ts' \
    "launcher loaded a worker-only resource"
  assert_not_contains "$invocation_args" "$PROJECT/skills" \
    "launcher loaded the public skills directory"
  pass "fm defaults Pi, loads only top-level Firstmate extensions and local skills"
}

test_launcher_preserves_provider_model_and_thinking_overrides() {
  local -a caller_args expected
  caller_args=(--model 'openrouter/anthropic/claude-sonnet-4-5' --thinking xhigh --mode text)
  expected=(
    --no-extensions
    --no-skills
    --skill "$PROJECT/.agents/skills"
    -e "$PROJECT/.pi/extensions/fm-branch-supervision.ts"
    -e "$PROJECT/.pi/extensions/fm-calm.ts"
    -e "$PROJECT/.pi/extensions/fm-future.ts"
    -e "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
    -e "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
    -e "$PROJECT/.pi/extensions/fm-zeta.ts"
    "${caller_args[@]}"
  )

  run_launcher "${caller_args[@]}"
  assert_invocation "${expected[@]}"
  pass "fm preserves provider-qualified model and thinking overrides"
}

test_launcher_honors_option_terminator() {
  local -a expected
  expected=(
    --no-extensions
    --no-skills
    --skill "$PROJECT/.agents/skills"
    --model openai-codex/gpt-5.6-sol
    --thinking low
    -e "$PROJECT/.pi/extensions/fm-branch-supervision.ts"
    -e "$PROJECT/.pi/extensions/fm-calm.ts"
    -e "$PROJECT/.pi/extensions/fm-future.ts"
    -e "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
    -e "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
    -e "$PROJECT/.pi/extensions/fm-zeta.ts"
    -- --model caller/message --thinking caller-level
  )

  run_launcher -- --model caller/message --thinking caller-level
  assert_invocation "${expected[@]}"
  pass "fm keeps option-like messages after the caller's terminator"
}

test_launcher_reports_missing_pi() {
  local error_file="$TMP_ROOT/missing-pi.err" rc invocation_args
  if PATH="$MISSING_PATH" /bin/bash "$PROJECT/fm" >"$TMP_ROOT/missing-pi.out" 2>"$error_file"; then
    rc=0
  else
    rc=$?
  fi
  assert_equals 127 "$rc" "launcher used an unavailable Pi dependency"
  assert_contains "$(cat "$error_file")" 'pi executable not found on PATH' \
    "launcher did not explain the missing Pi dependency"
  pass "fm reports a missing Pi executable without invoking anything else"
}

test_launcher_defaults_and_isolation
test_launcher_preserves_provider_model_and_thinking_overrides
test_launcher_honors_option_terminator
test_launcher_reports_missing_pi
