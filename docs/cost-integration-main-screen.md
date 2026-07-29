# Cost Display Integration: Main Screen

## Overview

Cost per agent is displayed inline in the Claude Code task listing, next to task duration:

```
Working
  ✱ multi-crewmate cost monitoring    17m $2
  ✱ exports bets bet value            12m $15

Completed
  ✱ FS work item investigation        1h $25
```

## Format

Each task shows: `{duration} ${cost}`

- **Duration**: How long the task has been running (existing display)
- **Cost**: $ symbol + estimated cost per agent in that task (new)

## Implementation

### 1. Display Cost for Any Task

```bash
bin/fm-format-task-cost.sh <taskid>
# Output: $15
```

### 2. In Task Listing (CLI)

When displaying tasks, append cost:

```bash
for taskid in $(list_all_tasks); do
  cost=$(bin/fm-format-task-cost.sh "$taskid")
  duration=$(get_task_uptime "$taskid")
  echo "  ✱ $taskid ... $duration $cost"
done
```

### 3. Integration Points

**In Claude Code interface:**
- Task list sidebar
- Backlog view
- Active agents list
- Supervision output

**In Firstmate output:**
- `bin/fm-session-start.sh` fleet digest
- Supervision task listing
- Cost monitoring in real-time wakeups

## Cost Calculation

Cost per agent is calculated from:
1. **Model** (extracted from task metadata)
   - Haiku: $2/min
   - Sonnet: $10/min
   - Opus: $25/min

2. **Effort level** (multiplier)
   - low: 0.8x
   - medium: 1.0x
   - high: 1.5x
   - xhigh: 2.0x

**Formula:** `base_cost * effort_multiplier`

Examples:
- Haiku + low = $1.60
- Sonnet + high = $15
- Opus + xhigh = $50

## Display Examples

| Task | Duration | Cost | Total Estimate |
|------|----------|------|-----------------|
| exploration | 17m | $2 | ~$34 (17m × $2/min) |
| implementation | 2h 30m | $15 | ~$2,250 (150m × $15/min) |
| complex audit | 1h | $25 | ~$1,500 (60m × $25/min) |

## Integration with Dispatch

When a task spawns via `fm-dispatch-with-cost.sh`:

1. Model is selected based on current budget
2. Cost is determined by model + effort
3. Cost is displayed immediately in task listing
4. Cost persists throughout task lifetime

## Configuration

Modify base costs in `bin/fm-format-task-cost.sh`:

```bash
case "$MODEL" in
  opus)   BASE=25 ;;      # Edit here
  sonnet) BASE=10 ;;      # Edit here
  haiku)  BASE=2 ;;       # Edit here
esac
```

## Files

- `bin/fm-format-task-cost.sh` — Cost formatter (callable from any display)
- `config/crew-dispatch.json` — Model selection profiles
- `bin/fm-dispatch-with-cost.sh` — Spawn with dynamic selection
- `docs/cost-monitoring.md` — Full system documentation

## No Separate Dashboard

This approach eliminates the need for a separate cost dashboard. Cost information is integrated directly into the main task listing where you already look for status and duration.
