#!/usr/bin/env bash
# Import retained markdown backlog/archive evidence into canonical per-task records.
# Existing legacy files are read only and remain untouched after import.
# Usage: fm-task-import.sh --backlog <path> [--archive <path>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG=
ARCHIVE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --backlog) BACKLOG=${2:-}; shift 2 ;;
    --archive) ARCHIVE=${2:-}; shift 2 ;;
    *) echo "usage: fm-task-import.sh --backlog <path> [--archive <path>]" >&2; exit 2 ;;
  esac
done
[ -f "$BACKLOG" ] && [ ! -L "$BACKLOG" ] || { echo "REFUSED: legacy backlog is not a regular file" >&2; exit 6; }
[ -z "$ARCHIVE" ] || { [ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ]; } || { echo "REFUSED: legacy archive is not a regular file" >&2; exit 6; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-import.XXXXXX") || exit 1
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/current/data" "$tmp/current/state" "$tmp/current/config"
cp "$BACKLOG" "$tmp/current/data/backlog.md" || exit 1
FM_HOME="$tmp/current" FM_DATA_OVERRIDE="$tmp/current/data" FM_STATE_OVERRIDE="$tmp/current/state" \
  FM_CONFIG_OVERRIDE="$tmp/current/config" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json >"$tmp/current.json" || exit $?
python3 "$SCRIPT_DIR/fm-task-record.py" --data "$DATA" import-snapshot --snapshot "$tmp/current.json" || exit $?

if [ -n "$ARCHIVE" ]; then
  mkdir -p "$tmp/archive/data" "$tmp/archive/state" "$tmp/archive/config"
  { printf '## Done\n'; sed '/^## Archived /d' "$ARCHIVE"; } >"$tmp/archive/data/backlog.md" || exit 1
  FM_HOME="$tmp/archive" FM_DATA_OVERRIDE="$tmp/archive/data" FM_STATE_OVERRIDE="$tmp/archive/state" \
    FM_CONFIG_OVERRIDE="$tmp/archive/config" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json >"$tmp/archive.json" || exit $?
  python3 "$SCRIPT_DIR/fm-task-record.py" --data "$DATA" import-snapshot --snapshot "$tmp/archive.json" --archive
fi
