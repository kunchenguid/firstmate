# Mission control board

`bin/fm-mission-control.sh` renders the fleet's current state into one self-contained HTML board that the captain keeps open.
It is a generator, not a server: each run writes one file, and the page reloads itself so a regenerated file appears without a click.

The board is a compact executive summary: a stat strip, the decisions waiting on the captain, a card per project, what landed today, a very recent autonomous-actions feed, and a quiet System view carrying fleet health plus a provider allowance snapshot.
Its neutral Grok-inspired visual system uses dark as the explicit CSS fallback and default, then follows a light system preference for bright contexts.
The renderer's inline style is the sole board CSS owner and documents the role-token contract and semantic mappings.
Components consume those roles instead of owning palette literals.
Idle project cards use the quieter panel token without a shadow, while projects needing action keep the stronger needs-you edge, so the existing decisions-first scan order remains clear without hiding any project or section.
Visual treatment never changes whether a control, fact-intake form, composer, dispatch editor, no-script section, or self-reload behavior is available.
Its in-page controls use monochrome SVG line icons and no emoji, while an inline SVG compass mark keeps Mission Control distinct in browser tabs and bookmarks without adding an asset request.
The script's own header and `--help` own its exact flags, environment variables, paths, and exit codes, including the two commands that set a decision aside and bring it back.

## What the board does

The board shows state.
By default it shows nothing else: no reply controls, no review surface, no browser network requests, and no supervision wiring.
The generator's allowance read is a bounded `quota-axi --tui --once` subprocess on the board's existing regeneration cadence, never a live terminal or a request from the rendered page.
`--controls` adds the captain reply layer described under "Replying from the board", which records requests and still performs nothing itself.
That layer is the only thing that makes the page itself reach the network, and only to the URL it was loaded from.

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
  A decision filed with structured context shows it as labelled sections under the row - "Why now", "What it affects", "Recommendation", and, where the filer established that no built surface applies, "No built surface" - so the captain can find the recommendation without reading a paragraph for it.
  When a decision has downstream backlog dependents, it also shows one compact "Blocking:" line with each dependent's title, or its id when the available snapshot cannot resolve that title.
  That block is a sibling of the row rather than part of it, because the row title is a link whenever the decision has one and reading the context must never navigate away; at phone width each label sits above the text it labels.
  An old-style decision that carries only a plain hold reason renders exactly as it always has, while an earlier decision that already records an optional question or decision-aid URL keeps that behavior without gaining the new labelled context block.
  When controls are enabled and the direct board-reply service proves it is available, a decision with two to four explicitly recorded option labels shows them as quick-answer buttons and keeps a `Write your own answer` control beside them.
  The superseded Lavish transport remains Answer-only.
  No prose is parsed to invent options, so a decision without that field keeps the original free-text-only Answer control.
  A decision explicitly marked as fact intake and carrying a valid non-longtext-only `fact_fields` schema renders an ordered single-column form with the recorded labels, hints, examples, units, required status, and type-appropriate controls.
  A legacy fact with no schema, a malformed or unsupported schema, and a longtext-only schema keep the original `Fact needed` textarea and recorded expected-answer hint.
  A decision without the explicit fact marker renders its Answer control exactly as before, and the board never infers the marker or fields from its question or recommendation.
  [`docs/decision-hold-lifecycle.md`](decision-hold-lifecycle.md) owns the fields themselves and which of them a filing must supply.
  Two or more open decisions carrying the same non-null group key render inside one consolidated card whose readable heading comes from that key.
  Each member remains a complete labelled sub-question with its original context, dependency line, decision aid, Answer control, any available Set aside control, quick answers or fact framing, acknowledgement banner, and Ask-firstmate entry point.
  The wrapper reports how many sub-questions have recorded answers, using `N of M facts provided` when every member is fact intake, but it does not merge their identities or answering paths.
  A unique group key and an absent group key both keep the standalone decision rendering, so visible grouping begins only when at least two open decisions share the key.
  A partially answered group stays at unanswered priority and keeps each answered member's existing quiet acknowledgement treatment, while a group moves below unanswered decisions only after every member has a recorded Answer request.
  Grouping is confined to the waiting list and never changes the Deferred shelf.
  A structured HTTPS decision aid appears as its own readable link and remains on its recorded private host.
  Only valid HTTP or HTTPS references are clickable; a local report path such as `data/example/report.md` remains non-clickable context when no explicit served HTTPS aid exists, because the board does not serve fleet-local files.
  URL validation runs in the required jq rendering path, so valid links do not disappear when optional browser tooling such as Node is unavailable.
  The board never probes, publishes, mounts, or rewrites that destination.
  Bounded or unavailable secondmate registries, omitted homes, and registered homes whose decisions could not be read all mark the waiting status incomplete.
  A decision with a durably recorded Answer request stays visible until its underlying decision resolves, but it sorts after every decision that still needs an answer so the remaining work stays at the top.
  This is presentation ordering within the waiting list only: it neither changes backlog order nor touches the Deferred shelf.
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
- **Recent autonomous actions** is a fleet-wide awareness feed, distinct from shipped backlog work and captain decisions.
  It shows at most eight newest-first entries from the preceding 12 hours, then lets older entries age out without a page-back control.
  It includes only a standing-authority finding decision or a standing-authority PR merge that firstmate recorded going forward.
  An empty feed means no qualifying action has been recorded in that window; it does not reconstruct earlier chat or status prose.
