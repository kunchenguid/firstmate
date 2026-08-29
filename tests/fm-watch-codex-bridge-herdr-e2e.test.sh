#!/usr/bin/env bash
# tests/fm-watch-codex-bridge-herdr-e2e.test.sh - real-herdr end-to-end test for
# the Codex-primary watcher bridge (bin/fm-watch-codex-bridge.sh), the live
# counterpart of tests/fm-watch-codex-bridge.test.sh's portable regression.
# Mirrors tests/fm-afk-inject-herdr-e2e.test.sh's isolation patterns: everything
# runs on a throwaway, named, NEVER-default lab session whose every Herdr call
# is routed through bin/fm-herdr-lab.sh (the guarded non-default lab contract;
# the running default session is a tripwire that teardown verifies unchanged).
# Skips cleanly when herdr or jq is not installed.
#
# What this test proves live, beyond the portable suite:
#   - the arm, run organically inside a codex-named session process in a real
#     Herdr pane (no FM_BRIDGE_HARNESS seam), resolves the exact pane, binds
#     the session lock pid to the pane's shell descendant tree, launches the
#     persistent owner in its own tracked non-visible workspace in the SAME
#     named session, and is idempotent (the second arm attaches);
#   - the daemon injects the exact canonical one-line doorbell (U+2063
#     FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: <verbatim queued
#     reason> ... Run bin/fm-wake-drain.sh first ...) into the primary pane
#     through the verified submit path, confirms delivery, and records the
#     delivery point;
#   - duplicate suppression: nothing newer queued -> no second injection;
#   - a busy primary (native agent state) defers without typing, and the
#     bounded retry delivers once the pane goes idle;
#   - a pending composer (unsubmitted captain draft) is never typed into: the
#     bridge defers, the draft is submitted verbatim by the captain, and only
#     then is the wake doorbelled;
#   - a replaced session (the recorded lock pid dies) stands the daemon down
#     within a tick or two, and every post-standdown wake row stays durable.
#
# The "Codex primary" is a deterministic fixture (not a real Codex binary): a
# bare-agent composer loop that registers itself as a real herdr agent via
# `herdr pane report-agent` (the same technique the away-mode herdr e2e uses),
# plus a codex-NAMED bash stand-in that plays the Codex session. The pane's
# shell descendant tree positively contains that stand-in, which is exactly the
# primary-identity evidence the bridge requires.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT/bin/fm-watch-codex-bridge.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-codex-watcher-injection) || {
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
TMP_ROOT=
CLEANED=0
cleanup_all() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
  rm -rf "${TMP_ROOT:-}"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
  || { printf 'not ok - could not provision isolated Herdr lab session\n' >&2; exit 1; }
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { printf 'not ok - fm_backend_source herdr failed\n' >&2; exit 1; }
fm_backend_herdr_version_check || { printf 'not ok - herdr version floor check failed\n' >&2; cleanup_all; exit 1; }

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-codex-bridge-e2e.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"
LOG_FILE="$TMP_ROOT/submitted.log"
: > "$LOG_FILE"
STANDIN="$TMP_ROOT/codex"
cp "$(command -v bash)" "$STANDIN"

# Test cadence: the wrapper exports these before the arm, and the arm forwards
# the documented daemon knobs through the launch env.
BRIDGE_POLL=1
RETRY_SECS=2

# --- the primary pane ---------------------------------------------------------

WS_OUT=$(lab workspace create --cwd "$TMP_ROOT" --label fm-codex-bridge-primary --no-focus 2>/dev/null) \
  || fail "could not create the primary workspace"
