# Mission control board

`bin/fm-mission-control.sh` renders the fleet's current state into one self-contained HTML board that the captain keeps open.
It is a generator, not a server: each run writes one file, and the page reloads itself so a regenerated file appears without a click.

The board is a calm, light executive summary: a stat strip, the decisions waiting on the captain, a card per project, what landed today, and a quiet strip carrying fleet health and allowance.
It uses monochrome SVG line icons and no emoji.
The script's own header and `--help` own its exact flags, environment variables, paths, and exit codes.

## What the board does

The board shows state and nothing else.
It carries no reply, approve, or input controls, integrates with no Lavish review surface, serves over no network, and is wired into no supervision cycle.
Those belong to phase 2 and are firstmate's to add.

The board never shows a completion percentage or an estimated finish time.
Progress judgement is firstmate's, derived from evidence a renderer cannot see, so inventing a number here would be a guess presented as a measurement.
Each project card instead states only what live state can prove: what is under way, what waits on the captain, and when the project last changed.

## Sections

- **Awaiting your decision**, first and most prominent, merges three sources of captain-gated work: captain-held items in this home's backlog, tasks with a recorded PR awaiting a review or merge call, and captain-held decisions inside a registered secondmate's own home.
  That third source matters because a secondmate's decisions live in its backlog and never appear in this home's, so a board built from the local backlog alone would silently drop them.
  Each row names the home it came from when that home is not the main one.
  Bounded or unavailable secondmate registries, omitted homes, and registered homes whose decisions could not be read all mark the waiting status incomplete.
  Credential and login needs are not detected and are not faked.
- **The stat strip** counts what is awaiting the captain, what is under way, what landed today, and how many project cards the board is showing.
- **Projects** shows one card per registered project, plus a card for each second mate and for any unregistered project that has work under way.
  A task the captain can see running is never invisible just because its project was never registered.
  Each card carries a status pill, a one-line live state, the calls waiting on the captain, and when the project last changed.
  If the backlog is unavailable, a card whose calm state cannot be proved says `Unconfirmed` rather than `Idle`.
- **Shipped today** lists the backlog items that landed on the board's own current date, with their PR or report links.
  Done records without a completion date are excluded from the list and disclosed in the stat tile instead of being silently counted as today.
- **Fleet health** lists blocked or failed tasks, backlog items waiting on an unresolved blocker, and non-decision secondmate work whose own state or blocker linkage says it is held.
  It sits in the closing strip, so anything blocked or failed is also announced in a bar above the primary sections rather than left for the captain to scroll to.
- **Allowance** shows the current allowance per provider.

An idle second mate is healthy and is rendered as such, never as an alarm.

Any source may be absent.
An absent backlog, project registry, secondmate table, or allowance reading renders an explicit unavailable or empty notice that states what is missing, and never a misleading zero.

## Where the data comes from

The board does not parse fleet state itself.
Like `bin/fm-fleet-view.sh` it renders one `bin/fm-fleet-snapshot.sh --json` capture, so current state, backlog roles, captain actionability, and secondmate current state keep exactly one owner.
Paths come from that snapshot's own resolved roots, so the board follows the active home without resolving `FM_HOME` a second time.

Three inputs come from outside the snapshot because the snapshot does not own them:

- `data/projects.md` is the delivery-posture registry that the project cards group by.
- `quota-axi --json` is the live allowance reading.
  A provider with no readable window is reported with its reason, because a sign-in gap is not an exhausted allowance.
- Each project card's last-change time.
  A registered project is dated by its clone's last commit, read with `git log -1`, which survives task teardown as the per-task state-file times do not.
  A second mate is dated by when it last reported, because its own clone can trail the work it advised on, and a plausible but stale time is worse than no time at all.
  Either source can be missing, and a missing source renders as a dash rather than a guess.

Relative wording ("9:05am today", "11:35pm yesterday", "22 Jul") is derived from the render's own current time, which `FM_MISSION_CONTROL_NOW_EPOCH` fixes, so the same snapshot always renders the same page.

Reading a project clone's history is the only thing the board does to a project, and it never writes there.

A backlog row may record its project as a bare name or as a full clone path.
Both name the same project, so both fold onto the same rollup row and display as the project name.

Every value that comes from fleet state, the registry, or the allowance reading is HTML-escaped before it reaches the page.

## Serving and refreshing

Firstmate regenerates the board by running the script again; the output is written to a temporary file and renamed into place, so a browser refreshing on its own cadence never reads a half-written page.
The page carries a meta refresh (25 seconds by default, `--refresh` to change it) and shows how long ago it was rendered, so a board whose generator has stopped is visibly stale rather than quietly wrong.

The page is fully self-contained with inline styles and no external requests, so it renders correctly from a local file and over a private network.
The generator does not serve it; how the file is exposed is phase 2's decision.

## Verification

`tests/fm-mission-control.test.sh` renders the board end to end from a fixture home and from captured snapshot payloads, covering present and absent sources, cross-home captain decisions, escaping of hostile prose, project folding, work outside the registry, blocked work, unmeasurable allowance windows, and self-reload.
It also pins a fixed current time and commits its fixture clones at explicit epochs, so the last-change wording, its three degrade-to-dash paths, and the promise that no clone is written to are all checked against times the test chose.
