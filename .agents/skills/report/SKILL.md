---
name: report
description: >-
  Generate a "pick up where I left off" fleet digest from firstmate's live fleet state.
  Use when the captain invokes /report or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Plain /report is chat-only by default, /report file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact, and /report lavish additionally builds and arms the interactive fleet board; live PR enrichment remains opt-in and composes with the other modes.
  Also load this skill's board-wake handling when a procevent lavish wake's source id matches the canonical source id of the stable bearings board path.
user-invocable: true
metadata:
  internal: true
---

# report

Generate a complete current snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset.
Plain `/report` returns the durable Markdown fleet report in ordinary conversation history.
Only `/report file` also writes the same Markdown to the dated report artifact.
Only `/report lavish` builds the interactive fleet board beside that report, through `bin/fm-bearings-board.sh` (its header owns every board mechanic and the fm-bearings-board.v1 payload contract).
A digest/build invocation is operationally read-only apart from observational remote-ledger cache refreshes, durable per-target reconcile-notify requests when the captured state needs them, plus the explicit per-mode artifacts: the dated report in file mode, and in lavish mode the board file plus the answer binding and source registration that `bin/fm-bearings-board.sh build` records through their own owners.
During that invocation it never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, or mutates backlog or task state.
Board answers are acted on later under the normal authority rules; this skill's board-wake section explicitly owns the guarded routing at that time.

## Invocation modes

- Plain `/report` gathers a fresh bounded snapshot and renders the Markdown report in normal conversation history without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/report file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the same Markdown report with that path in its opening.
- `/report lavish` gathers a fresh bounded snapshot, rebuilds and arms the interactive fleet board (the "Lavish board mode" section below), and renders the same Markdown report with the board URL in its opening.
- Treat `file` and `lavish` only as explicit invocation options in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", "persist it", "make a file", or "make a board" as file or lavish mode unless the invocation explicitly includes the standalone option.
- When the captain asks to include PRs, pass the snapshot command's live-PR opt-in.
- `/report include PRs` remains chat-only and makes the live-PR opt-in.
- `/report file include PRs` and `/report lavish include PRs` compose the same way.

## What it does

For a contribution notification or linked-issue filing, go directly to Contribution follow-up.
For plain report invocations, run `bin/fm-report.sh --command report` once and return its stdout exactly as the assistant's normal Markdown response.
Pass `--include-prs` only when the captain explicitly asks for live PR enrichment.
The command composes `bin/fm-bearings-snapshot.sh`, the captain-facing task lifecycle projection, and durable closed-task history rather than parsing backlog, worker, endpoint, status, acceptance, delivery, monitoring, or closure records itself.
The response intentionally remains in ordinary conversation history; never render it as a widget, notification, terminal-only command, or hidden custom message.
Do not prepend or append a summary because the command owns the complete report and its Recommendations section.

In explicit `file` mode, capture that same command output, replace `data/status-report-<YYYY-MM-DD>.md` from scratch, and return the byte-identical Markdown in chat with the file path added to the opening sentence.
Never consult an older report to decide what the current report says.
This is the only file-mode write allowed by the skill.

In explicit `lavish` mode, produce the same Markdown report in chat and additionally build the interactive board through the existing board procedure below.
The board is an optional live decision surface, not the report itself, and it never replaces or changes the conversation-history response.

## Lavish board mode

`/report lavish` adds one deliverable beside the unchanged Markdown report: the interactive fleet board, a myfirstmate-styled Lavish page where the captain answers Captain's Call items directly instead of replying in chat.
`bin/fm-bearings-board.sh` owns every board mechanic - the stable board path, fm-bearings-board.v1 payload validation, template injection, live Lavish session verification and ended-session reopening, the any-origin answer binding, and listener registration - so the per-invocation work is composing the payload and running its `build`.

Compose the payload from the same snapshot with the same ranking judgment as the chat digest, plus these board rules:

