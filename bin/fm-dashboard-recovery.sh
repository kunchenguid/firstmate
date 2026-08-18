#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MAX_ATTEMPTS=${FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS:-2}

case "${1:-}" in observe) ;; *) echo "usage: fm-dashboard-recovery.sh observe <task-id>" >&2; exit 2 ;; esac
ID=${2:-}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "fm-dashboard-recovery: invalid task id" >&2; exit 2 ;; esac
case "$MAX_ATTEMPTS" in ''|*[!0-9]*|0) echo "fm-dashboard-recovery: invalid maximum attempts" >&2; exit 2 ;; esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
kind=$(fm_meta_get "$META" kind)
case "$kind" in ship|scout|'') ;; *) exit 0 ;; esac
DIR="$STATE/dashboard-recovery"
if [ -e "$DIR" ] || [ -L "$DIR" ]; then
  [ -d "$DIR" ] && [ ! -L "$DIR" ] || exit 1
else
  (umask 077; mkdir -p "$DIR")
  chmod 700 "$DIR"
fi
LOCK="$DIR/$ID.lock"
fm_lock_acquire_wait "$LOCK"
PREFLIGHT_LOCK=
PREFLIGHT_LOCK_HELD=0
PREFLIGHT_LOCK_OWNER=
RECOVERY_PID=
RECOVERY_OUTPUT=
RECOVERY_MONITOR_WAS_ON=0
RECOVERY_CANCELLED=0
RECOVERY_CHILD_REAPED=0
RECOVERY_CANCEL_GUARD=
RECOVERY_CANCEL_GUARD_DIR=
RECOVERY_CANCEL_LOCK=
RECOVERY_TEST_READY=${FM_DASHBOARD_RECOVERY_TEST_PID_READY:-}
RECOVERY_TEST_CONTINUE=${FM_DASHBOARD_RECOVERY_TEST_PID_CONTINUE:-}
if [ -n "$RECOVERY_TEST_READY" ] || [ -n "$RECOVERY_TEST_CONTINUE" ]; then
  [ "${FM_DASHBOARD_RECOVERY_TESTING:-0}" = 1 ] && [ -n "$RECOVERY_TEST_READY" ] && [ -n "$RECOVERY_TEST_CONTINUE" ] || exit 1
fi
cleanup() {
  if [ -n "$RECOVERY_OUTPUT" ]; then
    rm -f -- "$RECOVERY_OUTPUT" || true
  fi
  if [ "$RECOVERY_CANCELLED" = 1 ] && [ "$RECOVERY_CHILD_REAPED" = 0 ] && [ -n "$RECOVERY_CANCEL_GUARD" ]; then
    recovery_mark_cancelled || true
  elif [ -n "$RECOVERY_CANCEL_GUARD_DIR" ]; then
    [ -z "$RECOVERY_CANCEL_GUARD" ] || rm -f -- "$RECOVERY_CANCEL_GUARD" || true
    rmdir "$RECOVERY_CANCEL_GUARD_DIR" 2>/dev/null || true
  fi
  if recovery_owns_cancel_lock; then
    fm_lock_release "$RECOVERY_CANCEL_LOCK" || true
  fi
  if [ "$PREFLIGHT_LOCK_HELD" = 1 ]; then
    PREFLIGHT_LOCK_HELD=0
    fm_lock_release "$PREFLIGHT_LOCK" || true
  fi
  fm_lock_release "$LOCK" || true
}
recovery_owns_cancel_lock() {
  local owner
  [ -n "$RECOVERY_CANCEL_LOCK" ] || return 1
  owner=$(cat "$RECOVERY_CANCEL_LOCK/pid" 2>/dev/null || true)
  [ "$owner" = "${BASHPID:-$$}" ]
}
recovery_mark_cancelled() {
  local held=0
  [ -n "$RECOVERY_CANCEL_GUARD" ] || return 0
  if recovery_owns_cancel_lock; then
    held=1
  elif [ -n "$RECOVERY_CANCEL_LOCK" ]; then
    fm_lock_acquire_wait "$RECOVERY_CANCEL_LOCK" || return 1
    held=1
  fi
  if ! (umask 077; : > "$RECOVERY_CANCEL_GUARD"); then
    [ "$held" = 0 ] || fm_lock_release "$RECOVERY_CANCEL_LOCK" || true
    return 1
  fi
  [ "$held" = 0 ] || fm_lock_release "$RECOVERY_CANCEL_LOCK" || return 1
}
recovery_signal() {
  local signal=$1 status=$2
  RECOVERY_CANCELLED=1
  if [ -n "$RECOVERY_PID" ]; then
    kill -s "$signal" -- "-$RECOVERY_PID" 2>/dev/null || kill -s "$signal" "$RECOVERY_PID" 2>/dev/null || true
    wait "$RECOVERY_PID" 2>/dev/null || true
    RECOVERY_PID=
    RECOVERY_CHILD_REAPED=1
  fi
  recovery_mark_cancelled || true
  exit "$status"
}
trap cleanup EXIT
trap 'recovery_signal HUP 129' HUP
trap 'recovery_signal INT 130' INT
trap 'recovery_signal TERM 143' TERM
STATE_BIN=${FM_DASHBOARD_RECOVERY_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$STATE_BIN" "$ID" 2>/dev/null || true)
case "$line" in state:\ unknown\ *) ;; *) exit 0 ;; esac
backend=$(fm_backend_of_meta "$META")
target=$(fm_backend_target_of_meta "$META")
[ -n "$target" ] || exit 0
AGENT_STATE_BIN=${FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN:-}
if [ -n "$AGENT_STATE_BIN" ]; then
  agent_state=$("$AGENT_STATE_BIN" "$backend" "$target" 2>/dev/null || true)
