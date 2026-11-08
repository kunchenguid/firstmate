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

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

SESSION="fm-lab-eventwait-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab session"

# The dispatcher is a separately linted production boundary. Its dynamic
# adapter source edges stop at each independently linted canonical adapter.
# shellcheck source=/dev/null
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
# Load the narrow production owner only after pointing it at scratch state, then
# override wake so the handler enqueues without exiting the test.
export FM_STATE_OVERRIDE="$STATE"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-push-transition-lib.sh"
wake() { return 0; }
handle_push_transition herdr "$SESSION" "$REC"
[ -e "$STATE/.wake-queue" ] || fail "handle_push_transition did not create the wake queue"
grep -q 'stale' "$STATE/.wake-queue" || fail "the wake queue must carry a stale record: $(cat "$STATE/.wake-queue")"
grep -q "$TARGET" "$STATE/.wake-queue" || fail "the stale record must name the task window $TARGET"
grep -q 'herdr: agent blocked' "$STATE/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
pass "real herdr: the watcher fast-path enqueues a stale wake naming the task window from the live blocked transition"

# --- a gone pane does not take the live panes off the push path -------------
# Real herdr rejects the WHOLE events.subscribe with pane_not_found when one
# subscribed pane no longer exists, so a stale task record used to turn every
# live pane's push wake off. One gone pane plus one pane driven to blocked must
# still return the blocked record, and the cause must be named.
IDS2=$(fm_backend_herdr_create_task "$CONTAINER" "fm-evwait2" /tmp "") || fail "create_task (gone pane) failed"
read -r _ GONE_PANE <<EOF
$IDS2
EOF
IDS3=$(fm_backend_herdr_create_task "$CONTAINER" "fm-evwait3" /tmp "") || fail "create_task (live pane) failed"
read -r _ LIVE_PANE <<EOF
$IDS3
EOF
[ -n "$GONE_PANE" ] && [ -n "$LIVE_PANE" ] || fail "create_task did not return pane ids for the gone/live panes"
for p in "$GONE_PANE" "$LIVE_PANE"; do
  fm_herdr_lab_cli "$SESSION" pane report-agent "$p" --source fm-evwait-test --agent claude --state idle >/dev/null 2>&1 \
    || fail "could not register pane $p's agent as idle"
done
fm_herdr_lab_cli "$SESSION" pane close "$GONE_PANE" >/dev/null 2>&1 || fail "could not close the pane that must read as gone"
[ "$(fm_backend_herdr_pane_presence_state "$SESSION" "$GONE_PANE")" = dead ] || fail "setup: the closed pane must read dead"

export FM_BACKEND_EVENTS_DIAG_FILE="$SCRATCH/diag"; : > "$FM_BACKEND_EVENTS_DIAG_FILE"
OUT2="$SCRATCH/out2"; RCF2="$SCRATCH/rc2"; : > "$OUT2"; : > "$RCF2"
( fm_backend_herdr_wait_transition "$SESSION" 8 "$STATE" "$SESSION:$GONE_PANE" "$SESSION:$LIVE_PANE" > "$OUT2"; echo $? > "$RCF2" ) &
WPID2=$!
sleep 1
fm_herdr_lab_cli "$SESSION" pane report-agent "$LIVE_PANE" --source fm-evwait-test --agent claude --state blocked >/dev/null 2>&1 \
  || fail "could not drive the live pane to blocked"
wait "$WPID2"
[ "$(cat "$RCF2")" = 0 ] || fail "one gone pane must not fail the subscription; expected rc 0, got '$(cat "$RCF2")' diag='$(cat "$FM_BACKEND_EVENTS_DIAG_FILE")'"
[ "$(fm_transition_pane_id "$(cat "$OUT2")")" = "$LIVE_PANE" ] || fail "the returned record must be the live pane's, got '$(cat "$OUT2")'"
case "$(cat "$FM_BACKEND_EVENTS_DIAG_FILE")" in
  *"$SESSION:$GONE_PANE"*pane_not_found*|*pane_not_found*"$SESSION:$GONE_PANE"*) : ;;
  *) fail "the cause line must name the gone pane and herdr's error, got '$(cat "$FM_BACKEND_EVENTS_DIAG_FILE")'" ;;
esac
pass "real herdr ($HERDR_VERSION): a gone pane is dropped and named, and the live pane's blocked edge still returns"

# --- Cursor's native blocked is not a wake -----------------------------------
# herdr reads a Cursor pane blocked in every state, so the push path must not
# escalate it (the poll loop stays the backstop for such a worker).
IDS4=$(fm_backend_herdr_create_task "$CONTAINER" "fm-evwait4" /tmp "") || fail "create_task (cursor pane) failed"
read -r _ CURSOR_PANE <<EOF
$IDS4
EOF
[ -n "$CURSOR_PANE" ] || fail "create_task did not return a cursor pane id"
if fm_herdr_lab_cli "$SESSION" pane report-agent "$CURSOR_PANE" --source fm-evwait-test --agent cursor --state blocked >/dev/null 2>&1; then
  : > "$FM_BACKEND_EVENTS_DIAG_FILE"
  CURSOR_OUT=$(fm_backend_herdr_wait_transition "$SESSION" 2 "$STATE" "$SESSION:$CURSOR_PANE"); CURSOR_RC=$?
  [ "$CURSOR_RC" = 1 ] || fail "a Cursor pane reading blocked must not escalate; expected a clean timeout (rc 1), got rc=$CURSOR_RC out='$CURSOR_OUT'"
  pass "real herdr ($HERDR_VERSION): a Cursor pane reading blocked raises no push wake"
else
  echo "skip: this herdr build does not accept a cursor agent report; the Cursor gate is covered by tests/fm-backend-herdr.test.sh"
fi

unset FM_BACKEND_EVENTS_DIAG_FILE
cleanup_all
trap - EXIT
