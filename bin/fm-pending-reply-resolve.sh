#!/usr/bin/env bash
# fm-pending-reply-resolve.sh - explicitly close one parent-owned pending reply.
#
# Usage:
#   FM_HOME=<parent-home> bin/fm-pending-reply-resolve.sh <corr-id> [reason...]
#
# The command preserves the record as resolved audit evidence and closes the
# exact durable OPEN DECISIONS entry created by its escalation. It never deletes
# or hand-edits unrelated parent state.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; pending-reply resolution requires the explicit parent home" >&2
  exit 1
fi
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing" >&2
  exit 1
fi

corr=${1:-}
if ! printf '%s' "$corr" | grep -Eq '^[A-Fa-f0-9]{16}$'; then
  echo "error: corr-id must be exactly 16 hexadecimal characters" >&2
  exit 2
fi
corr=$(printf '%s' "$corr" | tr 'A-F' 'a-f')
shift
reason=${*:-closed by operator}

# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

rec=$(fm_pending_reply_path "$STATE" "$corr")
if [ ! -f "$rec" ]; then
  echo "error: pending-reply record '$corr' does not exist under $STATE" >&2
  exit 1
fi
task_id=$(fm_pending_reply_get "$rec" task_id)
if ! fm_pending_reply_resolve_manual "$STATE" "$corr" "$reason"; then
  echo "error: could not resolve pending reply $corr" >&2
  exit 1
fi
printf 'resolved pending reply %s for task %s\n' "$corr" "${task_id:-unknown}"
