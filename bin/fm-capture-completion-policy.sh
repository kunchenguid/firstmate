#!/usr/bin/env bash
# Capture the current registered completion policy on one legacy in-flight ship task.
# Usage: fm-capture-completion-policy.sh <task-id> --if-absent
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-completion-policy-lib.sh
. "$SCRIPT_DIR/fm-completion-policy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

[ "$#" -eq 2 ] && fm_task_id_path_safe "$1" && [ "$2" = --if-absent ] || {
  echo "usage: fm-capture-completion-policy.sh <task-id> --if-absent" >&2
  exit 2
}
ID=$1
META="$STATE/$ID.meta"
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ "$META_LOCK_HELD" = 0 ] || fm_lock_release "$META_LOCK" || true
  [ "$CONTROL_LOCK_HELD" = 0 ] || fm_lock_release "$CONTROL_LOCK" || true
  return "$status"
}
trap cleanup EXIT

fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: task record for $ID is unsafe or missing ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
}
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
fm_backlog_record_present "$META" "task record" "$STATE" || exit 1
[ "$(fm_meta_get "$META" kind)" = ship ] || {
  echo "error: task $ID is not a ship task; nothing was changed" >&2
  exit 1
}
EXISTING=$(fm_meta_get "$META" completion_policy)
[ -z "$EXISTING" ] || {
  echo "error: task $ID already records completion_policy=$EXISTING; nothing was changed" >&2
  exit 1
}
PROJECT=$(fm_meta_get "$META" project)
[ -n "$PROJECT" ] || { echo "error: task $ID records no project; nothing was changed" >&2; exit 1; }
PROJECT_NAME=$(basename "$PROJECT")
POLICY=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$FM_ROOT/bin/fm-project-mode.sh" --completion-policy "$PROJECT_NAME") || exit 1
MODE=$(fm_meta_get "$META" mode)
FORGE=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$FM_ROOT/bin/fm-project-mode.sh" --forge "$PROJECT_NAME") || exit 1
fm_completion_policy_supported "$POLICY" "$MODE" "$PROJECT" "$FORGE" "task $ID policy capture" || exit 1

TMP="$STATE/.$ID.meta.completion-policy.${BASHPID:-$$}"
cat "$META" > "$TMP"
printf 'completion_policy=%s\n' "$POLICY" >> "$TMP"
fm_backlog_atomic_transition publish "$TMP" "$META" "task record" "$STATE" || exit 1
TMP=
printf 'captured: task=%s project=%s completion_policy=%s\n' "$ID" "$PROJECT_NAME" "$POLICY"
