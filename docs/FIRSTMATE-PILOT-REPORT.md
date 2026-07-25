# FirstMate Phase 2 — Pilot Report

**Programme:** pilot-collections  
**Date:** 2026-07-25T20:09:29+01:00  
**Host:** cerberus

## What was proven (infrastructure)

- Programme + task registry in SQLite (`state/programme.db`)
- Durable task packets under `data/*/packet/`
- Dependency-aware ready queue
- Scheduler dry-run with concurrency/ownership config
- Deliberate failure → repair task factory path
- Ledger + resume without chat history
- Deliberate failure marker removed

## What still requires live workers / app

- Actual Cursor crewmate spawns for each pilot task
- Real gallery Collection create → admin approve → public visible
- Playwright against running DEV server
- no-mistakes + GitHub Actions on a real branch

## Next

Dispatch with:

```bash
bin/fm-brief.sh <id> northscapes-gallery
# fill brief, then:
bin/fm-spawn.sh <id> projects/northscapes-gallery --harness cursor --model auto
bin/fm-phase2-heartbeat.sh beat <id>
```

Do **not** start the full Epic Northscapes programme until these live gates are green on one vertical slice.
