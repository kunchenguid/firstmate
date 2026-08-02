#!/usr/bin/env bash
# Behavior tests for the home-scoped no-mistakes reattach remedy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REATTACH="$ROOT/bin/fm-no-mistakes-reattach.sh"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-reattach)
fm_git_identity fmtest fmtest@example.invalid

make_case() {  # <name> <id>
  local id=$2 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/fakebin" "$dir/wt"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" checkout -q -b "fm/$id"
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/wt" "kind=ship" "mode=no-mistakes" "worktree_git_ref=refs/heads/fm/$id"
  printf '%s\n' "$dir"
}

make_retry_fake() {  # <case-dir>
  local dir=$1
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_CALLS"
if [ "${1:-}" = axi ] && [ "$#" -eq 1 ]; then
  printf 'daemon: %s\n' "${FM_FAKE_DAEMON_STATE:-running}"
  exit 0
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = run ]; then
  count=$(awk 'END { print NR + 0 }' "$FM_FAKE_RUN_CALLS" 2>/dev/null || printf 0)
  printf 'run\n' >> "$FM_FAKE_RUN_CALLS"
  if [ "$count" -lt "${FM_FAKE_TIMEOUTS:-1}" ]; then
    printf '%s\n' 'error: "drive run: reconcile run 01TEST: read response: read unix ->/tmp/home/.no-mistakes/socket: i/o timeout"' >&2
    exit 1
  fi
  printf '%s\n' 'outcome: checks-passed' 'pr: "https://github.com/o/r/pull/7"'
  exit 0
fi
printf '%s\n' 'error: unexpected invocation'
exit 2
SH
  chmod +x "$dir/fakebin/no-mistakes"
}

run_reattach() {  # <case-dir> <id>
  FM_HOME="$1/home" PATH="$1/fakebin:$PATH" \
    FM_NM_REATTACH_BACKOFF_BASE=0 FM_NM_REATTACH_BACKOFF_CAP=0 \
    FM_NM_REATTACH_MAX_ATTEMPTS="${FM_FAKE_MAX_ATTEMPTS:-4}" \
    FM_FAKE_CALLS="$1/calls" FM_FAKE_RUN_CALLS="$1/run-calls" \
    FM_FAKE_TIMEOUTS="${FM_FAKE_TIMEOUTS:-1}" FM_FAKE_DAEMON_STATE="${FM_FAKE_DAEMON_STATE:-running}" \
    "$REATTACH" "$2"
}

test_transient_timeout_recovers() {
  local id=retry-a dir out run_calls
  dir=$(make_case retry "$id")
  make_retry_fake "$dir"
  : > "$dir/calls"
  : > "$dir/run-calls"
  out=$(FM_FAKE_TIMEOUTS=1 run_reattach "$dir" "$id") \
    || fail "reattach did not recover from an induced timeout"
  assert_contains "$out" "outcome: checks-passed" "recovered reattach returns the live outcome"
  run_calls=$(awk 'END { print NR + 0 }' "$dir/run-calls")
  [ "$run_calls" -eq 2 ] || fail "reattach used $run_calls run attempts, want 2"
  assert_not_contains "$(cat "$dir/calls")" "daemon restart" "helper issues no explicit daemon restart"
  assert_not_contains "$(cat "$dir/calls")" "daemon stop" "helper issues no explicit daemon stop"
  assert_contains "$out" "outcome: checks-passed" "test claims recovery, not lifecycle immunity"
  pass "an induced reconciliation timeout recovers on reattach"
}

test_recovery_is_not_tied_to_the_second_attempt() {
  local id=retry-late-a2 dir out run_calls
  dir=$(make_case retry-late "$id")
  make_retry_fake "$dir"
  : > "$dir/calls"
  : > "$dir/run-calls"
  out=$(FM_FAKE_TIMEOUTS=3 run_reattach "$dir" "$id") \
    || fail "reattach did not recover on a later retry"
  assert_contains "$out" "outcome: checks-passed" "later recovery returns the live outcome"
  run_calls=$(awk 'END { print NR + 0 }' "$dir/run-calls")
  [ "$run_calls" -eq 4 ] || fail "later recovery used $run_calls run attempts, want 4"
  pass "reattach recovery is independent of which retry succeeds"
}

test_non_transient_error_does_not_retry() {
  local id=fatal-b dir out rc
  dir=$(make_case non-transient "$id")
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = axi ] && [ "$#" -eq 1 ]; then printf 'daemon: running\n'; exit 0; fi
printf '%s\n' 'error: "run head no longer matches the current branch"'
exit 1
SH
  chmod +x "$dir/fakebin/no-mistakes"
  : > "$dir/calls"
  : > "$dir/run-calls"
  out=$(run_reattach "$dir" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "non-transient error exit"
  assert_contains "$out" "run head no longer matches" "non-transient error is preserved"
  pass "a non-transient reattach error is not retried"
}

test_stopped_daemon_is_not_started() {
  local id=stopped-c dir out rc
  dir=$(make_case stopped "$id")
  make_retry_fake "$dir"
  : > "$dir/calls"
  : > "$dir/run-calls"
  out=$(FM_FAKE_DAEMON_STATE=stopped FM_FAKE_MAX_ATTEMPTS=2 run_reattach "$dir" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "stopped daemon refusal exit"
  assert_contains "$out" "refusing to start or restart" "stopped daemon refusal is explicit"
  [ ! -s "$dir/run-calls" ] || fail "stopped daemon path invoked axi run"
  assert_not_contains "$(cat "$dir/calls")" "daemon start" "stopped preflight issues no daemon start"
  pass "the local remedy refuses to start a stopped shared daemon"
}

test_home_and_branch_scope_are_enforced() {
  local id=scope-d dir out rc
  dir=$(make_case scope "$id")
  make_retry_fake "$dir"
  : > "$dir/calls"
  : > "$dir/run-calls"
  git -C "$dir/wt" checkout -q -b fm/another-task
  out=$(run_reattach "$dir" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "branch scope refusal exit"
  assert_contains "$out" "branch identity" "branch scope refusal names identity"
  [ ! -s "$dir/calls" ] || fail "scope refusal contacted no-mistakes"
  pass "the remedy is confined to the task recorded in this home"
}

test_transient_timeout_recovers
test_recovery_is_not_tied_to_the_second_attempt
test_non_transient_error_does_not_retry
test_stopped_daemon_is_not_started
test_home_and_branch_scope_are_enforced

echo "all fm-no-mistakes-reattach tests passed"
