#!/usr/bin/env bash
# Behavior tests for bin/fm-tmp-sweep.sh.
#
# The sweep retargets onto a fixture directory only when FM_TMP_SWEEP_TEST=1.
# Nothing here touches the host /tmp, and the injected cwd file stands in for
# lsof so the cases stay portable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-tmp-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-tmp-sweep)
SWEEP_ROOT=
CWD_FILE=

use_root() {
  local name=$1
  SWEEP_ROOT="$TMP_ROOT/$name"
  mkdir -p "$SWEEP_ROOT"
  CWD_FILE="$TMP_ROOT/$name.cwds"
  printf '/no/live/cwd\n' >"$CWD_FILE"
}

age_days() {
  local days=$1
  shift
  fm_touch_epoch $(( $(date +%s) - days * 86400 )) "$@"
}

run_sweep() {
  FM_TMP_SWEEP_TEST=1 \
    FM_TMP_SWEEP_ROOT="$SWEEP_ROOT" \
    FM_TMP_SWEEP_CWD_FILE="$CWD_FILE" \
    "$SWEEP" "$@"
}

test_help() {
  "$SWEEP" --help >/dev/null || fail "help exited non-zero"
  pass "help exits 0"
}

test_dry_run_keeps_aged_hhe() {
  local out
  use_root dry
  mkdir -p "$SWEEP_ROOT/hhe-aged"
  printf 'x\n' >"$SWEEP_ROOT/hhe-aged/f"
  age_days 4 "$SWEEP_ROOT/hhe-aged" "$SWEEP_ROOT/hhe-aged/f"
  out=$(run_sweep --dry-run) || fail "dry-run exited non-zero"
  [ -d "$SWEEP_ROOT/hhe-aged" ] || fail "dry-run removed the directory"
  printf '%s\n' "$out" | grep -F "would remove: $SWEEP_ROOT/hhe-aged" >/dev/null \
    || fail "dry-run did not name the aged directory"
  pass "dry-run names an aged hhe directory and leaves it in place"
}

test_apply_removes_aged_hhe_only() {
  local out state
  use_root apply
  state="$TMP_ROOT/apply-state"
  mkdir -p "$state" "$SWEEP_ROOT/hhe-old" "$SWEEP_ROOT/hhe-new" "$SWEEP_ROOT/fm-old" "$SWEEP_ROOT/keep-me"
  printf 'x\n' >"$SWEEP_ROOT/hhe-old/f"
  age_days 4 "$SWEEP_ROOT/hhe-old" "$SWEEP_ROOT/hhe-old/f" "$SWEEP_ROOT/fm-old" "$SWEEP_ROOT/keep-me"
  out=$(run_sweep --state "$state") || fail "apply exited non-zero"
  [ ! -e "$SWEEP_ROOT/hhe-old" ] || fail "aged hhe directory survived"
  [ -d "$SWEEP_ROOT/hhe-new" ] || fail "fresh hhe directory was removed"
  [ -d "$SWEEP_ROOT/fm-old" ] || fail "aged fm- directory was removed"
  [ -d "$SWEEP_ROOT/keep-me" ] || fail "unrelated directory was removed"
  printf '%s\n' "$out" | grep -F "removed: $SWEEP_ROOT/hhe-old" >/dev/null \
    || fail "apply did not report the removal"
  grep -F 'removed=1' "$state/.tmp-sweep-last" >/dev/null \
    || fail "last-result file did not record the removal"
  pass "apply removes aged hhe scratch and leaves fresh, fm-, and unrelated names"
}

