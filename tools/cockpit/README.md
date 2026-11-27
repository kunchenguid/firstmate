# Miko cockpit tooling

Tracked copy of the scripts that refresh the Miko cockpit page.
They moved here from an untracked secondmate data directory so the tooling lives in one repository.
The [cockpit-refresh skill](../../.agents/skills/cockpit-refresh/SKILL.md) owns what every refresh updates and checks and the step order; [VERVERS-REGELS.md](VERVERS-REGELS.md) is its short Dutch pointer.

| File | Purpose |
|------|---------|
| `cockpit-sync.sh`, `cockpit-sync.py` | The shared first step of every refresh on every cockpit: verifies each goal item, builds the captain's list, and checks a built page; `--help` owns flags, environment, JSON shape and page contract. |
| `refresh-cockpit.sh` | One real-status pass; runs `refresh-cockpit.py` beside it. Read-only on GitHub, safe on a short timer. |
| `refresh-cockpit.py` | The refresh itself: lane status files, PR state and production state into the page and `card-data.json`. |
| `kanban-from-wbs.py` | Regenerates the kanban grid from the WBS boxes; `refresh-cockpit.py` calls it. |
| `goal_drive.py` | Renders the shared goal views, captain steps and drive controls from scoped cockpit truth. |

## Paths

Nothing is hard-coded.
Every path comes from the environment.

| Variable | Default | Meaning |
|----------|---------|---------|
| `FM_HOME` | `~/.firstmate` | Firstmate home whose `state/*.status` and `state/*.meta` lane files are read. |
| `COCKPIT_DATA_DIR` | `$FM_HOME/data/miko-all-in-one-lavish` | Directory holding `cockpit-2.html`, `card-data.json` and `.refresh.lock`. |
| `MIKO_WORKTREE` | none, required | A git worktree of the Miko repository with an `origin` remote; the run stops with a message when it is unset. |
| `COCKPIT_OUT` | unset | Write the refreshed page to this file and leave the installed page and `card-data.json` alone. |
| `COCKPIT_GOAL_HOME` | `$FM_HOME` | Firstmate home that owns the goal records. |
| `COCKPIT_SCOREBOARD_CONFIG` | unset | Enable the hourly secondmate scoreboard using an explicit input-path JSON config; `bin/fm-secondmate-scoreboard.py --help` owns its format and limits. |

The scripts find each other through their own location, so the directory can be called from any working directory.
`gh` must be authenticated for the Miko repository, and `tasks-axi` is required by the sync step for any home that has a backlog; Azure DevOps pull requests are read with a signed-in `az`.

## Run

```bash
MIKO_WORKTREE=/path/to/miko tools/cockpit/refresh-cockpit.sh
```

A second run in the same minute changes nothing; `tests/cockpit-tools.test.sh` proves that on a synthetic fixture.

## Doelen: Miko and Geris page hosts

Run the shared drive pass after the page generator has rendered `<h2 id="doelen">` and any project-specific content from the same scoped truth.
The page keeps its existing `mikoSend(event, key)` handler from the Jouw beslissingen forms.
Use `cockpit-sync.py --help` for live truth paths, project selection, captain-waiting audit and required renderings.

```bash
python3 -I tools/cockpit/goal_drive.py --page "$COCKPIT_PAGE" --truth "$COCKPIT_TRUTH"
```

The shared pass fills existing `id="doel-<id>"` containers or adds a card for a goal missing from the host layout.
Let it own the rings and goal lists rather than leaving independently generated copies in the template.
The drive script's `--help` owns its preview flags.
Update that home's Firstmate and any local goal readers before enabling the controls, because old readers do not understand records with switch marks.

### WBS and kanban label slots

Host templates opt in by adding an empty `<span class="fm-goal-item-status" data-fm-goal-item="GOAL_ID/ITEM_ID"></span>` inside each HTML WBS block or kanban card that represents a goal item.
For an SVG WBS box, use an empty `<text>` with the same class and attribute, and set its coordinates so the status text fits on the box's dark background.
See `cockpit-sync.py --help` for which containers qualify and how a linked Kanban card inherits the WBS key.
The drive pass fills missing views with shared boxes or cards instead of guessing a match from titles or delivery-stage text.

### Switch answers

The existing Lavish listener captures the switch as a keyed answer, just like the other cockpit forms.
For a worker-owned cockpit, the host forwards the source and captured result path to main on the existing parent status channel, rather than applying it itself or posting raw result bytes.
Main follows the [drive-goal board-wake procedure](../../.agents/skills/drive-goal/SKILL.md#cockpit-goal-drive-answers); `bin/fm-goal.sh --help` owns the key grammar and apply command.
