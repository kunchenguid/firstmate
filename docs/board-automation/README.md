# Board-driven automation

Turn the "Hadrien FirstMate" Azure Board into the control surface that launches fleet work: the captain drags a card between columns and the right agent starts automatically.
A local bash daemon polls the board (no webhook, no public tunnel), detects column transitions, and spawns crewmates through the normal firstmate machinery.
Firstmate agents should load the agent-only [`board-automation`](../../.agents/skills/board-automation/SKILL.md) checklist before arming, killing, restarting, or supervising the daemon.

Parts:
- `bin/fm-board-daemon.sh` - the poll loop.
- `bin/fm-board-arm.sh` - start / verify / restart the daemon (like `fm-watch-arm.sh`).
- `bin/fm-board-lib.sh` - Azure DevOps REST helpers.
- `docs/board-automation/board-plan-brief.md` and `board-impl-brief.md` - the templated briefs the daemon fills in per work item (a local `data/_templates/board-*-brief.md` copy overrides these when present).

## Columns and what triggers a spawn

`Proposed` -> `Ready to plan` -> `Planned` -> `In Progress` -> `PR` -> `Done`.

The daemon acts only on a **column transition** versus the value it last saw for that card, never on first-sight (see Seeding):

| Transition into...                        | Action                                |
| ----------------------------------------- | ------------------------------------- |
| `Ready to plan`                           | spawn a **planning scout**            |
| `In Progress` (from `Planned`/`Proposed`) | spawn an **implementation ship crew** |
| `Planned`, `PR`, `Done`, `Proposed`       | observed, logged, no spawn            |

The plan scout writes a plan (a scout report plus a work-item comment) and moves the card to `Planned`.
The impl crew implements, tests, opens a PR, links it natively to the work item, and moves the card to `PR`.
`Done` is captain/merge-driven.
Agent-driven column moves only ever land on non-trigger columns (`Planned`, `PR`), so the daemon never re-triggers on its own agents' work.

## Board fields (env-overridable; defaults are the live board)

- Org/project: `https://dev.azure.com/talroo/Product` (`FM_BOARD_ORG_URL`)
- Area path: `Product\Hadrien FirstMate` (`FM_BOARD_AREA_PATH`)
- Column field: `WEF_BABA3EEA87FD424E9CFBCA5DBD7D9953_Kanban.Column` (`FM_BOARD_COLUMN_FIELD`)
- Lane field: `WEF_BABA3EEA87FD424E9CFBCA5DBD7D9953_Kanban.Lane` (`FM_BOARD_LANE_FIELD`)

Board writes use the full-access PAT `ADO_PAT_FULL_ACCESS` from `~/.env`; the daemon sources it at startup and never prints it.
Three of the Committed-state columns (`Planned`/`In Progress`/`PR`) share `System.State=Committed` and are distinguished only by the column field, which is why moves patch that field rather than the state.

## CPU-safety design (a hard requirement)

The daemon must never slow the captain's Mac:
- Poll every `FM_BOARD_POLL_SECS` seconds (default **120**), then `sleep` - no busy-wait.
- Exactly one WIQL board query plus one (chunked) batch detail fetch per cycle, and nothing else on an idle board.
- Each request is one short-lived `curl` parsed by a single `python3` pass.
- The process re-nices itself to +19 (`renice`) and, on Linux, lowers IO priority with `ionice -c 3` (absent on macOS, so skipped there). Idle cost is effectively zero.
- A portable singleton lock (`state/.board-daemon.lock`, the same primitive the watcher uses) means only one instance runs per home; a duplicate self-evicts within one poll.

## Repo resolution (never guess)

To spawn, the daemon must map a card to a fleet project under `projects/`:
1. An explicit `repo:<name>` token in the card's tags or title wins.
2. Otherwise the card's **lane** maps to a project via `config/board-lane-map` (a `Lane Name = project-name` file, `#` comments) merged over a small built-in default (`AI Knowledge Base -> ai-knowledge-base`, `Greenhouse / IT Screener -> greenhouse-auto`).
3. The resolved name must be an actual clone under `projects/`.

