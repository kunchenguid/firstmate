#!/usr/bin/env bash
# Refresh one local observer pane without mutating the observed FirstMate home.
# Usage: fm-dashboard-loop.sh <mode> <target> <interval-seconds>
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:?mode required}
TARGET=${2:-}
INTERVAL=${3:-3}
case "$INTERVAL" in ''|*[!0-9]*|0) echo "error: interval must be a positive integer" >&2; exit 2 ;; esac
OUTPUT=$(mktemp "${TMPDIR:-/tmp}/fm-dashboard.XXXXXX") || exit 1
trap 'rm -f "$OUTPUT"' EXIT HUP INT TERM
printf 'DASHBOARD · %s · read-only\nLoading first snapshot…\n' "$MODE"
while :; do
  "$SCRIPT_DIR/fm-dashboard-view.sh" "$MODE" --target "$TARGET" > "$OUTPUT" 2>&1
  clear 2>/dev/null || printf '\033[H\033[2J'
  cat "$OUTPUT"
  sleep "$INTERVAL"
done
