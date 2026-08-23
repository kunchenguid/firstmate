#!/usr/bin/env bash
# tests/fm-composer-statusbar-herdr-e2e.test.sh - the real-Herdr end-to-end
# guard for the 2026-08-19 night-supervision outage (task
# fm-composer-odczyt-herdr).
#
# The classifier half of that outage is pinned portably by
# tests/fm-composer-lib.test.sh. This guard proves the half a screen fixture
# cannot: that an escalation is actually DELIVERED and CONFIRMED, and that a
# steer's Enter is confirmed without anyone re-sending it by hand, against a
# real pane whose terminal draws a multi-row status bar UNDER the input row.
# That is what failed for 4229 s with the work already finished: the composer
# read `unknown`, so the away-mode daemon refused to deliver 196 times running
# and every fm-send reported its Enter unconfirmed.
#
# The supervisor pane is a deterministic bash loop, not a harness binary, for
# the same reason tests/fm-afk-inject-herdr-e2e.test.sh uses one: this test
# asserts on submitted CONTENT, not on pane appearance, and the loop can draw
# the exact outage geometry on demand. It draws the bare agent-glyph composer
# row and then, BELOW it, a 13-row status bar carrying two adjacent solid
# rules - the shape that forged pi's separated composer and outranked the real
# input row. It registers as a real Herdr agent and reports an idle/working/
# idle cycle around each submission, because Herdr submit confirmation is
# native agent-state, not composer text (docs/herdr-backend.md "Native
# agent-state submit confirmation").
#
# Herdr isolation: every lifecycle action and every task-specific Herdr call
# goes through bin/fm-herdr-lab.sh in a named non-`default` lab session, and a
# PATH shim routes the production adapter's own calls through the same helper,
# so nothing here can reach the captain's running `default` session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_COMPOSER_STATUSBAR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_COMPOSER_STATUSBAR_E2E=1 to run the real-Herdr status-bar delivery regression"
  exit 0
fi
for tool in herdr jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name fm-composer-statusbar)
TMP_ROOT=$(fm_test_tmproot fm-composer-statusbar-e2e)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
LOG_FILE="$TMP_ROOT/submitted.log"
ORIGINAL_PATH=$PATH
DAEMON_PID=
PANE=
TARGET=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "$STATE" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION"

mkdir -p "$HOME_DIR"/{state,data,config,projects} "$PROJECT" "$FAKEBIN"
: > "$LOG_FILE"

# Route the production adapter's own Herdr calls through the guarded helper:
# the shim strips only the adapter's validated trailing --session pair and
# refuses anything scoped to another session, then the helper re-appends it.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo 'wrapper requires isolated session' >&2; exit 98; }
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

# --- the supervisor pane ----------------------------------------------------

PANE=$(lab workspace create --cwd "$PROJECT" --label fm-statusbar-supervisor --no-focus \
  | jq -r '.result.root_pane.pane_id')
[ -n "$PANE" ] && [ "$PANE" != null ] || fail "the lab workspace did not return a root pane id"
TARGET="$SESSION:$PANE"

# Herdr can return a created pane before its shell is ready to accept Enter, so
# require a stable shell-owned foreground before launching the fixture.
ready=false
for _ in $(seq 1 100); do
  if lab pane process-info --pane "$PANE" 2>/dev/null | jq -e '
    .result.process_info as $p
    | ($p.foreground_processes | length == 1)
      and ($p.foreground_processes[0].pid == $p.shell_pid)' >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.2
done
[ "$ready" = true ] || fail "the lab supervisor pane's shell never became ready"

