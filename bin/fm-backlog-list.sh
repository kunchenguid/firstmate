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

Default: omit items whose hold reason starts with "backlog:" and print the
  shared hidden-count hint when any are omitted.
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

fm_backlog_render_title_lines "$FILE" "$MODE" "$LIMIT" status
