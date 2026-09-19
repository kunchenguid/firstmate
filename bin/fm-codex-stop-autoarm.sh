#!/usr/bin/env bash
# Codex native async Stop owner (Codex CLI 0.154.0+).
# Usage: fm-codex-stop-autoarm.sh < Stop-payload.json
#        fm-codex-stop-autoarm.sh --ready <session-id> <turn-id>
#        fm-codex-stop-autoarm.sh --handling
#
# The native async hook owns this process and its tracked watcher child. On a
# durable wake, codex queue targets the originating session, including when
# idle. A quiet cycle renews after one hour, before the hook's two-hour timeout.
# No shell daemon or model-owned background task is involved. --ready is the
# read-only Stop guard proof: a session-bound live callback AND healthy watcher,
# or a successful queue receipt for this exact Stop turn, at most 30 seconds old.
# The per-home lock serializes concurrent Stop firings. The atomic receipt binds
# session, turn, session-lock PID, callback PID/identity, phase and timestamp.
# A failed queue never consumes or acknowledges the durable wake queue.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
LOCK="$STATE/.codex-autoarm.lock"
RECORD="$STATE/.codex-autoarm.json"
FAILURE="$STATE/.codex-autoarm-failure"
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
# Older CLIs may execute async registrations synchronously. Remain inert there;
# read-only health queries must never accept stale native receipts in fallback.
if ! "$SCRIPT_DIR/fm-codex-native-capable.sh"; then
  [ "$#" -eq 0 ] && exit 0
  exit 1
fi

