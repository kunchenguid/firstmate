#!/usr/bin/env bash
# tests/fm-afk-inject-rex-e2e.test.sh - token-free real-Rex guard for away mode
# when Firstmate runs in a Rex pane: supervisor discovery from inside a real
# Rex pane (ancestry proof), the away launcher's hidden daemon block
# (bin/fm-afk-launch.sh), and the daemon's composer-gated inject
# (bin/fm-supervise-daemon.sh inject_msg) into that pane. Everything runs on a
# private lab server provisioned through bin/fm-rex-lab.sh, whose tripwire
# proves the live Rex server was left untouched. The supervisor pane is a small
# deterministic loop drawing a bare `❯ <buf>` composer and logging every
# submitted line, the shape tests/fm-afk-inject-herdr-e2e.test.sh uses.
# Runs by default where rex and jq are installed; FM_REX_AFK_E2E=0 disables it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_REX_AFK_E2E rex jq

unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID REX_SESSION REX_BLOCK REX_SERVER REX_CLIENT FM_BACKEND_REX_SERVER \
  FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND 2>/dev/null || true

LAB_HELPER="$ROOT/bin/fm-rex-lab.sh"
LAB=$("$LAB_HELPER" name afk)
TMP_ROOT=$(fm_test_tmproot fm-afk-inject-rex-e2e)
REX_VERSION=$(rex version 2>/dev/null | head -1)
STATE_DIR="$TMP_ROOT/home/state"
LOG_FILE="$TMP_ROOT/submitted.log"
mkdir -p "$STATE_DIR"
: >"$LOG_FILE"

cleanup() {
  afk_exit "$STATE_DIR" 2>/dev/null || true
  "$LAB_HELPER" teardown "$LAB" || printf 'not ok - the Rex lab teardown or its live-server tripwire failed\n' >&2
}
trap cleanup EXIT

e2e_fail() { fail "$1 ($REX_VERSION)"; }

"$LAB_HELPER" provision "$LAB" || e2e_fail "could not provision a private Rex lab server"
FM_REX_SERVER=$("$LAB_HELPER" server "$LAB")
export FM_REX_SERVER FM_HOME="$TMP_ROOT/home" STATE="$STATE_DIR"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"
fm_backend_source rex || e2e_fail "could not source the rex adapter"

