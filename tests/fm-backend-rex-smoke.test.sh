#!/usr/bin/env bash
# tests/fm-backend-rex-smoke.test.sh - token-free real-binary guard for the Rex
# adapter (bin/backends/rex.sh). It provisions a private headless Rex server
# through bin/fm-rex-lab.sh (never the live server; the lab's tripwire checks
# the live server is untouched) and drives the adapter against it: session and
# tab creation, labels, focus, live cwd, send and keys, capture, agent state
# from real processes, close, exit 3 and exit 4, and the autostart refusal.
# Runs by default where rex and jq are installed; FM_REX_SMOKE=0 disables it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_REX_SMOKE rex jq

unset TMUX HERDR_ENV REX_SESSION REX_BLOCK REX_SERVER REX_CLIENT FM_BACKEND_REX_SERVER 2>/dev/null || true

LAB_HELPER="$ROOT/bin/fm-rex-lab.sh"
LAB=$("$LAB_HELPER" name smoke)
TMP_ROOT=$(fm_test_tmproot fm-backend-rex-smoke)
REX_VERSION=$(rex version 2>/dev/null | head -1)

cleanup() {
  "$LAB_HELPER" teardown "$LAB" || printf 'not ok - the Rex lab teardown or its live-server tripwire failed\n' >&2
}
trap cleanup EXIT

smoke_fail() { fail "$1 ($REX_VERSION)"; }

"$LAB_HELPER" provision "$LAB" || smoke_fail "could not provision a private Rex lab server"
FM_REX_SERVER=$("$LAB_HELPER" server "$LAB")
export FM_REX_SERVER
export FM_HOME="$TMP_ROOT/home" STATE="$TMP_ROOT/home/state"
mkdir -p "$STATE" "$TMP_ROOT/work/proj"
WORK=$(cd "$TMP_ROOT/work/proj" && pwd -P)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source rex || smoke_fail "could not source the rex adapter"

wait_capture() { # <target> <label> <needle>
  local i
  for i in $(seq 1 40); do
    fm_backend_rex_capture "$1" 200 "$2" 2>/dev/null | grep -qF -- "$3" && return 0
    sleep 0.1
  done
  return 1
}

wait_state() { # <target> <state>
  local i state
  for i in $(seq 1 40); do
    state=$(fm_backend_rex_agent_state "$1")
    [ "$state" = "$2" ] && return 0
    sleep 0.1
  done
  printf '%s' "$state"
  return 1
}

fm_backend_rex_container_ensure || smoke_fail "container_ensure refused the lab server"
[ "$FM_BACKEND_REX_SERVER" = "$FM_REX_SERVER" ] || smoke_fail "container_ensure did not pin the lab server"
[ -n "$FM_BACKEND_REX_SERVER_INSTANCE" ] || smoke_fail "container_ensure recorded no server instance"
pass "rex smoke: the private server passes the version gate and its instance is recorded"

IDS=$(fm_backend_rex_create_task fm-smoke-a "$WORK") || smoke_fail "create_task failed"
read -r SID WID BID <<EOF
$IDS
EOF
TA="$SID:$BID"
IDS=$(fm_backend_rex_create_task fm-smoke-b "$WORK") || smoke_fail "second create_task failed"
read -r _ WID_B BID_B <<EOF
$IDS
EOF
TB="$SID:$BID_B"
VIEW=$(fm_backend_rex_cli session inspect "session:$SID" --json) || smoke_fail "session inspect failed"
[ "$(printf '%s' "$VIEW" | jq -r .label)" = fm-local ] || smoke_fail "the home session is not labeled fm-local"
[ "$(printf '%s' "$VIEW" | jq '.windows | length')" = 2 ] || smoke_fail "the home session should hold exactly the two task tabs"
[ "$(printf '%s' "$VIEW" | jq -r .active_window_id)" = "window:$WID" ] || smoke_fail "--focus=false let the second tab take focus"
[ "$(printf '%s' "$VIEW" | jq -r --arg w "window:$WID_B" '.windows[] | select(.window_id == $w) | .label')" = "proj·smoke-b" ] \
  || smoke_fail "the tab label is not <project>·<id>"
