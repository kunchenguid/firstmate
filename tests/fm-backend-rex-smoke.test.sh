#!/usr/bin/env bash
# tests/fm-backend-rex-smoke.test.sh - token-free real-binary guard for the Rex
# adapter (bin/backends/rex.sh). It provisions a private headless Rex server
# through bin/fm-rex-lab.sh (never the live server; the lab's tripwire checks
# the live server is untouched) and drives the adapter against it: session and
# tab creation, labels, focus, live cwd, send and keys, capture, agent state
# from real processes, Firstmate's attention marks, notifications, validation
# progress, and state tint, the real `rex events` push wait, close, exit 3 and
# exit 4, and the autostart refusal.
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
[ "$(printf '%s' "$VIEW" | jq -r --arg w "window:$WID_B" '.windows[] | select(.window_id == $w) | .label')" = "Ship · smoke-b" ] \
  || smoke_fail "the tab label is not the sidebar-sized fallback"
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

# Attention marks: one tty write lands Firstmate's own id=fm record, titled
# with the tab label, and an OSC 777 notification that Rex streams as
# desktop_notification. A root record standing in for the harness's own report
# (which is what the app's sounds and notifications follow) must survive every
# Firstmate write untouched, and the whole mark, progress, and clear sequence
# must stream exactly one desktop notification.
EVENTS="$TMP_ROOT/events.jsonl"
env -u REX_SESSION -u REX_BLOCK -u REX_CLIENT -u REX_SERVER "$(fm_backend_rex_bin)" -S "$FM_REX_SERVER" --autostart=false \
  events -s "session:$SID" --json >"$EVENTS" 2>/dev/null &
EVENTS_PID=$!
sleep 1
fm_backend_rex_tty_write "$TB" "$(printf '\033]7501;state=done:app=smoke-harness:msg=%s\033\134' "$(printf 'turn finished' | base64)")" \
  || smoke_fail "the stand-in harness root record could not be written"
fm_backend_rex_mark "$TB" blocked question "Needs your decision" fm-smoke-b "Smoke · tab" "Smoke · tab" || smoke_fail "the mark could not be written"
for _ in $(seq 1 40); do grep -q desktop_notification "$EVENTS" && break; sleep 0.1; done
[ "$(fm_backend_rex_mark_read "$TB")" = $'blocked\tquestion\tNeeds your decision\tSmoke · tab\t' ] || smoke_fail "the id=fm record did not read back: $(fm_backend_rex_block_call "$TB" program_status)"
jq -e --arg b "block:$BID_B" 'select(.payload.event.payload.block_id == $b and .payload.event.payload.name == "program_status_changed" and .payload.event.payload.payload.id == "fm")' "$EVENTS" >/dev/null \
  || smoke_fail "the mark did not stream as program_status_changed id=fm"
jq -e --arg b "block:$BID_B" 'select(.payload.event.payload.block_id == $b and .payload.event.payload.name == "desktop_notification")' "$EVENTS" >/dev/null \
  || smoke_fail "the OSC 777 notification did not stream as desktop_notification: $(grep -c . "$EVENTS") events"
NOTE=$(jq -c --arg b "block:$BID_B" 'select(.payload.event.payload.name == "desktop_notification") | .payload.event.payload.payload' "$EVENTS" | head -1)
[ "$(printf '%s' "$NOTE" | jq -r .title)" = "Smoke · tab" ] || smoke_fail "the notification title is not the tab label: $NOTE"
fm_backend_rex_progress "$TB" 33 "Validating: review 3/9" fm-smoke-b "Smoke · tab" || smoke_fail "the progress record could not be written"
[ "$(fm_backend_rex_mark_read "$TB" fm/validate)" = $'working\t\tValidating: review 3/9\tSmoke · tab\t33' ] \
  || smoke_fail "the id=fm/validate record did not read back with its progress: $(fm_backend_rex_block_call "$TB" program_status)"
