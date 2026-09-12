#!/usr/bin/env bash
# Open-blocked-key sweep: list every still-open blocked key, and close only
# keys whose task is provably terminal. Dry-run by default.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-blocker-sweep-tests)
SWEEP="$ROOT/bin/fm-blocker-sweep.sh"

run_sweep() {  # <case-dir> [args...]
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" "$SWEEP" "$@" 2>&1
}

seed_home() {  # <case-dir>
  mkdir -p "$1/home/state" "$1/home/data"
}

test_lists_live_blocked_key_and_does_not_write() {
  local dir out before
  dir="$TMP_ROOT/list-live"
  seed_home "$dir"
  printf 'window=synthetic:fm-live\nbackend=tmux\nkind=ship\n' > "$dir/home/state/live-task.meta"
  printf 'blocked [key=token]: waiting on a refresh\n' > "$dir/home/state/live-task.status"
  before=$(cat "$dir/home/state/live-task.status")
  out=$(run_sweep "$dir") || fail "list should succeed: $out"
  assert_contains "$out" 'open-blocked live-task [key=token]' "live blocked key was not listed"
  assert_contains "$out" 'state=live' "live task was not classified live"
  assert_contains "$out" 'home=primary' "primary home was not labeled"
  [ "$(cat "$dir/home/state/live-task.status")" = "$before" ] \
    || fail "dry-run wrote the status file"
  pass "dry-run lists a live blocked key and writes nothing"
}

test_lists_each_terminal_state_without_closing() {
  local dir out
  dir="$TMP_ROOT/list-states"
  seed_home "$dir"
  printf 'backend=tmux\nkind=ship\n' > "$dir/home/state/dead-task.meta"
  printf 'blocked [key=dead-key]: leftover\n' > "$dir/home/state/dead-task.status"
  printf 'window=synthetic:fm-done\nbackend=tmux\nkind=ship\n' > "$dir/home/state/done-task.meta"
  printf 'blocked [key=done-key]: leftover\ndone: finished the work\n' > "$dir/home/state/done-task.status"
  printf 'window=synthetic:fm-merged\nbackend=tmux\nkind=ship\npr=https://example.com/pull/1\n' > "$dir/home/state/merged-task.meta"
  printf 'blocked [key=merged-key]: leftover\ndone: PR merged\n' > "$dir/home/state/merged-task.status"
  printf 'window=synthetic:fm-failed\nbackend=tmux\nkind=ship\n' > "$dir/home/state/failed-task.meta"
  printf 'blocked [key=failed-key]: leftover\nfailed: the reproduction never compiled\n' > "$dir/home/state/failed-task.status"
  out=$(run_sweep "$dir") || fail "list should succeed: $out"
  assert_contains "$out" 'open-blocked dead-task [key=dead-key]' "dead-endpoint key was not listed"
  assert_contains "$out" 'dead-task [key=dead-key]' "dead-task row missing"
  printf '%s\n' "$out" | grep -F 'dead-task [key=dead-key]' | grep -q 'state=dead-endpoint' \
    || fail "dead task was not classified dead-endpoint: $out"
  printf '%s\n' "$out" | grep -F 'done-task [key=done-key]' | grep -q 'state=done' \
    || fail "done task was not classified done: $out"
  printf '%s\n' "$out" | grep -F 'merged-task [key=merged-key]' | grep -q 'state=pr-merged' \
    || fail "merged task was not classified pr-merged: $out"
  printf '%s\n' "$out" | grep -F 'failed-task [key=failed-key]' | grep -q 'state=failed' \
    || fail "failed task was not classified failed: $out"
  grep -q 'resolved' "$dir/home/state/"*.status && fail "dry-run appended a resolved line"
  pass "dry-run lists dead-endpoint, done, pr-merged, and failed without writing"
}

test_close_terminal_writes_only_terminal_keys() {
  local dir out
  dir="$TMP_ROOT/close-terminal"
  seed_home "$dir"
  printf 'window=synthetic:fm-live\nbackend=tmux\nkind=ship\n' > "$dir/home/state/live-task.meta"
  printf 'blocked [key=live-key]: still running\n' > "$dir/home/state/live-task.status"
  printf 'backend=tmux\nkind=ship\n' > "$dir/home/state/dead-task.meta"
  printf 'blocked [key=dead-key]: leftover\n' > "$dir/home/state/dead-task.status"
  printf 'window=synthetic:fm-done\nbackend=tmux\nkind=ship\n' > "$dir/home/state/done-task.meta"
  printf 'blocked [key=done-key]: leftover\ndone: finished the work\n' > "$dir/home/state/done-task.status"
  printf 'window=synthetic:fm-merged\nbackend=tmux\nkind=ship\npr=https://example.com/pull/1\n' > "$dir/home/state/merged-task.meta"
  printf 'blocked [key=merged-key]: leftover\ndone: PR merged\n' > "$dir/home/state/merged-task.status"
  printf 'window=synthetic:fm-unk\nbackend=tmux\nkind=ship\n' > "$dir/home/state/unk-task.meta"
  printf 'blocked [key=unk-key]: hidden\n' > "$dir/status-source"
  ln -s "$dir/status-source" "$dir/home/state/unk-task.status"
  out=$(run_sweep "$dir" --close-terminal) || fail "close-terminal should succeed: $out"
  assert_contains "$out" 'open-blocked live-task [key=live-key]' "live key disappeared from the listing"
  assert_not_contains "$out" 'closed live-task' "close-terminal wrote a live key"
  grep -q 'resolved \[key=live-key\]' "$dir/home/state/live-task.status" \
    && fail "close-terminal appended resolved to a live task"
  grep -q 'resolved \[key=dead-key\]' "$dir/home/state/dead-task.status" \
    || fail "close-terminal did not close a dead-endpoint key"
  grep -q 'resolved \[key=done-key\]' "$dir/home/state/done-task.status" \
    || fail "close-terminal did not close a done key"
  grep -q 'resolved \[key=merged-key\]' "$dir/home/state/merged-task.status" \
    || fail "close-terminal did not close a pr-merged key"
  assert_contains "$out" 'closed dead-task [key=dead-key]' "dead-endpoint close was not reported"
  assert_contains "$out" 'closed done-task [key=done-key]' "done close was not reported"
  assert_contains "$out" 'closed merged-task [key=merged-key]' "pr-merged close was not reported"
  grep -q 'resolved' "$dir/home/state/unk-task.status" 2>/dev/null \
    && fail "close-terminal followed a refused status symlink"
  assert_contains "$out" 'state=unknown' "an unreadable status was not listed unknown"
  pass "close-terminal appends resolved only for provably terminal keys"
}

test_missing_status_is_skipped() {
  local dir out
  dir="$TMP_ROOT/missing-status"
  seed_home "$dir"
  printf 'window=synthetic:fm-missing\nbackend=tmux\nkind=ship\n' > "$dir/home/state/missing-task.meta"
  out=$(run_sweep "$dir") || fail "missing status should not fail the sweep: $out"
  assert_not_contains "$out" 'missing-task' "a meta without status was listed"
  pass "a missing status file is skipped"
}

test_lists_live_blocked_key_and_does_not_write
test_lists_each_terminal_state_without_closing
test_close_terminal_writes_only_terminal_keys
test_missing_status_is_skipped
