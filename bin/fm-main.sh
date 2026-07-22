#!/usr/bin/env bash
# Launch the captain's MAIN firstmate session with its standing display name.
# Usage: fm-main.sh [extra-harness-args...]
#   The main firstmate is launched by the captain, not by fm-spawn.sh, and a
#   running session cannot rename itself from a script, so the durable way to
#   keep the "FM Main" session name across restarts is to launch through this
#   helper (or an alias to it) instead of a bare harness command.
#   It runs claude from the firstmate repo root (the primary must start there
#   so the tracked .claude/settings.json hooks load; see the harness-adapters
#   skill) and adds the session display name via -n/--name, verified on
#   Claude Code 2.1.217 (2026-07-22). The name flag only sets the display name
#   the Claude phone app shows; it never changes remote-control state.
#   Extra arguments are passed through to claude unchanged.
#   Set FM_MAIN_SESSION_NAME to override the default "FM Main" label.
#   Only claude has a verified session-name flag; a captain running the primary
#   on another harness should launch that harness directly (no name flag to
#   add) until one is verified there.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command -v claude >/dev/null 2>&1 || {
  echo "error: claude not found on PATH; fm-main.sh only knows claude's verified session-name flag" >&2
  exit 1
}

cd "$FM_ROOT"
exec claude --name "${FM_MAIN_SESSION_NAME:-FM Main}" "$@"
