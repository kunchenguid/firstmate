#!/bin/bash
# fm-cost-display.sh - Source this to enhance task display with costs

format_task_with_cost() {
  local line="$1"
  local taskid
  
  if [[ "$line" =~ fm-[a-z0-9-]+ ]]; then
    taskid="${BASH_REMATCH[0]}"
    
    if [ -f "state/${taskid}.meta" ]; then
      local cost
      cost=$(bin/fm-format-task-cost.sh "$taskid" 2>/dev/null || echo "")
      if [ -n "$cost" ]; then
        line="${line% *} $cost"
      fi
    fi
  fi
  
  echo "$line"
}

format_tasks_with_costs() {
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    format_task_with_cost "$line"
  done
}

export -f format_task_with_cost
export -f format_tasks_with_costs