else
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)
fi
case "$agent_state" in dead|missing) ;; *) exit 0 ;; esac
PREFLIGHT_FINGERPRINT=$(fm_meta_get "$META" preflight_fingerprint)
preflight_record_validate() {
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-ship-end-to-end.sh" validate "$ID" >/dev/null
}
preflight_lock_acquire_checking() {
  local attempts=0
  while [ "$attempts" -lt 600 ]; do
    preflight_record_validate || return 1
    if fm_lock_try_acquire "$PREFLIGHT_LOCK"; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 0.1
  done
  return 1
}
if [ -n "$PREFLIGHT_FINGERPRINT" ]; then
  PREFLIGHT_LOCK="$DATA/$ID/.ship-preflight.lock"
  preflight_lock_acquire_checking || exit 1
  PREFLIGHT_LOCK_HELD=1
  PREFLIGHT_LOCK_OWNER=${BASHPID:-$$}
  preflight_record_validate || exit 1
fi
preflight_awaiting_approval() {
  local rc=0
  [ -n "$PREFLIGHT_FINGERPRINT" ] || return 1
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-ship-end-to-end.sh" verify-recovery "$ID" --fingerprint "$PREFLIGHT_FINGERPRINT" >/dev/null || rc=$?
  [ "$rc" -eq 4 ]
}
RECORD="$DIR/$ID.json"
attempts=0
prior_state=
reason=
if [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
  IFS=$'\t' read -r prior_state attempts reason < <(jq -r '[.state // "",(.attempts // 0 | tostring),(.reason // "")] | @tsv' "$RECORD" 2>/dev/null || true)
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
fi
if preflight_awaiting_approval; then
  if [ "$prior_state" = unrecoverable ]; then
    attempts=0
    prior_state=pending
    tmp=$(umask 077; mktemp "$DIR/.${ID}.XXXXXX")
    if ! jq -n --arg id "$ID" --arg state pending --arg reason "$reason" --argjson attempts 0 --argjson confirmed_at "$(date +%s)" \
      '{schema_version:1,id:$id,state:$state,attempts:$attempts,confirmed_at:$confirmed_at,reason:$reason}' > "$tmp" \
      || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
      rm -f -- "$tmp"
      exit 1
    fi
  fi
  exit 0
fi
if [ "$prior_state" = unrecoverable ]; then
  exit 0
fi
recovery_at=$(date +%s)
case "$recovery_at" in ''|*[!0-9]*) exit 1 ;; esac
transition_status=0
recovery_claim=$("$SCRIPT_DIR/fm-dashboard-transition.sh" recovery-claim "$STATE" "$ID" "$recovery_at") || transition_status=$?
case "$transition_status" in
  0) ;;
  3) exit 0 ;;
  *) exit "$transition_status" ;;
esac
[ -n "$recovery_claim" ] || exit 1
if [ "$prior_state" = pending ] && [ "$attempts" -eq 0 ] && [ -n "$reason" ]; then
  tmp=$(umask 077; mktemp "$DIR/.${ID}.XXXXXX")
  if ! jq -n --arg id "$ID" --arg state pending --arg reason "$reason" --argjson attempts 0 --argjson confirmed_at "$(date +%s)" \
    '{schema_version:1,id:$id,state:$state,attempts:$attempts,confirmed_at:$confirmed_at,reason:$reason}' > "$tmp" \
    || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    exit 1
  fi
