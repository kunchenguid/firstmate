#!/usr/bin/env bash
# fm-fleet-dashboard.sh - generate the Lavish fleet dashboard artifacts.
#
# Usage:
#   fm-fleet-dashboard.sh [--open] [--snapshot-json <path>] [--html <path>] [--markdown <path>] [--pointer <path>|--no-pointer]
#
# Default outputs:
#   .lavish/fleet-dashboard.html
#   .lavish/fleet-dashboard.md
#   data/dashboard.md
#
# The dashboard is generated from fm-fleet-snapshot.sh --json.
# It is a read surface only: ask-tool remains the decision input.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

OPEN=0
SNAPSHOT_JSON=
HTML="$FM_HOME/.lavish/fleet-dashboard.html"
MARKDOWN="$FM_HOME/.lavish/fleet-dashboard.md"
POINTER="$DATA/dashboard.md"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --open)
      OPEN=1
      shift
      ;;
    --snapshot-json)
      [ "$#" -ge 2 ] || { echo "fm-fleet-dashboard: --snapshot-json requires a value" >&2; exit 2; }
      SNAPSHOT_JSON=$2
      shift 2
      ;;
    --snapshot-json=*)
      SNAPSHOT_JSON=${1#--snapshot-json=}
      shift
      ;;
    --html)
      [ "$#" -ge 2 ] || { echo "fm-fleet-dashboard: --html requires a value" >&2; exit 2; }
      HTML=$2
      shift 2
      ;;
    --html=*)
      HTML=${1#--html=}
      shift
      ;;
    --markdown)
      [ "$#" -ge 2 ] || { echo "fm-fleet-dashboard: --markdown requires a value" >&2; exit 2; }
      MARKDOWN=$2
      shift 2
      ;;
    --markdown=*)
      MARKDOWN=${1#--markdown=}
      shift
      ;;
    --pointer)
      [ "$#" -ge 2 ] || { echo "fm-fleet-dashboard: --pointer requires a value" >&2; exit 2; }
      POINTER=$2
      shift 2
      ;;
    --pointer=*)
      POINTER=${1#--pointer=}
      shift
      ;;
    --no-pointer)
      POINTER=
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "fm-fleet-dashboard: python3 not found" >&2; exit 1; }

SNAPSHOT_TMP=
cleanup() {
  [ -z "$SNAPSHOT_TMP" ] || rm -f "$SNAPSHOT_TMP"
}
trap cleanup EXIT

if [ -z "$SNAPSHOT_JSON" ]; then
  SNAPSHOT_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-dashboard.XXXXXX") || exit 1
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$SNAPSHOT_TMP" || exit 1
  SNAPSHOT_JSON=$SNAPSHOT_TMP
fi

args=(--snapshot-json "$SNAPSHOT_JSON" --html "$HTML" --markdown "$MARKDOWN")
[ -z "$POINTER" ] || args+=(--pointer "$POINTER")
"$SCRIPT_DIR/fm-fleet-dashboard.py" "${args[@]}" || exit $?

if [ "$OPEN" -eq 1 ]; then
  command -v lavish-axi >/dev/null 2>&1 || { echo "fm-fleet-dashboard: lavish-axi not found" >&2; exit 1; }
  lavish-axi "$HTML"
fi