test_fresh_child_keeps_old_directory() {
  use_root fresh-child
  mkdir -p "$SWEEP_ROOT/hhe-tree/sub"
  printf 'x\n' >"$SWEEP_ROOT/hhe-tree/sub/f"
  age_days 4 "$SWEEP_ROOT/hhe-tree" "$SWEEP_ROOT/hhe-tree/sub" "$SWEEP_ROOT/hhe-tree/sub/f"
  touch "$SWEEP_ROOT/hhe-tree/sub/f"
  run_sweep >/dev/null || fail "sweep exited non-zero"
  [ -f "$SWEEP_ROOT/hhe-tree/sub/f" ] || fail "a directory with a fresh file was removed"
  pass "a fresh file inside an old directory keeps the directory"
}

test_live_cwd_keeps_aged_directory() {
  local out
  use_root live
  mkdir -p "$SWEEP_ROOT/hhe-live/sub"
  printf 'x\n' >"$SWEEP_ROOT/hhe-live/sub/f"
  age_days 4 "$SWEEP_ROOT/hhe-live" "$SWEEP_ROOT/hhe-live/sub" "$SWEEP_ROOT/hhe-live/sub/f"
  printf '%s\n' "$SWEEP_ROOT/hhe-live/sub" >"$CWD_FILE"
  out=$(run_sweep) || fail "sweep exited non-zero"
  [ -d "$SWEEP_ROOT/hhe-live" ] || fail "a directory with a live cwd was removed"
  printf '%s\n' "$out" | grep -F "skip (live process rooted under it): $SWEEP_ROOT/hhe-live" >/dev/null \
    || fail "live cwd skip was not reported"
  pass "a live process working directory keeps the scratch and is reported"
}

test_symlink_is_kept() {
  use_root link
  mkdir -p "$SWEEP_ROOT/real-dir"
  printf 'x\n' >"$SWEEP_ROOT/real-dir/f"
  ln -s real-dir "$SWEEP_ROOT/hhe-link"
  run_sweep >/dev/null || fail "sweep exited non-zero"
  [ -L "$SWEEP_ROOT/hhe-link" ] || fail "symlink candidate was removed"
  [ -f "$SWEEP_ROOT/real-dir/f" ] || fail "symlink target was removed"
  pass "a symlink candidate and its target are both kept"
}

test_jest_rs_is_exact() {
  use_root jest
  mkdir -p "$SWEEP_ROOT/jest_rs" "$SWEEP_ROOT/jest_rs_extra"
  printf 'x\n' >"$SWEEP_ROOT/jest_rs/f"
  age_days 4 "$SWEEP_ROOT/jest_rs" "$SWEEP_ROOT/jest_rs/f" "$SWEEP_ROOT/jest_rs_extra"
  run_sweep >/dev/null || fail "sweep exited non-zero"
  [ ! -e "$SWEEP_ROOT/jest_rs" ] || fail "aged jest_rs survived"
  [ -d "$SWEEP_ROOT/jest_rs_extra" ] || fail "jest_rs_extra was removed"
  pass "jest_rs is an exact path, not a prefix"
}

test_claude_sessions() {
  use_root claude
  mkdir -p "$SWEEP_ROOT/claude-1000/proj/old-session" \
    "$SWEEP_ROOT/claude-1000/proj/new-session" \
    "$SWEEP_ROOT/claude-1000/only/s1" \
    "$SWEEP_ROOT/claude-1000/empty-old"
  printf 'a\n' >"$SWEEP_ROOT/claude-1000/proj/old-session/a"
  printf 'b\n' >"$SWEEP_ROOT/claude-1000/proj/new-session/b"
  printf 'c\n' >"$SWEEP_ROOT/claude-1000/only/s1/c"
  printf 'n\n' >"$SWEEP_ROOT/claude-1000/note.txt"
  age_days 4 \
    "$SWEEP_ROOT/claude-1000/proj/old-session" \
    "$SWEEP_ROOT/claude-1000/proj/old-session/a" \
    "$SWEEP_ROOT/claude-1000/only" \
    "$SWEEP_ROOT/claude-1000/only/s1" \
    "$SWEEP_ROOT/claude-1000/only/s1/c" \
    "$SWEEP_ROOT/claude-1000/empty-old" \
    "$SWEEP_ROOT/claude-1000/note.txt"
  run_sweep >/dev/null || fail "sweep exited non-zero"
  [ ! -e "$SWEEP_ROOT/claude-1000/proj/old-session" ] || fail "aged session survived"
  [ -d "$SWEEP_ROOT/claude-1000/proj/new-session" ] || fail "fresh session was removed"
  [ -d "$SWEEP_ROOT/claude-1000/proj" ] || fail "project with a fresh session was removed"
  [ ! -e "$SWEEP_ROOT/claude-1000/only" ] || fail "project whose sessions were all eligible survived"
  [ ! -e "$SWEEP_ROOT/claude-1000/empty-old" ] || fail "empty aged project directory survived"
  [ -f "$SWEEP_ROOT/claude-1000/note.txt" ] || fail "a file directly under claude-1000 was removed"
  pass "claude sweep removes aged sessions and empty projects, and keeps fresh sessions and top-level files"
}

