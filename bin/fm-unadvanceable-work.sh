#!/usr/bin/env bash
# fm-unadvanceable-work.sh - report in-flight work with no recorded way forward.
#
# This detector is read-only. It prints one line for each task satisfying all
# four conditions below and prints nothing when no task satisfies them:
#
#   state=in_flight; live_worker=no; hold=no; blocked_by=no
#
# Missing task metadata is owned by the contradiction digest's
# backlog-without-meta kind, so this detector does not report a no-meta row.
# When metadata exists, it delegates current-state classification to
# fm-crew-state.sh. Only a terminal done/failed result proves there is no live
# worker; unknown, malformed, or failed liveness reads count as live and
# suppress the finding. This makes the detector deliberately blind to crashed
# or unreachable workers whose metadata remains but whose liveness cannot be
# resolved.
#
# In-flight enumeration comes from the tasks-axi backlog backend, so the
# detector is only an instrument on a home where that backend is available
# (bin/fm-tasks-axi-lib.sh owns the predicate; `config/backlog-backend=manual`
# and an absent or incompatible binary both opt out). Exit status covers
# enumeration, not liveness: 0 means every in-flight task was enumerated and
# checked against the four conditions and stdout is the complete finding set for
# that pass; any non-zero exit means the in-flight set could not be read at all,
# so nothing about strandedness was established.
#
# Silence under exit 0 is therefore narrower than "no unadvanceable work": it
# means none was found among the tasks whose liveness could be read. The
# per-task liveness read fails toward live, as described above - an
# unresolvable, timed-out, or malformed read suppresses the finding rather than
# report one it cannot support - so the blind spot is a crashed or unreachable
# worker whose metadata remains and whose liveness never resolves. A home where
# every candidate reads that way exits 0 silent, and a projector consuming the
# line count reads that as zero stranded. Enumeration failures are loud;
# liveness failures are quiet by design.
#
# Holding that contract takes more than the backend gate, which only covers the
# exec path. The row scan reads fixed field positions and so only enters
# row-reading state on the exact `tasks[N]{id,state,kind,repo,title,blocked_by,
# held}:` header this detector was written against; a listing carrying any other
# shape would otherwise skip every row and exit 0 empty, reporting "could not
# look" as peace. The listing's own leading `count: N` is the cross-check: N is
# the number of rows actually emitted (a bounded listing reports
# `count: N of M total` and still emits N), an empty result carries no bracketed
# header at all, and a parse that reads a different number of rows than tasks-axi
# says it printed is a shape this detector cannot read, so it exits non-zero
# instead of reporting silence. Findings are buffered until that check passes,
# so stdout is either the complete finding set or nothing.
#
# Usage: fm-unadvanceable-work.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BACKLOG="$DATA/backlog.md"
CREW_STATE="${FM_CREW_STATE_OVERRIDE:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

if ! fm_tasks_axi_backend_available "$CONFIG"; then
  printf 'fm-unadvanceable-work: tasks-axi backlog backend is disabled or incompatible\n' >&2
  exit 1
fi

listing=$(tasks-axi list --file "$BACKLOG" --state in_flight --limit 10000 \
  --fields blocked_by,held 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'fm-unadvanceable-work: could not read in-flight tasks: %s\n' "$listing" >&2
  exit 1
fi

count=$(printf '%s\n' "$listing" | sed -n 's/^count: \([0-9][0-9]*\).*/\1/p' | sed -n '1p')
case "$count" in
  ''|*[!0-9]*)
    printf 'fm-unadvanceable-work: could not read in-flight tasks: tasks-axi returned no task count\n' >&2
    exit 1
    ;;
esac

in_tasks=0
rows_seen=0
findings=
while IFS= read -r line; do
  case "$line" in
    tasks\[*\]\{id,state,kind,repo,title,blocked_by,held\}:)
      in_tasks=1
      ;;
    "  "*)
      [ "$in_tasks" -eq 1 ] || continue
      rows_seen=$((rows_seen + 1))
      row=${line#  }
      id=${row%%,*}
      [ -n "$id" ] || continue
      held=${row##*,}
      [ "$held" = no ] || continue
      row_without_held=${row%,*}
      case "$row_without_held" in
        *\")
          blocked_by=${row_without_held##*,\"}
          blocked_by=${blocked_by%\"}
          ;;
        *)
          blocked_by=${row_without_held##*,}
          ;;
      esac
      [ "$blocked_by" = none ] || continue
      [ -e "$STATE/$id.meta" ] || continue
      crew_line=$("$CREW_STATE" "$id" 2>/dev/null) || crew_line='state: unknown · source: none'
      case "$crew_line" in
        "state: done"*|"state: failed"*)
          ;;
        *)
          continue
          ;;
      esac
      findings="$findings$id: state=in_flight; live_worker=no; hold=no; blocked_by=no
"
      ;;
    *)
      in_tasks=0
      ;;
  esac
done <<EOF
$listing
EOF

if [ "$rows_seen" -ne "$count" ]; then
  printf 'fm-unadvanceable-work: could not read in-flight tasks: tasks-axi listed %s row(s) but the row scan parsed %s; this listing shape is not the one the detector reads\n' \
    "$count" "$rows_seen" >&2
  exit 1
fi

[ -z "$findings" ] || printf '%s' "$findings"
