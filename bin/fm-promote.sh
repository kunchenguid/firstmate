#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the task's risk-selected validation lane).
# Usage: fm-promote.sh <task-id> [--validation <routine|review-only|full>]
#   --validation records the lane selected during promotion risk classification.
#   Without it, a direct-PR or local-only baseline uses routine and a
#   no-mistakes baseline uses full.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:-}
VALIDATION_OVERRIDE=
case "${2:-}" in
  '') ;;
  --validation)
    VALIDATION_OVERRIDE=${3:-}
    [ "$#" -eq 3 ] || { echo "error: usage: fm-promote.sh <task-id> [--validation <routine|review-only|full>]" >&2; exit 1; }
    ;;
  --validation=*)
    VALIDATION_OVERRIDE=${2#--validation=}
    [ "$#" -eq 2 ] || { echo "error: usage: fm-promote.sh <task-id> [--validation <routine|review-only|full>]" >&2; exit 1; }
    ;;
  *)
    echo "error: usage: fm-promote.sh <task-id> [--validation <routine|review-only|full>]" >&2
    exit 1
    ;;
esac
[ -n "$ID" ] || { echo "error: usage: fm-promote.sh <task-id> [--validation <routine|review-only|full>]" >&2; exit 1; }
case "$VALIDATION_OVERRIDE" in
  ''|routine|review-only|full) ;;
  *) echo "error: --validation must be one of routine, review-only, full" >&2; exit 1 ;;
esac
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP="$META.tmp"
MODE=$(sed -n 's/^mode=//p' "$META" | head -1)
if [ -n "$VALIDATION_OVERRIDE" ]; then
  VALIDATION=$VALIDATION_OVERRIDE
else
  case "$MODE" in
    no-mistakes) VALIDATION=full ;;
    *) VALIDATION=routine ;;
  esac
fi
case "$VALIDATION" in
  full) MODE=no-mistakes ;;
  review-only) MODE=direct-PR ;;
  routine) [ "$MODE" = no-mistakes ] && MODE=direct-PR ;;
esac
grep -v -e '^kind=' -e '^mode=' -e '^validation=' "$META" > "$TMP"
{
  echo "mode=$MODE"
  echo "validation=$VALIDATION"
  echo "kind=ship"
} >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=${MODE:-unknown} validation=$VALIDATION (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