test_task_removes_own_names_without_age() {
  use_root task
  mkdir -p "$SWEEP_ROOT/longtask1-scratch" "$SWEEP_ROOT/hhe-aged"
  printf 'x\n' >"$SWEEP_ROOT/longtask1-scratch/f"
  age_days 4 "$SWEEP_ROOT/hhe-aged"
  run_sweep --task longtask1 >/dev/null || fail "task sweep exited non-zero"
  [ ! -e "$SWEEP_ROOT/longtask1-scratch" ] || fail "fresh task scratch survived teardown sweep"
  [ -d "$SWEEP_ROOT/hhe-aged" ] || fail "task sweep removed an unrelated aged hhe name"
  pass "teardown sweep removes the task id's names immediately and leaves other names"
}

test_short_task_id_removes_nothing() {
  local err rc
  use_root short
  err="$TMP_ROOT/short.err"
  mkdir -p "$SWEEP_ROOT/abcdefg-scratch"
  rc=0
  run_sweep --task abcdefg >/dev/null 2>"$err" || rc=$?
  [ "$rc" -eq 0 ] || fail "short task id exited $rc"
  [ -d "$SWEEP_ROOT/abcdefg-scratch" ] || fail "short task id removed a prefixed directory"
  grep -F 'short task id' "$err" >/dev/null || fail "short task id was not reported"
  pass "a task id shorter than 8 characters removes nothing"
}

test_unsafe_task_id_removes_nothing() {
  local rc
  use_root unsafe
  mkdir -p "$SWEEP_ROOT/hhe-keep"
  age_days 4 "$SWEEP_ROOT/hhe-keep"
  rc=0
  run_sweep --task '../evil' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "unsafe task id exited $rc"
  [ -d "$SWEEP_ROOT/hhe-keep" ] || fail "unsafe task id removed a directory"
  pass "a task id that is not path-safe removes nothing"
}

test_other_live_task_keeps_its_prefix() {
  local state
  use_root owners
  state="$TMP_ROOT/owners-state"
  mkdir -p "$state" \
    "$SWEEP_ROOT/other-live-scratch" \
    "$SWEEP_ROOT/other-live-task-scratch"
  printf 'x\n' >"$state/other-live-task.meta"
  run_sweep --task other-live --state "$state" >/dev/null || fail "task sweep exited non-zero"
  [ ! -e "$SWEEP_ROOT/other-live-scratch" ] || fail "this task's own scratch survived"
  [ -d "$SWEEP_ROOT/other-live-task-scratch" ] || fail "another live task's prefix was removed"
  pass "teardown sweep keeps a name that belongs to another live task id"
}

