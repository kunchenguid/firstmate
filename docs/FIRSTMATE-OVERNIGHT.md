# FirstMate overnight autonomous delivery

## Goal

While you sleep, FirstMate on Cerberus keeps scheduling and spawning **Cursor** crewmates (`model=auto`) against the active programme until the queue is drained or something needs a captain decision.

## Start (Cerberus)

```bash
ssh cerberus
cd ~/agentic/firstmate
export FM_HOME=$PWD PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

# Load programme + enable overnight daemon + kick first spawn
scripts/fm-overnight-start.sh --programme overnight-gallery
```

In the OpenCode primary pane, also enter AFK so routine wakes are daemon-handled:

- Run the `/afk` skill, **or**
- Tracked: `bin/fm-afk-start.sh` (do not fire-and-forget with bare `&`)

Then you may disconnect SSH.

## What runs

| Component | Role |
|-----------|------|
| `firstmate-phase2-overnight.service` | Every ~45s: stale recover + `fm-phase2-continue.sh` (schedule/spawn) |
| `firstmate-phase2-eventd.service` | Event queue |
| `firstmate-phase2-watchdog.timer` | Heartbeat recover |
| `fm-watch` / AFK supervise daemon | Existing FirstMate wake path |
| Cursor crewmates | Implement tasks from packets |

## Stop

```bash
systemctl --user stop firstmate-phase2-overnight.service
# or: touch ~/agentic/firstmate/state/.phase2-overnight.stop
bin/fm-afk-return.sh   # when back, if AFK was used
scripts/firstmate-resume.sh
```

## Logs

```bash
tail -f ~/agentic/firstmate/state/.phase2-overnight.log
bin/fm-phase2-status.sh
journalctl --user -u firstmate-phase2-overnight.service -f
```

## Limits (honest)

- Overnight **continues the loaded programme** — it does not invent Epic architecture alone.
- High-risk actions (prod deploy, live Stripe/Gelato, destructive migrate) still need captain approval.
- Product repos need **GitHub Actions** (gallery now has `.github/workflows/ci.yml`) or CI gates stall.
- Keep primary OpenCode **orchestration-only**; do not implement in the primary overnight.
- If Treehouse pool is exhausted/dirty, spawns block until a slot is free.

## Morning checklist

1. `scripts/firstmate-resume.sh`
2. `bin/fm-phase2-status.sh`
3. Review PRs / `data/*/packet/RESULT.md`
4. `bin/fm-afk-return.sh` if still away
5. Unblock any `blocked` / `needs-decision` tasks