LOOP_SCRIPT="$TMP_ROOT/statusbar-loop.sh"
cat > "$LOOP_SCRIPT" <<LOOP
#!/usr/bin/env bash
# Draws the outage geometry: a bare agent-glyph composer row with a status bar
# BELOW it. Two of the bar's rows are adjacent solid rules, which is exactly
# the separated shape; the cursor is returned to the composer row with a
# RELATIVE move, so the block stays correct even when drawing the bar scrolls
# the pane.
MARK=\$'\xE2\x81\xA3'
LOG="\$1"
HELPER='$LAB_HELPER'
SESSION='$SESSION'
PANE='$PANE'
report_agent_state() {  # <idle|working>
  "\$HELPER" run "\$SESSION" pane report-agent "\$PANE" \
    --source fm-test-supervisor --agent fm-test-supervisor --state "\$1" >/dev/null 2>&1
}
BAR=(
'────────────────────────────────────────'
'  BLAKE OS | CC: 2.1.235 | RZESZOW, 19'
'  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄'
'  PWD: lab'
'  ────────────────────────────────────────'
'  CONTEXT: 12%'
'  ········································'
'  ────────────────────────────────────────'
'  USE: 5HR: 61% | WEEK: 65% (SUB/API)'
'  ────────────────────────────────────────'
'  ────────────────────────────────────────'
'  "There is no next time." -Celestine Chua'
'  bypass permissions on (shift+tab to cycle)'
)
OLD_STTY=\$(stty -g 2>/dev/null || true)
[ -z "\$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() { [ -z "\$OLD_STTY" ] || stty "\$OLD_STTY" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
report_agent_state idle

_buf=
redraw() {
  local avail=40 shown tail_n row
  if [ "\${#_buf}" -gt "\$avail" ]; then
    tail_n=\$((avail - 3))
    shown="...\${_buf: -\$tail_n}"
  else
    shown="\$_buf"
  fi
  printf '\r\033[K❯ %s' "\$shown"
  for row in "\${BAR[@]}"; do printf '\n\033[K%s' "\$row"; done
  printf '\033[J'
  printf '\033[%dA\r\033[K❯ %s' "\${#BAR[@]}" "\$shown"
}
submit_line() {
  local _line=\$_buf _c _hex
  if [ "\${_line:0:1}" = "\$MARK" ]; then _c="injection"; else _c="user"; fi
  _hex=\$(printf '%s' "\$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "\$_hex" "\$_line" "\$_c" >> "\$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
  report_agent_state working
  sleep 0.6
  report_agent_state idle
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "\$_ch" ]; then submit_line; continue; fi
  case "\$_ch" in
    \$'\r'|\$'\n') submit_line ;;
    \$'\177'|\$'\b') _buf=\${_buf%?}; redraw ;;
    *) _buf="\${_buf}\${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
  fm_backend_herdr_send_text_line "$TARGET" "bash '$LOOP_SCRIPT' '$LOG_FILE'" \
  || fail "could not start the status-bar supervisor loop in the lab pane"
sleep 2

# --- 1. the classifier, live on the outage geometry -------------------------

verdict=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
  fm_backend_composer_state herdr "$TARGET")
[ "$verdict" = empty ] \
  || fail "an idle composer with a status bar drawn below it must classify empty, got '$verdict'"
pass "live herdr: an idle composer under a 13-row status bar classifies empty"

# --- 2. fm-send confirms its own Enter --------------------------------------
# The outage's second symptom: the text landed in the composer but the submit
# read-back never confirmed, so every steer had to be finished by hand with
# `herdr pane send-keys <pane> Enter`. Exit 3 is fm-send's own code for that.
#
# The pane is put MID-TURN first, on purpose. Herdr confirms a submit from
# native agent-state when the pre-Enter baseline is legibly idle, and only
# falls back to reading the composer when it is not - so a pane that is idle
# when the steer arrives never exercises this defect at all. The pane firstmate
# was steering that night was a working agent, which is exactly the case that
# falls back to the composer read and got `unknown`.
lab pane report-agent "$PANE" --source fm-test-supervisor \
  --agent fm-test-supervisor --state working >/dev/null

cat > "$STATE/steer-task.meta" <<EOF
window=$TARGET
backend=herdr
kind=ship
mode=no-mistakes
worktree=$PROJECT
project=synthetic-project
EOF

send_rc=0
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
  "$ROOT/bin/fm-send.sh" steer-task "steer under the status bar" \
  >"$TMP_ROOT/send.out" 2>"$TMP_ROOT/send.err" || send_rc=$?
sleep 1
# The line reaching the pane is not the point: it reached the pane during the
# outage too. The point is that fm-send can now SEE that it did, so the caller
# is not left re-sending Enter by hand over an instruction that already landed.
grep -qF 'steer under the status bar' "$LOG_FILE" \
  || fail "the steer never reached the pane at all (exit $send_rc): $(tail -1 "$TMP_ROOT/send.err")"
[ "$send_rc" -eq 0 ] \
  || fail "the steer landed but fm-send reported it undelivered (exit $send_rc): $(tail -1 "$TMP_ROOT/send.err")"
