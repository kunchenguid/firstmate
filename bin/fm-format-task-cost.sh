#!/bin/bash
# fm-format-task-cost.sh - Format cost per agent for display
# Usage: fm-format-task-cost.sh <taskid>
# Output: "$15" (cost for that specific agent only)

set -euo pipefail

TASKID="${1:-}"
[ -z "$TASKID" ] && exit 0

METAFILE="state/${TASKID}.meta"
[ ! -f "$METAFILE" ] && exit 0

# Extract model and effort from metadata
MODEL=$(grep -o 'model=[^ ]*' "$METAFILE" | cut -d= -f2 || echo "sonnet")
EFFORT=$(grep -o 'effort=[^ ]*' "$METAFILE" | cut -d= -f2 || echo "medium")

# Calculate cost per agent
case "$MODEL" in
  opus)   BASE=25 ;;
  sonnet) BASE=10 ;;
  haiku)  BASE=2 ;;
  *)      BASE=10 ;;
esac

case "$EFFORT" in
  low)    MULT=0.8 ;;
  medium) MULT=1.0 ;;
  high)   MULT=1.5 ;;
  xhigh)  MULT=2.0 ;;
  *)      MULT=1.0 ;;
esac

COST=$(echo "$BASE * $MULT" | bc 2>/dev/null | xargs printf "%.0f" || echo "$BASE")

# Output format: "$15" (cost per agent)
printf "\$%s" "$COST"
