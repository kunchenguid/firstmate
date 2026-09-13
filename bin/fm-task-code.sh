#!/usr/bin/env bash
# Read stored task-code identity and render its bounded display form.
#
# Usage:
#   fm-task-code.sh display <code>
#   fm-task-code.sh resolve <code-or-prefix>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-code-lib.sh
. "$SCRIPT_DIR/fm-task-code-lib.sh"

case "${1:-}" in
  display)
    [ "$#" -eq 2 ] || { echo "usage: fm-task-code.sh display <code>" >&2; exit 2; }
    fm_task_code_visible "$2"
    ;;
  resolve)
    [ "$#" -eq 2 ] || { echo "usage: fm-task-code.sh resolve <code-or-prefix>" >&2; exit 2; }
    STATE=${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME or FM_STATE_OVERRIDE is required}/state}
    meta=$(fm_task_code_meta_for_selector "$2" "$STATE") || {
      echo "error: stored task code '$2' is unknown, ambiguous, or a clipped display value" >&2
      exit 1
    }
    basename "$meta" .meta
    ;;
  *)
    echo "usage: fm-task-code.sh display <code> | resolve <code-or-prefix>" >&2
    exit 2
    ;;
esac