test_daily_issue_token_protects_live_lane() {
  local state
  use_root issue
  state="$TMP_ROOT/issue-state"
  mkdir -p "$state" \
    "$SWEEP_ROOT/hhe1802-note" \
    "$SWEEP_ROOT/hhe1803-note" \
    "$SWEEP_ROOT/hhe18020-note"
  printf 'x\n' >"$state/hhe1802-some-task.meta"
  age_days 4 "$SWEEP_ROOT/hhe1802-note" "$SWEEP_ROOT/hhe1803-note" "$SWEEP_ROOT/hhe18020-note"
  run_sweep --state "$state" >/dev/null || fail "daily sweep exited non-zero"
  [ -e "$SWEEP_ROOT/hhe1802-note" ] || fail "live issue token did not protect its names"
  [ ! -e "$SWEEP_ROOT/hhe1803-note" ] || fail "a different issue survived"
  [ ! -e "$SWEEP_ROOT/hhe18020-note" ] || fail "a longer issue id was treated as the live token"
  pass "a live hhe issue token protects only names that belong to that issue"
}

test_if_due_runs_once_per_interval() {
  local state rc
  use_root due
  state="$TMP_ROOT/due-state"
  mkdir -p "$state" "$SWEEP_ROOT/hhe-a"
  age_days 4 "$SWEEP_ROOT/hhe-a"
  run_sweep --if-due --state "$state" >/dev/null || fail "first due sweep exited non-zero"
  [ ! -e "$SWEEP_ROOT/hhe-a" ] || fail "first due sweep left the aged directory"
  [ -f "$state/.tmp-sweep-stamp" ] || fail "due sweep did not write its stamp"
  mkdir -p "$SWEEP_ROOT/hhe-b"
  age_days 4 "$SWEEP_ROOT/hhe-b"
  rc=0
  run_sweep --if-due --state "$state" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "second due sweep exited $rc"
  [ -d "$SWEEP_ROOT/hhe-b" ] || fail "a sweep inside the interval removed a directory"
  age_days 2 "$state/.tmp-sweep-stamp"
  run_sweep --if-due --state "$state" >/dev/null || fail "sweep after the interval exited non-zero"
  [ ! -e "$SWEEP_ROOT/hhe-b" ] || fail "an aged stamp did not make the sweep run again"
  pass "--if-due removes once per interval and runs again after the stamp ages"
}

test_if_due_dry_run_does_not_stamp() {
  local state
  use_root due-dry
  state="$TMP_ROOT/due-dry-state"
  mkdir -p "$state" "$SWEEP_ROOT/hhe-dry"
  age_days 4 "$SWEEP_ROOT/hhe-dry"
  run_sweep --if-due --dry-run --state "$state" >/dev/null || fail "due dry-run exited non-zero"
  [ -d "$SWEEP_ROOT/hhe-dry" ] || fail "due dry-run removed the directory"
  [ ! -e "$state/.tmp-sweep-stamp" ] || fail "due dry-run wrote the stamp"
  pass "--if-due --dry-run removes nothing and does not write the stamp"
}

test_empty_cwd_scan_removes_nothing() {
  local rc
  use_root empty-cwd
  mkdir -p "$SWEEP_ROOT/hhe-keep"
  age_days 4 "$SWEEP_ROOT/hhe-keep"
  : >"$CWD_FILE"
  rc=0
  run_sweep >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "empty cwd scan exited $rc"
  [ -d "$SWEEP_ROOT/hhe-keep" ] || fail "empty cwd scan removed a directory"
  pass "an empty live-process scan removes nothing"
}

test_help
test_dry_run_keeps_aged_hhe
test_apply_removes_aged_hhe_only
test_fresh_child_keeps_old_directory
test_live_cwd_keeps_aged_directory
test_symlink_is_kept
test_jest_rs_is_exact
test_claude_sessions
test_task_removes_own_names_without_age
test_short_task_id_removes_nothing
test_unsafe_task_id_removes_nothing
test_other_live_task_keeps_its_prefix
test_daily_issue_token_protects_live_lane
test_if_due_runs_once_per_interval
test_if_due_dry_run_does_not_stamp
test_empty_cwd_scan_removes_nothing