PANE_ID=$(printf '%s' "$WS_OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
[ -n "$PANE_ID" ] || fail "workspace create did not return a root pane id"
SUPERVISOR_TARGET="$HERDR_LAB_SESSION:$PANE_ID"

# Herdr can return the created pane before its interactive shell is ready to
# receive Enter; require a stable shell-owned foreground first (same readiness
# shape as tests/fm-afk-inject-herdr-e2e.test.sh).
PANE_READY=false
READY_SAMPLES=0
for _ in $(seq 1 100); do
  PROCESS_INFO=$(fm_backend_herdr_cli "$HERDR_LAB_SESSION" pane process-info --pane "$PANE_ID" 2>/dev/null || true)
  if printf '%s' "$PROCESS_INFO" | jq -e '
    .result.process_info as $process
    | ($process.foreground_processes | length == 1)
      and ($process.foreground_processes[0].pid == $process.shell_pid)
  ' >/dev/null 2>&1; then
    READY_SAMPLES=$((READY_SAMPLES + 1))
    if [ "$READY_SAMPLES" -ge 10 ]; then
      PANE_READY=true
      break
    fi
  else
    READY_SAMPLES=0
  fi
  sleep 0.1
done
[ "$PANE_READY" = true ] || fail "the primary pane's shell did not become ready"

# --- the Codex-primary fixture ------------------------------------------------
# A codex-NAMED bash stand-in plays the Codex session: it holds the fleet lock,
# runs the arm twice (started, then attached) as its own child, and stays alive
# as the recorded session. Both arms are stand-in children, so harness detection
# runs the real ancestry walk (no FM_BRIDGE_HARNESS seam), and the session-
# ownership gate sees the arm as a genuine descendant of the lock holder. The
# stand-in clears foreign harness markers first - the same launch-boundary
# hygiene bin/fm-spawn.sh applies - because herdr panes inherit the spawner's
# environment and this lab was provisioned from this suite's own session.
# The wrapper stays as the pane's foreground composer process, so no injection
# can land before the pane can log it.
WRAPPER="$TMP_ROOT/primary-wrapper.sh"
cat > "$WRAPPER" <<WRAPPER
#!/usr/bin/env bash
set -u
LOG="\$1"; STATE="\$2"; HOME_DIR_ARG="\$3"; TARGET="\$4"; STANDIN="\$5"; BRIDGE="\$6"
(
  export FM_HOME="\$HOME_DIR_ARG" STATE="\$STATE" TARGET="\$TARGET" BRIDGE="\$BRIDGE"
  export FM_BRIDGE_POLL="$BRIDGE_POLL" FM_BRIDGE_INJECT_RETRY_SECS="$RETRY_SECS"
  exec "\$STANDIN" -c '
    unset CLAUDECODE CURSOR_AGENT CURSOR_INVOKED_AS PI_CODING_AGENT GROK_AGENT
    unset GROK_HOOK_EVENT GROK_HOOK_NAME GROK_SESSION_ID GROK_WORKSPACE_ROOT
    unset MUSE_CURRENT_SESSION_LOG
    printf "%s\n" "\$\$" > "\$STATE/.lock"
    printf "%s\n" "\$\$" > "\$STATE/session.pid"
    FM_SUPERVISOR_TARGET="\$TARGET" FM_SUPERVISOR_BACKEND=herdr "\$BRIDGE" arm > "\$STATE/arm.out" 2>&1
    printf "rc=%s\n" "\$?" >> "\$STATE/arm.out"
    sleep 1
    FM_SUPERVISOR_TARGET="\$TARGET" FM_SUPERVISOR_BACKEND=herdr FM_HOME="\$FM_HOME" "\$BRIDGE" arm > "\$STATE/arm2.out" 2>&1
    printf "rc=%s\n" "\$?" >> "\$STATE/arm2.out"
    sleep 900 >/dev/null 2>&1 &
    wait
  '
) &
STANDIN_JOB=\$!
i=0
while [ \$i -lt 150 ]; do
  grep -q 'watcher bridge: started' "\$STATE/arm.out" 2>/dev/null && break
  sleep 0.1
  i=\$((i + 1))
done
grep -q 'watcher bridge: started' "\$STATE/arm.out" 2>/dev/null || {
  printf 'arm never started\n' >&2
  kill \$STANDIN_JOB 2>/dev/null || true
  exit 1
}

# Composer loop: draws the shared classifier's positively identified bare-agent
# shape, registers a real herdr agent (idle/working), and logs every submitted
# line with an injection/user classification. The force-busy flag sustains a
# native busy verdict for the deferral scenario.
MARK=\$'\xE2\x81\xA3'
AGENT_SOURCE=fm-codex-bridge-e2e
report_agent_state() {
  herdr pane report-agent "\$HERDR_PANE_ID" --source "\$AGENT_SOURCE" --agent "\$AGENT_SOURCE" --state "\$1" --session "\$HERDR_SESSION" >/dev/null 2>&1
}
OLD_STTY=\$(stty -g 2>/dev/null || true)
[ -z "\$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "\$OLD_STTY" ] || stty "\$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
LAST_STATE=
update_agent_state() {
  local want
  if [ -e "\$STATE/busy-flag" ]; then want=working; else want=idle; fi
  [ "\$want" = "\$LAST_STATE" ] && return 0
  report_agent_state "\$want"
  LAST_STATE=\$want
}
update_agent_state

_buf=
redraw() {
  printf '\r\033[K❯ %s' "\$_buf"
}
submit_line() {
  local _line=\$_buf _c _hex
  if [ "\${_line:0:1}" = "\$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=\$(printf '%s' "\$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "\$_hex" "\$_line" "\$_c" >> "\$LOG"
  _buf=
  printf '\r\033[K\n'
  report_agent_state working
  sleep 0.6
  report_agent_state idle
  LAST_STATE=idle
  redraw
}

redraw
while :; do
  if ! IFS= read -r -n 1 -t 0.5 _ch; then
    update_agent_state
    continue
  fi
  if [ -z "\$_ch" ]; then
    submit_line
    continue
  fi
  case "\$_ch" in
    \$'\r'|\$'\n') submit_line ;;
    \$'\177'|\$'\b') _buf=\${_buf%?}; redraw ;;
    *) _buf="\${_buf}\${_ch}"; redraw ;;
  esac
