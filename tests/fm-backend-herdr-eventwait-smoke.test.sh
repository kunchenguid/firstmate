#!/usr/bin/env bash
# tests/fm-backend-herdr-eventwait-smoke.test.sh - REAL-herdr smoke test for the
# native pane.agent_status_changed push escalation (fm_backend_herdr_wait_transition,
# bin/backends/herdr.sh, and its raw-socket reader bin/backends/herdr-eventwait.py).
# It drives a real idle->blocked transition in an ISOLATED, never-default herdr
# lab session and asserts the subscriber returns that transition sub-second and
# that the watcher's handle_push_transition lands a stale record in a scratch
# state/.wake-queue. Skips cleanly when herdr, jq, or python3 is missing.
#
# Safety (2026-07-02 incident, tests/herdr-test-safety.sh): cleanup uses ONLY
# herdr_safe_stop_and_delete on a private fm-lab-* session, never a bare/ambient
# `herdr server stop`. Every lifecycle op goes through bin/fm-herdr-lab.sh, which
# refuses the default session and verifies the fleet-state tripwire.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the event subscriber)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

SESSION="fm-lab-eventwait-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab session"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)

# --- real capability gate ----------------------------------------------------

if ! fm_backend_herdr_events_capable "$SESSION"; then
  echo "skip: this herdr build is below the events.subscribe capability (protocol < 16 or events surface absent)"
  cleanup_all
  trap - EXIT
  exit 0
fi
pass "real herdr ($HERDR_VERSION): events.subscribe capability gate passes (protocol >= 16, events surface present in api schema)"

# --- container + a real task pane in the isolated session --------------------

CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-evwait1" /tmp "$SEEDED_TAB_ID") || fail "create_task failed"
read -r _TAB_ID PANE_ID <<EOF
$IDS
EOF
[ -n "$PANE_ID" ] || fail "create_task did not return a pane id"
TARGET="$SESSION:$PANE_ID"

# scratch firstmate state so window_to_task and the wake queue resolve
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-evwait.XXXXXX")
STATE="$SCRATCH/state"; mkdir -p "$STATE"
cat > "$STATE/evwait1.meta" <<EOF
window=$TARGET
backend=herdr
kind=ship
EOF

SOCK=$(fm_backend_herdr_socket_path "$SESSION")
[ -n "$SOCK" ] || fail "could not resolve the isolated session's socket path"

# --- register the pane's agent idle, then drive idle->blocked ----------------
# report-agent is herdr's documented primitive for a non-built-in process to
# report its own agent state (docs/herdr-backend.md); routed through the lab
# helper's guarded `run` so it carries the trailing --session.
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state idle >/dev/null 2>&1 \
  || fail "could not register the pane's agent as idle"

OUT="$SCRATCH/out"; RCF="$SCRATCH/rc"
: > "$OUT"; : > "$RCF"
# Bounded subscriber wait in the background; it must sit past the idle reconcile
# and return only when the pane transitions to blocked.
( fm_backend_herdr_wait_transition "$SESSION" 8 "$STATE" "$TARGET" > "$OUT"; echo $? > "$RCF" ) &
WPID=$!
sleep 0.5   # let it connect, subscribe, and reconcile the idle baseline

START=$(python3 -c 'import time; print(time.time())')
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state blocked >/dev/null 2>&1 \
  || fail "could not drive the pane's agent to blocked"
wait "$WPID"
END=$(python3 -c 'import time; print(time.time())')

RC=$(cat "$RCF" 2>/dev/null || echo "")
REC=$(cat "$OUT" 2>/dev/null || echo "")
ELAPSED=$(python3 -c "print(f'{($END)-($START):.3f}')" 2>/dev/null || echo "?")

[ "$RC" = 0 ] || fail "wait_transition should return 0 on a real idle->blocked transition, got rc='$RC' rec='$REC'"
REC_PANE=$(fm_transition_pane_id "$REC")
REC_TO=$(fm_transition_to_status "$REC")
[ "$REC_PANE" = "$PANE_ID" ] || fail "the returned record's pane_id ('$REC_PANE') must match the driven pane ('$PANE_ID')"
[ "$REC_TO" = "blocked" ] || fail "the returned record's to_status must be 'blocked', got '$REC_TO'"
# Sub-second: comfortably under the ~240s stale-pane wedge timer this replaces.
UNDER_ONE=$(python3 -c "print('yes' if (($END)-($START)) < 1.0 else 'no')" 2>/dev/null || echo "no")
[ "$UNDER_ONE" = yes ] || echo "note: idle->blocked wake took ${ELAPSED}s (>1s; still far under the 240s wedge timer, not fatal)" >&2
pass "real herdr ($HERDR_VERSION): a driven idle->blocked transition returns the blocked record in ${ELAPSED}s (pane $PANE_ID)"

# --- the watcher's fast-path lands a stale record in the scratch wake queue ---
# Source the watcher (its guard returns before the lock/loop) and override wake so
# handle_push_transition enqueues without exiting the test.
export FM_STATE_OVERRIDE="$STATE"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"
wake() { return 0; }
handle_push_transition herdr "$SESSION" "$REC"
[ -e "$STATE/.wake-queue" ] || fail "handle_push_transition did not create the wake queue"
grep -q 'stale' "$STATE/.wake-queue" || fail "the wake queue must carry a stale record: $(cat "$STATE/.wake-queue")"
grep -q "$TARGET" "$STATE/.wake-queue" || fail "the stale record must name the task window $TARGET"
grep -q 'herdr: agent blocked' "$STATE/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
pass "real herdr: the watcher fast-path enqueues a stale wake naming the task window from the live blocked transition"

cleanup_all
trap - EXIT