fm_backend_rex_create_task fm-smoke-a "$WORK" >/dev/null 2>&1 && smoke_fail "a duplicate scoped label was not refused"
fm_backend_rex_target_ready "$TA" fm-smoke-a || smoke_fail "the new block is not ready under its scoped label"
pass "rex smoke: one fm-local session holding exactly the task tabs, unfocused labeled tabs, and duplicate refusal"

CWD=$(fm_backend_rex_current_path "$TA" fm-smoke-a)
[ "$CWD" = "$WORK" ] || smoke_fail "current_path read '$CWD', expected '$WORK'"
state=$(wait_state "$TA" dead) || smoke_fail "an idle shell read '$state', expected dead"
pass "rex smoke: current_path is the live foreground cwd and an idle shell reads dead"

fm_backend_rex_send_text_line "$TA" "printf 'rex-%s\\n' smoke-ok" fm-smoke-a || smoke_fail "send_text_line did not submit"
wait_capture "$TA" fm-smoke-a rex-smoke-ok || smoke_fail "the submitted line's output never appeared"
fm_backend_rex_send_literal "$TA" "-n not-an-option" fm-smoke-a || smoke_fail "send_literal failed"
wait_capture "$TA" fm-smoke-a "-n not-an-option" || smoke_fail "option-shaped text did not arrive literally"
fm_backend_rex_send_key "$TA" C-u fm-smoke-a || smoke_fail "C-u was not delivered"
pass "rex smoke: text rides stdin literally and submits with Enter"

fm_backend_rex_send_text_line "$TA" "sleep 60" fm-smoke-a || smoke_fail "could not start sleep"
state=$(wait_state "$TA" ambiguous) || smoke_fail "a foreground sleep read '$state', expected ambiguous"
fm_backend_rex_send_key "$TA" C-c fm-smoke-a || smoke_fail "C-c was not delivered"
state=$(wait_state "$TA" dead) || smoke_fail "after C-c the shell read '$state', expected dead"
ln -sf /bin/sleep "$TMP_ROOT/claude"
fm_backend_rex_send_text_line "$TA" "'$TMP_ROOT/claude' 60" fm-smoke-a || smoke_fail "could not start the claude-named process"
state=$(wait_state "$TA" alive) || smoke_fail "a claude-named foreground read '$state', expected alive"
fm_backend_rex_send_key "$TA" C-c fm-smoke-a || smoke_fail "C-c was not delivered"
pass "rex smoke: agent_state reads real foreground processes (shell dead, other ambiguous, harness-named alive)"

fm_backend_rex_send_text_line "$TA" "clear; seq 1 80" fm-smoke-a || smoke_fail "could not print scrollback"
wait_capture "$TA" fm-smoke-a 80 || smoke_fail "seq output never appeared"
ROWS=$(fm_backend_rex_block_call "$TA" size | jq -r .rows)
LINES=$(fm_backend_rex_cli capture -s "session:$SID" -b "block:$BID" | wc -l | tr -d ' ')
[ "$LINES" -gt "$ROWS" ] || smoke_fail "rex capture returned $LINES lines on a $ROWS-row screen; a viewport-only capture now exists, so revisit FM_BACKEND_VISIBLE_CAPTURE"
pass "rex smoke: capture includes scrollback ($LINES lines, $ROWS rows), so rex stays out of the viewport-capture list"

LIVE=$(fm_backend_rex_list_live)
printf '%s\n' "$LIVE" | grep -qx "$TA"$'\t'fm-smoke-a || smoke_fail "list_live did not list task a"
printf '%s\n' "$LIVE" | grep -qx "$TB"$'\t'fm-smoke-b || smoke_fail "list_live did not list task b"
pass "rex smoke: list_live finds this home's tabs"

fm_backend_kill rex "$TA" "" fm-smoke-a || smoke_fail "kill of task a failed"
fm_backend_rex_cli block inspect "block:$BID" --json >/dev/null 2>&1
[ "$?" -eq 3 ] || smoke_fail "a closed block did not answer exit 3"
[ "$(fm_backend_rex_agent_state "$TA")" = missing ] || smoke_fail "a closed block did not read missing"
fm_backend_rex_cli session inspect "session:$SID" --json >/dev/null 2>&1 || smoke_fail "the home session was retired while a tab remained"
fm_backend_kill rex "$TB" "" fm-smoke-b || smoke_fail "kill of task b failed"
fm_backend_rex_cli session inspect "session:$SID" --json >/dev/null 2>&1
[ "$?" -eq 3 ] || smoke_fail "the emptied home session was not retired"
fm_backend_kill rex "$TA" "" fm-smoke-a || smoke_fail "killing an already-gone block must succeed"
pass "rex smoke: kill proves exit 3 and retires the emptied home session only after its last tab"

