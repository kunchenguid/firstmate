#!/usr/bin/env bash
# Tests for fm-worker-stall-check.sh: wakes firstmate only when a worktree's
# HEAD has stayed frozen past the threshold with a staged, uncommitted merge
# still pending.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-worker-stall-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-stall-check)

new_case() {  # <name> -> prints case dir with state/ and a one-commit worktree
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  fm_git_init_commit "$dir/wt"
  printf '%s\n' "$dir"
}

run_check() {  # <state-dir> <task> <worktree>
  FM_STATE_OVERRIDE="$1" "$CHECK" "$2" "$3"
}

assert_silent() {  # <output> <pass-message>
  if [ -z "$1" ]; then
    pass "$2"
  else
    fail "expected silence, got: $1"
  fi
}

test_missing_args_silent() {
  out=$("$CHECK" 2>&1) || true
  assert_silent "$out" "no args prints nothing"
}

test_non_worktree_silent() {
  local dir
  dir=$(new_case notgit)
  out=$(run_check "$dir/state" task1 "$TMP_ROOT/does-not-exist" 2>&1) || true
  assert_silent "$out" "a non-worktree path prints nothing"
}

test_fresh_head_silent_and_records_marker() {
  local dir
  dir=$(new_case fresh)
  out=$(run_check "$dir/state" task2 "$dir/wt" 2>&1)
  [ -z "$out" ] || fail "first sighting of a HEAD must be silent, got: $out"
  if [ -f "$dir/state/.worker-stall-task2" ]; then
    pass "fresh HEAD records a first-seen marker"
  else
    fail "expected a first-seen marker to be written"
  fi
}

# Regression for the age-never-advances bug: the FIRST sighting must persist
# an epoch alongside the sha, not just the sha. A marker holding only the sha
# makes every later poll's `${seen#* }` extraction fall through to "now",
# pinning the computed age at zero forever regardless of real elapsed time.
test_fresh_marker_persists_epoch() {
  local dir marker fields
  dir=$(new_case epoch)
  run_check "$dir/state" task6 "$dir/wt" >/dev/null 2>&1
  marker=$(cat "$dir/state/.worker-stall-task6")
  fields=$(printf '%s' "$marker" | wc -w | tr -d ' ')
  case "$marker" in
    *' '[0-9]*)
      if [ "$fields" = 2 ]; then
        pass "first-sighting marker persists sha and a numeric epoch"
      else
        fail "expected exactly sha+epoch, got: $marker"
      fi
      ;;
    *) fail "first-sighting marker missing a numeric epoch field, got: $marker" ;;
  esac
}

test_frozen_under_threshold_silent() {
  local dir
  dir=$(new_case underthresh)
  run_check "$dir/state" task3 "$dir/wt" >/dev/null 2>&1
  head=$(git -C "$dir/wt" rev-parse --short HEAD)
  printf '%s %s\n' "$head" "$(date +%s)" > "$dir/state/.worker-stall-task3"
  printf 'two\n' > "$dir/wt/merge.txt"
  git -C "$dir/wt" add merge.txt
  out=$(FM_WORKER_STALL_MIN=30 run_check "$dir/state" task3 "$dir/wt" 2>&1)
  assert_silent "$out" "frozen HEAD under the stall threshold stays silent"
}

test_frozen_past_threshold_with_staged_reports() {
  local dir head
  dir=$(new_case pastthresh)
  run_check "$dir/state" task4 "$dir/wt" >/dev/null 2>&1
  head=$(git -C "$dir/wt" rev-parse --short HEAD)
  printf '%s %s\n' "$head" "$(( $(date +%s) - 3600 ))" > "$dir/state/.worker-stall-task4"
  printf 'two\n' > "$dir/wt/merge.txt"
  git -C "$dir/wt" add merge.txt
  out=$(FM_WORKER_STALL_MIN=30 run_check "$dir/state" task4 "$dir/wt" 2>&1)
  case "$out" in
    *"stalled: task4 HEAD frozen at $head"*"1 staged file"*)
      pass "frozen HEAD past threshold with staged files reports a stall" ;;
    *) fail "expected a stall report, got: $out" ;;
  esac
}

test_frozen_past_threshold_no_staged_silent() {
  local dir head
  dir=$(new_case cleanpast)
  run_check "$dir/state" task5 "$dir/wt" >/dev/null 2>&1
  head=$(git -C "$dir/wt" rev-parse --short HEAD)
  printf '%s %s\n' "$head" "$(( $(date +%s) - 3600 ))" > "$dir/state/.worker-stall-task5"
  out=$(FM_WORKER_STALL_MIN=30 run_check "$dir/state" task5 "$dir/wt" 2>&1)
  assert_silent "$out" "frozen HEAD with a clean index stays silent (no stuck merge)"
}

test_missing_args_silent
test_non_worktree_silent
test_fresh_head_silent_and_records_marker
test_fresh_marker_persists_epoch
test_frozen_under_threshold_silent
test_frozen_past_threshold_with_staged_reports
test_frozen_past_threshold_no_staged_silent
