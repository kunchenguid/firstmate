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
| `goal_drive.py` | Adds goal-drive controls, the Doelen status ring, and opted-in WBS and kanban labels to an already rendered page. |

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
`gh` must be authenticated for the Miko repository, and `tasks-axi` is required by the sync step for any home that has a backlog; Azure DevOps pull requests are read with a signed-in `az`.

## Run

```bash
MIKO_WORKTREE=/path/to/miko tools/cockpit/refresh-cockpit.sh
```

A second run in the same minute changes nothing; `tests/cockpit-tools.test.sh` proves that on a synthetic fixture.

## Doelen: Miko and Geris page hosts

Run the shared drive-state pass after the usual page generator has rendered `<h2 id="doelen">` and a container with `id="doel-<id>"` for every goal the pass will include.
The page keeps its existing `mikoSend(event, key)` handler from the Jouw beslissingen forms.
The pass preserves the goal cards, their contents and actions, and refreshes the drive KPI, switches, and item statuses.
The Doelen ring shows one segment per nonzero item status and a labeled count for every status.
The ring and item labels use the same palette and the same `fm-goal.sh export` snapshot: green Klaar, blue Bezig, amber Kan starten, grey-blue Wacht, purple Aan jou, and muted Vervallen.
`startable: true` takes precedence over the folded state, so an eligible item marked running without a live task shows as Kan starten.
An open captain item shows as Aan jou; other non-startable open items and blocked items show as Wacht.

```bash
python3 -I tools/cockpit/goal_drive.py --goal-home "$GOAL_HOME" --page "$COCKPIT_PAGE" --truth "$COCKPIT_TRUTH"
```

`--truth` takes the file `cockpit-sync.sh` wrote and makes the ring and labels show its verified statuses instead of the raw marks.
Repeat `--goal-id <id>` to limit the switches, both KPIs, and item labels to selected goals from a shared home (for example, on the Geris cockpit).
Omit `--goal-id` to include every goal in the home.
Use `--output "$PREVIEW_PAGE"` to leave the installed page untouched.
Set `COCKPIT_GOAL_HOME` instead if the same page is published by `refresh-cockpit.sh`.
Use the goal record owner's home, not the page host's home if they differ.
Update that home's Firstmate and any local goal readers before enabling the controls, because old readers do not understand records with switch marks.

### WBS and kanban label slots

Host templates opt in by adding an empty `<span class="fm-goal-item-status" data-fm-goal-item="GOAL_ID/ITEM_ID"></span>` inside each HTML WBS block or kanban card that represents a goal item.
For an SVG WBS box, use an empty `<text>` with the same class and attribute, and set its coordinates so the status text fits on the box's dark background.
In Miko, put the SVG slot inside `#wbs-blok g[data-id]` and the HTML slot inside the corresponding rich `#kanban .kb-card[data-wbs]`; `kanban-from-wbs.py` copies the WBS key onto generated `.kb-mini` cards automatically.
Do not reuse a delivery step ID for the goal/item key unless the two IDs are actually the same; the pass does not infer a mapping from WBS IDs, titles or lane statuses.
Slots without a matching exported item stay empty, and the pass does not change delivery-stage columns.

### Switch answers

The existing Lavish listener captures the switch as a keyed answer, just like the other cockpit forms.
For a worker-owned cockpit, the host forwards the source and captured result path to main on the existing parent status channel, rather than applying it itself or posting raw result bytes.
Main follows the [drive-goal board-wake procedure](../../.agents/skills/drive-goal/SKILL.md#cockpit-goal-drive-answers); `bin/fm-goal.sh --help` owns the key grammar and apply command.
