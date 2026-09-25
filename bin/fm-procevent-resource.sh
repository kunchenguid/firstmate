#!/usr/bin/env bash
# Thin process-event adapter for bin/fm-resource-guard.sh.
#
# Usage:
#   fm-procevent-resource.sh poll <task-id> --interval <seconds>
#   fm-procevent-resource.sh classify <result-file>
#   fm-procevent-resource.sh terminal <result-file>
#
# Policy, quota reads, record mutation, privacy, and pause semantics remain
# wholly owned by fm-resource-guard.sh. This adapter only gives the generic
# process-event runner its stable built-in classify/terminal surface. A
# `resumed` or `error` result is not terminal: the source stays registered so
# the runner restarts the same one monitor for the reopened or still-guarded
# budget.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

result_status() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist or is unsafe: $file"
  awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$file"
}

case "${1-}" in
  poll)
    shift
    exec "$SCRIPT_DIR/fm-resource-guard.sh" monitor "$@"
    ;;
  classify)
    [ "$#" -eq 2 ] || usage
    case "$(result_status "$2")" in
      pause-required) printf 'pause-required\n' ;;
      awaiting-authority) printf 'awaiting-authority\n' ;;
      resumed) printf 'resumed\n' ;;
      retired) printf 'retired\n' ;;
      error) printf 'error\n' ;;
      *) printf 'unknown\n' ;;
    esac
    ;;
  terminal)
    [ "$#" -eq 2 ] || usage
    case "$(result_status "$2")" in pause-required|awaiting-authority|retired) exit 0 ;; *) exit 1 ;; esac
    ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
