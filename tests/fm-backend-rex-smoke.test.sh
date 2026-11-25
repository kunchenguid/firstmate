#!/usr/bin/env bash
# tests/fm-backend-rex-smoke.test.sh - real Rex smoke test for the Rex
# session-provider adapter (bin/backends/rex.sh). Every other suite fakes the
# CLI; this one uses the private server provided by
# tests/rex-test-safety.sh. No harness is launched: only a plain shell runs
# in the test's blocks, so no update prompt or install can be triggered.
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
WORK=$REX_TEST_WORK
mkdir -p "$WORK/sub"
wait_for() { rex_test_wait_for "$@"; }

# --- the test's own session --------------------------------------------------

PAIR=$(rex_test_new_session smoke) || fail "could not create the test's own fm-test- session"
read -r SMOKE_SID MAIN_BLOCK <<<"$PAIR"
pass "real rex: created the test's own session $SMOKE_SID"

# --- placement: a Rex-hosted launcher gets focus-safe tabs in its own session

TRIPLE=$(TERM_PROGRAM=rex REX_SESSION="$SMOKE_SID" REX_BLOCK="$MAIN_BLOCK" fm_backend_rex_create_task fm-test-alpha "$WORK") \
  || fail "create_task from a Rex-hosted launcher failed"
read -r SID WID BID <<<"$TRIPLE"
[ "$SID" = "$SMOKE_SID" ] || fail "the task tab must open in the launcher's own session, got $SID"
fm_backend_rex_id_valid window "$WID" || fail "create_task returned no window id"
T=$(fm_backend_rex_target "$SID" "$BID")
VIEW=$(fm_backend_rex_session_view "$SMOKE_SID")
[ "$(printf '%s' "$VIEW" | jq '.windows | length')" = 2 ] || fail "the launcher session must now hold two tabs"
[ "$(printf '%s' "$VIEW" | jq -r '.active_window_id')" != "$WID" ] || fail "the new tab must not take focus"
SIZE=$(fm_backend_rex_block_call "$T" size)
[ "$(printf '%s' "$SIZE" | jq -r '"\(.columns)x\(.rows)"')" = 200x50 ] || fail "the task block must be resized to 200x50, got $SIZE"
SCOPED=$(fm_backend_rex_scoped_name fm-test-alpha)
[ "$(printf '%s' "$VIEW" | jq -r --arg b "$BID" '.windows[].layers[].blocks[] | select(.block_id == $b) | .label')" = "$SCOPED" ] \
  || fail "the task block must carry the home-scoped label $SCOPED"
TERM_PROGRAM=rex REX_SESSION="$SMOKE_SID" REX_BLOCK="$MAIN_BLOCK" fm_backend_rex_create_task fm-test-alpha "$WORK" >/dev/null 2>&1 \
  && fail "a duplicate task label in the session must be refused"
pass "real rex: a Rex-hosted launcher gets a focus-safe 200x50 tab in its own session; duplicates are refused"

# --- input, capture, viewport ------------------------------------------------

shell_ready() { [ "$(fm_backend_rex_agent_state "$T")" = dead ]; }
wait_for 50 shell_ready || fail "the task block's shell never reached a prompt"
fm_backend_rex_send_text_line "$T" "printf 'fm-smoke-%s\\n' ok" || fail "send_text_line failed"
smoke_echoed() { fm_backend_rex_capture "$T" 20 | grep -qx 'fm-smoke-ok'; }
wait_for 50 smoke_echoed || fail "send_text_line output never appeared in the capture"
ROWS=$(fm_backend_rex_rows "$T") || fail "could not read the block's rows"
VISIBLE=$(fm_backend_visible_capture rex "$T" && printf x) || fail "visible capture failed"
LINES=$(printf '%s' "${VISIBLE%x}" | awk 'END { print NR }')
[ "$LINES" = "$ROWS" ] || fail "the derived viewport must be exactly size.rows ($ROWS) lines, got $LINES"
printf '%s' "${VISIBLE%x}" | grep -qx 'fm-smoke-ok' || fail "the derived viewport must show the echoed line"
fm_backend_rex_send_literal "$T" '-n dashed' || fail "an option-shaped literal must send"
fm_backend_rex_send_key "$T" C-u || fail "send_key C-u failed"
for key in Tab Escape C-c Enter; do
  fm_backend_rex_send_key "$T" "$key" || fail "send_key $key failed"
done
pass "real rex: line submit, capture, and a derived viewport of exactly size.rows lines; literal and every mapped key send"

# --- process view: cwd through a nested subshell, agent state -----------------

