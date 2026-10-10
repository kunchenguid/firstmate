#!/usr/bin/env bash
# tests/fm-watch-misplaced-worker.test.sh - the watcher's report of a ship or
# scout agent running outside its recorded worktree (misplaced_worker_check in
# bin/fm-watch.sh). The watcher's source guard lets this file load its
# functions without the singleton lock or the blocking loop. The placement
# proof is overridden here; tests/fm-backend-herdr.test.sh and
# tests/fm-herdr-restore-misplaced-worker-e2e.test.sh own it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-watch-misplaced-worker)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# Production modules are independently linted canonical roots.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

WAKE_LOG="$TMP/wakes"
: > "$WAKE_LOG"
# The real wake exits the cycle; this one records the reason and returns 0.
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
# FM_TEST_PLACEMENT is "<rc> [directory]" for the next placement read.
# shellcheck disable=SC2329 # Runtime override called by the sourced watcher.
fm_backend_task_outside_worktree() {
  local rc=${FM_TEST_PLACEMENT%% *}
  [ "$rc" != 0 ] || printf '%s' "${FM_TEST_PLACEMENT#* }"
  return "$rc"
}

W=default:w1:p2
fm_write_meta "$STATE_DIR/t1.meta" "window=$W" "backend=herdr" "kind=ship" "worktree=/pool/wt"

check() {  # <placement> -> prints the check's return code
  local rc=0
  FM_TEST_PLACEMENT=$1
  misplaced_worker_check "$W" t1 || rc=$?
  printf '%s' "$rc"
}
wakes() { wc -l < "$WAKE_LOG" | tr -d '[:space:]'; }

[ "$(check '0 /main')" = 0 ] || fail "a misplaced worker should make the caller skip its other checks"
[ "$(wakes)" = 1 ] || fail "a misplaced worker should wake once, got $(wakes)"
grep -qF "worker agent runs in /main, outside its recorded worktree /pool/wt" "$WAKE_LOG" \
  || fail "the wake should name both directories: $(cat "$WAKE_LOG")"
[ "$(check '0 /main')" = 0 ] || fail "a still-misplaced worker should keep its other checks skipped"
[ "$(wakes)" = 1 ] || fail "the same directory must not wake again, got $(wakes)"
pass "a misplaced worker is surfaced once per directory"

[ "$(check 2)" = 1 ] || fail "an unreadable placement read should let the other checks run"
[ "$(check '0 /main')" = 0 ] || fail "the worker is still misplaced after the unreadable read"
[ "$(wakes)" = 1 ] || fail "an unreadable read must not clear the report, so no second wake; got $(wakes)"
pass "an unreadable placement read keeps the report and never wakes again"

[ "$(check 1)" = 1 ] || fail "a worker proven back in place should let the other checks run"
[ "$(check '0 /main')" = 0 ] || fail "a newly misplaced worker should skip its other checks"
[ "$(wakes)" = 2 ] || fail "a worker misplaced again after proven recovery should wake again, got $(wakes)"
[ "$(check '0 /other')" = 0 ] || fail "a worker in another directory is still misplaced"
[ "$(wakes)" = 3 ] || fail "a new directory should wake once more, got $(wakes)"
pass "positive evidence of recovery, or a new directory, re-arms the report"

echo "# fm-watch-misplaced-worker.test.sh: all assertions passed"
