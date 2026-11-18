# Miko cockpit tooling

Tracked copy of the scripts that refresh the Miko cockpit page.
They moved here from an untracked secondmate data directory so the tooling lives in one repository.
[VERVERS-REGELS.md](VERVERS-REGELS.md) states what every refresh updates and checks; it is the rules owner.

| File | Purpose |
|------|---------|
| `refresh-cockpit.sh` | One real-status pass; runs `refresh-cockpit.py` beside it. Read-only on GitHub, safe on a short timer. |
| `refresh-cockpit.py` | The refresh itself: lane status files, PR state and production state into the page and `card-data.json`. |
| `kanban-from-wbs.py` | Regenerates the kanban grid from the WBS boxes; `refresh-cockpit.py` calls it. |

## Paths

Nothing is hard-coded.
Every path comes from the environment.

| Variable | Default | Meaning |
|----------|---------|---------|
| `FM_HOME` | `~/.firstmate` | Firstmate home whose `state/*.status` and `state/*.meta` lane files are read. |
| `COCKPIT_DATA_DIR` | `$FM_HOME/data/miko-all-in-one-lavish` | Directory holding `cockpit-2.html`, `card-data.json` and `.refresh.lock`. |
| `MIKO_WORKTREE` | none, required | A git worktree of the Miko repository with an `origin` remote; the run stops with a message when it is unset. |
| `COCKPIT_OUT` | unset | Write the refreshed page to this file and leave the installed page and `card-data.json` alone. |
| `COCKPIT_SCOREBOARD_CONFIG` | unset | Enable the hourly secondmate scoreboard using an explicit input-path JSON config; `bin/fm-secondmate-scoreboard.py --help` owns its format and limits. |

The scripts find each other through their own location, so the directory can be called from any working directory.
`gh` must be authenticated for the Miko repository, and `tasks-axi` is optional.

## Run

```bash
MIKO_WORKTREE=/path/to/miko tools/cockpit/refresh-cockpit.sh
```

A second run in the same minute changes nothing; `tests/cockpit-tools.test.sh` proves that on a synthetic fixture.
