#!/bin/bash
# fm-session-start-with-costs.sh - Wrapper around fm-session-start.sh that appends costs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run normal session start and post-process output to add costs
"$SCRIPT_DIR/fm-session-start.sh" | while IFS= read -r line; do
  # Check if line contains a task ID (fm-xxx-xxx pattern)
  if [[ "$line" =~ fm-[a-z0-9-]+ ]]; then
    taskid="${BASH_REMATCH[0]}"
    # Try to append cost if metadata exists
    if [ -f "state/${taskid}.meta" ]; then
      cost=$("$SCRIPT_DIR/fm-format-task-cost.sh" "$taskid" 2>/dev/null || echo "")
      if [ -n "$cost" ]; then
        # Append cost to end of line
        line="${line% } $cost"
      fi
    fi
  fi
  echo "$line"
done
