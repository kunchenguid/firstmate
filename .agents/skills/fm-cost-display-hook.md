---
name: fm-cost-display-hook
description: Hook that injects cost display into task listings
metadata:
  internal: true
  trigger: task-display
  priority: 10
---

# Cost Display Hook for Task Listings

When Firstmate or Claude Code displays tasks, inject cost per agent automatically.

## Integration Points

### 1. Backlog Display
When displaying backlog items, append cost:
```bash
# Original: "- [ ] task-name (status) ... time"
# New:      "- [ ] task-name (status) ... time $15"

for line in $(cat data/backlog.md | grep '^\- \['); do
  taskid=$(echo "$line" | grep -o 'fm-[a-z0-9-]*' | head -1)
  if [ -n "$taskid" ]; then
    cost=$(bin/fm-format-task-cost.sh "$taskid" 2>/dev/null || echo "")
    [ -n "$cost" ] && line="${line% *} $cost"
  fi
  echo "$line"
done
```

### 2. Session Start Output
In `bin/fm-session-start.sh` fleet digest, show costs alongside duration:
```
Working
  ✱ task-id ... 2h $15
  ✱ task-id ... 45m $2
```

### 3. Claude Code Task Sidebar
When Claude Code renders the task list sidebar, each item shows:
```
task-name ... duration $cost
```

## Activation

Add to task display any time a task appears:
1. Extract taskid from display line
2. Call `bin/fm-format-task-cost.sh <taskid>`
3. Append `$X` to the end of the display line

## Configuration

Costs are sourced from:
- `state/<taskid>.meta` — task metadata with model/effort
- `bin/fm-format-task-cost.sh` — cost calculation
- `config/crew-dispatch.json` — base cost rates

## No Changes Required

This hook requires no changes to task storage or metadata.
It purely displays additional information at render time.
