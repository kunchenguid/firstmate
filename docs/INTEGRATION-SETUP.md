# Permanent Main-Screen Cost Integration

## Status: Ready to Deploy

The cost display system is complete. To make costs appear in Claude Code's main screen permanently:

## Step 1: Hook Into Task Display (Claude Code)

Claude Code's task sidebar renders tasks. Add cost display by modifying the task renderer to call:

```bash
bin/fm-format-task-cost.sh <taskid>
```

Each task line becomes:
```
task-name ... duration $cost
```

## Step 2: Hook Into Firstmate Output

Firstmate's session start and supervision output display tasks. Modify formatters to append cost:

**In `bin/fm-session-start.sh` fleet digest:**
```bash
# When displaying active tasks, append cost
for taskid in $(list_active_tasks); do
  cost=$(bin/fm-format-task-cost.sh "$taskid")
  echo "  ✱ $taskid ... ${uptime} ${cost}"
done
```

**In backlog display:**
```bash
# When showing backlog items, append cost
grep '^\- \[' data/backlog.md | while read line; do
  taskid=$(echo "$line" | grep -o 'fm-[a-z0-9-]*' | head -1)
  cost=$(bin/fm-format-task-cost.sh "$taskid" 2>/dev/null || echo "")
  echo "${line} ${cost}"
done
```

## Step 3: Verification

Once integrated, costs will appear automatically:

```bash
# Test display
for taskid in fm-explore-001 fm-implement-001; do
  duration="17m"
  cost=$(bin/fm-format-task-cost.sh "$taskid")
  echo "✱ $taskid ... $duration $cost"
done
```

Expected output:
```
✱ fm-explore-001 ... 17m $2
✱ fm-implement-001 ... 17m $15
```

## Files Ready

- `bin/fm-format-task-cost.sh` — Cost calculator (call this)
- `bin/fm-task-display-with-cost.sh` — Task formatter with cost
- `.agents/skills/fm-cost-display-hook.md` — Hook documentation
- `config/crew-dispatch.json` — Model/cost configuration
- `docs/cost-integration-main-screen.md` — Integration guide

## Integration Checklist

- [ ] Claude Code task sidebar modified to call `fm-format-task-cost.sh`
- [ ] Session start fleet digest shows costs next to duration
- [ ] Backlog display appends costs to task items
- [ ] Supervision output includes cost in task listings
- [ ] Test with live tasks running

## Rollback

If anything breaks, simply remove the cost display calls. No data is modified:

```bash
# Costs are read-only from task metadata
# Removing the display calls has no effect on task state
```

## Costs Are Live Now

Your two test tasks already have costs assigned:
- `fm-explore-001`: $2 (Haiku/low)
- `fm-implement-001`: $15 (Sonnet/high)

They're ready to display in the main screen as soon as the integration is wired.
