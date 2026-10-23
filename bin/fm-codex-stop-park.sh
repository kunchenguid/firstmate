#!/usr/bin/env bash
# Codex 0.163.0 model-free supervision. Native SessionStart registers the
# session; asynchronous Stop owns one foreground arm and queues only a real
# wake through `codex queue --thread`. This works in embedded CLI mode without
# an app-server daemon. No terminal injection or separate event selector.
#
# Usage: fm-codex-stop-park.sh --session-start|--guard|--capable
#        fm-codex-stop-park.sh                 (asynchronous Stop hook)
# Hook modes read the native JSON payload on stdin. --capable is read-only.
# Registration also requires the native transcript's codex-tui originator;
# headless exec sessions have no persistent interactive input surface.
# Unsupported versions, manual session starts, workers, and foreign session
# owners retain the existing foreground checkpoint and turn-end guard.
#
# state/.codex-park-session binds selection to the native session and fleet
# lock PID. state/.codex-park.lock is the shared lock library's single-flight
# claim. state/.codex-park.json records the claim's PID identity, session,
# outcome and timestamp; it never acknowledges or alters the wake queue.
# The arm remains the owner of watcher identity, recovery generations and
# successor following. Quiet polls never return to the model.
#
# Async hooks do not themselves wake Codex. A bounded native queue submission
# does; delivery failure latches this session to foreground fallback and stays
# visible to the next synchronous Stop guard. One arm failure is reported and
# retried; a second consecutive failure also latches fallback. A dead park is
# reported when the next Stop replaces its stale claim. Signals terminate only
# the tracked arm child; fm_exec_timed also reaps it after owner death on Perl
# hosts. FM_CODEX_PARK_OWNER_PID and FM_CODEX_PARK_OWNER_IDENTITY bind the
# watcher itself to this hook: its poll loop exits when that identity is gone,
# even if the native harness killed the timeout wrapper too. No other owner
# sets these variables, and no process is signalled by that self-expiry check.
# The native hook timeout is deliberately longer than a process lifetime
# in ordinary use; a hook timeout is a failure, never a quiet polling clock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

MODE=${1:-stop}
SESSION_FILE="$STATE/.codex-park-session"
CLAIM="$STATE/.codex-park.lock"
RECORD="$STATE/.codex-park.json"
FALLBACK="$STATE/.codex-park-fallback"
SESSION=
CHILD=
OUT=
OWNED=0
CODEX_COMMAND=

verified_cli() {
  local pid executable
  command -v jq >/dev/null 2>&1 || return 1
  [ "$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null)" = codex ] || return 1
  # Version the running native ancestor, not a possibly upgraded PATH shim.
  while IFS= read -r pid; do
    if [ -L "/proc/$pid/exe" ]; then
      executable=$(readlink "/proc/$pid/exe")
    else
      executable=$(ps -o comm= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//')
    fi
    case "$executable" in */codex) ;; *) continue ;; esac
    [ -x "$executable" ] || return 1
    [ "$("$executable" --version 2>/dev/null)" = 'codex-cli 0.163.0' ] || return 1
    CODEX_COMMAND=$executable
    return 0
  done < <(fm_harness_ancestry_pids)
  return 1
}

registered() {
  local registered_session registered_pid
  [ -f "$SESSION_FILE" ] && [ ! -L "$SESSION_FILE" ] || return 1
  registered_session=$(sed -n '1p' "$SESSION_FILE")
  registered_pid=$(sed -n '2p' "$SESSION_FILE")
  [ -n "$registered_session" ] && [ "$registered_pid" = "$(cat "$STATE/.lock" 2>/dev/null)" ] || return 1
  [ -z "$SESSION" ] || [ "$SESSION" = "$registered_session" ] || return 1
  [ "$(cat "$FALLBACK" 2>/dev/null)" != "$registered_session" ]
}

capable() {
  fm_primary_scope_matches "$FM_ROOT" "$STATE" && verified_cli \
    && fm_session_lock_owned_by_self "$STATE" || return 1
  # Only the native SessionStart wrapper supplies this before its receipt is
  # published; the digest has acquired the session lock before rendering.
  [ -n "${FM_CODEX_PARK_SESSION:-}" ] || registered
}

