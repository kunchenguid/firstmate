#!/usr/bin/env bash
# Contract tests for bin/fm-crew-state.sh's direct backend/status reader.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-state)
CREW_STATE="$ROOT/bin/fm-crew-state.sh"

make_case() {
  local name=$1 dir state wt fb
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  wt="$dir/wt"
  fb="$dir/fakebin"
  mkdir -p "$state" "$wt" "$fb"
  git -C "$wt" init -q
  git -C "$wt" config user.email t@example.com
  git -C "$wt" config user.name T
  printf 'x\n' > "$wt/file"
  git -C "$wt" add file && git -C "$wt" commit -q -m init
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  display-message) exit 0 ;;
  capture-pane)
    case "${FM_FAKE_TMUX_CAPTURE:-}" in
      busy) printf 'Thinking... esc to interrupt\n' ;;
      idle|'') printf 'idle prompt\n' ;;
      *) printf '%s\n' "$FM_FAKE_TMUX_CAPTURE" ;;
    esac
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$dir"
}

write_meta() {
  local state=$1 id=$2 wt=$3 kind=${4:-ship}
  cat > "$state/$id.meta" <<EOF
window=test:fm-$id
worktree=$wt
project=$wt
harness=claude
kind=$kind
mode=direct-PR
yolo=off
EOF
}

run_state() {
  local dir=$1 id=$2 capture=${3:-idle}
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_TMUX_CAPTURE="$capture" \
    "$CREW_STATE" "$id"
}

test_busy_pane_reports_working() {
  local dir out
  dir=$(make_case busy)
  write_meta "$dir/state" busy "$dir/wt"
  out=$(run_state "$dir" busy busy)
  assert_contains "$out" "state: working" "busy pane did not report working"
  assert_contains "$out" "source: pane" "busy pane did not own working source"
  pass "crew-state reports busy pane as working"
}

test_status_log_reports_terminal_when_idle() {
  local dir out
  dir=$(make_case "done")
  write_meta "$dir/state" "done" "$dir/wt"
  printf 'done: PR https://example.test checks green\n' > "$dir/state/done.status"
  out=$(run_state "$dir" "done" idle)
  assert_contains "$out" "state: done" "idle done log did not report done"
  assert_contains "$out" "source: status-log" "done log did not own source"
  pass "crew-state falls back to mapped status log"
}

test_resolved_log_is_not_current_state() {
  local dir out
  dir=$(make_case resolved)
  write_meta "$dir/state" resolved "$dir/wt" secondmate
  printf 'resolved: blocker cleared\n' > "$dir/state/resolved.status"
  out=$(run_state "$dir" resolved idle)
  assert_contains "$out" "state: unknown" "resolved event became current state"
  assert_contains "$out" "source: none" "resolved event should not own source"
  pass "crew-state ignores decision-closing log events"
}

test_missing_backend_target_is_unknown() {
  local dir out
  dir=$(make_case gone)
  write_meta "$dir/state" gone "$dir/wt"
  rm -rf "$dir/wt"
  out=$(run_state "$dir" gone idle)
  assert_contains "$out" "state: unknown" "missing worktree did not report unknown"
  assert_contains "$out" "worktree gone" "missing worktree detail lost"
  pass "crew-state reports missing worktree as unknown"
}

test_busy_pane_reports_working
test_status_log_reports_terminal_when_idle
test_resolved_log_is_not_current_state
test_missing_backend_target_is_unknown
