#!/usr/bin/env bash
# tests/fm-backend-rex-eventwait-smoke.test.sh - real Rex smoke test for the
# Rex push path (fm_backend_rex_wait_transition and its bounded Lua reader,
# bin/backends/rex-eventwait.lua). It drives a real OSC 7501 blocked edge in a
# task tab on a private lab server (bin/fm-rex-lab.sh, whose tripwire checks
# the live server is untouched), measures how long the wait takes to return
# it, and asserts the watcher's handle_push_transition lands a stale wake
# carrying Rex's blocked kind and message in a scratch wake queue. It also
# covers dedupe with a clean deadline, an endpoint-gone edge, and a reader
# that cannot start. Only a plain shell runs in the test's blocks.
# Runs by default where rex and jq are installed; FM_REX_SMOKE=0 disables it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_REX_SMOKE rex jq

unset TMUX HERDR_ENV REX_SESSION REX_BLOCK REX_SERVER REX_CLIENT FM_BACKEND_REX_SERVER \
  FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED 2>/dev/null || true

LAB_HELPER="$ROOT/bin/fm-rex-lab.sh"
LAB=$("$LAB_HELPER" name evwait)
TMP_ROOT=$(fm_test_tmproot fm-backend-rex-eventwait-smoke)

cleanup() {
  "$LAB_HELPER" teardown "$LAB" || printf 'not ok - the Rex lab teardown or its live-server tripwire failed\n' >&2
}
trap cleanup EXIT

"$LAB_HELPER" provision "$LAB" || fail "could not provision a private Rex lab server"
FM_REX_SERVER=$("$LAB_HELPER" server "$LAB")
export FM_REX_SERVER
export FM_HOME="$TMP_ROOT/home" STATE="$TMP_ROOT/home/state"
mkdir -p "$STATE" "$TMP_ROOT/work"
WORK=$(cd "$TMP_ROOT/work" && pwd -P)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source rex || fail "could not source the rex adapter"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
wait_for() { # <tries> <command...>
  local tries=$1 n=0
  shift
  while [ "$n" -lt "$tries" ]; do
    "$@" && return 0
    sleep 0.2
    n=$((n + 1))
  done
  return 1
}

fm_backend_rex_container_ensure || fail "container_ensure refused the lab server"
IDS=$(fm_backend_rex_create_task fm-evwait "$WORK") || fail "create_task failed"
read -r SID _ BID <<EOF
$IDS
EOF
T="$SID:$BID"
printf '%s\n' "window=$T" "backend=rex" "kind=ship" "rex_server=$FM_REX_SERVER" "rex_session_id=$SID" "rex_block_id=$BID" >"$STATE/evwait.meta"
unset FM_BACKEND_REX_SERVER

fm_backend_rex_events_capable "$SID" || fail "a reachable API revision 5 server must be events-capable"
pass "real rex: the push capability gate passes on the recorded server without starting one"

shell_ready() { [ "$(fm_backend_rex_agent_state "$T")" = dead ]; }
wait_for 50 shell_ready || fail "the task block's shell never reached a prompt"

# osc7501: report a program status from the block's foreground shell, the
# Program Status Protocol shape a harness emits (msg is base64).
osc7501() { # <state> [kind] [msg]
  local fields="state=$1:app=fm-test"
  [ -z "${2:-}" ] || fields="$fields:kind=$2"
  [ -z "${3:-}" ] || fields="$fields:msg=$(printf '%s' "$3" | base64 | tr -d '\n')"
  fm_backend_rex_send_text_line "$T" "printf '\\033]7501;$fields\\033\\\\'"
}

osc7501 working || fail "could not report a working baseline"
reads_busy() { [ "$(fm_backend_rex_busy_state "$T")" = busy ]; }
wait_for 50 reads_busy || fail "the working baseline never registered"

# --- a driven blocked edge, measured -------------------------------------------