fm_backend_rex_progress "$TB" 44 "Validating: review 4/9" fm-smoke-b "Smoke · tab" || smoke_fail "the progress record could not be updated"
fm_backend_rex_mark "$TB" clear "" "" fm-smoke-b || smoke_fail "the mark could not be cleared"
[ "$(fm_backend_rex_mark_read "$TB")" = $'clear\t\t\t\t' ] || smoke_fail "clearing left Firstmate's record behind"
[ "$(fm_backend_rex_mark_read "$TB" fm/validate)" = $'clear\t\t\t\t' ] || smoke_fail "clearing the mark left the progress record beneath it"
ROOT_REC=$(fm_backend_rex_status_records "$TB" | jq -c '[.[] | select((.id // "") == "")] | first | {state, app, msg}')
[ "$ROOT_REC" = '{"state":"done","app":"smoke-harness","msg":"turn finished"}' ] \
  || smoke_fail "a Firstmate write touched the harness's root record: $ROOT_REC"
sleep 1
kill "$EVENTS_PID" 2>/dev/null || true
wait "$EVENTS_PID" 2>/dev/null || true
NOTES=$(jq -s --arg b "block:$BID_B" '[.[] | select(.payload.event.payload.block_id == $b and .payload.event.payload.name == "desktop_notification")] | length' "$EVENTS")
[ "$NOTES" = 1 ] || smoke_fail "the mark, progress, and clear sequence must stream exactly one desktop notification, got $NOTES"
jq -e -s --arg b "block:$BID_B" '[.[] | .payload.event.payload | select(.block_id == $b and .name == "program_status_changed" and .payload.record.app == "firstmate" and (.payload.id // "") == "")] | length == 0' "$EVENTS" >/dev/null \
  || smoke_fail "Firstmate wrote a root program-status record"
fm_backend_rex_capture "$TB" 50 fm-smoke-b | grep -q '7501\|777' && smoke_fail "a mark's bytes showed on the screen"
fm_backend_rex_tab_rename "$TB" "Ship · renamed" fm-smoke-b || smoke_fail "the tab could not be renamed"
VIEW=$(fm_backend_rex_cli window ls -s "session:$SID" --json)
[ "$(printf '%s' "$VIEW" | jq -r --arg w "window:$WID_B" '.windows[] | select(.window_id == $w) | .label')" = "Ship · renamed" ] || smoke_fail "the tab rename did not take"
pass "rex smoke: a mark is an invisible id=fm record titled with the tab label plus a streamed desktop notification ($NOTE), a progress record carries its percentage, clearing the mark removes both, the harness's root record is untouched and the sequence streams exactly one notification; a tab rename takes"

# State tint: OSC 11 written to the pane's terminal changes the background a
# program in the pane reads back with its own OSC 11 query, and OSC 111
# restores it. A headless server with no client theme leaves the default
# background undefined and does not answer the query, which reads as none.
cat >"$TMP_ROOT/bg-probe" <<'PROBE'
#!/usr/bin/env bash
old=$(stty -g)
stty raw -echo min 0 time 10
printf '\033]11;?\033\\' >/dev/tty
reply=$(dd bs=1 count=64 </dev/tty 2>/dev/null)
stty "$old"
bg=$(printf '%s' "$reply" | sed -n 's/.*\(rgb:[0-9a-fA-F/]*\).*/\1/p')
printf 'BG=%s=\n' "${bg:-none}"
PROBE
chmod +x "$TMP_ROOT/bg-probe"
probe_bg() { # <target> <label> -> the background the pane's program reads
  local i
  fm_backend_rex_send_text_line "$1" "clear; '$TMP_ROOT/bg-probe'" "$2" || return 1
  for i in $(seq 1 40); do
    fm_backend_rex_capture "$1" 50 "$2" 2>/dev/null | sed -n 's/.*BG=\([^=]*\)=.*/\1/p' | tail -1 | grep . && return 0
    sleep 0.1
  done
  return 1
}
BG0=$(probe_bg "$TB" fm-smoke-b) || smoke_fail "the pane's program could not read its background"
fm_backend_rex_tint "$TB" '#2b2614' fm-smoke-b || smoke_fail "the tint could not be written"
BG1=$(probe_bg "$TB" fm-smoke-b) || smoke_fail "the tinted background could not be read"
[ "$BG1" = rgb:2b2b/2626/1414 ] || smoke_fail "the tint did not reach the pane: read $BG1"
fm_backend_rex_tint "$TB" reset fm-smoke-b || smoke_fail "the tint could not be reset"
BG2=$(probe_bg "$TB" fm-smoke-b) || smoke_fail "the reset background could not be read"
[ "$BG2" = "$BG0" ] || smoke_fail "the reset did not restore the background: read $BG2, was $BG0"
fm_backend_rex_tint "$TB" 'red' fm-smoke-b && smoke_fail "a tint that is not #rrggbb must be refused"
fm_backend_rex_tint "$TB" '#2b2614' fm-smoke-other && smoke_fail "a tint for another task's label must be refused"
pass "rex smoke: a tint reaches the pane's own background query ($BG1) and a reset restores it ($BG2)"

