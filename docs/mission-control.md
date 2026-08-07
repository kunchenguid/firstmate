# Mission control board

`bin/fm-mission-control.sh` renders the fleet's current state into one self-contained HTML board that the captain keeps open.
It is a generator, not a server: each run writes one file, and the page reloads itself so a regenerated file appears without a click.

The board is a calm, light executive summary: a stat strip, the decisions waiting on the captain, a card per project, what landed today, and a quiet strip carrying fleet health and allowance.
It uses monochrome SVG line icons and no emoji.
The script's own header and `--help` own its exact flags, environment variables, paths, and exit codes, including the two commands that set a decision aside and bring it back.

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
- **Deferred** is the quiet shelf under that list, closed by default, holding the decisions the captain has consciously set aside.
  A deferred decision is excluded from the waiting list, from the section count, and from the "Awaiting you" tile, because reducing what is in the captain's eyeline is the entire point of setting one aside.
  It keeps the title, the home or project it belongs to, and the reason that identifies it, so it is still there when the captain looks.
  A second mate reports its queued rows bounded, so a shelf that is on screen says when a decision set aside there could fall outside that window rather than implying its list is complete.
  A bound alone never puts the shelf on screen: with nothing set aside to show, the board says nothing about deferred work instead of standing an empty panel over every busy second mate.
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

## Navigation

The board is one page, not one scroll.
The header, the stat strip, and the red attention bar are always in view, because "is anything on fire, and how much awaits me" must never be a click away.
Everything below them is grouped behind four tabs: Decisions (the waiting list and the Deferred shelf), Projects, Activity (what shipped today), and System (fleet health and allowance).
The board opens on Decisions.

The tabs are keyboard-reachable, carry the tab and tabpanel roles with their selected state, and move with the arrow, Home, and End keys.
With no script the tab strip is hidden and every section stays visible, so the board degrades to the single scrolling page it was before rather than hiding its content behind controls that cannot work.

The self-reload navigates without the URL fragment, so a fragment cannot be what carries the selected tab across a reload; the tab is remembered in the browser instead and restored before the page paints, so it neither resets nor flashes the default panel every 25 seconds.
A `#tab=<name>` fragment still selects a tab on the first load, which is what a hand-typed or copied link uses.
A browser that refuses storage - a private context, or a restricted `file://` origin - simply opens on Decisions each time.

The Deferred shelf is held to the same bar, because a shelf that snapped shut every 25 seconds would be the same jarring reset in a smaller place.
It is closed for a captain who never opens it, stays open for one who does, and stays closed again once they close it.

## Deferring a decision

The board stays read-only; `bin/fm-mission-control.sh --help` owns the exact commands for setting a decision aside and bringing it back, including the reason-preservation hazard.

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

`tests/fm-mission-control.test.sh` renders the board end to end from a fixture home and from captured snapshot payloads, covering present and absent sources, cross-home captain decisions, escaping of hostile prose, project folding, work outside the registry, blocked work, unmeasurable allowance windows, self-reload, the tab structure, and the deferred shelf.
The deferred cases pin the awaiting count and the section count to literal numbers rather than to the absence of a title, because dropping a decision from the list while still counting it and counting it while still listing it fail separately.
It also pins a fixed current time and commits its fixture clones at explicit epochs, so the last-change wording, its three degrade-to-dash paths, and the promise that no clone is written to are all checked against times the test chose.

`tests/fm-fleet-snapshot-view.test.sh` pins the deferred classification itself: a parked hold on work that is not a captain decision is ordinary held work, a captain decision that still has an unresolved blocker stays blocked rather than deferred, and a deferred decision never reaches the secondmate home summary's holds.

That a tab survives the board's own reload cannot be shown by a shell test, so it is checked in a real browser and the before and after boards are captured in [`docs/evidence/mission-control/`](evidence/mission-control/).
