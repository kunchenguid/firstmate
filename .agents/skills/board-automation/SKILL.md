---
name: board-automation
description: Agent-only operator checklist for the board-driven automation daemon that watches the Hadrien FirstMate Azure board and auto-launches agents when the captain drags a card. Use before arming, killing, restarting, or supervising the board daemon, editing the board lane->project map, or reconciling board-spawned tasks.
user-invocable: false
metadata:
  internal: true
---

# board-automation

Operator checklist for the board-driven automation daemon.
It does not replace the full reference in `docs/board-automation/README.md`; read that for the columns, fields, CPU-safety design, guardrails, and every config knob.
The daemon watches the "Hadrien FirstMate" Azure board and auto-launches agents when the captain drags a card, so the board is the control surface.

## What it is

- `bin/fm-board-daemon.sh` polls the board every `FM_BOARD_POLL_SECS` (default 120s), detects a card's column transition versus the value it last saw, and spawns the right agent through `bin/fm-spawn.sh`.
- `bin/fm-board-arm.sh` starts / verifies / restarts the daemon, modelled on `bin/fm-watch-arm.sh`.
- Two transitions spawn: into "Ready to plan" spawns a planning scout; into "In Progress" from Planned/Proposed spawns an implementation ship crew. Every other column change is observed, not spawned.
- Board-spawned tasks use ids `board-<work-item-id>-<plan|impl>` and are supervised by the normal watcher/afk machinery like any other crewmate.

## Arming and killing

Run the arm helper as the harness's tracked background task, exactly as with the watcher, and trust its single status line (`started` / `healthy` / `FAILED`):

```sh
bin/fm-board-arm.sh            # start (detached) or verify
bin/fm-board-arm.sh --restart  # home-scoped restart; NEVER pkill -f (kills sibling homes)
```

The daemon is deliberately NOT wired into session start or bootstrap: it runs only when the captain explicitly arms it.
The kill switch `state/.board-daemon.off` makes a running daemon idle instantly (polls nothing, spawns nothing) until removed.
To observe without spending, arm with `FM_BOARD_AUTOSPAWN=0` (detect + log, suppress spawns) and watch `state/.board-daemon.log`.

## Guardrails you rely on

These are enforced in the daemon; know them so you can read the log correctly:

- First sight of any card seeds its column marker without spawning, so a start / restart / newly created card never mass-spawns. Only a later move triggers work.
- One agent per card+stage (a live `state/board-<id>-<stage>.meta` or a `state/.board-spawned-<id>-<stage>` marker dedupes). Remove the marker to re-enable a stage.
- Concurrency cap `FM_BOARD_MAX_INFLIGHT` (default 4) and hourly runaway cap `FM_BOARD_MAX_PER_HOUR` (default 12); excess is queued, not dropped.
- Repo resolution never guesses: an `UNRESOLVED` log line means a card's lane has no fleet project. Add a `config/board-lane-map` entry (copy `docs/examples/board-lane-map`) or a `repo:<name>` tag on the card, and the next cycle picks it up.

## Supervising board-spawned tasks

Treat a `board-*` task like any crewmate: read its state with `bin/fm-crew-state.sh`, relay review-ready PRs and scout reports to the captain in plain outcomes, and tear down with `bin/fm-teardown.sh` after the work lands.
A plan scout's deliverable is its report plus a work-item comment; it moves the card to "Planned".
An impl crew opens a PR, links it natively to the work item, and moves the card to "PR".
If `config/crew-dispatch.json` exists, set `FM_BOARD_HARNESS` so the daemon passes an explicit `--harness` (the daemon cannot do natural-language dispatch matching itself).

## The PAT

Board reads/writes use `ADO_PAT_FULL_ACCESS` from `~/.env`; the daemon sources it at startup and never prints it.
A missing PAT surfaces as a board-query failure in the log, not a spawn.
