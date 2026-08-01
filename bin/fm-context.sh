#!/usr/bin/env bash
# Inspect or self-report one Firstmate session's context usage.
#
# data/captain-shared.md owns the routing rule.
# This executable exposes its mechanical verdict without restating that rule.
# `show` always prints the verdict; `eligible` returns 0 only for an under result
# and 3 for every over, unreadable, or invalid-config result.
# `self-report` writes a short-lived report bound to the current task metadata.
# Firstmate-launched sessions receive FM_CONTEXT_STATE_DIR and
# FM_CONTEXT_TASK_ID so meter-invisible harnesses can run it directly.
#
# Usage:
#   fm-context.sh show <task-id|meta-path>
#   fm-context.sh eligible <task-id|meta-path>
#   fm-context.sh self-report <percent>
#   fm-context.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${FM_CONTEXT_STATE_DIR:-$FM_HOME/state}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-context-lib.sh
. "$SCRIPT_DIR/fm-context-lib.sh"

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
}

resolve_meta() {  # <task-id|meta-path>
  case "$1" in
    */*.meta) printf '%s\n' "$1" ;;
    *.meta) printf '%s/%s\n' "$STATE" "$1" ;;
    *) printf '%s/%s.meta\n' "$STATE" "$1" ;;
  esac
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  show|eligible)
    command=$1
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    meta=$(resolve_meta "$2")
    fm_context_inspect_meta "$meta" "$STATE" "$CONFIG"
    printf '%s\n' "$FM_CONTEXT_RESULT"
    if [ "$command" = eligible ] && [ "$FM_CONTEXT_STATUS" != under ]; then
      exit 3
    fi
    ;;
  self-report)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    [ -n "${FM_CONTEXT_TASK_ID:-}" ] || {
      echo "fm-context: FM_CONTEXT_TASK_ID is not set for this session" >&2
      exit 2
    }
    fm_context_self_report_write "$STATE" "$FM_CONTEXT_TASK_ID" "$2" || {
      echo "fm-context: ${FM_CONTEXT_CEILING_ERROR:-self-report failed}" >&2
      exit 1
    }
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
