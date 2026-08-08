# Mission control board

`bin/fm-mission-control.sh` renders the fleet's current state into one self-contained HTML board that the captain keeps open.
It is a generator, not a server: each run writes one file, and the page reloads itself so a regenerated file appears without a click.

The board is a calm, light executive summary: a stat strip, the decisions waiting on the captain, a card per project, what landed today, and a quiet strip carrying fleet health and allowance.
It uses monochrome SVG line icons and no emoji.
The script's own header and `--help` own its exact flags, environment variables, paths, and exit codes, including the two commands that set a decision aside and bring it back.

## What the board does

The board shows state.
By default it shows nothing else: no reply controls, no review surface, no network, and no supervision wiring.
`--controls` adds the captain reply layer described under "Replying from the board", which queues requests and still performs nothing itself.

The board never shows a completion percentage or an estimated finish time.
Progress judgement is firstmate's, derived from evidence a renderer cannot see, so inventing a number here would be a guess presented as a measurement.
Each project card instead states only what live state can prove: what is under way, what waits on the captain, and when the project last changed.
"What is under way" is listed item by item, because a count says something is happening without saying what.
Each item shows its backlog title or falls back to its task id, presents its recorded worker model as a readable label, and shows how far it has travelled as a five-rung ladder - Setup, Building, Validating, Checks, Ready - always labelled with the stage it has reached.
A rung is a lifecycle position the fleet can prove, never a fraction of the work done, and the colour of the filled rungs says whether the item is still moving, so an item stopped at rung four keeps the rungs it earned and still reads as stopped.
Setup is labelled `Setup: endpoint present` only when task metadata and recorded endpoint presence are available but no current-state source or activity has been observed yet.
For ordinary work this is an endpoint-presence claim, not proof that a live worker is running; second mates use their already-available agent-liveness result as an additional requirement.
Every Setup rung uses the neutral slate `quiet` tone because even verified endpoint liveness does not prove movement.
Ready keeps the top rung but uses the board's amber needs-you tone because green checks awaiting review or merge are not completed work.
The stage itself is derived by the snapshot rather than by the board; see `bin/fm-fleet-snapshot.sh` for the `current_state.stage` contract.

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
  Each card carries a status pill, a one-line live state, a row per in-progress item, the calls waiting on the captain, and when the project last changed.
  A second mate's active-task total is accepted only as a non-negative integer; any other reported value is never converted into a count, and both its card and the "In progress" tile disclose either the received rows as a lower bound or that the count is unavailable.
  An older second mate that omits the total keeps its original semantics: the received rows and their omission record establish the total instead.
  A card long enough to stop being readable keeps the first six items visible and puts every additional received item in an expandable shelf with its name, stage, and model intact.
  Rows omitted by an upstream second mate bound stay separately disclosed as unavailable rather than being mixed into that shelf.
  A model the fleet never recorded is labelled `model not recorded`; a stage omitted by a second mate home running an older firstmate is labelled `Stage unavailable` and drawn as an unfilled hatched ladder rather than as a proven zero stage.
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
Project overflow shelves do not share or persist the Deferred shelf preference.

## Replying from the board

`--controls` adds a reply layer to the same board file.
Every control on it does exactly one thing: it queues one request that wakes firstmate.
It performs no action, calls no endpoint, and carries no authority.

That distinction is the whole safety model, so it is worth stating plainly.
A board request is evidence of the captain's intent, not an authenticated captain instruction.
Firstmate does with it exactly what it would have done had the captain said the same words in chat, under its own contract in `AGENTS.md`: an approval that needs the captain's explicit word still gets confirmed with the captain first, a merge still happens only if firstmate's own checks pass, and nothing destructive, irreversible, or security-sensitive is ever executed from a tap.
The surface is reachable by anything that can reach the local Lavish port, so being able to reach it is never treated as authorization for any of that.

There are five controls, and each row offers only what it can actually resolve:

- **Approve merge** and **Reply**, on a PR awaiting the captain.
- **Answer** and **Set aside**, on a decision the captain holds in a backlog.
- **Answer** alone on a task-level open decision, because there is no backlog row behind it and therefore no hold kind to change.
- **Ask firstmate**, once, for something new.

A decision belonging to a second mate carries the home it came from and is applied in that home, never in the main one.
Setting a decision aside carries no reason text at all: the stored reason is the captain's own, and firstmate reads it from the owning home rather than letting a request overwrite it.
A row the board cannot name unambiguously gets no controls, because a request firstmate cannot resolve is worse than one the captain makes in chat.

The layer is hidden by CSS and revealed only after a script confirms the Lavish bridge is present.
The same file served statically is therefore the read-only board exactly as before, with no controls and no dead affordances, and only the copy served through Lavish grows the reply layer.
With `--controls` the self-reload moves into `<noscript>` and a managed reload takes over, holding while a control is open so a 25-second refresh cannot discard half-typed text; without the flag the meta refresh is untouched.

[`bin/fm-procevent-mission-control.sh`](../bin/fm-procevent-mission-control.sh) owns arming the wake and turning what comes back into validated requests, and its `--help` owns the request format, the fail-closed rules, and the lavish-axi version the format is verified against.

The reply surface lasts as long as the review session behind it.
Ending that session from the panel, which the captain can do with one tap beside the send button, delivers the request in hand and then retires the surface, and arming it before the session is open retires it before it ever works.
Either way the read-only board is unaffected; only the ability to reply from it stops, until the session is opened again and the surface re-armed.
How the control surface is exposed beyond this machine is a separate decision and is not made here.

## Deferring a decision

`bin/fm-mission-control.sh --help` owns the exact commands for setting a decision aside and bringing it back, including the reason-preservation hazard.

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
The generator does not serve it; how the file is exposed is decided outside it.

## Verification

`tests/fm-mission-control.test.sh` renders the board end to end from a fixture home and from captured snapshot payloads, covering present and absent sources, cross-home captain decisions, escaping of hostile prose, project folding, work outside the registry, per-item stage and model rendering, bounded cross-home stage values, safe handling of valid, missing, and malformed secondmate active-task totals, item overflow, blocked work, unmeasurable allowance windows, self-reload, the tab structure, and the deferred shelf.
The deferred cases pin the awaiting count and the section count to literal numbers rather than to the absence of a title, because dropping a decision from the list while still counting it and counting it while still listing it fail separately.
It also pins a fixed current time and commits its fixture clones at explicit epochs, so the last-change wording, its three degrade-to-dash paths, and the promise that no clone is written to are all checked against times the test chose.

The reply layer is covered in the same suite: that the default board is unchanged by its existence, that each row offers only the controls it can resolve, that a control reaches nothing but the Lavish bridge, that it stays hidden until that bridge is proved present, and that fleet prose stays escaped inside the attributes a control carries.
`tests/fm-procevent-mission-control.test.sh` pins the request normalizer against bytes captured from a real send through a real browser, and drives every fail-closed path - a forged envelope, an out-of-vocabulary intent, a truncated capture, a defer carrying reason text - to a refusal rather than a plausible request.

`tests/fm-fleet-snapshot-view.test.sh` pins lifecycle-stage derivation and its conservative fallbacks, secondmate Setup liveness, and the deferred classification itself: a parked hold on work that is not a captain decision is ordinary held work, a captain decision that still has an unresolved blocker stays blocked rather than deferred, and a deferred decision never reaches the secondmate home summary's holds.

That a tab survives the board's own reload cannot be shown by a shell test, so it is checked in a real browser and the before and after boards are captured in [`docs/evidence/mission-control/`](evidence/mission-control/).
