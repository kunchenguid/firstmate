#!/bin/bash
# fm-format-task-line.sh - Format a single task line with cost appended
# Usage: fm-format-task-line.sh "task-line" [state-dir]

set -euo pipefail

TASK_LINE="${1:-}"
STATE_DIR="${2:-state}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -z "$TASK_LINE" ] && exit 0

# Extract taskid from line
if [[ "$TASK_LINE" =~ fm-[a-z0-9-]+ ]]; then
  TASKID="${BASH_REMATCH[0]}"
  
  # Get cost if metadata exists
  if [ -f "$STATE_DIR/${TASKID}.meta" ]; then
    COST=$("$SCRIPT_DIR/fm-format-task-cost.sh" "$TASKID" 2>/dev/null || echo "")
    if [ -n "$COST" ]; then
      # Append cost to end of line (trim trailing space first)
      TASK_LINE="${TASK_LINE% } $COST"
    fi
  fi
fi

echo "$TASK_LINE"
