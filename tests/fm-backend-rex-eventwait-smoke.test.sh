#!/usr/bin/env bash
# tests/fm-backend-rex-eventwait-smoke.test.sh - real Rex smoke test for the
# Rex push path (fm_backend_rex_wait_transition and its bounded Lua reader,
# bin/backends/rex-eventwait.lua). It drives a real OSC 7501 blocked edge in
# its own fm-test- session, measures how long the wait takes to return it, and
# asserts the watcher's handle_push_transition lands a stale wake carrying
# Rex's blocked kind and message in a scratch wake queue. It also covers the
# clean deadline, an endpoint-gone edge, and a reader that cannot start.
# Isolation is tests/rex-test-safety.sh's private server and state-changing
# call guard. Only a plain shell runs in the test's blocks.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  rex_test_cleanup
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

# shellcheck source=tests/rex-test-safety.sh
. "$ROOT/tests/rex-test-safety.sh"
trap rex_test_cleanup EXIT
rex_test_prepare || { rc=$?; [ "$rc" = 1 ] && exit 0; exit "$rc"; }

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

fm_backend_rex_events_capable x || fail "a reachable API revision 5 server must be events-capable"
pass "real rex: the push capability gate passes without starting a server"

PAIR=$(rex_test_new_session evwait) || fail "could not create the test's own fm-test- session"
read -r SID BID <<<"$PAIR"
S=${SID#session:}
T=$(fm_backend_rex_target "$SID" "$BID")
shell_ready() { [ "$(fm_backend_rex_agent_state "$T")" = dead ]; }
rex_test_wait_for 50 shell_ready || fail "the test block's shell never reached a prompt"

# osc7501: report a program status from the block's foreground shell, the
# Program Status Protocol shape a harness emits (msg is base64).
osc7501() {  # <state> [kind] [msg]
  local fields="state=$1:app=fm-test"
  [ -z "${2:-}" ] || fields="$fields:kind=$2"
  [ -z "${3:-}" ] || fields="$fields:msg=$(printf '%s' "$3" | base64 | tr -d '\n')"
  fm_backend_rex_send_text_line "$T" "printf '\\033]7501;$fields\\033\\\\'"
}

osc7501 working || fail "could not report a working baseline"
reads_busy() { [ "$(fm_backend_rex_busy_state "$T")" = busy ]; }
rex_test_wait_for 50 reads_busy || fail "the working baseline never registered"

# --- a driven blocked edge, measured -------------------------------------------

OUT="$REX_TEST_WORK/out"; RCF="$REX_TEST_WORK/rc"
( fm_backend_wait_transition rex "$S" 10 "$STATE" "$T" >"$OUT"; echo $? >"$RCF" ) &
WPID=$!
sleep 1.5   # the reader subscribes, then reconciles the working baseline
START=$(now_ms)
osc7501 blocked permission "Allow Bash: rm -rf build" || fail "could not drive the blocked edge"
wait "$WPID"
END=$(now_ms)
ELAPSED=$((END - START))
REC=$(cat "$OUT")
[ "$(cat "$RCF")" = 0 ] || fail "a driven blocked edge must return 0, got rc=$(cat "$RCF") rec=$REC"
[ "$(fm_transition_pane_id "$REC")" = "${BID#block:}" ] || fail "the record must name the driven block: $REC"
[ "$(fm_transition_to_status "$REC")" = blocked ] || fail "the record must be blocked: $REC"
[ "$(fm_transition_detail "$REC")" = "permission: Allow Bash: rm -rf build" ] || fail "the record must carry Rex's kind and message: $REC"
[ "$ELAPSED" -lt 3000 ] || fail "the blocked edge took ${ELAPSED}ms to return, beyond a 3s bound"
pass "real rex: a driven blocked edge returns its record, with Rex's kind and message, ${ELAPSED}ms after the report was sent"

export FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$ROOT"
cat >"$STATE/evwait.meta" <<EOF
window=$T
backend=rex
kind=ship
EOF
# shellcheck source=/dev/null
. "$ROOT/bin/fm-push-transition-lib.sh"
wake() { return 0; }
handle_push_transition rex "$S" "$REC"
grep -q "stale	$T	" "$STATE/.wake-queue" || fail "the wake queue must carry a stale record naming $T: $(cat "$STATE/.wake-queue")"
grep -q 'rex: agent blocked (permission: Allow Bash: rm -rf build)' "$STATE/.wake-queue" \
  || fail "the stale payload must name rex and carry the kind and message: $(cat "$STATE/.wake-queue")"
pass "real rex: the watcher fast path enqueues a stale wake carrying Rex's blocked kind and message"

# --- dedupe, clean deadline ------------------------------------------------------

START=$(now_ms)
fm_backend_wait_transition rex "$S" 2 "$STATE" "$T" >/dev/null
RC=$?
END=$(now_ms)
[ "$RC" = 1 ] || fail "a still-blocked block already escalated must give a clean deadline (1), got $RC"
[ $((END - START)) -ge 1500 ] || fail "the clean deadline returned after $((END - START))ms, before its 2s budget"
pass "real rex: an escalated block is not re-delivered and the reader runs its whole budget ($((END - START))ms for 2s)"

# --- an endpoint-gone edge ends the wait at once ---------------------------------

PAIR2=$(rex_test_new_session evgone) || fail "could not create a second fm-test- session"
read -r SID2 BID2 <<<"$PAIR2"
T2=$(fm_backend_rex_target "$SID2" "$BID2")
TRIPLE=$(fm_backend_rex_create_task_in_session "$SID2" fm-test-gone "$REX_TEST_WORK") || fail "could not open a second tab"
read -r _ _ BID3 <<<"$TRIPLE"
T3=$(fm_backend_rex_target "$SID2" "$BID3")
( fm_backend_wait_transition rex "${SID2#session:}" 10 "$STATE" "$T3" >/dev/null; echo $? >"$RCF" ) &
WPID=$!
sleep 1.5
START=$(now_ms)
fm_backend_rex_kill "$T3" || fail "could not close the watched tab"
wait "$WPID"
END=$(now_ms)
[ "$(cat "$RCF")" = 1 ] || fail "a closed watched block must end the wait with 1, got $(cat "$RCF")"
[ $((END - START)) -lt 3000 ] || fail "the gone edge took $((END - START))ms to end the wait"
pass "real rex: closing a watched block ends the wait $((END - START))ms later for an immediate poll"

# --- a reader that cannot start falls back --------------------------------------

fm_backend_rex_cli kill "$SID2" >/dev/null 2>&1 || fail "could not kill the second test session"
fm_backend_wait_transition rex "${SID2#session:}" 2 "$STATE" "$T2" >/dev/null
RC=$?
[ "$RC" = 2 ] || fail "a reader for a gone session must return 2 so the watcher polls, got $RC"
pass "real rex: a reader that cannot start returns 2 and the watcher falls back to polling"

rex_test_assert_isolated