- A Captain's Call decision key is the captain-held TASK ID from `decisions_open` (legacy `<origin>-decision-<key>` rows are already task ids); a merge card's key is `merge.<task-id>`; the Charted Next dispatch picker's key is `dispatch.charted`.
- Before carding a hold, check that its SUBJECT has not already landed, and omit it when it has. `build` drops a card whose task or PR appears in the payload's own landed rows, and one whose task is no longer an open captain call. When a hold waits on one specific PR, put that PR in the card's `pr_url`. When it concerns a published version, put the artifact and numeric three-part version in the card's structured `subject`; landed rows for releases carry the same identity, and a matching or newer version drops the card. Identity matching is structured only, so verify any subject without one of these identities against current reality before carding it.
- Never author a `reconcile` option on any card. `build` gives every decision card the standard reconcile choice itself, and the payload validator reserves that value across all card types; recommendations must name an authored option.
- Compose exactly one decision card per captain-held task id. When one task carries multiple questions, consolidate all of them and their options into that card; never emit duplicate cards with the same task-id key.
- Decision cards carry agent-authored copy: a short noun-phrase title, one-line `about` and `decide` context rows, and option labels with hints, with the recommended option marked.
- Card `type` (decision, merge, credential) is your composing judgment from the row's content; no backlog field types a card for you.
- When the card's task is a captain-gated WORK item (the answer should free it to proceed rather than complete it), set the card's `close: "release"` so the answer lifts the hold instead of closing the task; question-shaped items omit it.
- A Charted Next row's optional `kind` separates work from alarms: omit it (or set `"queued"`) for real queued work, and set `"warning"` on every action-free fleet-integrity notice - the `(main-inventory)` gate, the `(return-catchup)` gate, an unavailable secondmate home, and an inventory-mismatch repair notice. The board badges a warning row `needs repair` instead of `waiting` and leaves it out of the Charted Next count, so those rows never read as dispatchable queued work.
- `charted_more` counts omitted queued rows only, while `charted_warning_more` counts omitted warning rows only; keep both counts separate whenever the board payload truncates Charted Next.
- Every Underway row copies the task-identifying `in_flight.name` from the snapshot into an explicit `name` field, which the board leads with while keeping the run status on its second line.
  The snapshot command's header owns its durable-title-or-id normalization; never replace the projected label with run status or invent another label.
- Every Charted Next row copies the snapshot gate's durable filed date into `filed`, and the board orders the section by it, newest filed first.
  Follow `bin/fm-bearings-board.sh`'s payload contract for the accepted format.
  Omit it or pass null for a row with no durable filed date - the main-inventory or return-catchup warning, an unavailable secondmate home, or a queued row filed before dates were recorded - and the board keeps those rows in payload order after every dated row.
- Every Captain's Call item and every Underway, Recently Landed, and Charted Next row carries an explicit `repo` field. Fill it from the snapshot and task records wherever known; use null or an empty string only as the deliberate genuinely-no-repo marker, in which case the template may show the internal id. Ids otherwise stay in the payload only as the routing channel, and composed reasons name blockers in plain words.

Run `build` once after composing the payload.
Its serve-first sequence publishes the board, establishes and verifies its Lavish session with `lavish-axi`, reopens an ended session when necessary, and only then binds the answer source and proves a live polling listener; use the session URL it prints in the chat digest.
Never bind or arm the board before its session is listed open.
Never run `lavish-axi poll` for the board yourself: the armed source's supervised runner owns the blocking poll, and both the build and the watcher's ordinary reconcile repair a missing listener, so no conversational turn ever blocks on the board.

### Handling a board wake

