#!/usr/bin/env bash
# Behavior tests for backend and status-log current-state reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)

new_case() {  # <name> <id> -> echoes the case directory
  local dir="$TMP_ROOT/$1" id=$2
  mkdir -p "$dir/state" "$dir/worktree" "$dir/fakebin"
  fm_write_meta "$dir/state/$id.meta" \
    "window=test-session:fm-$id" \
    "worktree=$dir/worktree" \
    "kind=ship" \
    "harness=claude"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    [ "${FM_TEST_PANE_MISSING:-0}" != 1 ] || exit 1
    printf '%%1\n'
    ;;
  list-windows)
    [ "${FM_TEST_PANE_MISSING:-0}" = 1 ] || printf 'fm-%s\n' "${FM_TEST_TASK_ID:-unknown}"
    exit 0
    ;;
  capture-pane)
    printf 'idle pane\n'
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

run_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" FM_TEST_TASK_ID="$2" "$CREW_STATE" "$2"
}

write_idle_record() {  # <case-dir> <id>
  local dir=$1 id=$2 generation
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/state" "$id") || fail "could not arm busy record"
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" "$id" idle --gen "$generation" \
    --source claude-hook --event stop || fail "could not write idle record"
}

write_busy_record() {  # <case-dir> <id>
  local dir=$1 id=$2 generation
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/state" "$id") || fail "could not arm busy record"
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" "$id" busy --gen "$generation" \
    --source claude-hook --event user-prompt-submit || fail "could not write busy record"
}

test_busy_record_is_current_work() {
  local dir out
  dir=$(new_case busy busy)
  write_busy_record "$dir" busy
  out=$(run_state "$dir" busy)
  assert_contains "$out" 'state: working' 'a current semantic busy record reports working'
  assert_contains "$out" 'source: pane' 'busy state identifies the pane source'
  assert_contains "$out" 'claude-hook' 'busy state identifies its trusted writer'
  pass 'semantic busy record reports current work'
}

test_idle_record_allows_status_log_fallback() {
  local dir out
  dir=$(new_case idle idle)
  write_idle_record "$dir" idle
  printf 'needs-decision: choose a storage backend\n' > "$dir/state/idle.status"
  out=$(run_state "$dir" idle)
  assert_contains "$out" 'state: parked' 'idle endpoint uses the status-log decision state'
  assert_contains "$out" 'source: status-log' 'idle endpoint identifies the status-log source'
  assert_contains "$out" 'choose a storage backend' 'status detail is preserved'
  pass 'idle endpoint reconciles the latest status event'
}

test_paused_status_is_distinct() {
  local dir out
  dir=$(new_case paused paused)
  write_idle_record "$dir" paused
  printf 'paused: waiting on an upstream release\n' > "$dir/state/paused.status"
  out=$(run_state "$dir" paused)
  assert_contains "$out" 'state: paused' 'a declared external wait remains distinct'
  assert_contains "$out" 'waiting on an upstream release' 'pause reason is preserved'
  pass 'paused status remains distinguishable from a wedge'
}

test_unrecognized_status_event_is_not_current_state() {
  local dir out
  dir=$(new_case resolved resolved)
  write_idle_record "$dir" resolved
  printf 'needs-decision [key=choice]: choose one\nresolved [key=choice]: chose one\n' > "$dir/state/resolved.status"
  out=$(run_state "$dir" resolved)
  assert_contains "$out" 'state: unknown' 'decision-closing event is not a state'
  assert_contains "$out" 'source: none' 'decision-closing event does not become a source'
  assert_not_contains "$out" 'chose one' 'resolution detail is not rendered as current state'
  pass 'decision-closing events do not replace current state'
}

test_missing_busy_record_does_not_infer_from_stale_log() {
  local dir out
  dir=$(new_case missing-busy missing)
  printf 'done: an old completion\n' > "$dir/state/missing.status"
  out=$(run_state "$dir" missing)
  assert_contains "$out" 'state: unknown' 'missing semantic state remains unknown'
  assert_not_contains "$out" 'state: done' 'stale status cannot override unknown endpoint state'
  pass 'missing semantic state does not trust a stale log'
}

test_missing_endpoint_does_not_trust_status_log() {
  local dir out
  dir=$(new_case gone gone)
  write_idle_record "$dir" gone
  printf 'done: old completion\n' > "$dir/state/gone.status"
  out=$(FM_TEST_PANE_MISSING=1 run_state "$dir" gone)
  assert_contains "$out" 'state: unknown' 'missing pane reports unknown'
  assert_contains "$out" 'backend target gone' 'positive absence is identified'
  assert_not_contains "$out" 'state: done' 'a stale status log is not used for a missing pane'
  pass 'missing endpoint cannot reuse a stale state event'
}

test_usage_error_is_distinct() {
  local out rc
  out=$("$CREW_STATE" 2>&1); rc=$?
  expect_code 2 "$rc" 'missing task id is a usage error'
  assert_contains "$out" 'usage: fm-crew-state.sh' 'usage diagnostic names the command'
  pass 'usage errors retain their explicit exit code'
}

test_busy_record_is_current_work
test_idle_record_allows_status_log_fallback
test_paused_status_is_distinct
test_unrecognized_status_event_is_not_current_state
test_missing_busy_record_does_not_infer_from_stale_log
test_missing_endpoint_does_not_trust_status_log
test_usage_error_is_distinct

echo 'all fm-crew-state tests passed'