OUT="$TMP_ROOT/out"
RCF="$TMP_ROOT/rc"
( fm_backend_wait_transition rex "$SID" 10 "$STATE" "$T" >"$OUT"; echo $? >"$RCF" ) &
WPID=$!
sleep 1.5 # the reader subscribes, then reconciles the working baseline
START=$(now_ms)
osc7501 blocked permission "Allow Bash: rm -rf build" || fail "could not drive the blocked edge"
wait "$WPID"
END=$(now_ms)
ELAPSED=$((END - START))
REC=$(cat "$OUT")
[ "$(cat "$RCF")" = 0 ] || fail "a driven blocked edge must return 0, got rc=$(cat "$RCF") rec=$REC"
[ "$(fm_transition_pane_id "$REC")" = "$BID" ] || fail "the record must name the driven block: $REC"
[ "$(fm_transition_to_status "$REC")" = blocked ] || fail "the record must be blocked: $REC"
[ "$(fm_transition_detail "$REC")" = "permission: Allow Bash: rm -rf build" ] || fail "the record must carry Rex's kind and message: $REC"
[ "$ELAPSED" -lt 3000 ] || fail "the blocked edge took ${ELAPSED}ms to return, beyond a 3s bound"
pass "real rex: a driven blocked edge returns its record, with Rex's kind and message, ${ELAPSED}ms after the report was sent"

(
  export FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-push-transition-lib.sh"
  wake() { return 0; }
  handle_push_transition rex "$SID" "$REC"
) || fail "handle_push_transition failed"
grep -q "stale	$T	" "$STATE/.wake-queue" || fail "the wake queue must carry a stale record naming $T: $(cat "$STATE/.wake-queue" 2>/dev/null)"
grep -q 'rex: agent blocked (permission: Allow Bash: rm -rf build)' "$STATE/.wake-queue" \
  || fail "the stale payload must name rex and carry the kind and message: $(cat "$STATE/.wake-queue")"
pass "real rex: the watcher fast path enqueues a stale wake carrying Rex's blocked kind and message"

# --- dedupe, clean deadline ------------------------------------------------------

START=$(now_ms)
fm_backend_wait_transition rex "$SID" 2 "$STATE" "$T" >/dev/null
RC=$?
END=$(now_ms)
[ "$RC" = 1 ] || fail "a still-blocked block already escalated must give a clean deadline (1), got $RC"
[ $((END - START)) -ge 1500 ] || fail "the clean deadline returned after $((END - START))ms, before its 2s budget"
pass "real rex: an escalated block is not re-delivered and the reader runs its whole budget ($((END - START))ms for 2s)"

# --- an endpoint-gone edge ends the wait at once ---------------------------------

FM_BACKEND_REX_SERVER=$FM_REX_SERVER
IDS=$(fm_backend_rex_create_task fm-evgone "$WORK") || fail "could not open a second tab"
read -r _ _ BID2 <<EOF
$IDS
EOF
unset FM_BACKEND_REX_SERVER
T2="$SID:$BID2"
( fm_backend_wait_transition rex "$SID" 10 "$STATE" "$T2" >/dev/null; echo $? >"$RCF" ) &
WPID=$!
sleep 1.5
START=$(now_ms)
fm_backend_rex_kill "$T2" "" fm-evgone || fail "could not close the watched tab"
wait "$WPID"
END=$(now_ms)
[ "$(cat "$RCF")" = 1 ] || fail "a closed watched block must end the wait with 1, got $(cat "$RCF")"
[ $((END - START)) -lt 3000 ] || fail "the gone edge took $((END - START))ms to end the wait"
pass "real rex: closing a watched block ends the wait $((END - START))ms later for an immediate poll"

# --- a reader that cannot start falls back --------------------------------------

GONE_SID=00000000-0000-7000-8000-000000000000
fm_backend_wait_transition rex "$GONE_SID" 2 "$STATE" "$GONE_SID:$BID" >/dev/null
RC=$?
[ "$RC" = 2 ] || fail "a reader for a gone session must return 2 so the watcher polls, got $RC"
pass "real rex: a reader that cannot start returns 2 and the watcher falls back to polling"

fm_backend_rex_kill "$T" "" fm-evwait || fail "could not close the task tab"
