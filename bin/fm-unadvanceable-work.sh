#!/usr/bin/env bash
# fm-unadvanceable-work.sh - report in-flight work with no recorded way forward.
#
# This detector is read-only. It prints one line for each task satisfying all
# four conditions below and prints nothing when no task satisfies them:
#
#   state=in_flight; live_worker=no; hold=no; blocked_by=no
#
# Missing task metadata means there is no recorded worker. When metadata exists,
# this script delegates current-state classification to fm-crew-state.sh. Only a
# terminal done/failed result proves there is no live worker; unknown, malformed,
# or failed liveness reads count as live and suppress the finding. This makes the
# detector deliberately blind to crashed or unreachable workers whose metadata
# remains but whose liveness cannot be resolved.
#
# Usage: fm-unadvanceable-work.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BACKLOG="$DATA/backlog.md"
CREW_STATE="${FM_CREW_STATE_OVERRIDE:-$SCRIPT_DIR/fm-crew-state.sh}"

listing=$(tasks-axi list --file "$BACKLOG" --state in_flight --limit 10000 \
  --fields blocked_by,held 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'fm-unadvanceable-work: could not read in-flight tasks: %s\n' "$listing" >&2
  exit 1
fi

in_tasks=0
while IFS= read -r line; do
  case "$line" in
    tasks\[*\]\{id,state,kind,repo,title,blocked_by,held\}:)
      in_tasks=1
      ;;
    "  "*)
      [ "$in_tasks" -eq 1 ] || continue
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
      if [ -e "$STATE/$id.meta" ]; then
        crew_line=$("$CREW_STATE" "$id" 2>/dev/null) || crew_line='state: unknown · source: none'
        case "$crew_line" in
          "state: done"*|"state: failed"*)
            ;;
          *)
            continue
            ;;
        esac
      fi
      printf '%s: state=in_flight; live_worker=no; hold=no; blocked_by=no\n' "$id"
      ;;
    *)
      in_tasks=0
      ;;
  esac
done <<EOF
$listing
EOF