park_alive() {
  local pid identity anchor
  [ -f "$RECORD" ] || return 1
  pid=$(jq -r '.pid // empty' "$RECORD" 2>/dev/null)
  [ "$pid" = "$(cat "$CLAIM/pid" 2>/dev/null)" ] || return 1
  fm_pid_alive "$pid" || return 1
  identity=$(fm_pid_identity "$pid") || return 1
  anchor=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  jq -e --arg session "$SESSION" --arg identity "$identity" --arg anchor "$anchor" \
    '.session == $session and .identity == $identity and .anchor == $anchor' "$RECORD" >/dev/null 2>&1
}

record() {
  local outcome=$1 temp="$RECORD.tmp.$$"
  jq -n --arg session "$SESSION" --arg identity "$IDENTITY" \
    --arg anchor "$ANCHOR" --arg outcome "$outcome" --argjson pid "$$" \
    --argjson at "$(date +%s)" \
    '{session:$session,identity:$identity,anchor:$anchor,pid:$pid,at:$at,outcome:$outcome}' > "$temp" \
    && mv -f "$temp" "$RECORD"
}

fallback() { printf '%s\n' "$SESSION" > "$FALLBACK"; }

deliver() {
  local message=$1
  fm_session_lock_owned_by_self "$STATE" && registered || return 1
  fm_run_timed 20 "$CODEX_COMMAND" queue --thread "$SESSION" --message "$message" > "$STATE/.codex-park-delivery.tmp.$$" 2>&1
  local rc=$?
  rm -f "$STATE/.codex-park-delivery.tmp.$$"
  return "$rc"
}

# shellcheck disable=SC2329 # EXIT trap owns cleanup.
cleanup() {
  if [ -n "$CHILD" ]; then
    kill -TERM "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
  fi
  [ -z "$OUT" ] || rm -f "$OUT"
  [ "$OWNED" -eq 0 ] || fm_lock_release "$CLAIM"
}

case "$MODE" in
  --capable) capable; exit $? ;;
  --session-start|--guard|stop) ;;
  -h|--help)
    echo 'Usage: fm-codex-stop-park.sh [--session-start|--guard|--capable]'
    exit 0 ;;
  *) echo "error: unknown argument: $MODE" >&2; exit 2 ;;
esac
PAYLOAD=$(cat)
SESSION=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)
case "$SESSION" in ''|*[!A-Za-z0-9-]*) SESSION= ;; esac

if [ "$MODE" = --session-start ]; then
  transcript=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)
  if [ -n "$SESSION" ] && [ "$(cat "$FALLBACK" 2>/dev/null)" != "$SESSION" ] \
    && fm_primary_root_matches "$FM_ROOT" && verified_cli \
    && [ -f "$transcript" ] \
    && head -n 1 "$transcript" | jq -e --arg session "$SESSION" \
      '.type == "session_meta" and .payload.id == $session and .payload.originator == "codex-tui"' >/dev/null 2>&1; then
    export FM_CODEX_PARK_SESSION="$SESSION"
  fi
  printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-sessionstart-run.sh"
  rc=$?
  if [ -n "${FM_CODEX_PARK_SESSION:-}" ] && fm_session_lock_owned_by_self "$STATE"; then
    printf '%s\n%s\n' "$SESSION" "$(cat "$STATE/.lock")" > "$SESSION_FILE.tmp.$$" \
      && mv -f "$SESSION_FILE.tmp.$$" "$SESSION_FILE"
  fi
  exit "$rc"
fi

if [ "$MODE" = --guard ]; then
  if [ -n "$SESSION" ] && capable && [ ! -e "$STATE/.afk" ] \
    && fm_supervision_needed "$STATE"; then
    # Startup grace for the async hook to publish its claim: 50 x 0.2s, about 10s.
    # That is 5x the earlier ~2s grace, under which retained native lab sessions
    # recorded no fallback latch; an observation bound, not a measured
    # hook-start to claim-publication latency.
    for _ in $(seq 50); do
      park_alive && exit 0
      # A queued wake owns the immediate handoff to the next model turn.
      if jq -e --arg session "$SESSION" --argjson now "$(date +%s)" \
        '.session == $session and .outcome == "delivered" and ($now - .at) < 5' \
        "$RECORD" >/dev/null 2>&1; then exit 0; fi
      sleep 0.2
    done
    fallback
    echo 'Codex watcher park failed to establish a live owner. Use the bounded foreground checkpoint protocol for this session; inspect state/.codex-park.json.' >&2
    printf '%s' "$PAYLOAD" | jq -e '.stop_hook_active == true' >/dev/null 2>&1 || exit 2
  elif [ -n "$SESSION" ] && [ "$(cat "$FALLBACK" 2>/dev/null)" = "$SESSION" ]; then
    echo 'Codex watcher park is in foreground fallback after a failure; inspect state/.codex-park.json and resume bounded foreground checkpoints.' >&2
    printf '%s' "$PAYLOAD" | jq -e '.stop_hook_active == true' >/dev/null 2>&1 || exit 2
  fi
  printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh"
  exit $?