- **Fleet health** lists blocked or failed tasks, backlog items waiting on an unresolved blocker, non-decision secondmate work whose own state or blocker linkage says it is held, and open captain decisions the structural readiness checklist reports as incomplete.
  An incomplete decision reads `incomplete` with the specific gaps as its hint, because a decision that reaches Captain's Call unanswerable is a fleet health problem rather than a decision waiting on the captain; [`docs/decision-hold-lifecycle.md`](decision-hold-lifecycle.md) owns the checklist.
  It sits in the closing strip, so every fleet health item is also announced in a bar above the primary sections rather than left for the captain to scroll to.
  That bar names the count as blocked or failed while those are the only kind present, and widens to fleet health items once a held secondmate item or an incomplete decision joins them.
- **Dispatch** shows the live `config/crew-dispatch.json` in the System view without making the board a second schema owner.
  It states whether the optional file is absent, valid, invalid, or unavailable and says that the verdict was checked during the current render.
  Each natural-language rule and the default show their profile count, harness, model, effort, optional provider, quota-array shape, independence and fallback summary, every configured fallback assignment, and a collapsed rationale when one exists.
  The full condition stays readable without sharing a horizontal row with the assignment, so a long task type cannot push the model out of view at phone width.
  Raw JSON remains available only in an expandable shelf.
  The canonical schema and all field semantics remain in [`docs/configuration.md`](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson).
  The view also notes that secondmate homes receive this same file when inherited configuration is pushed.
- **Model-provider allowance** shows `quota-axi`'s own one-shot terminal screen in the System view.
  Reciprocal links connect this provider-budget surface with Dispatch directly above it without adding routing or selection logic.
  Mission Control does not interpret, augment, or reproduce the snapshot's allowance numbers, pace, layout, or history.
  The fixed-width screen is plain text inside a themed, horizontally scrollable surface, with terminal control sequences removed and every character HTML-escaped before rendering.
  At phone width the screen uses a smaller monospace presentation with box-drawing coverage so more of its grid remains legible while the page body stays contained.
  If `quota-axi` is missing, fails, times out, or returns no output, the section plainly states that allowance information is unavailable without inventing numbers or restoring the old charts.
  Token Dashboard logging and its saved history remain untouched, but Mission Control no longer reads or renders them.

An idle second mate is healthy and is rendered as such, never as an alarm.

## Navigation

The board is one page, not one scroll.
The header, the stat strip, and the red attention bar are always in view, because "is anything on fire, and how much awaits me" must never be a click away.
Everything below them is grouped behind four tabs: Decisions (the waiting list and the Deferred shelf), Projects, Activity (what shipped today), and System (fleet health and allowance).
The board opens on Decisions.

The tabs are keyboard-reachable, carry the tab and tabpanel roles with their selected state, and move with the arrow, Home, and End keys.
With no script the tab strip is hidden and every section stays visible, so the board degrades to the single scrolling page it was before rather than hiding its content behind controls that cannot work.
Every project or second-mate name on a project card, and every matching project or home tag on an awaiting or deferred row, is a click target.
With no script each target is an ordinary in-page link to the exact current card, while a name with no card in the current snapshot remains inert instead of leading to a dead destination.

The self-reload navigates without the URL fragment, so a fragment cannot be what carries the selected tab across a reload; the tab is remembered in browser-local state scoped to this board home and document and restored before the page paints, so it neither resets nor flashes the default panel every 60 seconds.
The same scoped session memory preserves the visible card or section plus its viewport offset, with a clamped scroll fallback when that anchor disappears.
Because the memory is updated while the captain reads and types, it also survives a full document replacement triggered by an external board-file rewrite rather than only the board's own reload timer.
A `#tab=<name>` fragment still selects a tab on the first load, which is what a hand-typed or copied link uses.
Explicit fragment navigation and deliberate tab changes win over saved reading position.
With script, the same target selects Projects, scrolls to the exact card, records it as the reading anchor, and briefly highlights it before the board returns to its ordinary appearance.
This works for registered projects, unregistered projects with current work, and second mates.
A browser that refuses storage - a private context, or a restricted `file://` origin - simply opens on Decisions each time.