done
WRAPPER
chmod +x "$WRAPPER"

fm_backend_herdr_send_text_line "$SUPERVISOR_TARGET" \
  "bash '$WRAPPER' '$LOG_FILE' '$HOME_DIR/state' '$HOME_DIR' '$SUPERVISOR_TARGET' '$STANDIN' '$BRIDGE'" \
  || fail "could not start the primary wrapper in the pane"

# Wait for both arm outcomes (started, then attached).
i=0
while [ "$i" -lt 100 ]; do
  if grep -q 'watcher bridge: started' "$HOME_DIR/state/arm.out" 2>/dev/null \
    && grep -q 'watcher bridge: attached' "$HOME_DIR/state/arm2.out" 2>/dev/null; then
    break
  fi
  sleep 0.3
  i=$((i + 1))
done
ARM_OUT=$(cat "$HOME_DIR/state/arm.out" 2>/dev/null)
ARM2_OUT=$(cat "$HOME_DIR/state/arm2.out" 2>/dev/null)
printf '%s' "$ARM_OUT" | grep -q 'watcher bridge: started' \
  || fail "the arm never started the bridge (arm.out: $ARM_OUT)"
printf '%s' "$ARM_OUT" | grep -q "supervising $SUPERVISOR_TARGET" \
  || fail "the arm did not record the exact primary pane as its target (arm.out: $ARM_OUT)"
printf '%s' "$ARM2_OUT" | grep -q 'watcher bridge: attached' \
  || fail "the second arm did not attach to the live bridge (arm2.out: $ARM2_OUT)"
[ "$(printf '%s' "$ARM2_OUT" | grep -c 'watcher bridge: started')" -eq 0 ] \
  || fail "the second arm launched a duplicate bridge instead of attaching"
pass "the arm launched one persistent owner in the named session and re-arming attaches"

# The bridge's own non-visible workspace exists in the lab session.
BRIDGE_WS_COUNT=$(lab workspace list 2>/dev/null | jq '[.result.workspaces[]? | select(.label | startswith("firstmate-codex-bridge"))] | length' 2>/dev/null) \
  || BRIDGE_WS_COUNT=0
[ "$BRIDGE_WS_COUNT" -eq 1 ] || fail "expected exactly one bridge workspace in the lab session (got: $BRIDGE_WS_COUNT)"
pass "the bridge daemon runs in its own tracked non-visible workspace"

bridge_status_line() {
  FM_HOME="$HOME_DIR" "$BRIDGE" status
}
wait_log() {  # <pattern> <timeout-seconds>
  local pattern=$1 timeout=$2 i=0
  while [ "$i" -lt $((timeout * 4)) ]; do
    grep -q "$pattern" "$HOME_DIR/state/.watch-codex-bridge.log" 2>/dev/null && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}
wait_injections() {  # <count> <timeout-seconds>
  local want=$1 timeout=$2 i=0 have
  while [ "$i" -lt $((timeout * 4)) ]; do
    have=$(grep -c $'\tinjection$' "$LOG_FILE" 2>/dev/null || true)
    [ "$have" -ge "$want" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}
append_wake() {  # <kind> <key> <payload>
  FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2" "$3"
}
queue_top() {
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    fm_bridge_queue_top
  ' _ "$BRIDGE"
}
injection_lines() {
  grep $'\tinjection$' "$LOG_FILE" 2>/dev/null || true
}
assert_line_contains() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (line: $1)" ;;
  esac
}

# --- scenario A: exact canonical doorbell, delivered and deduplicated ---------

append_wake stale "default:wH:p2" "stale: default:wH:p2 (idle 244s, possible wedge, escalation 1)" \
  || fail "append_wake failed"
wait_injections 1 20 || fail "the daemon never injected the queued wake (log: $(cat "$LOG_FILE"))"
LINE=$(injection_lines | head -1)
HEX=${LINE%%$'\t'*}
case "$HEX" in e281a3*) ;; *) fail "the delivered line does not start with the U+2063 operational mark" ;; esac
TEXT=$(printf '%s' "$LINE" | cut -f2)
assert_line_contains "$TEXT" \
  "FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: stale: default:wH:p2 (idle 244s, possible wedge, escalation 1)" \
  "the delivered doorbell lost the verbatim queued reason"