If it cannot resolve, the daemon does **not** guess.
It logs an `UNRESOLVED` line once, leaves the card untouched, and retries later, so adding a lane-map entry or a `repo:` tag lets the next cycle pick it up with no re-drag needed.
Copy `docs/examples/board-lane-map` to `config/board-lane-map` and fill in the mappings for your fleet; the file is local (gitignored).

## Guardrails

- **Seeding / no mass-spawn:** on first sight of any card the daemon records its column without spawning.
  A fresh start (or restart, or a newly created card) seeds the whole board silently; only a later *move* triggers work.
  To trigger a freshly created card, drag it (create a transition) rather than creating it in-place in a trigger column.
- **Dedupe:** one agent per card+stage.
  Before spawning it checks for a live in-flight `state/board-<id>-<stage>.meta` and a persisted `state/.board-spawned-<id>-<stage>` marker.
  Remove the marker to allow a re-plan / re-implement of the same card+stage.
- **Concurrency cap:** `FM_BOARD_MAX_INFLIGHT` (default **4**) board tasks in flight; excess transitions are queued (retried next cycle), not dropped.
- **Hourly runaway cap:** `FM_BOARD_MAX_PER_HOUR` (default **12**) spawns per rolling hour; over that, the daemon refuses to spawn until the window rolls off.
- **Observability:** every decision is logged to `state/.board-daemon.log`; each real spawn records the task to `data/backlog.md` and posts a comment on the card so the captain sees it took.

## Config / environment

| Setting | Default | Meaning |
| --- | --- | --- |
| `FM_BOARD_POLL_SECS` | 120 | seconds between cycles |
| `FM_BOARD_MAX_INFLIGHT` | 4 | concurrent board tasks |
| `FM_BOARD_MAX_PER_HOUR` | 12 | rolling-hour spawn cap |
| `FM_BOARD_AUTOSPAWN` | on | `0`/`off` -> detect + log but suppress spawns (transition NOT consumed, so re-enabling acts on it) |
| `FM_BOARD_DRY_RUN` | 0 | `1` -> never spawn or write to Azure; log `[DRY] would ...` and advance markers |
| `FM_BOARD_FIXTURE` | - | read cards from a batch-workitems JSON file instead of Azure (tests) |
| `FM_BOARD_HARNESS` | - | pass an explicit `--harness` to spawns (set this if `config/crew-dispatch.json` exists) |

## Kill switch (how to stop it instantly)

Create `state/.board-daemon.off` and the loop idles (polls nothing, spawns nothing) until you remove the file.
This is the safe stop; the daemon keeps its lock but does no work.
`FM_BOARD_AUTOSPAWN=0` is the softer knob (keep observing, just do not spawn).

## Arm / kill

```sh
bin/fm-board-arm.sh            # start (detached) or verify; one honest status line
bin/fm-board-arm.sh --restart  # home-scoped restart (never a broad pkill)
touch  state/.board-daemon.off # stop acting
rm     state/.board-daemon.off # resume
```

Arming does not by itself make the daemon act if the kill switch is present.
**Default posture: the daemon is not wired into session start or bootstrap - it runs only when the captain explicitly arms it.**
To first observe without spending, arm with `FM_BOARD_AUTOSPAWN=0` (or leave the kill switch on) and watch `state/.board-daemon.log`; then enable when satisfied.

## Manual / test modes

```sh
bin/fm-board-daemon.sh --seed   # seed seen-markers for all current cards, no spawn, exit
bin/fm-board-daemon.sh --once   # run exactly one poll cycle, then exit
FM_BOARD_DRY_RUN=1 FM_BOARD_FIXTURE=/path/cards.json bin/fm-board-daemon.sh --once
```
