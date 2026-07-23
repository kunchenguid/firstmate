#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to the recorded delivery mode and fixed-lane contract rendered by
# fm-brief.sh).
# Usage: fm-promote.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

MODE=$(sed -n 's/^mode=//p' "$META")
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "error: task $ID has missing, duplicate, or unsupported recorded mode" >&2; exit 1 ;;
esac
SHIP_CONTRACT=$("$FM_ROOT/bin/fm-brief.sh" --ship-contract "$ID" "$MODE")
HANDOFF=$(cat <<EOF
The scout task is now promoted to a ship task.
Review scratch state with git status and git log.
Return to a clean default-branch base.
Carry over only intended fix changes.
Create branch fm/$ID and implement the authorized change.
Follow the recorded delivery contract below.

$SHIP_CONTRACT
EOF
)

TMP="$META.tmp"
grep -v '^kind=' "$META" > "$TMP"
echo "kind=ship" >> "$TMP"
mv "$TMP" "$META"

HOME_Q=$(printf '%q' "$FM_HOME")
HANDOFF_Q=$(printf '%q' "$HANDOFF")
echo "promoted $ID to ship (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID $HANDOFF_Q"
