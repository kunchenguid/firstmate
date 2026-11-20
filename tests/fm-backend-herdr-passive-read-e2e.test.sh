#!/usr/bin/env bash
# tests/fm-backend-herdr-passive-read-e2e.test.sh - isolated real-herdr
# regression test: reading a task whose named Herdr session is stopped must
# leave that session stopped.
#
# An operator stops a named Herdr session while a task record still names it.
# Firstmate's own read-only reads of that task - the heartbeat's
# bin/fm-crew-state.sh, an operator's bin/fm-peek.sh, the watcher's stale-loop
# capture (watcher_capture is fm_backend_capture), and the native busy-state
# read - used to start the stopped server through fm_backend_herdr_target_ready,
# and Herdr then restored that session's whole saved layout. Only an operation
# that must reach the worker, such as sending a key, may start the session.
#
# Drives the real entry points against a real Herdr server in this test's own
# named lab session: the record names a real pane, the session is stopped
# through the guarded lab helper, every read runs, and the server must still
# report stopped afterwards; a final key send must start it again.
# Reads write to files rather than $(...): before the fix, a read that started
# a server left a waiting shell holding the reader's stdout until that server
# exited, which would hang the test instead of failing it.
#
# Safety (tests/herdr-test-safety.sh): every Herdr call targets this test's own
# isolated $SESSION through --session, the stop goes through fm_herdr_lab_stop,
# and cleanup uses only herdr_safe_stop_and_delete.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-passive-read-e2e-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
LAB_PREPARED=0
cleanup_all() {
  local status=$?
  trap - EXIT
  if [ "$LAB_PREPARED" = 1 ]; then
    herdr_safe_stop_and_delete "$SESSION" || {
      echo "not ok - could not tear down Herdr lab session: $SESSION" >&2
      status=1
    }
  fi
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
LAB_PREPARED=1

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-passive-read.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
WT="$SCRATCH/wt"
mkdir -p "$HOME_DIR/state" "$WT" "$SCRATCH/fakebin"
# crew-state looks up a validation run for the task's copy; this stub answers
# none so the read never reaches a real no-mistakes daemon.
printf '#!/bin/sh\nexit 1\n' > "$SCRATCH/fakebin/no-mistakes"
chmod +x "$SCRATCH/fakebin/no-mistakes"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }

RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${RAW%%$'\t'*}
SEEDED_TAB_ID=${RAW#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-pread "$WT" "$SEEDED_TAB_ID") || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
TARGET="$SESSION:$PANE_ID"
{
  echo "window=$TARGET"
  echo "endpoint_task_id=pread"
  echo "worktree=$WT"
  echo "harness=claude"
  echo "kind=ship"
  echo "backend=herdr"
} > "$HOME_DIR/state/pread.meta"

server_state() { fm_backend_herdr_server_running_state "$SESSION"; }
[ "$(server_state)" = running ] || fail "the lab session server should be running after task creation"

fm_herdr_lab_stop "$SESSION" >/dev/null 2>&1 || fail "could not stop the lab session through the guarded helper"
[ "$(server_state)" = stopped ] || fail "the lab session should report stopped after the guarded stop [herdr $HERDR_VERSION]"
pass "setup: a task record names a pane in a named Herdr session that is now stopped"

# --- the heartbeat's current-state read --------------------------------------
PATH="$SCRATCH/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_CREW_STATE_NO_FORGE=1 \
  "$ROOT/bin/fm-crew-state.sh" pread > "$SCRATCH/crew-state.out" 2>&1
[ "$(server_state)" = stopped ] \
  || fail "REGRESSION: fm-crew-state.sh restarted the stopped session it only read: $(cat "$SCRATCH/crew-state.out")"
grep -Fq "backend target gone: $TARGET" "$SCRATCH/crew-state.out" \
  || fail "fm-crew-state.sh should report the stopped session's endpoint as gone, got: $(cat "$SCRATCH/crew-state.out")"
pass "real herdr $HERDR_VERSION: fm-crew-state.sh reports the stopped session's task as gone and leaves the session stopped"

# --- the operator's peek -----------------------------------------------------
rc=0
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-peek.sh" pread 20 > "$SCRATCH/peek.out" 2>&1 || rc=$?
[ "$(server_state)" = stopped ] || fail "REGRESSION: fm-peek.sh restarted the stopped session it only read"
[ "$rc" -ne 0 ] || fail "fm-peek.sh should fail on a stopped session, got: $(cat "$SCRATCH/peek.out")"
pass "real herdr $HERDR_VERSION: fm-peek.sh fails on the stopped session and leaves it stopped"

# --- the watcher's stale-loop read and the native busy read ------------------
rc=0
fm_backend_capture herdr "$TARGET" 40 fm-pread > "$SCRATCH/capture.out" 2>&1 || rc=$?
[ "$(server_state)" = stopped ] || fail "REGRESSION: fm_backend_capture (the watcher's stale-loop read) restarted the stopped session"
[ "$rc" -ne 0 ] || fail "fm_backend_capture should fail on a stopped session"
fm_backend_busy_state herdr "$TARGET" > "$SCRATCH/busy.out" 2>&1
[ "$(server_state)" = stopped ] || fail "REGRESSION: fm_backend_busy_state restarted the stopped session"
[ "$(cat "$SCRATCH/busy.out")" = unknown ] || fail "a stopped session's busy state should read unknown, got: $(cat "$SCRATCH/busy.out")"
pass "real herdr $HERDR_VERSION: the watcher's capture and the native busy read leave the stopped session stopped"

# --- a send must still reach the worker --------------------------------------
fm_backend_send_key herdr "$TARGET" Enter fm-pread > "$SCRATCH/send.out" 2>&1 \
  || fail "a key send to the stopped session's task failed: $(cat "$SCRATCH/send.out")"
[ "$(server_state)" = running ] || fail "a key send must start the stopped session it has to reach [herdr $HERDR_VERSION]"
pass "real herdr $HERDR_VERSION: a key send still starts the stopped session to reach its worker"
