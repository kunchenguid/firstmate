#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. An optional --mode records an explicit task delivery-mode override in both
# metadata and data/<task-id>/delivery-mode, preserving the project's yolo posture.
# After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the selected delivery mode).
# Usage: fm-promote.sh <task-id> [--mode <no-mistakes|direct-PR|local-only>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:-}
[ -n "$ID" ] || { echo "error: usage: fm-promote.sh <task-id> [--mode <mode>]" >&2; exit 1; }
case "$ID" in
  *[!A-Za-z0-9._-]*) echo "error: invalid task id '$ID'" >&2; exit 1 ;;
esac
shift
MODE_OVERRIDE=
MODE_OVERRIDE_SET=0
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --mode ] \
    || { echo "error: usage: fm-promote.sh <task-id> [--mode <mode>]" >&2; exit 1; }
  MODE_OVERRIDE=$2
  MODE_OVERRIDE_SET=1
  case "$MODE_OVERRIDE" in
    no-mistakes|direct-PR|local-only) ;;
    *) echo "error: unknown delivery mode '$MODE_OVERRIDE'" >&2; exit 1 ;;
  esac
fi
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
[ -n "$MODE_OVERRIDE" ] || MODE_OVERRIDE=$MODE
[ -n "$MODE_OVERRIDE" ] || MODE_OVERRIDE=direct-PR

if [ "$MODE_OVERRIDE_SET" -eq 1 ]; then
  TASK_DIR="$DATA/$ID"
  MODE_FILE="$TASK_DIR/delivery-mode"
  [ -d "$TASK_DIR" ] && [ ! -L "$TASK_DIR" ] \
    || { echo "error: unsafe task data directory at $TASK_DIR" >&2; exit 1; }
  [ ! -e "$MODE_FILE" ] || { [ -f "$MODE_FILE" ] && [ ! -L "$MODE_FILE" ]; } \
    || { echo "error: unsafe task delivery-mode override at $MODE_FILE" >&2; exit 1; }
  MODE_FILE_TMP="$TASK_DIR/.delivery-mode.tmp.$$"
  printf '%s\n' "$MODE_OVERRIDE" > "$MODE_FILE_TMP"
  mv "$MODE_FILE_TMP" "$MODE_FILE"
fi

TMP="$META.tmp"
grep -v -e '^kind=' -e '^mode=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
echo "mode=$MODE_OVERRIDE" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE_OVERRIDE (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for $MODE_OVERRIDE: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
