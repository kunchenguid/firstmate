#!/usr/bin/env bash
# Reflag a scout task as a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. A vessel is reflagged
# when its registry and contract change while hull and crew stay, which is
# exactly this operation - see docs/vocabulary-collisions.md for why the fleet
# stopped calling it promotion, a word the Agentic Engineering platform owns for
# a canonized law.
#
# Moves the task to deliverable=ship and stage=reflagged in state/<task-id>.meta
# so fm-teardown.sh applies the full ship-task teardown protection again. The
# deprecated kind= alias is dual-written beside them for the migration window
# (bin/fm-task-axis-lib.sh owns both the axes and the alias's derivation).
# Reflagging is the ONLY writer of stage=reflagged, which is what makes the
# lifecycle axis true: before the split this transition was expressed by
# rewriting a deliverable type, so a reflagged ship and a commissioned one were
# indistinguishable.
#
# After reflagging, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so this is where the task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the axis change. Firstmate resolves both at reflag time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Usage: fm-reflag.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-task-axis-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-task-axis-lib.sh"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-reflag.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: reflagging requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: reflagging requires --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

"$FM_ROOT/bin/fm-guard.sh" || true
ID=${POS[0]}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

# A record whose deprecated alias contradicts its axes has an identity nobody can
# read, so reflagging it would decide that identity by luck. Refuse and name the
# disagreement instead; this is a stop-and-investigate result, not an obstacle.
if fm_task_axes_conflict "$META"; then
  echo "error: task $ID records a contradictory identity ($FM_TASK_AXES_CONFLICT); settle it before reflagging" >&2
  exit 1
fi
[ "$(fm_task_deliverable "$META")" = scout ] || {
  echo "error: task $ID is not a scout task (deliverable=scout not in meta)" >&2
  exit 1
}

# Drop the fields this transition replaces, then write the new ones back through
# the ordering-safe path: a task's record doubles as PR identity, and anything
# unrecognized landing after a `pr=` line would invalidate it
# (bin/fm-task-axis-lib.sh explains why that position is a contract).
TMP="$META.tmp"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' -e '^role=' -e '^deliverable=' -e '^stage=' "$META" > "$TMP"
mv "$TMP" "$META"
readarray -t REFLAG_LINES < <(printf 'kind=ship\n'; fm_task_axes_emit ship reflagged; printf 'mode=%s\nyolo=%s\n' "$MODE" "$YOLO")
fm_task_axes_write_before_pr "$META" "${REFLAG_LINES[@]}" || {
  echo "error: task $ID metadata could not be updated" >&2
  exit 1
}

HOME_Q=$(printf '%q' "$FM_HOME")
echo "reflagged $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