wait_for 50 shell_ready || fail "the shell did not return to a prompt after the keys"
fm_backend_rex_send_text_line "$T" "cd '$WORK/sub' && exec /bin/sh" || fail "could not start the nested shell"
in_sub() { [ "$(fm_backend_rex_current_path "$T")" = "$WORK/sub" ]; }
wait_for 50 in_sub || fail "current_path must follow the nested shell's cwd, got '$(fm_backend_rex_current_path "$T")'"
fm_backend_rex_send_text_line "$T" "sleep 60" || fail "could not start sleep"
sleeping() { [ "$(fm_backend_rex_agent_state "$T")" = ambiguous ]; }
wait_for 50 sleeping || fail "a non-shell non-harness foreground must read ambiguous"
fm_backend_rex_send_key "$T" C-c || fail "C-c failed"
wait_for 50 shell_ready || fail "the shell must read dead again after C-c"
pass "real rex: current_path follows a nested shell; agent_state reads dead at a shell, ambiguous under another program"

# --- program status: trusted only while its owner is in the foreground chain -

fm_backend_rex_send_text_line "$T" "printf '\\033]7501;state=working:app=fm-test\\033\\\\'" || fail "could not emit OSC 7501"
reads_busy() { [ "$(fm_backend_rex_busy_state "$T")" = busy ]; }
wait_for 50 reads_busy || fail "a working record from the foreground shell must read busy"
fm_backend_rex_send_text_line "$T" "printf '\\033]7501;state=idle:app=fm-test\\033\\\\'" || fail "could not emit OSC 7501 idle"
reads_idle() { [ "$(fm_backend_rex_busy_state "$T")" = idle ]; }
wait_for 50 reads_idle || fail "an idle record from the foreground shell must read idle"
pass "real rex: OSC 7501 records from the foreground shell drive busy_state"

# --- cleanup and absence proof -----------------------------------------------

ENDPOINT=$(fm_backend_rex_server_endpoint) || fail "could not read the server endpoint"
fm_backend_rex_kill "$T" || fail "kill must close the block and prove it gone"
[ "$(fm_backend_rex_block_presence "$T")" = missing ] || fail "a killed block must read missing"
[ "$(fm_backend_rex_endpoint_absence_recheck "$T" "$ENDPOINT")" = missing ] || fail "the absence proof must read missing"
[ "$(fm_backend_rex_endpoint_absence_recheck "$T" unix:///not-this-server.sock)" = unproven ] \
  || fail "an absence claim against another server must be unproven"
[ "$(fm_backend_rex_session_view "$SMOKE_SID" | jq '.windows | length')" = 1 ] \
  || fail "kill must close only the task's tab"
pass "real rex: kill closes exactly the task tab and the recorded server proves it gone"

TRIPLE2=$(fm_backend_rex_create_task_in_session "$SMOKE_SID" fm-test-beta "$WORK") || fail "create_task_in_session failed"
read -r _ _ BID2 <<<"$TRIPLE2"
fm_backend_rex_kill "$(fm_backend_rex_target "$SMOKE_SID" "$BID2")" || fail "kill of the reclaimed tab failed"
fm_backend_rex_create_task_in_session "session:00000000-0000-7000-8000-000000000000" fm-test-gamma "$WORK" >/dev/null 2>&1
[ "$?" = 2 ] || fail "create_task_in_session on a session that does not exist must return 2"
pass "real rex: relaunch reclaim opens a tab in the exact session, and a gone session returns 2 creating nothing"

rex_test_assert_isolated

# --- server stop, passive recovery, and reclaim after session loss -------------
LIVE=$(fm_backend_rex_target "$SMOKE_SID" "$MAIN_BLOCK")
[ "$(fm_backend_rex_block_presence "$LIVE")" = present ] || fail "the launcher block must be present before the server stops"
rex_test_stop_server
: >"$WORK/calls"
[ "$(fm_backend_rex_agent_state "$LIVE")" = unreadable ] \
  || fail "a passive read after stopping the private server must be unreadable, not autostart it"
[ -s "$WORK/calls" ] || fail "the passive read made no rex call"
! grep -q '^default' "$WORK/calls" \
  || fail "every passive read must disable autostart itself, got:"$'\n'"$(cat "$WORK/calls")"
pass "real rex: passive reads disable autostart and do not start a stopped server"
rex_test_start_server || fail "the private Rex server did not recover after restart"
[ "$(fm_backend_rex_endpoint_absence_recheck "$LIVE" "$ENDPOINT")" = missing ] \
  || fail "a session lost at server stop must be proven missing after the private server recovers"
fm_backend_rex_create_task_in_session "$SMOKE_SID" fm-test-after-restart "$WORK" >/dev/null 2>&1
[ "$?" = 2 ] || fail "reclaim in a session lost at server stop must return 2"
pass "real rex: after server restart, the recorded session is gone and reclaim creates nothing"
