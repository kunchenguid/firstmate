#!/usr/bin/env bash
# tests/fm-afk-reap-wake-e2e.test.sh - isolated native away-mode delivery test.
#
# A Claude-native away daemon is itself the harness-tracked background task.
# Routine watcher wakes must keep that task parked, while a captain-relevant
# wake must complete it with an afk-reap-wake reason after the watcher has
# durably queued the event.
#
# The test deliberately supplies an unsupported supervisor backend, a missing
# target, and a busy-everywhere regex.
# The old injection delivery would defer before or at its busy/composer guards.
# Native reap-wake delivery must never inspect those inputs and must still
# complete reliably.
#
# Isolation: every state artifact lives under a disposable directory inside
# this worktree.
set -u
export FM_GATE_REFUSE_BYPASS=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START="$ROOT/bin/fm-afk-start.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"

STATE_DIR=
DAEMON_PID=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  if [ -n "${DAEMON_PID:-}" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  [ -z "${STATE_DIR:-}" ] || rm -rf "$STATE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

STATE_DIR=$(mktemp -d "$ROOT/.afk-reap-wake-e2e.XXXXXX")
: > "$STATE_DIR/.afk"
printf 'none\t-\tnative\n' > "$STATE_DIR/.afk-daemon-terminal"

FM_STATE_OVERRIDE="$STATE_DIR" \
FM_AFK_STATE_PREPARED=1 \
FM_AFK_DELIVERY=reap-wake \
FM_ESCALATE_BATCH_SECS=0 \
FM_HOUSEKEEPING_TICK=1 \
FM_POLL=1 \
FM_SIGNAL_GRACE=1 \
FM_HEARTBEAT=999999 \
FM_CHECK_INTERVAL=999999 \
FM_BUSY_REGEX='.' \
FM_SUPERVISOR_BACKEND=unsupported \
FM_SUPERVISOR_TARGET=missing-pane \
"$START" > "$STATE_DIR/daemon.out" 2> "$STATE_DIR/daemon.err" &
DAEMON_PID=$!

start_deadline=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$start_deadline" ]; do
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
  sleep 0.2
done
[ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
  sed 's/^/  /' "$STATE_DIR/daemon.err" >&2
  fail "native away daemon did not start"
}

printf 'working: routine progress\n' > "$STATE_DIR/crew.status"
sleep 4
kill -0 "$DAEMON_PID" 2>/dev/null \
  || fail "routine wake completed the tracked task and spent an LLM turn"
if grep -F 'afk-reap-wake:' "$STATE_DIR/daemon.out" >/dev/null 2>&1; then
  fail "routine wake emitted a native completion reason"
fi
pass "routine wake stays in bash and keeps the native task parked"

printf 'needs-decision: choose the safe rollout\n' > "$STATE_DIR/crew.status"
completion_deadline=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$completion_deadline" ]; do
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$DAEMON_PID" 2>/dev/null; then
  sed 's/^/  /' "$STATE_DIR/daemon.err" >&2
  fail "captain-relevant wake did not complete the native tracked task"
fi
if ! wait "$DAEMON_PID"; then
  DAEMON_PID=
  fail "native tracked task exited non-zero"
fi
DAEMON_PID=

grep -F 'afk-reap-wake: Supervisor escalate (1 event(s)):' "$STATE_DIR/daemon.out" >/dev/null \
  || fail "native completion reason did not carry the batched escalation"
grep -F 'needs-decision: choose the safe rollout' "$STATE_DIR/daemon.out" >/dev/null \
  || fail "native completion reason omitted the captain-relevant status"
grep -F 'signal' "$STATE_DIR/.wake-queue" >/dev/null \
  || fail "durable wake queue did not retain the escalation before completion"
[ ! -s "$STATE_DIR/.subsuper-escalations" ] \
  || fail "delivered escalation remained buffered"
[ ! -e "$STATE_DIR/.subsuper-inject-wedged" ] \
  || fail "reap-wake delivery created an injection wedge marker"
[ ! -e "$STATE_DIR/.supervise-daemon.lock" ] \
  || fail "completed daemon retained its singleton lock"
[ ! -e "$STATE_DIR/.afk-native-process" ] \
  || fail "completed native task retained its process marker"
[ -e "$STATE_DIR/.afk" ] \
  || fail "native task completion incorrectly ended away mode"
pass "captain-relevant wake completes natively despite old pane-guard false-defer inputs"

FM_HOME="$ROOT" FM_STATE_OVERRIDE="$STATE_DIR" "$LAUNCH" start-native >/dev/null 2>&1 \
  || fail "away lifecycle could not prepare the next native tracked task"
[ "$(cat "$STATE_DIR/.afk-daemon-terminal" 2>/dev/null)" = $'none\t-\tnative' ] \
  || fail "away lifecycle did not restore the native launch record"
pass "completed native task can be re-armed without leaving away mode"

echo "all native afk reap-wake tests passed"
