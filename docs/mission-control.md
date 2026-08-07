# Mission control board

`bin/fm-mission-control.sh` renders the fleet's current state into one self-contained dark HTML board that the captain keeps open.
It is a generator, not a server: each run writes one file, and the page reloads itself so a regenerated file appears without a click.

This document covers phase 1, which is read-only.
The script's own header and `--help` own its exact flags, environment variables, paths, and exit codes.

## What phase 1 does

Phase 1 shows state and nothing else.
The board carries no reply, approve, or input controls, integrates with no Lavish review surface, serves over no network, and is wired into no supervision cycle.
Those belong to phase 2 and are firstmate's to add.

The board never shows a completion percentage or an estimated finish time.
Progress judgement is firstmate's, derived from evidence a renderer cannot see, so inventing a number here would be a guess presented as a measurement.
Each active task instead shows its current phase, the age of its task record, and when it last reported, plus one clearly labelled empty slot that phase 2 fills with a firstmate-supplied progress note.

## Sections

- **Waiting on you**, first and most prominent, merges three sources of captain-gated work: captain-held items in this home's backlog, tasks with a recorded PR awaiting a review or merge call, and captain-held decisions inside a registered secondmate's own home.
  That third source matters because a secondmate's decisions live in its backlog and never appear in this home's, so a board built from the local backlog alone would silently drop them.
  Each card names the home it came from when that home is not the main one.
  Bounded or unavailable secondmate registries, omitted homes, and registered homes whose decisions could not be read all mark the waiting status incomplete.
  Credential and login needs are not detected in phase 1 and are not faked.
- **In progress** shows each task with live metadata: its project, kind, current run state, last reported event, task-record age, and the phase-2 progress slot.
- **Recently shipped** lists recent landed backlog items with their PR or report links.
- **Fleet health** lists blocked or failed tasks and items waiting on an unresolved blocker.
- **Allowance** shows the current allowance per provider.
- **Projects** rolls the backlog up per registered project, with each project's delivery posture.
- **Second mates** shows each registered secondmate and its routed state.
  An idle secondmate is healthy and is rendered as such, never as an alarm.

Any source may be absent.
An absent backlog, project registry, secondmate table, or allowance reading renders an explicit unavailable or empty notice that states what is missing, and never a misleading zero.

## Where the data comes from

The board does not parse fleet state itself.
Like `bin/fm-fleet-view.sh` it renders one `bin/fm-fleet-snapshot.sh --json` capture, so current state, backlog roles, captain actionability, and secondmate current state keep exactly one owner.
Paths come from that snapshot's own resolved roots, so the board follows the active home without resolving `FM_HOME` a second time.

Three inputs come from outside the snapshot because the snapshot does not own them:

- `data/projects.md` is the delivery-posture registry that the per-project rollup groups by.
- `quota-axi --json` is the live allowance reading.
  A provider with no readable window is reported with its reason, because a sign-in gap is not an exhausted allowance.
- Each task's `state/<id>.meta` and `state/<id>.status` modification times give task-record age and last-update times, which the snapshot does not expose.
  The metadata file can be replaced when task details change, so its age is not presented as an immutable task start time.

A backlog row may record its project as a bare name or as a full clone path.
Both name the same project, so both fold onto the same rollup row and display as the project name.

Every value that comes from fleet state, the registry, or the allowance reading is HTML-escaped before it reaches the page.

## Serving and refreshing

Firstmate regenerates the board by running the script again; the output is written to a temporary file and renamed into place, so a browser refreshing on its own cadence never reads a half-written page.
The page carries a meta refresh (25 seconds by default, `--refresh` to change it) and shows how long ago it was rendered, so a board whose generator has stopped is visibly stale rather than quietly wrong.

The page is fully self-contained with inline styles and no external requests, so it renders correctly from a local file and over a private network.
Phase 1 does not serve it; how the file is exposed is phase 2's decision.

## Verification

`tests/fm-mission-control.test.sh` renders the board end to end from a fixture home and from captured snapshot payloads, covering present and absent sources, cross-home captain decisions, escaping of hostile prose, project folding, unmeasurable allowance windows, and self-reload.