# A secondmate pane opens as the first tab of its own fm-<id> session, and a
# worker that secondmate spawns from inside that pane joins the same session.
SM_HOME="$TMP_ROOT/sm-home"
mkdir -p "$SM_HOME/state"
printf 'smk\n' >"$SM_HOME/.fm-secondmate-home"
IDS=$(fm_backend_rex_create_task fm-smk "$SM_HOME" "$SM_HOME" "") || smoke_fail "the secondmate pane create_task failed"
read -r SM_SID SM_WID SM_BID <<EOF
$IDS
EOF
TSM="$SM_SID:$SM_BID"
[ "$(fm_backend_rex_cli session inspect "session:$SM_SID" --json | jq -r .label)" = fm-smk ] || smoke_fail "the secondmate session is not labeled fm-<id>"
state=$(wait_state "$TSM" dead) || smoke_fail "the secondmate pane's shell read '$state', expected dead"
PROBE="$TMP_ROOT/sm-worker.out"
fm_backend_rex_send_text_line "$TSM" "FM_REX_SERVER='$FM_REX_SERVER' FM_HOME='$SM_HOME' FM_ROOT='$SM_HOME' STATE='$SM_HOME/state' bash -c '. \"$ROOT/bin/fm-backend.sh\"; fm_backend_source rex && fm_backend_rex_create_task fm-w1 \"$WORK\" > \"$PROBE.tmp\" 2>&1; mv \"$PROBE.tmp\" \"$PROBE\"'" fm-smk \
  || smoke_fail "could not run the worker spawn inside the secondmate pane"
for _ in $(seq 1 100); do [ -s "$PROBE" ] && break; sleep 0.1; done
read -r W_SID _ W_BID <<EOF
$(cat "$PROBE" 2>/dev/null)
EOF
[ -n "${W_BID:-}" ] || smoke_fail "the in-pane worker spawn printed no ids: $(cat "$PROBE" 2>/dev/null)"
[ "$W_SID" = "$SM_SID" ] || smoke_fail "the secondmate's worker opened outside its fm-<id> session: $(cat "$PROBE")"
VIEW=$(fm_backend_rex_cli session inspect "session:$SM_SID" --json)
[ "$(printf '%s' "$VIEW" | jq -r '.windows[0].window_id')" = "window:$SM_WID" ] || smoke_fail "the worker tab displaced the secondmate pane from the first tab"
[ "$(printf '%s' "$VIEW" | jq '.windows | length')" = 2 ] || smoke_fail "the secondmate session should hold its pane and one worker tab"
fm_backend_rex_cli block close -s "session:$SM_SID" "block:$W_BID" >/dev/null 2>&1 || true
fm_backend_kill rex "$TSM" "" fm-smk || smoke_fail "closing the secondmate pane failed"
fm_backend_rex_cli session inspect "session:$SM_SID" --json >/dev/null 2>&1
[ "$?" -eq 3 ] || smoke_fail "the emptied fm-<id> session was not retired with its secondmate"
pass "rex smoke: a secondmate pane is the first tab of its fm-<id> session and its own worker joins that session"

DEAD_SOCK="$TMP_ROOT/dead.sock"
state=$(FM_BACKEND_REX_SERVER="unix://$DEAD_SOCK" fm_backend_rex_agent_state "$TA")
[ "$state" = unreadable ] || smoke_fail "an unreachable server read '$state', expected unreadable"
FM_BACKEND_REX_SERVER="unix://$DEAD_SOCK" fm_backend_rex_cli ls --json >/dev/null 2>&1
[ "$?" -eq 4 ] || smoke_fail "an unreachable server did not answer exit 4"
[ ! -e "$DEAD_SOCK" ] || smoke_fail "a call against a missing socket autostarted a server"
pass "rex smoke: an unreachable server is exit 4 and unreadable, and nothing autostarts"
