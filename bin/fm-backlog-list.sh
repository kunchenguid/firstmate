#!/usr/bin/env bash
# fm-backlog-list.sh - routine and explicit backlog status listing.
#
# Captain triage vocabulary is do / defer / backlog / kill.
# Items held with a reason that starts with "backlog:" are a hidden category:
# they are omitted from every routine firstmate listing (this command's default
# mode, session-start compact digest, fleet snapshot / fleet view / bearings)
# and appear only when this command is invoked with --backlog (or the broader
# --include-backlog which keeps ordinary rows and shows the hidden ones too).
# Deferred (hold-until / hold-kind future) and parked (hold-kind parked without
# the backlog: reason prefix) remain visible in the routine listing.
#
# This script is the explicit human status view for the hidden category and the
# single owner of the title-line listing filter used when tasks-axi is not the
# renderer. Predicate ownership lives in bin/fm-tasks-axi-lib.sh.
#
# Usage:
#   fm-backlog-list.sh [--file path] [--limit N]
#   fm-backlog-list.sh --backlog [--file path] [--limit N]
#   fm-backlog-list.sh --include-backlog [--file path] [--limit N]
#
# Default mode prints non-backlogged title lines plus a one-line hidden count
# hint when any were omitted. --backlog prints only backlogged title lines.
# --include-backlog prints every title line (no hiding).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DEFAULT_FILE="$DATA/backlog.md"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-backlog-list.sh [--file path] [--limit N]
       fm-backlog-list.sh --backlog [--file path] [--limit N]
       fm-backlog-list.sh --include-backlog [--file path] [--limit N]

List backlog task title lines with the hidden backlog category filtered.

Default: omit items whose hold reason starts with "backlog:", and when any
  were hidden print "N backlogged hidden - use bin/fm-backlog-list.sh --backlog to list".
--backlog: list only those hidden backlogged items.
--include-backlog: list every title line, including backlogged ones.

Deferred and parked holds without the backlog: reason prefix stay in the default listing.
Hold the item with: tasks-axi hold <id> --reason "backlog: <note>" [--kind parked|future|...]
Revive with: tasks-axi unhold <id>
EOF
}

MODE=routine
FILE=$DEFAULT_FILE
LIMIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --backlog)
      [ "$MODE" = routine ] || { echo "fm-backlog-list: --backlog and --include-backlog are mutually exclusive" >&2; exit 2; }
      MODE=backlog
      shift
      ;;
    --include-backlog)
      [ "$MODE" = routine ] || { echo "fm-backlog-list: --backlog and --include-backlog are mutually exclusive" >&2; exit 2; }
      MODE=include
      shift
      ;;
    --file)
      [ $# -ge 2 ] || { echo "fm-backlog-list: --file requires a path" >&2; exit 2; }
      FILE=$2
      shift 2
      ;;
    --limit)
      [ $# -ge 2 ] || { echo "fm-backlog-list: --limit requires a positive integer" >&2; exit 2; }
      case "$2" in
        ''|*[!0-9]*|0)
          echo "fm-backlog-list: --limit requires a positive integer" >&2
          exit 2
          ;;
      esac
      LIMIT=$2
      shift 2
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$FILE" ]; then
  echo "fm-backlog-list: backlog file not found: $FILE" >&2
  exit 1
fi

awk -v mode="$MODE" -v max="$LIMIT" '
  function state_for_heading(line, heading) {
    heading = line
    sub(/^##[[:space:]]+/, "", heading)
    sub(/[[:space:]]+$/, "", heading)
    if (heading == "In flight") return "in_flight"
    if (heading == "Queued") return "queued"
    if (heading == "Done") return "done"
    return ""
  }
  function is_backlogged(line) {
    return line ~ /\(hold:[[:space:]]*backlog:/
  }
  function is_title(line) {
    return line ~ /^[-*][[:space:]]+/
  }
  BEGIN {
    shown = 0
    total_visible = 0
    total_backlogged = 0
    printed_any = 0
  }
  /^##[[:space:]]+/ {
    state = state_for_heading($0)
    if (state != "") {
      pending_heading = $0
      heading_pending = 1
    }
    next
  }
  state != "" && is_title($0) {
    bl = is_backlogged($0)
    if (bl) total_backlogged++
    keep = 0
    if (mode == "backlog") {
      keep = bl
    } else if (mode == "include") {
      keep = 1
    } else {
      keep = !bl
    }
    if (!keep) next
    total_visible++
    if (max > 0 && shown >= max) next
    if (heading_pending) {
      print pending_heading
      heading_pending = 0
      printed_any = 1
    }
    print $0
    shown++
    printed_any = 1
    next
  }
  END {
    if (mode == "backlog") {
      if (total_backlogged == 0) {
        print "(no backlogged items)"
      } else if (max > 0 && total_visible > shown) {
        printf "(shown %d of %d backlogged item title line(s))\n", shown, total_visible
      } else {
        printf "(shown %d backlogged item title line(s))\n", shown
      }
    } else if (mode == "include") {
      if (total_visible == 0) {
        print "(no backlog item title lines found)"
      } else {
        printf "(shown %d of %d backlog item title line(s); includes backlogged)\n", shown, total_visible
        if (max > 0 && total_visible > shown) {
          printf "(truncated %d item(s); increase --limit for a larger listing)\n", total_visible - shown
        }
      }
    } else {
      if (total_visible == 0 && total_backlogged == 0) {
        print "(no backlog item title lines found)"
      } else if (total_visible == 0) {
        print "(no non-backlogged item title lines found)"
      } else {
        printf "(shown %d of %d non-backlogged item title line(s))\n", shown, total_visible
        if (max > 0 && total_visible > shown) {
          printf "(truncated %d item(s); increase --limit for a larger listing)\n", total_visible - shown
        }
      }
      if (total_backlogged > 0) {
        printf "%d backlogged hidden - use bin/fm-backlog-list.sh --backlog to list\n", total_backlogged
      }
    }
  }
' "$FILE"
