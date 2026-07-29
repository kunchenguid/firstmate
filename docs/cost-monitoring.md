# Dynamic Cost Monitoring & Model Selection

Firstmate now includes integrated cost monitoring and dynamic model selection based on available budget. This system automatically chooses the most cost-effective model (Haiku → Sonnet → Opus) based on your current quota window.

## Components

### 1. Dispatch Profiles (`config/crew-dispatch.json`)
Defines quota-aware model selection rules:
- **Opus** (most powerful): $25/min — use when you have >200k tokens remaining
- **Sonnet** (balanced): $10/min — default for 75k-200k remaining  
- **Haiku** (fast/cheap): $2/min — use when budget is tight (<50k remaining)

Profiles are matched in order; first match wins. Fallback is Sonnet/medium effort.

### 2. Dynamic Dispatcher (`bin/fm-dispatch-with-cost.sh`)
Wrapper around `fm-spawn.sh` that:
1. Calls `quota-axi` to check remaining budget
2. Matches against dispatch profiles in `config/crew-dispatch.json`
3. Resolves the best model/effort for current quota state
4. Spawns the crewmate with that model

**Usage:**
```bash
bin/fm-dispatch-with-cost.sh <task-id> <repo-name> [--scout]
```

This replaces direct `fm-spawn.sh` calls when you want automatic model selection.

### 3. Cost Formatter (`bin/fm-cost-format.sh`)
Extracts estimated cost per minute from task metadata and formats it for inline display.

**Usage:**
```bash
bin/fm-cost-format.sh <task-id>
# Output: $25/min
```

Can be piped into supervision display to show cost alongside timestamps.

### 4. Cost Dashboard (`.lavish/cost-dashboard.html`)
Real-time visualization showing:
- **Top right**: Current time + total fleet cost/min (like the image you showed)
- **Stats grid**: Active agents, remaining budget, daily burn rate, time to quota limit
- **Crewmates table**: Task name, model, effort, estimated $/min

Open with:
```bash
lavish-axi .lavish/cost-dashboard.html
```

## Integration Points

### In Supervision Output
Add cost display to the main task list (right-side timestamps):
```bash
# Example: show cost next to task time
"fm-bipromo-007 ... 2h $12/min"
```

### In Backlog
Record estimated task cost when adding to queue:
```
- [ ] implement-feature (cost estimate: $15/min for 1-2 hours)
```

### In Dispatch Profiles
Customize thresholds in `config/crew-dispatch.json`:
```json
{
  "name": "custom-profile",
  "match": {
    "budget_remaining_k": {"min": 100, "max": 250},
    "task_type": ["explore"]
  },
  "model": "sonnet",
  "effort": "high"
}
```

## Cost Estimation

Model costs are estimated (not actual billing):
- **Haiku**: 2k tokens/min input, ~500 output/min = $2/min
- **Sonnet**: 10k tokens/min input, ~2000 output/min = $10/min
- **Opus**: 25k tokens/min input, ~5000 output/min = $25/min

Effort multipliers:
- low: 0.8x (fast, surface-level reasoning)
- medium: 1.0x (standard analysis)
- high: 1.5x (deeper investigation)
- xhigh: 2.0x (exhaustive reasoning)

Actual cost depends on your task's input/output characteristics.

## Workflow Example

```bash
# 1. Check current quota
quota-axi --json

# 2. Dispatch task with automatic model selection
bin/fm-dispatch-with-cost.sh fm-task-123 bi-bom-myproject

# 3. Open cost dashboard to monitor fleet spending
lavish-axi .lavish/cost-dashboard.html

# 4. Supervision shows cost in task list
#    fm-task-123 ... 45m $10/min
```

## Configuration

### Default Profiles
Located in `config/crew-dispatch.json`. Edit to adjust thresholds.

### Disable Dynamic Selection
To always use a specific model, set directly in `fm-spawn.sh`:
```bash
fm-spawn.sh <task-id> --model=opus --effort=xhigh
```

### Custom Cost Estimates
Edit `bin/fm-cost-format.sh` to adjust BASE costs per model.

## Monitoring

The dashboard updates every 10 seconds with:
- Current time + total fleet cost/min (top right)
- Remaining quota + burn rate
- Active crewmates with individual costs
- Estimated time to quota limit

No manual updates needed — just keep it open while work runs.