The Deferred shelf is held to the same bar, because a shelf that snapped shut every 60 seconds would be the same jarring reset in a smaller place.
It is closed for a captain who never opens it, stays open for one who does, and stays closed again once they close it.
Project overflow shelves do not share or persist the Deferred shelf preference.

## Replying from the board

`--controls` adds a reply layer to the same board file.
Every control on it does exactly one thing: it records one request that wakes firstmate.
It performs no action, reaches no external host, and carries no authority.

That distinction is the whole safety model, so it is worth stating plainly.
A board request is evidence of the captain's intent, not an authenticated captain instruction.
Firstmate does with it exactly what it would have done had the captain said the same words in chat, under its own contract in `AGENTS.md`: an approval that needs the captain's explicit word still gets confirmed with the captain first, a merge still happens only if firstmate's own checks pass, and nothing destructive, irreversible, or security-sensitive is ever executed from a tap.
The surface is reachable by anything that can reach the service serving it, so being able to reach it is never treated as authorization for any of that.

There are six general controls plus the System view's bounded Dispatch editor, and each row offers only what it can actually resolve:

- **Approve merge** and **Reply**, on a PR awaiting the captain.
- **Answer** and **Set aside**, on a decision the captain holds in a backlog.
- **Answer** alone on a task-level open decision, because there is no backlog row behind it and therefore no hold kind to change.
- **Start something new**, as a board-level one-shot request for something to look into or build.
- **Ask firstmate**, as the board-level continuing conversation for a question or follow-up.
- **Change assignment**, on an existing dispatch rule or the default, limited to the model and effort of one existing profile.

The Dispatch editor appears only when `--controls` is enabled and the direct board-reply service proves it is live.
It never appears through the legacy Lavish bridge, a plain static server, or `file://`.
The profile selector chooses only among profiles already present in the selected rule or default, and v1 cannot add, delete, reorder, change an id, change `when`, or change a harness.
Submitting it records one `dispatch` request through the shared board vocabulary and does not edit configuration in the page or service.
Firstmate collects that request with `bin/fm-procevent-board-reply.sh apply`, which delegates the candidate to `bin/fm-crew-dispatch.sh` before acknowledging its wake.
That command resolves the canonical stable rule and profile ids, checks their rendered revisions, changes only the requested existing profile, validates the complete candidate with the same dispatch validator bootstrap uses, and atomically promotes only a valid file.
A stale rule, malformed profile array, unverified harness already present in the candidate, or unsupported effort leaves the file unchanged.
An open assignment draft retains the stable ids and revisions it began with and is discarded after regeneration if either object changed, so it can never bind itself to a newly occupying position.
The collector treats a repeated request as successful only when its request id and complete stable target payload match an already recorded successful result.
The collector records the applied assignment or refusal in private board state, and the next board regeneration shows that outcome beside the same task type.
An explicit per-task harness, model, or effort at spawn remains higher precedence than this default file.

Start something new and Ask firstmate are deliberately separate surfaces.
The new-work composer is a visually distinct intake card, while Ask firstmate retains the conversation and its replies.
Neither is nested in a decision or project card.

A decision belonging to a second mate carries the home it came from and is applied in that home, never in the main one.
An Answer form uses the exact structured question when one was recorded, otherwise it uses the decision title and reason as a concise reminder, and only falls back to `Your answer` when no useful context exists.
On the direct board-reply transport, an option button puts its recorded label through that same Answer form and submits the same `answer` request as free text; it creates no new wire intent or execution path.
Fact intake with a usable schema replaces that decision's textarea with real text, number, date, money, enum, and long-text controls in the schema's recorded order.
The form stays a single-column stack at phone width and ends with a full-width submit control, while the grouped-card progress remains visible in its header.
A collapsed `Add context that does not fit a field` note carries optional overflow context beside the structured values and never satisfies a required field.
A legacy fact with no usable schema keeps the prominent expected-shape line and `Your answer` textarea exactly as before.
The board never parses prose to invent fact intake or fields and does not provide a repeater, spreadsheet, or grid editor.
Each decision also offers `Ask a question about this`, which focuses the one shared Ask-firstmate composer and pre-fills a quoted reference to that decision's title.
It never creates a per-decision conversation or another transport.
Setting a decision aside carries no reason text at all: the stored reason is the captain's own, and firstmate reads it from the owning home rather than letting a request overwrite it.
A row the board cannot name unambiguously gets no controls, because a request firstmate cannot resolve is worse than one the captain makes in chat.

