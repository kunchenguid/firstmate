#!/usr/bin/env bash
# Pavel Telegram getUpdates adapter for the generic process-event runner.
# Usage:
#   fm-procevent-pavel-telegram.sh run <source-id>
#   fm-procevent-pavel-telegram.sh terminal <result-file>
#   fm-procevent-pavel-telegram.sh silent <result-file>
#   fm-procevent-pavel-telegram.sh self-announcing
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

case "${1:-}" in
  run)
    shift
    [ -n "${1:-}" ] || exit 2
    while :; do
      if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-pavel-ops.sh" collect --limit "${FM_PAVEL_COLLECT_LIMIT:-100}" --timeout "${FM_PAVEL_COLLECT_TIMEOUT:-30}" >/dev/null; then
        sleep "${FM_PAVEL_COLLECT_ERROR_SLEEP:-30}"
      fi
    done
    ;;
  terminal)
    exit 1
    ;;
  silent)
    exit 1
    ;;
  self-announcing)
    exit 0
    ;;
  -h|--help|help|'')
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    [ -n "${1:-}" ] && exit 0 || exit 2
    ;;
  *)
    printf 'error: unknown pavel-telegram adapter command: %s\n' "$1" >&2
    exit 2
    ;;
esac
