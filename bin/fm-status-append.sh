#!/usr/bin/env bash
# Append one task status event under the same lock used by status presentation
# and retirement. This is the worker-facing writer for new launch briefs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

if [ "$#" -ne 2 ]; then
  echo 'usage: fm-status-append.sh <task-id> <one-line-status>' >&2
  exit 2
fi
task=$1
line=$2
case "$task" in ''|.*|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 2 ;; esac
[ "${#task}" -le 160 ] || { echo 'error: invalid task id' >&2; exit 2; }
case "$line" in *$'\n'*|*$'\r'*|'') echo 'error: status must be one nonempty line' >&2; exit 2 ;; esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
fm_wake_status_append "$STATE" "$STATE/$task.status" "$line"