ready() {
  local session=$1 turn=$2 data pid identity phase recorded_turn stamp session_pid session_identity
  data=$(jq -er --arg session "$session" '
    select(.session == $session) |
    [.pid,.identity,.phase,.turn,.time,.session_pid,.session_identity] | @tsv' "$RECORD" 2>/dev/null) || return 1
  IFS=$'\t' read -r pid identity phase recorded_turn stamp session_pid session_identity <<< "$data"
  [ "$session_pid" = "$(cat "$STATE/.lock" 2>/dev/null)" ] || return 1
  fm_harness_pid_alive "$session_pid" || return 1
  [ "$session_identity" = "$(fm_pid_identity "$session_pid")" ] || return 1
  case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$phase" = queued ]; then
    [ "$recorded_turn" = "$turn" ] || return 1
    [ "$(( $(date +%s) - stamp ))" -ge 0 ] && [ "$(( $(date +%s) - stamp ))" -lt 30 ]
    return
  fi
  [ "$phase" = watching ] || return 1
  fm_pid_alive "$pid" || return 1
  [ "$identity" = "$(fm_pid_identity "$pid")" ] || return 1
  [ "$pid" = "$(cat "$LOCK/pid" 2>/dev/null)" ] || return 1
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"
}

if [ "${1:-}" = --handling ] && [ "$#" -eq 1 ]; then
  # The pull guard runs during model handling, when the completed callback has
  # handed off supervision to this live session until its next Stop. Bound that
  # tolerance to one grace window and require an actual successful queue receipt.
  session_pid=$(cat "$STATE/.lock" 2>/dev/null) || exit 1
  fm_harness_pid_alive "$session_pid" || exit 1
  jq -e --arg pid "$session_pid" --arg identity "$(fm_pid_identity "$session_pid")" --argjson now "$(date +%s)" --argjson grace "$GRACE" \
    '.phase == "queued" and .session_pid == $pid and .session_identity == $identity and (.time | type) == "number" and .time <= $now and ($now - .time) < $grace' \
    "$RECORD" >/dev/null 2>&1
  exit $?
fi
if [ "${1:-}" = --ready ] && [ "$#" -eq 3 ]; then
  ready "$2" "$3"
  exit $?
fi
[ "$#" -eq 0 ] || exit 2
PAYLOAD=$(cat) || exit 0
SESSION=$(printf '%s' "$PAYLOAD" | jq -er '.session_id | select(type == "string" and test("^[A-Za-z0-9_-]+$"))') || exit 0
TURN=$(printf '%s' "$PAYLOAD" | jq -er '.turn_id | select(type == "string" and length > 0)') || exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0
[ ! -e "$STATE/.afk" ] || exit 0
fm_supervision_needed "$STATE" "$GRACE" || exit 0
ready "$SESSION" "$TURN" && exit 0
umask 077
# A previous firing may be publishing its queue receipt. Wait for it to release
# the lock, or defer only once it proves an actual live watcher/callback pair.
acquired=0
for _ in $(seq 1 100); do
  if fm_lock_try_acquire "$LOCK"; then acquired=1; break; fi
  ready "$SESSION" "$TURN" && exit 0
  sleep 0.1
done
[ "$acquired" -eq 1 ] || exit 1
OUT=$(mktemp "$STATE/.codex-autoarm-output.XXXXXX") || { fm_lock_release "$LOCK"; exit 1; }
ARM_PID=
cleanup() {
  if [ -n "$ARM_PID" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  rm -f "$OUT"
  fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_session_lock_owned_by_self "$STATE" || exit 0
SESSION_PID=$(cat "$STATE/.lock") || exit 1
IDENTITY=$(fm_pid_identity "$$") || exit 1
SESSION_IDENTITY=$(fm_pid_identity "$SESSION_PID") || exit 1
publish() {
  local temp
  temp=$(mktemp "$STATE/.codex-autoarm-record.XXXXXX") || return 1
  jq -n --arg session "$SESSION" --arg turn "$TURN" --arg phase "$1" \
    --arg pid "$$" --arg identity "$IDENTITY" --arg session_pid "$SESSION_PID" \
    --arg session_identity "$SESSION_IDENTITY" --argjson time "$(date +%s)" \
    '{session:$session,turn:$turn,phase:$phase,pid:$pid,identity:$identity,session_pid:$session_pid,session_identity:$session_identity,time:$time}' \
    > "$temp" && mv "$temp" "$RECORD" && return 0
  rm -f "$temp"
  return 1
}
publish watching || exit 1
# shellcheck source=/dev/null
[ ! -f "$CONFIG/x-mode.env" ] || . "$CONFIG/x-mode.env"
rc=0
# This is a supervised child, never a detached shell daemon. Keep checking the
# session identity even while quiet, so an abruptly killed native session cannot
# orphan its callback and watcher. The EXIT trap owns termination and reaping.
"$SCRIPT_DIR/fm-watch-arm.sh" > "$OUT" 2>&1 &
ARM_PID=$!
deadline=$(( $(date +%s) + 3600 ))
while kill -0 "$ARM_PID" 2>/dev/null; do
  fm_session_lock_owned_by_self "$STATE" || exit 0
  [ ! -e "$STATE/.afk" ] || exit 0
  fm_supervision_needed "$STATE" "$GRACE" || exit 0
  if [ "$(date +%s)" -ge "$deadline" ]; then
    rc=124
    kill -TERM "$ARM_PID" 2>/dev/null || true
    break
  fi
  sleep 1
done
if [ "$rc" -eq 124 ]; then
  wait "$ARM_PID" 2>/dev/null || true
else
  wait "$ARM_PID" || rc=$?
fi
ARM_PID=
fm_session_lock_owned_by_self "$STATE" || exit 0
[ ! -e "$STATE/.afk" ] || exit 0
fm_supervision_needed "$STATE" "$GRACE" || exit 0
message='Firstmate watcher wake: run bin/fm-wake-drain.sh, handle the durable events, and acknowledge using its exact command. The native Codex Stop hook owns the next watcher cycle; do not run manual checkpoints.'
failed=0
if [ "$rc" -eq 124 ]; then
  message='Firstmate watcher lease renewal: drain and handle durable wakes, then end this turn so the native Codex Stop hook renews supervision. Do not run manual checkpoints.'
elif [ "$rc" -ne 0 ] || ! grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT"; then
  failed=1
  message='Firstmate Codex automatic watcher failed. Inspect state/.codex-autoarm.json and the watcher before resuming; drain durable events. Do not treat supervision as healthy.'
fi
# One failure notification per session episode, rather than a queue/Stop loop.
# A successful cycle resets the episode. Every failure still leaves the guard
# unable to prove supervision, so suppression cannot turn it into health.
if [ "$failed" -eq 1 ]; then
  publish failed || exit 1
  [ "$(cat "$FAILURE" 2>/dev/null)" != "$SESSION" ] || exit 1
  printf '%s\n' "$SESSION" > "$FAILURE" || exit 1
else
  rm -f "$FAILURE"
fi
publish delivering || exit 1
if fm_run_timed 20 codex queue --thread "$SESSION" --message "$message" >> "$OUT" 2>&1; then
  fm_session_lock_owned_by_self "$STATE" || exit 0
  publish queued || exit 1
else
  publish failed || true
  printf '%s\n' '{"systemMessage":"Firstmate Codex watcher could not queue its wake; durable events remain pending. Inspect supervision before ending the next turn."}'
  exit 1
fi