fi

[ -n "$SESSION" ] && capable || exit 0
[ ! -e "$STATE/.afk" ] && fm_supervision_needed "$STATE" || exit 0
fm_lock_try_acquire "$CLAIM" || exit 0
OWNED=1
trap cleanup EXIT
trap 'record interrupted; exit 0' HUP INT TERM
ANCHOR=$(cat "$STATE/.lock")
IDENTITY=$(fm_pid_identity "$$") || exit 1
previous=$(jq -r '.outcome // empty' "$RECORD" 2>/dev/null || true)
previous_session=$(jq -r '.session // empty' "$RECORD" 2>/dev/null || true)
# A SIGKILL cannot run EXIT cleanup. The exclusive claim proves no previous
# park is still using these private captures; retain only the small receipt.
rm -f "$STATE"/.codex-park-output.* "$STATE"/.codex-park-delivery.tmp.* "$RECORD".tmp.*
record arming || exit 1
if [ "$previous_session" = "$SESSION" ] \
  && { [ "$previous" = waiting ] || [ "$previous" = arming ] || [ "$previous" = interrupted ]; }; then
  if ! deliver 'Firstmate Codex park recovered a dead or interrupted owner. Drain the durable wake queue and inspect state/.codex-park.json; automatic supervision is restarting.'; then
    record delivery-failed; fallback; exit 1
  fi
fi
OUT=$(mktemp "$STATE/.codex-park-output.XXXXXX") || exit 1
attempt=0
while [ "$attempt" -lt 2 ]; do
  registered && fm_session_lock_owned_by_self "$STATE" || exit 0
  if [ -e "$STATE/.afk" ] || ! fm_supervision_needed "$STATE"; then record idle; exit 0; fi
  arm=("$SCRIPT_DIR/fm-watch-arm.sh")
  if fm_supervision_host_enabled "$CONFIG" codex; then
    arm=("$SCRIPT_DIR/fm-supervision-host.sh" park)
  fi
  # Tracked child, always waited/reaped. The timeout owner also reaps after a
  # SIGKILL of this hook; this is not a detached shell background watcher.
  (export FM_EXEC_TIMED_OWNER_PID=$$ FM_SUPERVISION_HOST_PRIMARY=codex FM_CODEX_MODEL_FREE_PARK=1
    export FM_CODEX_PARK_OWNER_PID=$$ FM_CODEX_PARK_OWNER_IDENTITY=$IDENTITY
    fm_exec_timed 2147483000 5 "${arm[@]}") > "$OUT" 2>&1 &
  CHILD=$!
  record waiting || exit 1
  while fm_pid_alive "$CHILD"; do
    if [ -e "$STATE/.afk" ] || ! fm_session_lock_owned_by_self "$STATE" \
      || ! registered || ! fm_supervision_needed "$STATE"; then
      record idle
      exit 0
    fi
    sleep 1
  done
  wait "$CHILD"; rc=$?
  CHILD=
  if [ "$rc" -eq 0 ] && grep -Eq '^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)' "$OUT"; then
    wake=$(grep -E '^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)' "$OUT")
    if deliver "Firstmate watcher wake: $wake
Run bin/fm-wake-drain.sh first. Handle every presented wake, open decision and unread status, then run its exact WAKE_ACK_REQUIRED command. The next Stop re-arms automatically; do not run a foreground checkpoint."; then
      record delivered
      exit 0
    fi
    record delivery-failed; fallback; exit 1
  fi
  attempt=$((attempt + 1))
  if ! deliver "Firstmate Codex park failed (arm exit $rc, attempt $attempt/2). Drain first and inspect state/.codex-park.json. Automatic recovery retries once; a repeated failure selects the bounded foreground checkpoint protocol."; then
    record delivery-failed; fallback; exit 1
  fi
done
record failed
fallback
exit 1