A request travels to the URL the document was loaded from, so the board carries no endpoint, no port, and no path convention, and works unchanged behind any reverse proxy.
The layer is hidden by CSS and revealed only after a script proves a transport that can actually reach firstmate: the reply service answering its presence probe, or the legacy Lavish bridge being present.
The same file served by a plain static server, or opened from disk, is therefore the read-only board exactly as before, with no controls and no dead affordances.
With script available, a managed reload preserves the active tab and meaningful reading position.
Browser-native restoration is disabled and the saved anchor is applied synchronously after draft layout is restored, so refreshed content does not paint at an intermediate position and visibly jump back.
With `--controls`, that reload also holds while a control is open or contains unsent text.
The no-script fallback remains read-only and refreshes through its meta tag.

An acknowledged control is replaced in place by a full-width confirmation banner, because a small coloured label beside an unchanged row was missed.
The banner leads its row, so a decision already answered reads as answered at a glance, and whatever the row can still resolve stays available under it.
Its outcome heading ships hidden and empty: the script fills in either an immediate acknowledgement or a matching durable record, so a statically served copy can never show a confirmation that has no evidence.
The banner claims only that, and never that the requested merge or decision has happened.
A collected banner says that no action is needed from the captain right now and uses the board's neutral quiet treatment rather than reading like another need.
The reply service answers after it has validated and durably recorded the request, so its labels are `Answer received`, `Merge request received`, and their corresponding forms.
The pinned Lavish bridge returns before delivery completes, so on that path the truthful labels remain `Answer queued` and `Answer sent` according to what it confirmed.
A queued banner keeps that distinction in its wording while using the same quiet no-action-needed treatment.

Recorded is not the same as collected, and the difference is a reachable live state rather than a hypothetical: a continuity break retires the wake until an operator rebases it, and a deployment that never armed leaves the same gap from the start.
The service therefore reports whether a wake is registered for this board, and the banner says `Recorded, but firstmate is not collecting replies from this board yet` when it is not, instead of implying firstmate already has it.
That uncollected variant keeps the board's amber needs-you treatment and is never flattened into the quiet collected state.
A confirmation restored on load is corrected as soon as the probe answers, so the wording always reflects the current state rather than the state at the time of the tap.

Ask firstmate is the one control that continues past its acknowledgement.
Firstmate posts a reply into that board's own conversation, the board shows the captain's messages and firstmate's replies together in order under the composer, and the captain answers there instead of switching to chat.
A Start something new request never joins that thread and receives the same persistent recorded confirmation as the other one-shot controls.
Beginning a distinct new-work draft retires that earlier presentation state without changing the durable request already recorded.
Each physical board has one continuing conversation rather than a new sub-thread for every Ask-firstmate message.
The conversation is display and nothing else: a firstmate message carries no control, no target, and no intent, it opens no execution path, and what reaches firstmate is still only ever a captain request.
It ships hidden and empty for the same reason the banner does, so a copy served as a static file or opened from disk shows no conversation at all.
It also keeps a tick of its own rather than riding the document reload, because that reload is deliberately held while a composer holds unsent text - exactly when the captain is mid-follow-up and a reply is most likely to arrive.

A failed or interrupted send leaves the form open, keeps its text editable, remains retryable, and records no acknowledgement.
The draft's session record keeps the attempted payload and its browser-generated identity across reloads: a byte-identical retry reuses that identity, while edited text receives a new identity.
That lets the service recognise an exact retry and record it once rather than twice without preventing the captain from changing the request.
Every open composer and its draft are saved eagerly in session storage under the exact board, owning home, item, decision key, and intent identity.
A full document reload restores only controls whose exact identity still exists, so an external generator rewrite cannot erase an in-progress answer and cannot attach it to a neighbouring decision.
Draft and immediate post-submit presentation state are browser-local, scoped by board home, document, owning home, item, decision key, and intent.
They bridge an in-progress edit or the interval between submission and the next board regeneration, survive a reload only while the same actionable item remains, and retire when that item disappears.
On every regeneration, the generator reads the direct reply service's append-only request log and marks a still-actionable Answer by the same owning-home, item, decision-key, and intent identity.
That durable signal makes a fresh board agree across devices, supplies the answered-row ordering, and never claims the underlying decision was resolved.
The direct request log is the source of truth for recorded Answer requests; browser storage is not fleet truth.
Once the board-reply wake is armed, firstmate collects its captured Answer records through the decision lifecycle rather than treating a banner as proof of closure.