pass "live herdr: fm-send confirms its own submit under the status bar, with no hand-sent Enter"

# --- 3. the away-mode cycle: delivered AND confirmed ------------------------

: > "$LOG_FILE"
afk_enter "$STATE"
PATH="$FAKEBIN:$ORIGINAL_PATH" \
HERDR_SESSION="$SESSION" \
FM_STATE_OVERRIDE="$STATE" \
FM_SUPERVISOR_BACKEND=herdr \
FM_SUPERVISOR_TARGET="$TARGET" \
FM_ESCALATE_BATCH_SECS=0 \
FM_HOUSEKEEPING_TICK=1 \
FM_POLL=1 \
FM_SIGNAL_GRACE=1 \
FM_HEARTBEAT=999999 \
FM_CHECK_INTERVAL=999999 \
FM_MAX_DEFER_SECS=20 \
FM_INJECT_CONFIRM_SLEEP=0.5 \
FM_INJECT_CONFIRM_RETRIES=6 \
FM_STALE_ESCALATE_SECS=999999 \
  nohup "$ROOT/bin/fm-supervise-daemon.sh" >"$TMP_ROOT/daemon.out" 2>"$TMP_ROOT/daemon.err" &
DAEMON_PID=$!
started=false
for _ in $(seq 1 40); do
  if grep -q 'backend=herdr' "$STATE/.supervise-daemon.log" 2>/dev/null; then started=true; break; fi
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.25
done
[ "$started" = true ] || fail "the away daemon never recorded backend=herdr: $(cat "$TMP_ROOT/daemon.err")"

echo "done: PR https://example.test/pr/900" > "$STATE/fake-c1.status"
delivered=false
for _ in $(seq 1 40); do
  grep -q 'Supervisor escalate' "$LOG_FILE" && { delivered=true; break; }
  sleep 0.5
done
[ "$delivered" = true ] \
  || fail "the escalation was never delivered under the status bar; daemon log: $(tail -5 "$STATE/.supervise-daemon.log" 2>/dev/null)"
marker_count=$(awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }' "$LOG_FILE")
[ "$marker_count" -eq 1 ] \
  || fail "expected exactly one delivered escalation, got $marker_count (duplicate or lost)"
digest_line=$(grep 'Supervisor escalate' "$LOG_FILE" | head -1)
case "$digest_line" in
  *injection) ;;
  *) fail "the delivered escalation was misclassified (expected injection): $digest_line" ;;
esac
[ ! -s "$STATE/.subsuper-inject-wedged" ] \
  || fail "the daemon raised the wedge alarm even though the composer was readable"
pass "live herdr: an away-mode escalation is delivered and confirmed exactly once under the status bar"

# --- 4. the injection gate, live under the same status bar ------------------
# The fix must not have bought delivery by declaring the pane empty: real typed
# text under the SAME status bar must still hold the next escalation back.

: > "$LOG_FILE"
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
  fm_backend_herdr_send_literal "$TARGET" "captain half-written sentence"
sleep 1
verdict=$(PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
  fm_backend_composer_state herdr "$TARGET")
[ "$verdict" = pending ] \
  || fail "real typed text under the status bar must read pending, got '$verdict'"
echo "needs-decision: pick A or B" > "$STATE/fake-c2.status"
sleep 10
if grep -q 'Supervisor escalate' "$LOG_FILE"; then
  fail "the daemon injected over the captain's half-written sentence"
fi
PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
  fm_backend_herdr_send_key "$TARGET" Enter
sleep 1
for _ in $(seq 1 40); do
  grep -q 'Supervisor escalate' "$LOG_FILE" && break
  sleep 0.5
done
grep -qF 'captain half-written sentence' "$LOG_FILE" \
  || fail "the captain's own line was lost instead of submitted"
grep -q 'Supervisor escalate' "$LOG_FILE" \
  || fail "the held escalation never arrived after the composer went idle"
if grep -q 'captain half-written sentence.*Supervisor escalate' "$LOG_FILE" \
   || grep -q 'Supervisor escalate.*captain half-written sentence' "$LOG_FILE"; then
  fail "the captain's line and the escalation were merged into one submission"
fi
pass "live herdr: the injection gate still holds over real typed text under the status bar"

afk_exit "$STATE" 2>/dev/null || true
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=
echo "# all fm-composer-statusbar-herdr-e2e tests passed"
