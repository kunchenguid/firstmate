#!/usr/bin/env bash
# Check or apply the ship-done acceptance gate for one task.
# Usage:
#   fm-done-guard.sh check <task-id>
#   fm-done-guard.sh apply <task-id>
# check prints verdict= and reason= and exits 0 when the done is accepted or
# skipped, 1 when it is refused, 2 on usage error. apply does the same check
# and, on refuse, steers the worker once to push and open a PR.
# bin/fm-done-guard-lib.sh owns the acceptance contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-done-guard-lib.sh
. "$SCRIPT_DIR/fm-done-guard-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  echo "usage: fm-done-guard.sh check|apply <task-id>" >&2
  exit 2
}

cmd=${1:-}
id=${2:-}
[ -n "$cmd" ] && [ -n "$id" ] || usage
case "$id" in
  ''|.*|*[!A-Za-z0-9._-]*)
    echo "error: invalid task id" >&2
    exit 2
    ;;
esac
case "$cmd" in
  check|apply) ;;
  *) usage ;;
esac

status="$STATE/$id.status"
fm_done_guard_check "$status"
rc=$?
fm_done_guard_print_check
if [ "$cmd" = apply ] && [ "$rc" -eq 1 ]; then
  line=$(last_status_line "$status")
  fm_done_guard_steer_status "$status" "$line" || true
fi
exit "$rc"