[`bin/fm-procevent-board-reply.sh`](../bin/fm-procevent-board-reply.sh) owns the reply service, arming the wake, posting firstmate's replies into the board conversation, and turning what was recorded into validated requests.
[`bin/fm-board-request-parse.pl`](../bin/fm-board-request-parse.pl) is the single owner of the board message vocabulary in both directions and of every fail-closed rule, shared by both transports, and the service validates a message at its door with that same program over the same bytes it is about to store.
Its captain-to-firstmate intents are `merge`, `reply`, `answer`, `defer`, `ask`, `file`, and `dispatch`.
A legacy `answer` carries its free-text `note` unchanged.
A fielded fact `answer` keeps that same intent and carries a `facts` object keyed by the stable field keys, the form's `required_keys`, and an optional overflow `note`.
The shared parser is the only required-key validator and rejects an incomplete structured answer by its stable keys, while the fielded form translates that refusal back to the recorded human labels before showing it to the captain.
It emits the accepted values as structure so firstmate does not re-parse prose.
The `file` intent carries only the captain's free-text `note` plus the common home and envelope fields, because it originates work with no existing item or decision target.

The legacy Lavish-bridged surface in [`bin/fm-procevent-mission-control.sh`](../bin/fm-procevent-mission-control.sh) remains supported for the shared captain-request vocabulary but gains no new transport behavior.
It is superseded because Lavish's own annotate review mode defaults on and cannot be configured off, and while it is on a real tap on a board control reaches Lavish's annotation prompt instead of the button.
That surface also lasts only as long as the review session behind it: ending the session delivers the request in hand and then retires it, and arming before the session is open retires it before it ever works.

## The board reply service

`bin/fm-procevent-board-reply.sh serve <board.html>` runs one small service in the foreground.
It serves the board file and its Ask-firstmate conversation for GET, accepts one validated captain request per POST, on one port, and does nothing else.
It binds loopback only and refuses a non-loopback bind rather than making the port wider.
The default port is 4321, `FM_BOARD_REPLY_PORT` changes the default, and `--port` overrides it for one run.
The script's own header and `--help` own its exact flags, and [`bin/fm-board-reply-server.py`](../bin/fm-board-reply-server.py) owns the exact wire behavior.

Tailnet reachability comes from reverse-proxying that port, which is this project's existing trust boundary for every captain-facing local surface, so the service adds no token layer of its own.
Firstmate deploys it in three steps, none of which touch this repo:

1. Render the board with `--controls` to a durable path outside any worktree, and keep regenerating it there.
2. Run `bin/fm-procevent-board-reply.sh serve <board.html>` as a long-lived process, and point `tailscale serve` at `http://127.0.0.1:<port>/` rather than at the file.
3. Arm the wake once with `bin/fm-procevent-board-reply.sh arm <board.html>`.

`serve` and `arm` must run with the same `FM_HOME`, because both resolve the request log and the registration from it.
A launch agent or unit that inherits no `FM_HOME` resolves them against the tracked code root instead, which reads as a working service on a board nothing is collecting.
`serve` prints the home it resolved and whether the board is armed in its startup output, so a mismatch is visible immediately rather than as a request that silently goes nowhere.

Arming has no precondition and is safe in any order: the request log is append-only and never consumed, so requests accepted while nothing is armed are picked up whole by a later arm.
A request recorded by the service becomes an ordinary durable `check` wake through the same `state/procevent/` framework every other source uses, so firstmate's normal wake drain picks it up with no second notification path.
At that wake, a validated `file` record surfaces its `note` unchanged for firstmate's ordinary `AGENTS.md` intake process.
For an `answer` or `dispatch`, firstmate runs `bin/fm-procevent-board-reply.sh apply <result-file>` before acknowledging the captured generation.
The collector preserves an answer's field values and overflow note as compact JSON, validates them against the filed decision, and delegates closure to `bin/fm-decision-hold.sh resolve-board` and its existing `resolve` ordering, while a dispatch request goes through the bounded shared validator and apply boundary.
A refusal leaves the captured request available and does not change the target state, so firstmate can report the reason and retry without losing the request.
The transport does no automatic backlog filing, project matching, task classification, or task dispatch.

`bin/fm-procevent-board-reply.sh say-source <source-id> <text>|-` is how firstmate answers a board-reply wake into its originating board's conversation, while `say <board.html> <text>|-` is the board-path form and `reply-log-path <board.html>` prints where that conversation is kept.
A reply is validated by the same program over the same bytes, under its own marker and its own single permitted intent, and direction is taken from the leading marker so neither side can claim the other's.
It is appended to a separate log the wake source never reads, which is what keeps firstmate from being woken by its own words and keeps a firstmate message from ever reaching the request path.
The service returns both sides together on a read the board makes for display only, keeps the newest 50 messages from a 256KB tail of each log, and reports that a read was partial rather than presenting a truncated history as the whole of it.
Both logs stamp whole seconds and the captain's side is laid out first, so a message and the reply to it recorded in the same second still read in that order.

