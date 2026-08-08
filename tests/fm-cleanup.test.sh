#!/usr/bin/env bash
# Public-interface tests for the structured attempt-bound cleanup operation:
# preflight-all-refusals-before-effects, per-effect receipts, branch-fate
# failure recording, wrapper identity, and nested-lock refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cleanup)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
export FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

# A fake treehouse keeps the provider-return step hermetic: the real binary
# refuses any copy it does not manage, exactly as fm-teardown.test.sh mocks
# treehouse for its own teardown fixtures.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <copy>`: succeed silently.
exit 0
SH
chmod +x "$FAKEBIN/treehouse"
CLEANUP_PATH="$FAKEBIN:$PATH"

setup_cleanup_attempt() {  # -> attempt id with claim+launch receipts and a tmux provider copy
  local aid gen
  aid=$(fm_attempt_alloc pi dos-g holu) || fail "alloc"
  gen=$(fm_attempt_generation "$aid") || fail "generation"
  fm_attempt_freeze_allocation "$aid" "$gen" "{\"provider\":\"tmux\",\"copy\":\"$TMP_ROOT/wt-g\"}" \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" "$gen" launch '{"endpoint":"w-g"}' || fail "launch"
  printf '%s\n' "$aid"
}

run_cleanup() {  # <attempt> <disposition> <env...>
  local aid=$1 disp=$2
  shift 2
  env "$@" PATH="$CLEANUP_PATH" "$ROOT/bin/fm-cleanup-lib.sh" --run "$aid" "$disp" 2>&1 || true
}

test_cleanup_refuses_live_processes_and_immature_quiet() {
  local aid out pid
  aid=$(setup_cleanup_attempt)
  mkdir -p "$TMP_ROOT/wt-g"
  (cd "$TMP_ROOT/wt-g" && sleep 300) &
  pid=$!
  out=$(run_cleanup "$aid" landed FM_TERMINAL_QUIET_SECS=100)
  kill "$pid" 2>/dev/null || true
  assert_contains "$out" "refused" "cleanup did not refuse"
  [ -d "$TMP_ROOT/wt-g" ] || fail "copy was removed on refusal"
  jq -e --arg n cleanup.endpoint '[.receipts[$n][]? | select(.state == "observed")] | length == 0' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "effect written despite refusal"
  pass "live processes and immature quiet preserve the copy with no effect written"
}

test_preflight_runs_before_any_effect() {
  # a refusal condition must prevent ALL effects: no endpoint, branch, provider,
  # or runtime effect may be observed
  local aid out pid n
  aid=$(setup_cleanup_attempt)
  mkdir -p "$TMP_ROOT/wt-g"
  (cd "$TMP_ROOT/wt-g" && sleep 300) &
  pid=$!
  out=$(run_cleanup "$aid" landed FM_TERMINAL_QUIET_SECS=0)
  kill "$pid" 2>/dev/null || true
  assert_contains "$out" "refused" "cleanup did not refuse on a live process"
  n=$(jq '[.receipts | to_entries[] | select(.key | startswith("cleanup.")) | .value[] | select(.state == "observed")] | length' \
    "$STATE/attempts/$aid.json")
  [ "$n" = 0 ] || fail "effects observed despite preflight refusal: $n"
  pass "all non-mutating refusal checks run before any endpoint stop, branch, or provider mutation"
}

test_cleanup_records_branch_disposition_failure() {
  local aid out
  aid=$(setup_cleanup_attempt)
  mkdir -p "$TMP_ROOT/wt-g"
  out=$(run_cleanup "$aid" landed FM_TERMINAL_QUIET_SECS=0 FM_BRANCH_DELETE_FAIL=1)
  jq -e --arg n cleanup.branch '[.receipts[$n][]? | select(.state == "observed")][0].evidence.failed == true' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "branch-disposition failure suppressed"
  jq -e --arg n cleanup.runtime '[.receipts[$n][]? | select(.state == "observed")] | length == 1' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "remaining effects did not complete after the branch-fate failure"
  pass "branch-disposition failure is recorded and the remaining effects still complete"
}

test_teardown_wrapper_identity() {
  local aid out
  aid=$(setup_cleanup_attempt)
  printf 'kind=ship\nmode=direct-PR\nattempt=%s\nworktree=%s/wt-g\n' "$aid" "$TMP_ROOT" > "$STATE/task-g.meta"
  out=$(env PATH="$CLEANUP_PATH" FM_TERMINAL_QUIET_SECS=0 \
    "$ROOT/bin/fm-teardown.sh" task-g --force 2>&1 || true)
  jq -e --arg n cleanup.runtime '[.receipts[$n][]? | select(.state == "observed")] | length == 1' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "teardown wrapper did not run the shared operation"
  pass "fm-teardown.sh is a compatibility wrapper over the same operation"
}

test_nested_lock_acquire_refuses() {
  local aid
  aid=$(setup_cleanup_attempt)
  fm_attempt_lock_acquire "$aid" || fail "outer acquire"
  fm_attempt_lock_acquire "$aid" && fail "nested acquire succeeded"
  fm_attempt_lock_release "$aid"
  pass "the cleanup path never reacquires a held attempt lock"
}

test_cleanup_refuses_live_processes_and_immature_quiet
test_preflight_runs_before_any_effect
test_cleanup_records_branch_disposition_failure
test_teardown_wrapper_identity
test_nested_lock_acquire_refuses
