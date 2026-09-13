#!/usr/bin/env bash
# fm-dispatch-breaker.sh - Operator diagnostic and recovery tool for Firstmate
# dispatch circuit breaker.
#
# Usage:
#   fm-dispatch-breaker.sh status <task-id>
#   fm-dispatch-breaker.sh reset <task-id> [--closed|--half-open]
#   fm-dispatch-breaker.sh check <task-id>
#
# Displays or manages the durable dispatch breaker state ($STATE/<id>.dispatch-breaker).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-dispatch-breaker-lib.sh
. "$SCRIPT_DIR/fm-dispatch-breaker-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-dispatch-breaker.sh status <task-id>
  fm-dispatch-breaker.sh reset <task-id> [--closed|--half-open]
  fm-dispatch-breaker.sh check <task-id>

Options:
  status   Show whether the breaker is closed/open/half-open, failure reason,
           worktree path, and the exact next action.
  reset    Reset an open breaker to half-open (default) or closed to permit retry.
  check    Test if dispatch is allowed; exits 0 if permitted, 1 if open.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

CMD=${1:-}
ID=${2:-}

[ -n "$CMD" ] && [ -n "$ID" ] || { usage >&2; exit 2; }

case "$CMD" in
  status)
    fm_dispatch_breaker_status "$STATE" "$ID"
    ;;
  check)
    fm_dispatch_breaker_check "$STATE" "$ID"
    ;;
  reset)
    target="half-open"
    case "${3:-}" in
      --closed) target="closed" ;;
      --half-open) target="half-open" ;;
      "") target="half-open" ;;
      *) echo "error: unknown reset flag '${3:-}' (expected --closed or --half-open)" >&2; exit 2 ;;
    esac
    fm_dispatch_breaker_reset "$STATE" "$ID" "$target"
    echo "Circuit breaker for task '$ID' reset to '$target'."
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
