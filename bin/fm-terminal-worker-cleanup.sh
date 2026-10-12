#!/usr/bin/env bash
# Stop an opted-in temporary worker before attempting its safe artifact cleanup.
#
# Usage: fm-terminal-worker-cleanup.sh <task-id>
#
# This is the supervision-side composition of the existing control and cleanup
# planes.  It never forces cleanup: exit preserves the endpoint and local copy,
# then fm-teardown.sh decides whether the artifact is safe to remove.  A
# refused or uncertain operation leaves one durable follow-up record naming the
# preserved copy and the action needed to resume it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CLEANUP_DIR="$STATE/terminal-worker-cleanup"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 1 ] || ! fm_task_id_path_safe "$1"; then
  printf 'usage: fm-terminal-worker-cleanup.sh <task-id>\n' >&2
  exit 2
fi
ID=$1
META="$STATE/$ID.meta"
STATUS="$STATE/$ID.status"
REPORT="$CLEANUP_DIR/$ID.pending"
LOCK="$STATE/.terminal-worker-cleanup-$ID.lock"

is_regular() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

meta_value() { # <key> <meta>
  grep "^$1=" "$2" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

clean_field() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200
}

write_followup() { # <phase> <state> <reason> <exit-result> <cleanup-result>
  local phase=$1 state=$2 reason=$3 exit_result=$4 cleanup_result=$5
  local tmp artifact kind backend host
  mkdir -p "$CLEANUP_DIR" || return 1
  [ ! -L "$CLEANUP_DIR" ] || return 1
  artifact=
  kind=
  backend=
  host=
  if is_regular "$META"; then
    artifact=$(meta_value worktree "$META")
    kind=$(meta_value kind "$META")
    backend=$(meta_value backend "$META")
    host=$(meta_value remote_host "$META")
  fi
  tmp=$(umask 077; mktemp "$CLEANUP_DIR/.pending.XXXXXX") || return 1
  {
    printf 'schema=fm-temporary-worker-cleanup.v1\n'
    printf 'task_id=%s\n' "$ID"
    printf 'phase=%s\n' "$(clean_field "$phase")"
    printf 'state=%s\n' "$(clean_field "$state")"
    printf 'kind=%s\n' "$(clean_field "$kind")"
    printf 'backend=%s\n' "$(clean_field "$backend")"
    printf 'remote_host=%s\n' "$(clean_field "$host")"
    printf 'artifact=%s\n' "$(clean_field "$artifact")"
    printf 'follow_up=land the preserved copy or explicitly discard it, then retry cleanup\n'
    printf 'exit_result=%s\n' "$(clean_field "$exit_result")"
    printf 'cleanup_result=%s\n' "$(clean_field "$cleanup_result")"
    printf 'reason=%s\n' "$(clean_field "$reason")"
    printf 'last_attempt_epoch=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$REPORT" || { rm -f -- "$tmp"; return 1; }
}

flag_for_state() { # <state>
  case "$1" in
    done|failed) printf '%s/auto-exit-temporary-workers\n' "$CONFIG" ;;
    blocked) printf '%s/auto-exit-blocked-workers\n' "$CONFIG" ;;
    parked) printf '%s/auto-exit-parked-workers\n' "$CONFIG" ;;
    *) return 1 ;;
  esac
}

# The task is called by the watcher only after a status change, but the option
# gate lives here as well so this executable remains safe to call directly.
if is_regular "$META"; then
  kind=$(meta_value kind "$META")
  [ -n "$kind" ] || kind=ship
  # A secondmate is a persistent worker and owns its own idle lifecycle.
  if [ "$kind" = secondmate ]; then
    exit 0
  fi
  if [ -n "$(meta_value remote_host "$META")" ]; then
    write_followup unsupported unknown "remote temporary-worker control is owned by the remote home" skipped skipped || true
    exit 0
  fi
else
  # A duplicate notification after successful teardown has neither record nor
  # status file and is a no-op.  A status without its metadata is actionable
  # uncertainty and is retained for reconciliation.
  if ! is_regular "$STATUS"; then
    exit 0
  fi
  write_followup uncertain unknown "task metadata is missing; preserve the status evidence and reconcile the task record" skipped skipped || true
  exit 0
fi

STATE_BIN="${FM_TERMINAL_WORKER_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
state_line=''
if ! state_line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA_DIR" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_CREW_STATE_NO_FORGE=1 "$STATE_BIN" "$ID" 2>&1); then
  write_followup uncertain unknown "current worker state could not be read: $(clean_field "$state_line")" skipped skipped || true
  exit 0
fi
current_state=$(printf '%s\n' "$state_line" | sed -n 's/^state: \([^ ]*\).*/\1/p' | head -1)
case "$current_state" in
  done|failed|blocked|parked) ;;
  *)
    write_followup uncertain "${current_state:-unknown}" "current worker state is uncertain; no lifecycle command was sent" skipped skipped || true
    exit 0
    ;;
esac
flag=$(flag_for_state "$current_state" || true)
is_regular "$flag" || exit 0

# The lock makes duplicate watcher notifications and a retry from another
# supervision actor converge on one exit-then-cleanup attempt.
fm_lock_try_acquire "$LOCK" || exit 0
cleanup_lock_held=1
# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup_lock_release() {
  local status=$?
  if [ "${cleanup_lock_held:-0}" -eq 1 ]; then
    cleanup_lock_held=0
    fm_lock_release "$LOCK" || true
  fi
  return "$status"
}
trap cleanup_lock_release EXIT

CONTROL_BIN="${FM_TERMINAL_WORKER_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
TEARDOWN_BIN="${FM_TERMINAL_WORKER_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"
exit_output=''
exit_rc=0
if exit_output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA_DIR" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$CONTROL_BIN" "$ID" exit 2>&1); then
  exit_rc=0
else
  exit_rc=$?
fi
if [ "$exit_rc" -ne 0 ]; then
  write_followup exit-refused "$current_state" "temporary worker was not stopped: $(clean_field "$exit_output")" refused skipped || true
  printf 'terminal-worker-cleanup: %s exit refused; preserved its recorded copy\n' "$ID" >&2
  exit 0
fi

cleanup_output=''
cleanup_rc=0
if cleanup_output=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA_DIR" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$TEARDOWN_BIN" "$ID" 2>&1); then
  cleanup_rc=0
else
  cleanup_rc=$?
fi
case "$cleanup_rc" in
  0|4)
    rm -f -- "$REPORT"
    printf 'terminal-worker-cleanup: %s exited; safe artifact cleanup completed\n' "$ID"
    ;;
  *)
    write_followup cleanup-refused "$current_state" "safe artifact cleanup was refused after exit: $(clean_field "$cleanup_output")" stopped refused || true
    printf 'terminal-worker-cleanup: %s exited; preserved its recorded copy for follow-up\n' "$ID"
    ;;
esac
exit 0
