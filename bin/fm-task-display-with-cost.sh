#!/bin/bash
# fm-task-display-with-cost.sh - Format task display with cost per agent
# Wraps task display to append cost from bin/fm-format-task-cost.sh
# Usage: fm-task-display-with-cost.sh <taskid> [duration]

set -euo pipefail

TASKID="${1:-}"
DURATION="${2:-0m}"

[ -z "$TASKID" ] && exit 0

# Get cost if task metadata exists
COST=""
if [ -f "state/${TASKID}.meta" ]; then
  COST=" $(bin/fm-format-task-cost.sh "$TASKID" 2>/dev/null || echo "")"
fi

# Output: taskid duration $cost
printf "%s %s%s" "$TASKID" "$DURATION" "$COST"
