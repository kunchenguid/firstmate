#!/usr/bin/env bash
# fm-fleet-board.sh - operate the always-on local Firstmate Kanban application.
#
# Usage:
#   fm-fleet-board.sh start   Start or reuse the loopback-only background app.
#   fm-fleet-board.sh open    Start the app and open it in the default browser.
#   fm-fleet-board.sh status  Print the verified process status.
#   fm-fleet-board.sh url     Print the verified local URL.
#   fm-fleet-board.sh stop    Stop only the process that proves its instance id.
#   fm-fleet-board.sh serve   Run in the foreground for supervision or tests.
#
# Environment:
#   FM_HOME                         Operational home projected by the board.
#   FM_FLEET_BOARD_PORT             Fixed loopback port, or 0 for the home's saved port.
#   FM_FLEET_BOARD_CACHE_SECONDS    Snapshot cache lifetime, default 3 seconds.
#   FM_FLEET_BOARD_SNAPSHOT_TIMEOUT Snapshot command timeout, default 18 seconds.
#   FM_FLEET_BOARD_SNAPSHOT_STDOUT_BYTES Maximum snapshot output, default 32 MiB.
#   FM_FLEET_BOARD_SNAPSHOT_STDERR_BYTES Maximum snapshot error output, default 64 KiB.
#
# The application binds only 127.0.0.1, reads fm-fleet-snapshot.sh as its sole
# task source, and routes captain actions through fm-inbox.sh.
# Runtime identity and logs live under state/fleet-board in the selected home.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$SCRIPT_DIR/fleet-board/server.py"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

command -v python3 >/dev/null 2>&1 || {
  printf 'fm-fleet-board: python3 is required\n' >&2
  exit 1
}

case "${1:-}" in
  start)
    exec python3 "$SERVER" --start
    ;;
  open)
    url=$(python3 "$SERVER" --start)
    if command -v open >/dev/null 2>&1; then
      open "$url" || printf 'fm-fleet-board: browser opener failed; use %s\n' "$url" >&2
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$url" || printf 'fm-fleet-board: browser opener failed; use %s\n' "$url" >&2
    fi
    printf '%s\n' "$url"
    ;;
  status)
    exec python3 "$SERVER" --status
    ;;
  url)
    exec python3 "$SERVER" --url
    ;;
  stop)
    exec python3 "$SERVER" --stop
    ;;
  serve)
    exec python3 "$SERVER" --serve --port "${FM_FLEET_BOARD_PORT:-0}"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