Two properties are worth stating precisely, because both are easy to assume and wrong.

The service never consumes its own log, and the source that reads it advances no cursor of its own: the resume point is derived from the runner's own durably captured results, so capture is the only commit point.
A runner that died after the source printed but before the runner captured therefore re-derives the same bytes instead of losing them, which removes the pre-capture loss window the Lavish poll has.
This is still not lossless delivery, and must never be described as such; [`bin/fm-procevent-lib.sh`](../bin/fm-procevent-lib.sh) owns the exact boundary, and a request the browser never managed to send was never here at all.

A loopback port is reachable by any page the captain happens to have open, so the service refuses a cross-site write three independent ways: the required `application/json` content type and the required `X-Fm-Board-Reply` header are both outside what a cross-origin request may send without a preflight, no preflight is ever granted, and a browser-asserted `Sec-Fetch-Site` that is present and not `same-origin` is rejected outright.
The conversation read uses the same loopback-only port and sends no `Access-Control-Allow-*` header, so another origin may issue the GET but cannot read its answer.
The request itself still carries no authority either way; this only keeps another page from putting words in the captain's mouth.

If the request log stops matching the recorded cursor - it was replaced, truncated, or hand-edited - the source reports one continuity break, retires itself, and stays unarmed rather than re-announcing forever.
`bin/fm-procevent-board-reply.sh arm --rebase <board.html>` is the supported recovery, and it deliberately skips whatever the recorded cursor can no longer account for.

## Deferring a decision

`bin/fm-mission-control.sh --help` owns the exact commands for setting a decision aside and bringing it back, including the reason-preservation hazard.

Any source may be absent.
An absent backlog, project registry, secondmate table, or allowance snapshot renders an explicit unavailable or empty notice that states what is missing, and never a misleading zero.

## Where the data comes from

The board does not parse fleet state itself.
Like `bin/fm-fleet-view.sh` it renders one `bin/fm-fleet-snapshot.sh --json` capture, so current state, backlog roles, captain actionability, dependency direction, and secondmate current state keep exactly one owner.
Each structured backlog record carries `blocked_by_ids`, its unresolved subset `unresolved_blocker_ids`, and reverse `blocks_ids`; the latter retains dependent ids after a blocker is Done, while the board resolves titles only from records available in that capture.
Paths come from that snapshot's own resolved roots, so the board follows the active home without resolving `FM_HOME` a second time.

Four concerns come from outside the snapshot because the snapshot does not own them:

- `data/projects.md` is the delivery-posture registry that the project cards group by.
- `quota-axi --tui --once` is the sole allowance source for Mission Control and owns the snapshot's content and terminal layout.
  The board captures it only while regenerating, removes terminal control sequences, and embeds the remaining text in the self-contained page.
  This display path does not change the separate `quota-axi --json` contract used for dispatch routing.
- `state/autonomous-actions.ndjson` is the private, append-only source for the narrow recent autonomous-actions feed.
  It is read only by the board and never derived from task status prose.
- Each project card's last-change time.
  A registered project is dated by its clone's last commit, read with `git log -1`, which survives task teardown as the per-task state-file times do not.
  A second mate is dated by when it last reported, because its own clone can trail the work it advised on, and a plausible but stale time is worse than no time at all.
  Either source can be missing, and a missing source renders as a dash rather than a guess.

Relative wording ("9:05am today", "11:35pm yesterday", "22 Jul") is derived from the render's own current time, which `FM_MISSION_CONTROL_NOW_EPOCH` fixes, so the same snapshot always renders the same page.

Reading a project clone's history is the only thing the board does to a project, and it never writes there.

A backlog row may record its project as a bare name or as a full clone path.
Both name the same project, so both fold onto the same rollup row and display as the project name.

[`docs/decision-hold-lifecycle.md`](decision-hold-lifecycle.md) owns which structured context fields a captain decision records and how they are backfilled through the supported hold interface.
The canonical backlog parser and secondmate-home summary carry that context to renderers, so Mission Control does not parse private body conventions itself.

Every value that comes from fleet state, the registry, the autonomous-action record, or the allowance snapshot is HTML-escaped before it reaches the page.

## Recording autonomous actions

When firstmate decides an ask-user finding under standing authority, it records the project, one-line finding, and decision with `bin/fm-autonomous-action.sh decision <project> <finding> <decision>`.
When it merges a PR under standing authority, it records the project and full PR URL with `bin/fm-autonomous-action.sh merge <project> <https-pr-url>`.
The script's header and `--help` own argument limits, timestamp handling, and the exact two record kinds.
The command is the sole supported writer, so recording needs no edit access to the board renderer or to the NDJSON format.