A board answer arrives as an ordinary `procevent lavish <source-id> <sequence>` check wake. Identify it by comparing the wake source id with `bin/fm-procevent-lavish.sh source-id "$(bin/fm-bearings-board.sh path)"`, regardless of which answer kinds the result contains; then load `process-event-sources` and follow its contract for the result read, adapter classification, and the handled acknowledgement.
Decision answers need no routing from you: the runner feeds the board's binding into `bin/fm-captain-hold.sh`'s one keyed-answer intake, which closes or releases each answered captain-held task at answer time; reconcile any `skipped:` key yourself with a direct `answer`, and when the captain's answer is "later", record it as a deferral with `bin/fm-captain-hold.sh hold <id> --reason "<reason>" --until <date>` instead of a closure.
A current structured Reconcile selection closes nothing: the versioned board context carries its exact selected option separately from any typed note, and the adapter routes that selection only into a durable re-check request while preserving the note as provenance.
The rollout-compatible old context still feeds ordinary non-reconcile answers, but its bare or separator-annotated reconcile values and every structurally uncertain choice feed neither intake and remain announced for deliberate handling.
Verify the call's latest state, then retire the request through `bin/fm-captain-hold.sh reconcile close <id> --evidence-file <path>` when it turns out to be moot, or `reconcile note <id> --note-file <path>` when it is genuinely still open.
Both outcomes refuse without that pending board-created request, and `bin/fm-captain-hold.sh reconcile list` names every request still outstanding.
A remote-secondmate card whose task is absent from the main backlog remains on the board unchanged, but its reconcile request is refused in the main home until the separately tracked owner-aware routing follow-up can query and mutate the authoritative secondmate home; handle the announced capture without claiming that a request or reconciliation succeeded.
`captain-hold-lifecycle` owns why a reconcile may never be recorded as the captain's answer.
Route the non-decision keys yourself:

- `merge.<task-id>` is the captain's explicit merge order; follow the merge ruling below.
- `dispatch.charted` carries comma-separated task ids the captain picked to start now; verify each id against the current backlog - still queued, blocker and time gate actually clear - then dispatch through the normal lifecycle, and report any id that no longer qualifies instead of forcing it.

After handling, rebuild the board from a fresh snapshot so acted-on items leave Captain's Call, and echo every action taken in chat so the board and chat never diverge silently.

### The merge-click ruling (captain-decided)

A board "Merge now" answer IS the captain's explicit merge word for that one exact PR; ask no second confirmation.
The safeguards are mandatory, not optional: resolve the PR from the task's own `state/<task-id>.meta` `pr=` record, never from board bytes; re-verify at wake time that the PR is still open and CI-green; refuse and report a red or changed PR rather than merging it; record the exact `merge` answer through `bin/fm-captain-hold.sh answer <task-id> --decision-file <file> --release` before invoking the merge; proceed only when that release succeeds; merge only through `bin/fm-pr-merge.sh`; and echo every merge in chat with the full PR URL.
Only the exact answer value `merge` authorizes a merge; an answer carrying a freeform note is the captain's instruction text to read and act on with judgment, never an auto-merge.

## Chat-response contract

`bin/fm-report.sh` is the single executable owner of plain `/report` and `/bearings` formatting.
It always renders concise Markdown tables in this order: Captain decisions and actions; Work under way; Done and ready for review; Accepted work in delivery or monitoring; Recently completed and closed; Charted next; then Recommendations.
Each table remains present with an explicit empty row when it has no work.
Recommendations are ordered by leverage: unblock active work, review candidate results, complete accepted delivery or monitoring, and only then close accepted scope when no forward work can move.
Every recommendation states why it matters, the consequence, and an exact `/t ...` or other command or action.
The report explicitly says when no captain action is needed.
It never calls work accepted, delivered, monitored, completed, or closed without the corresponding captain-facing lifecycle or closure record.
Superseded implementation rows are consolidated under the current result when the projection identifies their replacement, while every actionable reference remains visible.
Every PR appears as the full `https://...` URL.

Plain `/report` calls the formatter with `--command report`.
Plain `/bearings` calls it with `--command bearings`; that validated compatibility label is presentation-inert, so both commands are byte-identical and no second formatting implementation exists.
File, live-PR enrichment, and Lavish options route through this same contract and data path as described above.

## Tone and content rules

- The optional file-mode report is a private, captain-facing internal artifact that lives in gitignored `data/`, so unlike normal captain chat it MAY reference task ids, PR URLs, and repo names.
- The captain works with those directly and needs them to resume; keep the report organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.

## Supervision discipline

During a digest/build invocation, this skill changes no fleet state beyond observational remote-ledger cache refreshes, durable local per-target reconcile-notify requests, explicit report or board artifacts, binding, and source registration.
Do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, clean up work, or mutate any other `state/` or `data/` file during that invocation.
If the state gathered for the digest suggests an action, name it in its section and leave it to the normal lifecycle and configured authority.
On a later board wake, this read-only invocation rule yields to "Handling a board wake" and its guarded authority for captain-selected dispatches and merges.
