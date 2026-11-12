#!/usr/bin/env bash
# fm-status-server.sh - opt-in, read-only local status endpoint for this
# FM_HOME.
#
# Usage: fm-status-server.sh [--port <port>] [--interval <seconds>]
#
# Off unless explicitly started: this script has no daemon, no session-start
# hook, and no watcher wiring, so the endpoint exists only for the lifetime of
# this foreground process. Ctrl-C (or killing the process) stops it.
#
# Binds to 127.0.0.1 only, never a routable address, and accepts no argument
# that could change that. It serves two GET routes and refuses everything
# else (404 on any other path, 405 on any non-GET method: no writes, no
# commands):
#   GET /status   one JSON document combining bin/fm-crew-state.sh's live
#                 per-task verdicts (each with a pr_url from
#                 bin/fm-status-pr-url.sh, null when no PR is recorded), the
#                 published state/home-summary.json fleet ledger, and
#                 quota-axi's read-only capacity report.
#   GET /events   the same document as an SSE stream, re-sent every
#                 --interval seconds (default 5) until the client disconnects.
# Every field comes straight from those existing sources, so the endpoint
# never re-derives fleet state and never adds anything of its own. Those
# sources are chosen because none of them embed secrets: no tokens, no
# credentials, no .env values, no brief text, no raw pane/scrollback content.
# See bin/fm_status_server.py for the exact combination logic.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

PORT=8787
INTERVAL=5

while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      PORT=${2:-}
      shift 2
      ;;
    --interval)
      INTERVAL=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$PORT" in
  ''|*[!0-9]*) echo "fm-status-server: --port must be a positive integer" >&2; exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "fm-status-server: --port must be between 1 and 65535" >&2
  exit 2
fi
case "$INTERVAL" in
  ''|*[!0-9.]*) echo "fm-status-server: --interval must be a positive number" >&2; exit 2 ;;
esac

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-status-server: python3 required" >&2
  exit 1
fi

exec "$PY" "$SCRIPT_DIR/fm_status_server.py" \
  --port "$PORT" \
  --interval "$INTERVAL" \
  --fm-root "$FM_ROOT" \
  --fm-home "$FM_HOME" \
  --state-dir "$STATE"