## Serving and refreshing

Firstmate regenerates the board by running the script again; the output is written to a temporary file and renamed into place, so a browser refreshing on its own cadence never reads a half-written page.
With script available, the page reloads on a managed cadence of 60 seconds by default, configurable with `--refresh`, and the no-script fallback carries the equivalent meta refresh.
The page shows how long ago it was rendered, so a board whose generator has stopped is visibly stale rather than quietly wrong.
A generator that keeps running on schedule can still be executing stale code after a firstmate PR merges, since a fresh render timestamp says nothing about which commit produced it.
Every primary session start, and a successful merge of firstmate's own repository through this home's merge helper, fast-forwards the primary checkout without the captain running an update by hand; a checkout that cannot safely advance is left untouched and reported instead.
The merge-time trigger advances only the checkout, not the already-generated HTML, so the board adopts that code on its existing next generation rather than being regenerated with guessed local options.
A merge performed outside this home or from a standalone secondmate home has no merge-time trigger and falls back to the next primary session start.
See `bin/fm-ff-lib.sh`'s `primary_self_update` header comment for the exact mechanism shared by both triggers.
If a partial snapshot has no generated timestamp, the header and footer say that its render time is unavailable rather than showing a placeholder or estimating one.
To have Firstmate also surface that condition at session start, opt into the local freshness check described in [`docs/configuration.md`](configuration.md#mission-control-board-freshness-configmission-control-board--fm_mission_control_stale_secs).
When it does report staleness, restore or refresh the local generator and run another session start to confirm the board is current.

The page is fully self-contained with inline styles and no external requests, so it renders correctly from a local file and over a private network.
The generator does not serve it; how the file is exposed is decided outside it.

## Verification

`tests/fm-mission-control.test.sh` renders the board end to end from a fixture home and captured fleet snapshots, covering present and absent sources, known and unavailable header render times, the empty and populated recent autonomous-actions feed, its 12-hour expiry and newest-first order, cross-home captain decisions, escaping of hostile prose, project folding, work outside the registry, per-item stage and model rendering, bounded cross-home stage values, safe handling of valid, missing, and malformed secondmate active-task totals, item overflow, blocked work, the one-shot allowance snapshot's happy, missing-binary, and failed-command paths, its safe text rendering and fixed-width containment, self-reload, the self-contained favicon in ordinary and control-enabled boards, the tab structure, the deferred shelf, and labelled structured decision context.
The deferred cases pin the awaiting count and the section count to literal numbers rather than to the absence of a title, because dropping a decision from the list while still counting it and counting it while still listing it fail separately.
The decision-context case renders a structured and an old-style decision from one fixture home and pins the count of rendered context blocks, so leaving the old-style decision alone is proven rather than inferred from it happening to look bare.
The dependency case adds a titled dependent, an unavailable secondmate-dependent title, and a decision with no dependents, then pins the titled line, id fallback, and absence of an extra line.
The control-enabled half also proves that only the structured option set renders quick-answer buttons, that only an explicit valid fact schema renders the fielded form, and that legacy, malformed, and longtext-only fact schemas retain the expected-answer textarea.
The recorded-answer case renders a partially answered group, a fully answered group, a unique group key, an absent group key, and two deferred rows carrying a shared key.
It proves that each grouped sub-question keeps its independent content and controls, only the fully answered group sinks, standalone rows stay standalone, and Deferred remains an ordinary shelf.
It then measures the rendered page in a real browser at 1280px and 390px, because markup alone cannot show that grouped cards, context and dependency lines, option buttons, fact-field stacks, submit controls, progress labels, or fallback hints fit without pushing the board sideways; that measurement self-skips when Chrome or Node is absent.
It also pins a fixed current time and commits its fixture clones at explicit epochs, so the last-change wording, its three degrade-to-dash paths, and the promise that no clone is written to are all checked against times the test chose.

The reply layer is covered in the same suite: that the default board is unchanged by its existence, that each row offers only the controls it can resolve, that the one-shot new-work composer and continuing Ask-firstmate conversation keep their labelled inputs visible inside their distinct cards at 1280px and 390px in both themes, that a control names no host, port, or absolute endpoint and derives its target from the URL the document was loaded from, that it stays hidden until a transport is proved, and that the confirmation banner ships hidden with an empty outcome heading.
Fleet prose is checked to stay escaped inside the attributes a control carries.
A real-browser regression also covers exact and fallback Answer prompts, explicit quick answers beside the free-text path, fielded fact intake and its fallback cases, structured submission with overflow context, the per-decision entry into the one shared Ask-firstmate composer, main-home and secondmate decision links, malformed and hostile inputs, successful and failed sends, duplicate prevention, acknowledgement restoration and retirement, active-tab restoration, stable reading anchors, explicit-navigation precedence, and disappeared-anchor fallback.
It renders two fresh board copies from one durable request log and measures the recorded quiet banners, answered-row ordering, shared composer, Deferred shelf, exact cross-home identity, and quick-answer controls at 1280px and 390px.
It also proves that a quick answer and a typed answer emit the same validated `answer` intent with only their note text differing.

`tests/fm-crew-dispatch.test.sh` covers stable rule and profile ids, stale revisions, position-independent targeting, successful-request replay, request-id collisions, complete candidate validation, visible fallback assignments, the reciprocal allowance relationship, and read-only versus direct-service edit availability.

`tests/fm-board-reply.test.sh` covers the direct transport with no Lavish anywhere.
It re-proves every fail-closed rule at the service door and again at wake time, refuses a cross-site write and a non-loopback bind, holds captain text that looks like the wire format inside its own field, and pins the properties the cursor design rests on: a delta discarded before capture is re-derived byte for byte, a capture truncated before its end sentinel records no cursor and loses nothing, a captured delta advances the cursor so nothing is announced twice, a request accepted before arming survives to the next arm, one retried attempt is recorded once, and a broken cursor escalates exactly once with rebase as the recovery.
It applies captured choice and structured fact answers through the decision lifecycle, proves exact replays remain idempotent before and after Done retention, and keeps grouped siblings independently blocked until their own answers arrive.
It also proves a malformed fact answer leaves both its captured result and decision open, and that a fresh adapter process can apply a request captured before it started.
It also pins that the service reports an unarmed board as uncollected, at its probe, in the answer to a recorded request, and in its own startup output.
Its real-browser case serves the board through the service itself and drives a genuine Answer and Start something new request through to their confirmations, checks that each confirmation is a full-width banner rather than a label, that persistent presentation survives a reload and fits a 390 by 844 viewport, and that killing the service leaves the next control open, editable, retryable, and unacknowledged.
A second browser case retires the wake and proves that a request recorded while nothing is collecting is confirmed as recorded with the amber needs-you treatment and explicitly not collected.
That regression rewrites the served HTML file repeatedly while an Answer composer contains unsent text, then performs full document reloads and verifies the exact draft, control identity, tab, and anchored reading offset survive both replacements.
The Ask-firstmate conversation is covered in the same suite: a real thread of captain message, firstmate reply, and the captain's reply to that reply reads back in order, while the single-message flow is unchanged when no reply is ever posted.
A firstmate reply never reaches the wake source, is held to the same fail-closed rules as a captain request, and stays a quotation when it quotes the wire format; a forged or malformed conversation line is never rendered, and a partial read says so.
A third browser case proves the conversation is absent from a statically served copy, that both sides appear in order on the served board, that a reply posted from the command line reaches the board while its refresh is held by an open composer, that the conversation contains no control of any kind, and that it fits a 390 by 844 viewport.
With `FM_MISSION_CONTROL_LIVE_HOME` set to an active home, the same suite generates a fresh board directly from that fleet and uses Chrome at 390 by 844 to verify a meaningful reading anchor remains fixed through regeneration, a full reload, and the early refresh frames without printing fleet records.
`tests/fm-procevent-mission-control.test.sh` pins the request normalizer against bytes captured from real Answer and Start something new sends through a real browser, proves structured fact values and overflow context survive unchanged, proves missing required keys are named, and drives every fail-closed path - a forged envelope, an out-of-vocabulary intent, a truncated capture, a defer carrying reason text, and a new-work request carrying a disallowed target - to a refusal rather than a plausible request.

`tests/fm-fleet-snapshot-view.test.sh` pins lifecycle-stage derivation and its conservative fallbacks, secondmate Setup liveness, and the captain-hold classification itself: captain holds on ship and scout work are actionable when unblocked, parked captain holds are deferred regardless of the row's own kind, a held row with an unresolved blocker stays blocked rather than deferred, and a deferred row never reaches the secondmate home summary's holds.
It also pins empty and populated reverse dependency lists, retention after a blocker is Done, and preservation through the secondmate summary.

That a tab survives the board's own reload cannot be shown by a shell test, so it is checked in a real browser alongside project-tag navigation from a decision to its highlighted Projects card at desktop and 390px mobile widths, plus the no-script anchor fallback.
The existing visual board comparisons and live-fleet reading-position evidence are recorded in [`docs/evidence/mission-control/`](evidence/mission-control/); the project jump itself is exercised by the real-browser regression in `tests/fm-mission-control.test.sh`.
