#!/usr/bin/env bash
# fm-park.sh - record that a task is parked on purpose, or lift that record.
#
# A deliberately stopped task keeps whatever status line its worker last wrote,
# and a stopped worker never appends another, so the watcher would recheck that
# line on the declared-wait cadence forever. The park marker is firstmate's own
# record of the decision, kept in state/<id>.parked and never in the worker's
# status file; bin/fm-park-lib.sh owns its format and the read rules.
#
# Usage:
#   fm-park.sh park <task> --reason "<why it is parked>"
#       Write the marker (replacing an earlier one). The task must have a task
#       record (state/<id>.meta). Refuses an empty or multi-line reason.
#   fm-park.sh unpark <task>
#       Remove the marker. Idempotent. The next successful spawn or relaunch of
#       the task does this by itself.
#   fm-park.sh list
#       Print `<task>  <epoch>  <reason>` for every parked task. A malformed
#       marker is printed as an error and the exit status is 3.
# Exit codes: 0 ok, 2 usage or refusal, 3 a malformed marker was found.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-park-lib.sh
. "$SCRIPT_DIR/fm-park-lib.sh"

usage() {
  echo "usage: fm-park.sh park <task> --reason \"<why>\" | unpark <task> | list" >&2
  exit 2
}

CMD=${1:-}
shift 2>/dev/null || true
case "$CMD" in
  park)
    TASK=${1:-}
    shift 2>/dev/null || true
    fm_park_valid_id "$TASK" || usage
    REASON=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) REASON=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    case "$REASON" in
      *$'\n'* | *$'\r'*) echo "fm-park: refusing a multi-line reason" >&2; exit 2 ;;
    esac
    [ -n "${REASON//[[:space:]]/}" ] || { echo "fm-park: --reason is required and must not be empty" >&2; exit 2; }
    case "$REASON" in *[![:print:]]*) echo "fm-park: refusing a non-printable reason" >&2; exit 2 ;; esac
    [ -f "$STATE/$TASK.meta" ] || { echo "fm-park: no task record $STATE/$TASK.meta; nothing to park" >&2; exit 2; }
    target=$(fm_park_path "$STATE" "$TASK")
    if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
      echo "fm-park: refusing to replace $target, which is not a regular file" >&2
      exit 2
    fi
    tmp=$(umask 077 && mktemp "$STATE/.$TASK.parked.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    printf 'parked [at=%s]: %s\n' "$(date +%s)" "$REASON" > "$tmp"
    chmod 0700 "$tmp"
    mv -f -- "$tmp" "$target"
    trap - EXIT
    fm_park_status "$STATE" "$TASK" || { echo "fm-park: wrote a marker that does not read back: $FM_PARK_ERR" >&2; exit 2; }
    echo "parked $TASK: $FM_PARK_REASON"
    ;;
  unpark)
    TASK=${1:-}
    fm_park_valid_id "$TASK" || usage
    fm_park_clear "$STATE" "$TASK" || { echo "fm-park: could not remove the marker for $TASK" >&2; exit 2; }
    echo "unparked $TASK"
    ;;
  list)
    rc=0
    for f in "$STATE"/*.parked; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      id=$(basename "$f" .parked)
      st=0
      fm_park_status "$STATE" "$id" || st=$?
      case "$st" in
        0) printf '%s\t%s\t%s\n' "$id" "$FM_PARK_AT" "$FM_PARK_REASON" ;;
        *) printf '%s\tERROR\t%s\n' "$id" "${FM_PARK_ERR:-unreadable park marker}"; rc=3 ;;
      esac
    done
    exit "$rc"
    ;;
  *) usage ;;
esac