wait_for() { # <seconds*10> <command...>
  local n=$1 i
  shift
  for i in $(seq 1 "$n"); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

IDS=$(fm_backend_rex_create_task fm-afk-supervisor "$TMP_ROOT") || e2e_fail "could not open the supervisor tab"
read -r SID _WID BID <<EOF
$IDS
EOF
SUP="$SID:$BID"
shell_ready() { [ "$(fm_backend_rex_agent_state "$SUP")" = dead ]; }
wait_for 100 shell_ready || e2e_fail "the supervisor tab's shell never became ready"

# --- discovery from inside the real pane -------------------------------------
# Rex itself gives the pane REX_SESSION and REX_BLOCK; the lab server exports no
# REX_SERVER, so the probe names the lab server explicitly.
PROBE="$TMP_ROOT/discover.out"
fm_backend_rex_send_text_line "$SUP" "FM_REX_SERVER='$FM_REX_SERVER' FM_HOME='$FM_HOME' bash -c '. \"$ROOT/bin/fm-backend.sh\"; . \"$ROOT/bin/fm-supervisor-target-lib.sh\"; t=\$(discover_supervisor_target); b=\$(discover_supervisor_backend); printf \"%s %s\\n\" \"\$t\" \"\$b\" > \"$PROBE.tmp\"; mv \"$PROBE.tmp\" \"$PROBE\"'" fm-afk-supervisor \
  || e2e_fail "could not run the discovery probe in the supervisor pane"
probe_done() { [ -s "$PROBE" ]; }
wait_for 150 probe_done || e2e_fail "the discovery probe never reported"
[ "$(cat "$PROBE")" = "$SUP rex" ] || e2e_fail "discovery inside the Rex pane read '$(cat "$PROBE")', expected '$SUP rex'"
OUTSIDE=$(REX_SESSION="session:$SID" REX_BLOCK="block:$BID" discover_supervisor_backend)
[ "$OUTSIDE" = tmux ] || e2e_fail "this test process inherited the pane's REX_* without ancestry and still read '$OUTSIDE'"
pass "rex afk: discovery proves the Rex pane it runs in, and the same REX_* without ancestry falls back"

# --- the launcher's hidden daemon block ---------------------------------------
ENTRY="$TMP_ROOT/fake-entry.sh"
printf '#!/bin/sh\nexec sleep 300\n' >"$ENTRY"
chmod +x "$ENTRY"
OUT=$(
  FM_STATE_OVERRIDE=$STATE_DIR FM_AFK_LAUNCH_ENTRY=$ENTRY
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-afk-launch.sh"
  fm_afk_launch_create_rex "$SUP" rex 2>&1
) || e2e_fail "the launcher could not start a rex daemon block: $OUT"
IFS=$'\t' read -r REC_BACKEND DAEMON REC_SERVER <"$STATE_DIR/.afk-daemon-terminal" || e2e_fail "no daemon terminal record"
[ "$REC_BACKEND" = rex ] && [ "$REC_SERVER" = "$FM_REX_SERVER" ] || e2e_fail "the record should name rex and the lab server"
[ "${DAEMON%%:*}" = "$SID" ] || e2e_fail "the daemon block should live in the captain's session"
[ "$(fm_backend_rex_block_inspect "$DAEMON" | jq -r .block.placement)" = detached ] || e2e_fail "the daemon block must be detached (in no tab)"
[ "$(fm_backend_rex_cli session inspect "session:$SID" --json | jq '.windows | length')" = 1 ] || e2e_fail "the daemon launch changed the captain's tab strip"
# An interactive zsh hands the terminal's foreground back to its parent on
# `exec`, so the daemon can run outside the block's foreground group; look for
# it among every process on the block's tty instead.
daemon_running() {
  local pid tty
  pid=$(fm_backend_rex_block_call "$DAEMON" process | jq -r '.foreground.pid // empty')
  [ -n "$pid" ] || return 1
  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  [ -n "$tty" ] && ps -t "$tty" -o comm= 2>/dev/null | awk '$0 == "sleep" { found = 1 } END { exit !found }'
}
wait_for 100 daemon_running || e2e_fail "the daemon command never ran in the detached block's login shell: $(fm_backend_rex_cli capture -s "session:$SID" -b "block:${DAEMON#*:}" --trim 2>&1 | tail -5)"
OUT=$(
  FM_STATE_OVERRIDE=$STATE_DIR
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-afk-launch.sh"
  fm_afk_launch_record_read && fm_afk_launch_close_recorded && echo closed
)
[ "$OUT" = closed ] || e2e_fail "the recorded daemon block did not close by exact id"
fm_backend_rex_block_inspect "$DAEMON" >/dev/null
[ "$?" -eq 3 ] || e2e_fail "the closed daemon block does not answer exit 3"
pass "rex afk: the daemon runs in a recorded detached block of the captain's session and closes by exact id"

# --- composer-gated inject into the supervisor pane ----------------------------
LOOP="$TMP_ROOT/supervisor-loop.sh"
cat >"$LOOP" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
stty -echo -icanon min 1 time 0 2>/dev/null || true
_buf=
redraw() {
  local shown=$_buf
  [ "${#shown}" -le 40 ] || shown="...${shown: -37}"
  printf '\r\033[K\033[38;5;5m❯\033[0m %s' "$shown"
}
submit_line() {
  local c=user
  [ "${_buf:0:1}" != "$MARK" ] || c=injection
  printf '%s\t%s\n' "$c" "$_buf" >>"$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}
redraw
while IFS= read -r -n 1 _ch; do
  case "$_ch" in
    '' | $'\r' | $'\n') submit_line ;;
    $'\177' | $'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
fm_backend_rex_send_text_line "$SUP" "clear; bash '$LOOP' '$LOG_FILE'" fm-afk-supervisor || e2e_fail "could not start the supervisor loop"
composer_empty() { [ "$(fm_backend_composer_state rex "$SUP")" = empty ]; }
wait_for 100 composer_empty || e2e_fail "the supervisor loop's composer never read empty (read '$(fm_backend_composer_state rex "$SUP")')"

export FM_SUPERVISOR_BACKEND=rex FM_SUPERVISOR_TARGET=$SUP FM_DAEMON_PRIMARY_HARNESS=claude
afk_enter "$STATE_DIR"
inject_msg "rex-e2e escalation one" "$STATE_DIR" || e2e_fail "inject into an empty Rex composer failed: $INJECT_LAST_FAILURE"
# Claude strips invisible characters from a submitted prompt, so the daemon
# types the record-backed doorbell and the escalation body lives in the record
# the doorbell names (bin/fm-operational-input.sh).
injected() { grep -q 'Firstmate operational input waiting' "$LOG_FILE"; }
wait_for 50 injected || e2e_fail "the injected escalation never reached the supervisor pane; log: $(cat "$LOG_FILE")"
[ "$(grep -c . "$LOG_FILE")" = 1 ] || e2e_fail "exactly one line should have been submitted, got: $(cat "$LOG_FILE")"
RECORD=$(sed -n "s/.*read '\([^']*\)'.*/\1/p" "$LOG_FILE")
if [ ! -f "$RECORD" ] || ! grep -q 'rex-e2e escalation one' "$RECORD"; then
  e2e_fail "the doorbell's record '$RECORD' does not hold the escalation"
fi
pass "rex afk: an escalation is typed once and submitted into the Rex supervisor pane"

fm_backend_rex_send_literal "$SUP" "half typed by the captain" fm-afk-supervisor || e2e_fail "could not type into the composer"
pending() { [ "$(fm_backend_composer_state rex "$SUP")" = pending ]; }
wait_for 50 pending || e2e_fail "typed text never read pending (read '$(fm_backend_composer_state rex "$SUP")')"
if inject_msg "rex-e2e escalation two" "$STATE_DIR"; then
  e2e_fail "an inject over the captain's half-typed text must defer"
fi
assert_contains "$INJECT_LAST_FAILURE" "not confirmed-empty" "the deferral should name the composer gate"
sleep 0.5
[ "$(grep -c . "$LOG_FILE")" = 1 ] || e2e_fail "a deferred inject submitted something: $(cat "$LOG_FILE")"
pass "rex afk: the composer gate defers an inject over pending captain input"
