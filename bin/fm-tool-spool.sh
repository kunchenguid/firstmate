#!/usr/bin/env bash
# bin/fm-tool-spool.sh — CLI wrapper for Tool Output Spooling & On-Demand Discovery
# Usage:
#   fm-tool-spool.sh wrap [--max-lines N] [--max-bytes N] -- <command...>
#   fm-tool-spool.sh discover <tool-name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tool-spool-lib.sh
. "$SCRIPT_DIR/fm-tool-spool-lib.sh"

usage() {
  echo "usage: fm-tool-spool.sh wrap [--max-lines N] [--max-bytes N] -- <cmd...>"
  echo "       fm-tool-spool.sh discover <tool-name>"
  echo ""
  echo "Commands:"
  echo "  wrap       Execute command with output spooling protection"
  echo "  discover   Fetch tool help/schema on-demand to avoid upfront prompt bloat"
}

if [ $# -lt 1 ]; then
  usage >&2
  exit 1
fi

ACTION="$1"
shift

case "$ACTION" in
  wrap)
    MAX_LINES=$FM_SPOOL_DEFAULT_MAX_LINES
    MAX_BYTES=$FM_SPOOL_DEFAULT_MAX_BYTES

    while [ $# -gt 0 ]; do
      case "$1" in
        --max-lines)
          MAX_LINES="$2"
          shift 2 ;;
        --max-bytes)
          MAX_BYTES="$2"
          shift 2 ;;
        --)
          shift
          break ;;
        *)
          break ;;
      esac
    done

    if [ $# -lt 1 ]; then
      echo "error: no command provided to wrap" >&2
      exit 1
    fi

    fm_tool_spool_exec "$STATE_DIR" "$MAX_LINES" "$MAX_BYTES" "$@"
    ;;

  discover)
    if [ $# -lt 1 ]; then
      echo "error: tool name required for discover" >&2
      exit 1
    fi
    TOOL="$1"
    fm_tool_discover "$TOOL"
    ;;

  -h|--help)
    usage
    exit 0 ;;

  *)
    usage >&2
    exit 1 ;;
esac