# The push wait over a real stream: a root blocked report from inside the pane
# is the actionable edge, and the pane's program exiting is dead.
IDS=$(fm_backend_rex_create_task fm-smoke-c "$WORK") || smoke_fail "third create_task failed"
read -r _ _ BID_C <<EOF
$IDS
EOF
TC="$SID:$BID_C"
state=$(wait_state "$TC" dead) || smoke_fail "the third pane's shell read '$state', expected dead"
WAIT_OUT="$TMP_ROOT/wait.out"
( fm_backend_rex_wait_transition "$SID" 20 "$STATE" "$TC" >"$WAIT_OUT"; printf "\nrc=%s\n" "$?" >>"$WAIT_OUT" ) &
WAIT_PID=$!
sleep 3
fm_backend_rex_send_text_line "$TC" "printf '\\033]7501;state=blocked:kind=permission:app=smoke-probe\\033\\\\'" fm-smoke-c || smoke_fail "could not report blocked from the pane"
wait "$WAIT_PID"
grep -q '^rc=0$' "$WAIT_OUT" || smoke_fail "the real stream's blocked report did not end the wait: $(cat "$WAIT_OUT")"
[ "$(fm_transition_to_status "$(head -1 "$WAIT_OUT")")" = blocked ] || smoke_fail "the record is not blocked: $(cat "$WAIT_OUT")"
[ "$(fm_transition_pane_id "$(head -1 "$WAIT_OUT")")" = "$BID_C" ] || smoke_fail "the record names another block: $(cat "$WAIT_OUT")"
fm_backend_rex_commit_transition "$STATE" "$SID" "$(head -1 "$WAIT_OUT")"
( fm_backend_rex_wait_transition "$SID" 20 "$STATE" "$TC" >"$WAIT_OUT"; printf "\nrc=%s\n" "$?" >>"$WAIT_OUT" ) &
WAIT_PID=$!
sleep 3
fm_backend_rex_send_text_line "$TC" "exit" fm-smoke-c || smoke_fail "could not exit the third pane's shell"
wait "$WAIT_PID"
grep -q '^rc=0$' "$WAIT_OUT" || smoke_fail "the pane's program exiting did not end the wait: $(cat "$WAIT_OUT")"
[ "$(fm_transition_to_status "$(head -1 "$WAIT_OUT")")" = dead ] || smoke_fail "an exited pane is not dead: $(cat "$WAIT_OUT")"
fm_backend_kill rex "$TC" "" fm-smoke-c || smoke_fail "kill of task c failed"
rc=0
FM_BACKEND_REX_SERVER="unix://$TMP_ROOT/dead.sock" FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 \
  fm_backend_rex_wait_transition "$SID" 3 "$STATE" "$TB" >/dev/null || rc=$?
[ "$rc" -eq 2 ] || smoke_fail "an unreachable server's stream must make the wait unusable (2), got $rc"
pass "rex smoke: the event wait returns a real blocked report and a real exit as dead, and an unreachable server is unusable, never dead"

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
