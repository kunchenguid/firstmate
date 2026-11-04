#!/usr/bin/env bash
# fm-leave-stopped.sh - record that the captain ordered a task left stopped, so
# its dead endpoint never re-alarms.
#
# Usage:
#   fm-leave-stopped.sh <task-id> mark --reason "<captain's words>"
#   fm-leave-stopped.sh <task-id> clear
#   fm-leave-stopped.sh --help
#
# WHY. A worker that died (a trust prompt it could not answer, a crash to the
# shell) leaves a stable idle pane behind. The watcher reports that once, as it
# should, and then keeps re-reading the same unchanged pane; bounded or not,
# every later report is a repeat of a decision the captain already made when
# the order was "leave it stopped". This marker is that decision, durable and
# readable by the watcher, so the repeat never happens and nothing about the
# worker is touched to achieve it.
#
# WHAT IT DOES. `mark` writes state/<task-id>.stopped atomically:
#   schema=fm-leave-stopped.v1
#   at=<UTC timestamp>
#   reason=<text, one line>
# `clear` removes it.
#
# WHAT THE MARKER MEANS DOWNSTREAM.
#   - bin/fm-watch.sh skips the task's endpoint in its pane path entirely: no
#     capture, no stale classification, no wedge timer, no steering-inbox ring,
#     no declared-wait recheck, in normal and away mode alike. Its status log is
#     still read by the signal path, because a line the task appends is a real
#     state change.
#   - Nothing else changes: the record, worktree, endpoint, and backlog item
#     stay exactly as they were. This is not teardown, not exit, not a hold.
#     bin/fm-teardown.sh removes the marker with the rest of the task's state.
#
# WHAT IT REFUSES.
#   - A task id that is not an exact state/<id>.meta record in this home.
#   - The supervision branch actor (bin/fm-lease-lib.sh's role partition):
#     this is the captain's call relayed by main, never a branch judgment.
#   - A `--reason` that is empty or spans lines.
# A working reading does not refuse `mark`: a dead or dropped-to-shell terminal
# can keep a stale busy footer that bin/fm-crew-state.sh still reads as working,
# and that is exactly the endpoint the captain ordered left alone. `mark` records
# the marker anyway and prints a warning naming the current reading.
#
# It never relaunches, interrupts, exits, trusts, or otherwise drives the
# worker, and it never touches a project.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# The authoritative current-state read behind the working warning
# (crew_absorb_class; FM_CREW_STATE_BIN is its documented seam).
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

die() { echo "error: $*" >&2; exit 2; }

ID=${1:-}
VERB=${2:-}
[ -n "$ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
fm_task_id_creation_valid "$ID" || die "'$ID' is not a valid task id"
case "$ID" in
  fm-*) [ ! -f "$STATE/${ID#fm-}.meta" ] || die "'$ID' is a window label, not a task id; pass the exact task id '${ID#fm-}'" ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory '$STATE' is unavailable"
META="$STATE/$ID.meta"
MARKER="$STATE/$ID.stopped"

REASON=
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason)
      [ "$VERB" = mark ] || die "--reason applies to 'mark' only"
      [ "$#" -ge 2 ] || die "--reason requires a value"
      REASON=$2
      shift 2
      ;;
    --reason=*)
      [ "$VERB" = mark ] || die "--reason applies to 'mark' only"
      REASON=${1#--reason=}
      shift
      ;;
    *) die "unknown argument '$1'" ;;
  esac
done

case "$VERB" in
  mark|clear) ;;
  *) die "unknown verb '$VERB' (expected mark or clear)" ;;
esac

[ -f "$META" ] || die "no task '$ID' in $STATE (fm-leave-stopped resolves an exact task id only)"

case "$VERB" in
  clear)
    fm_lease_forbid_branch "leave-stopped clear (fm-leave-stopped)"
    if [ ! -e "$MARKER" ]; then
      echo "not marked: task $ID was not left stopped (nothing to clear)"
      exit 0
    fi
    rm -f -- "$MARKER" || die "could not remove state/$ID.stopped"
    echo "cleared: task $ID is supervised again (state/$ID.stopped removed)"
    exit 0
    ;;
esac

# --- mark -------------------------------------------------------------------
fm_lease_forbid_branch "leave-stopped mark (fm-leave-stopped)"
[ -n "$REASON" ] || die "mark requires --reason \"<the captain's words>\""
case "$REASON" in
  *$'\n'*|*$'\r'*) die "--reason must be a single line" ;;
esac

if [ "$(crew_absorb_class "$ID")" = working ]; then
  current=$("$FM_CREW_STATE_BIN" "$ID" 2>/dev/null) || true
  echo "warning: task $ID currently reads as working ($current); recording the captain's order anyway - the marker only silences the watcher and never stops, kills, or relaunches the worker" >&2
fi

tmp=$(mktemp "$STATE/.$ID.stopped.XXXXXX") || die "could not create the marker"
{
  printf 'schema=fm-leave-stopped.v1\n'
  printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'reason=%s\n' "$REASON"
} > "$tmp" || { rm -f "$tmp"; die "could not write the marker"; }
mv -f "$tmp" "$MARKER" || { rm -f "$tmp"; die "could not publish state/$ID.stopped"; }
echo "marked: task $ID is left stopped on the captain's order (state/$ID.stopped); its endpoint will not re-alarm until 'fm-leave-stopped.sh $ID clear'"