fi
RECOVERY_BIN=${FM_DASHBOARD_RECOVERY_SPAWN_BIN:-$SCRIPT_DIR/fm-spawn.sh}
case "$agent_state" in
  dead) recovery_action=--relaunch ;;
  missing) recovery_action=--recover-missing ;;
esac
RECOVERY_OUTPUT=$(umask 077; mktemp "$DIR/.${ID}.spawn.XXXXXX") || exit 1
RECOVERY_CANCEL_GUARD_DIR=$(umask 077; mktemp -d "$DIR/.${ID}.cancel.XXXXXX") || exit 1
RECOVERY_CANCEL_GUARD="$RECOVERY_CANCEL_GUARD_DIR/cancelled"
RECOVERY_CANCEL_LOCK="$RECOVERY_CANCEL_GUARD_DIR/handoff.lock"
fm_lock_acquire_wait "$RECOVERY_CANCEL_LOCK" || exit 1
case $- in *m*) RECOVERY_MONITOR_WAS_ON=1 ;; esac
set -m
FM_DASHBOARD_RECOVERY_CLAIM="$recovery_claim" FM_DASHBOARD_RECOVERY_PREFLIGHT_LOCK="$PREFLIGHT_LOCK" FM_DASHBOARD_RECOVERY_PREFLIGHT_LOCK_OWNER="$PREFLIGHT_LOCK_OWNER" FM_DASHBOARD_RECOVERY_CANCEL_GUARD="$RECOVERY_CANCEL_GUARD" FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" "$RECOVERY_BIN" "$ID" "$recovery_action" --dashboard-recovery > "$RECOVERY_OUTPUT" 2>&1 &
if [ -n "$RECOVERY_TEST_READY" ]; then
  : > "$RECOVERY_TEST_READY"
  while [ ! -e "$RECOVERY_TEST_CONTINUE" ]; do sleep 0.01; done
fi
RECOVERY_PID=$!
fm_lock_release "$RECOVERY_CANCEL_LOCK" || exit 1
[ "$RECOVERY_MONITOR_WAS_ON" = 1 ] || set +m
wait "$RECOVERY_PID" || recovery_status=$?
RECOVERY_PID=
RECOVERY_CHILD_REAPED=1
out=$(< "$RECOVERY_OUTPUT")
rm -f -- "$RECOVERY_OUTPUT" || exit 1
RECOVERY_OUTPUT=
rmdir "$RECOVERY_CANCEL_GUARD_DIR" || exit 1
RECOVERY_CANCEL_GUARD_DIR=
RECOVERY_CANCEL_GUARD=
RECOVERY_CANCEL_LOCK=
if [ "$PREFLIGHT_LOCK_HELD" = 1 ]; then
  PREFLIGHT_LOCK_HELD=0
  fm_lock_release "$PREFLIGHT_LOCK" || exit 1
fi
recovery_status=${recovery_status:-0}
"$SCRIPT_DIR/fm-dashboard-transition.sh" recovery-claim-clear "$STATE" "$ID" "$recovery_claim" >/dev/null 2>&1 || true
if [ "$recovery_status" -eq 0 ]; then
  rm -f -- "$RECORD"
  exit 0
fi
if [ "$recovery_status" -eq 4 ]; then
  exit 0
fi
if [ "$recovery_status" -eq 3 ]; then
  state=unrecoverable
  attempts=0
  reason=$(printf '%s\n' "$out" | head -1 | tr '\r\n' ' ' | sed 's/[[:space:]]*$//' | cut -c1-240)
  tmp=$(umask 077; mktemp "$DIR/.${ID}.XXXXXX")
  if ! jq -n --arg id "$ID" --arg state "$state" --arg reason "$reason" --argjson attempts "$attempts" --argjson confirmed_at "$(date +%s)" \
    '{schema_version:1,id:$id,state:$state,attempts:$attempts,confirmed_at:$confirmed_at,reason:$reason}' > "$tmp" \
    || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    exit 1
  fi
  exit 0
fi
attempts=$((attempts + 1))
state=pending
[ "$attempts" -lt "$MAX_ATTEMPTS" ] || state=unrecoverable
reason=$(printf '%s\n' "$out" | head -1 | tr '\r\n' ' ' | sed 's/[[:space:]]*$//' | cut -c1-240)
tmp=$(umask 077; mktemp "$DIR/.${ID}.XXXXXX")
if ! jq -n --arg id "$ID" --arg state "$state" --arg reason "$reason" --argjson attempts "$attempts" --argjson confirmed_at "$(date +%s)" \
  '{schema_version:1,id:$id,state:$state,attempts:$attempts,confirmed_at:$confirmed_at,reason:$reason}' > "$tmp" \
  || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
  rm -f -- "$tmp"
  exit 1
fi
