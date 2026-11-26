# Miko cockpit tooling

Tracked copy of the scripts that refresh the Miko cockpit page.
They moved here from an untracked secondmate data directory so the tooling lives in one repository.
[VERVERS-REGELS.md](VERVERS-REGELS.md) states what every refresh updates and checks; it is the rules owner.

| File | Purpose |
|------|---------|
| `refresh-cockpit.sh` | One real-status pass; runs `refresh-cockpit.py` beside it. Read-only on GitHub, safe on a short timer. |
| `refresh-cockpit.py` | The refresh itself: lane status files, PR state and production state into the page and `card-data.json`. |
| `kanban-from-wbs.py` | Regenerates the kanban grid from the WBS boxes; `refresh-cockpit.py` calls it. |
| `goal_drive.py` | Adds goal-drive controls and the drive KPI to an already rendered Doelen section. |

## Paths

Nothing is hard-coded.
Every path comes from the environment.

| Variable | Default | Meaning |
|----------|---------|---------|
| `FM_HOME` | `~/.firstmate` | Firstmate home whose `state/*.status` and `state/*.meta` lane files are read. |
| `COCKPIT_DATA_DIR` | `$FM_HOME/data/miko-all-in-one-lavish` | Directory holding `cockpit-2.html`, `card-data.json` and `.refresh.lock`. |
| `MIKO_WORKTREE` | none, required | A git worktree of the Miko repository with an `origin` remote; the run stops with a message when it is unset. |
| `COCKPIT_OUT` | unset | Write the refreshed page to this file and leave the installed page and `card-data.json` alone. |
| `COCKPIT_GOAL_HOME` | unset | Enable the Doelen drive-state pass with the home that owns the goals shown on this page. |
| `COCKPIT_SCOREBOARD_CONFIG` | unset | Enable the hourly secondmate scoreboard using an explicit input-path JSON config; `bin/fm-secondmate-scoreboard.py --help` owns its format and limits. |

The scripts find each other through their own location, so the directory can be called from any working directory.
`gh` must be authenticated for the Miko repository, and `tasks-axi` is optional.

## Run

```bash
MIKO_WORKTREE=/path/to/miko tools/cockpit/refresh-cockpit.sh
```

A second run in the same minute changes nothing; `tests/cockpit-tools.test.sh` proves that on a synthetic fixture.

## Doelen: Miko and Geris page hosts

Run the shared drive-state pass after the usual page generator has rendered `<h2 id="doelen">` and a container with `id="doel-<id>"` for every goal in that page's home.
The page keeps its existing `mikoSend(event, key)` handler from the Jouw beslissingen forms.
The pass preserves the goal cards, their contents and actions, and refreshes only the drive KPI and switches.

```bash
python3 -I tools/cockpit/goal_drive.py --goal-home "$GOAL_HOME" --page "$COCKPIT_PAGE"
```

Use `--output "$PREVIEW_PAGE"` to leave the installed page untouched.
Set `COCKPIT_GOAL_HOME` instead if the same page is published by `refresh-cockpit.sh`.
Use the goal record owner's home, not the page host's home if they differ.
Update that home's Firstmate and any local goal readers before enabling the controls, because old readers do not understand records with switch marks.

The existing Lavish listener captures the switch as a keyed answer, just like the other cockpit forms.
For a worker-owned cockpit, the host forwards the source and captured result path to main on the existing parent status channel, rather than applying it itself or posting raw result bytes.
Main follows the [drive-goal board-wake procedure](../../.agents/skills/drive-goal/SKILL.md#cockpit-goal-drive-answers); `bin/fm-goal.sh --help` owns the key grammar and apply command.
