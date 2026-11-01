#!/usr/bin/env bash
# Manually prune bulky scratch from closed tasks after verified teardown.
# Usage: fm-data-prune.sh [--confirm] [<task-id>...]
# No arguments previews all task folders. --confirm deletes the listed files.
# Requires Python 3 and compatible tasks-axi; uses FM_HOME and the standard
# FM_DATA_OVERRIDE and FM_STATE_OVERRIDE paths. No automatic retention exists.
# fm-data-prune.py owns file selection; docs/task-data-lifecycle.md owns lifecycle.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(dirname "$SCRIPT_DIR")}}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIRM=0
TASKS=()
usage() {
  printf '%s\n' 'Usage: fm-data-prune.sh [--confirm] [<task-id>...]' \
    'Default: preview all eligible task folders; --confirm removes bulky scratch.' \
    'Examples: fm-data-prune.sh; fm-data-prune.sh --confirm task-id'
}
die() { printf 'error: %s\n' "$1"; exit 1; }
for arg in "$@"; do
  case "$arg" in
    --help) usage; exit 0 ;;
    --confirm) CONFIRM=1 ;;
    -*|'') printf 'error: unknown argument %s\n' "$arg"; usage; exit 2 ;;
    *[!A-Za-z0-9._-]*|.|..) printf 'error: invalid task id %s\n' "$arg"; exit 2 ;;
    *) TASKS+=("$arg") ;;
  esac
done
command -v python3 >/dev/null 2>&1 || die 'install Python 3 before pruning'
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_tasks_axi_compatible || die "$FM_TASKS_AXI_CHECK_REASON"
[ -d "$DATA" ] || die "data directory is missing: $DATA"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is missing or unsafe: $STATE"
DATA=$(CDPATH='' cd -- "$DATA" && pwd -P)
LOCK=
CONTROL_LOCK=
release_locks() {
  [ -z "$LOCK" ] || fm_lock_release "$LOCK"
  [ -z "$CONTROL_LOCK" ] || fm_lock_release "$CONTROL_LOCK"
}
trap release_locks EXIT
trap 'exit 1' HUP INT TERM
if [ "${#TASKS[@]}" -eq 0 ]; then
  for folder in "$DATA"/*; do
    [ -d "$folder" ] && [ ! -L "$folder" ] || continue
    task=${folder##*/}
    case "$task" in *[!A-Za-z0-9._-]*|.|..) continue ;; esac
    TASKS+=("$task")
  done
fi
printf 'mode: %s\n' "$( [ "$CONFIRM" = 1 ] && printf confirm || printf dry-run )"
if [ "${#TASKS[@]}" -eq 0 ]; then
  printf 'tasks[0]: []\neligible_tasks: 0\n'
  exit 0
fi
printf 'tasks[%s]:\n' "${#TASKS[@]}"
COUNT=0
for task in "${TASKS[@]+"${TASKS[@]}"}"; do
  if [ ! -f "$STATE/$task.prune-safe" ] || [ -L "$STATE/$task.prune-safe" ] \
    || [ -e "$STATE/$task.meta" ] || [ -L "$STATE/$task.meta" ]; then
    printf '  - id: %s\n    skipped: no verified closed teardown or live/held state\n' "$task"
    continue
  fi
  CONTROL_LOCK="$STATE/.control-$task.lock"
  fm_lock_acquire_wait "$CONTROL_LOCK" || die "cannot lock task control $task"
  LOCK=$(fm_meta_lock_path "$STATE/$task.meta") || die 'invalid metadata lock path'
  fm_lock_acquire_wait "$LOCK" || die "cannot lock task $task"
  eligible=1
  for path in "$STATE/$task.meta" "$STATE/$task.backlog-close" "$STATE/$task.control-relaunch"; do
    if [ -e "$path" ] || [ -L "$path" ]; then eligible=0; fi
  done
  receipt="$STATE/$task.prune-safe"
  if [ ! -f "$receipt" ] || [ -L "$receipt" ] || [ "$(cat "$receipt")" != fm-prune-safe-v1 ]; then
    eligible=0
  fi
  if [ "$eligible" = 1 ]; then
    if fm_backlog_row_probe "$DATA" "$task" --include-archived; then
      case "$FM_BACKLOG_ROW_STATE:$FM_BACKLOG_ROW_HOLD_KIND" in
        'done no no:'|'archived no no:') ;;
        *) eligible=0 ;;
      esac
    else
      eligible=0
    fi
  fi
  if [ "$eligible" = 1 ]; then
    python3 "$SCRIPT_DIR/fm-data-prune.py" "$DATA" "$task" "$CONFIRM"
    COUNT=$((COUNT + 1))
  else
    printf '  - id: %s\n    skipped: no verified closed teardown or live/held state\n' "$task"
  fi
  fm_lock_release "$LOCK"
  LOCK=
  fm_lock_release "$CONTROL_LOCK"
  CONTROL_LOCK=
done
printf 'eligible_tasks: %s\n' "$COUNT"
if [ "$CONFIRM" = 0 ]; then
  printf 'help: rerun with --confirm to remove the listed files\n'
fi