assert_line_contains "$TEXT" "Run bin/fm-wake-drain.sh first and handle the queued wake" \
  "the delivered doorbell lost the canonical drain instruction"
[ "$(printf '%s\n' "$TEXT" | wc -l)" -eq 1 ] || fail "the delivered doorbell must be exactly one line"
TOP=$(queue_top) || fail "queue top unreadable"
[ "$(cat "$HOME_DIR/state/.watch-codex-bridge-delivered" 2>/dev/null)" = "$TOP" ] \
  || fail "the delivered marker must record the queue top (marker: $(cat "$HOME_DIR/state/.watch-codex-bridge-delivered" 2>/dev/null), top: $TOP)"
wait_log "wake doorbell delivered" 5 || fail "the daemon did not log a confirmed delivery"
pass "the daemon delivered the exact canonical doorbell and recorded the delivery point"

sleep $((RETRY_SECS * 2 + 2))
[ "$(grep -c $'\tinjection$' "$LOG_FILE")" -eq 1 ] \
  || fail "an already-doorbelled queue was injected again (duplicate suppression)"
pass "duplicate suppression: an already-doorbelled queue is never re-injected"

# --- scenario B1: a busy primary defers, then the bounded retry delivers ------

touch "$HOME_DIR/state/busy-flag"
sleep 1.5  # let the fixture report working
append_wake signal "c1.status" "signal: c1 finished" || fail "append_wake failed"
sleep $((RETRY_SECS * 2 + 2))
[ "$(grep -c $'\tinjection$' "$LOG_FILE")" -eq 1 ] \
  || fail "a busy primary pane was typed into (log: $(cat "$LOG_FILE"))"
wait_log "injection deferred: the primary pane is busy" 10 \
  || fail "the daemon did not log the busy deferral"
rm -f "$HOME_DIR/state/busy-flag"
wait_injections 2 20 || fail "the daemon did not deliver after the pane went idle"
NEW_TOP=$(queue_top)
[ "$(cat "$HOME_DIR/state/.watch-codex-bridge-delivered")" = "$NEW_TOP" ] \
  || fail "the delivered marker did not advance to the new queue top"
pass "a busy primary defers behind the bounded retry and is doorbelled once idle"

# --- scenario B2: a pending composer is never typed into ----------------------

fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "captain draft" \
  || fail "could not type the captain draft"
sleep 1  # let the fixture render the pending buffer
append_wake check "merge-poll" "check: merge poll fired" || fail "append_wake failed"
sleep $((RETRY_SECS * 2 + 2))
[ "$(grep -c $'\tinjection$' "$LOG_FILE")" -eq 2 ] \
  || fail "the bridge typed into a pending composer (log: $(cat "$LOG_FILE"))"
wait_log "composer not confirmed empty" 10 \
  || fail "the daemon did not log the pending-composer deferral"
# The captain submits their own draft untouched; only then is the wake delivered.
fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter \
  || fail "could not submit the captain draft"
wait_injections 3 20 || fail "the daemon did not deliver after the composer emptied"
DRAFT_LINE=$(grep -F 'captain draft' "$LOG_FILE" | head -1)
case "$DRAFT_LINE" in
  *$'\tuser'*) : ;;
  *) fail "the captain draft was not preserved verbatim as user input (line: $DRAFT_LINE)" ;;
esac
pass "a pending composer defers so the captain's draft is never overwritten"

# --- scenario C: a replaced session stands the bridge down --------------------

SESSION_PID=$(cat "$HOME_DIR/state/.lock")
kill "$SESSION_PID" 2>/dev/null || fail "could not kill the codex stand-in session"
append_wake heartbeat "fleet" "heartbeat" || fail "append_wake failed"
sleep $((BRIDGE_POLL * 4 + 2))
wait_log "standing down: the recorded session lock no longer names the recorded live session" 10 \
  || fail "the daemon did not stand down after the recorded session was replaced"
STATUS_LINE=$(bridge_status_line)
case "$STATUS_LINE" in
  *"not running"*) : ;;
  *) fail "the bridge status must report not running after the stand-down (got: $STATUS_LINE)" ;;
esac
sleep $((RETRY_SECS * 2 + 2))
[ "$(grep -c $'\tinjection$' "$LOG_FILE")" -eq 3 ] \
  || fail "an injection was typed after the recorded session was replaced"
[ "$(wc -l < "$HOME_DIR/state/.wake-queue")" -ge 4 ] \
  || fail "the post-standdown wake row must stay durable in the queue"
pass "a replaced session stands the bridge down and the durable queue keeps every row"

cleanup_all
CLEANED=1
trap - EXIT
pass "fm-watch-codex-bridge herdr e2e complete (lab session torn down, default session tripwire verified)"
