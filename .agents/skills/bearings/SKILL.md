---
name: bearings
description: >-
  Generate a "pick up where I left off" fleet digest from firstmate's live fleet state.
  Use when the captain invokes /bearings or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Plain /bearings is chat-only by default, /bearings file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact, and /bearings lavish additionally builds and arms the interactive fleet board; live PR enrichment remains opt-in and composes with the other modes.
  Also load this skill's board-wake handling when a procevent lavish wake's source id matches the canonical source id of the stable bearings board path.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a complete current snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset.
Plain `/bearings` returns only the concise four-section chat digest.
Only `/bearings file` writes the dated markdown report artifact and then returns the concise four-section chat digest linked to that report.
Only `/bearings lavish` builds the interactive fleet board beside that digest, through `bin/fm-bearings-board.sh` (its header owns every board mechanic and the fm-bearings-board.v1 payload contract).
A digest/build invocation is operationally read-only apart from observational remote-ledger cache refreshes, durable per-target reconcile-notify requests when the captured state needs them, plus the explicit per-mode artifacts: the dated report in file mode, and in lavish mode the board file plus the answer binding and source registration that `bin/fm-bearings-board.sh build` records through their own owners.
During that invocation it never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, or mutates backlog or task state.
Board answers are acted on later under the normal authority rules; this skill's board-wake section explicitly owns the guarded routing at that time.

## Invocation modes

- Plain `/bearings` gathers a fresh bounded snapshot and renders the four-section chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/bearings file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the four-section chat digest with a link or path to that report.
- `/bearings lavish` gathers a fresh bounded snapshot, rebuilds and arms the interactive fleet board (the "Lavish board mode" section below), and renders the four-section chat digest with the board's URL inside it.
- Treat `file` and `lavish` only as explicit invocation options in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", "persist it", "make a file", or "make a board" as file or lavish mode unless the invocation explicitly includes the standalone option.
- When the captain asks to include PRs, pass the snapshot command's live-PR opt-in.
- `/bearings include PRs` remains chat-only and makes the live-PR opt-in.
- `/bearings file include PRs` and `/bearings lavish include PRs` compose the same way.

## What it does

1. **Gather live fleet state with one deterministic command.**
   Run `snapshot=$(bin/fm-bearings-snapshot.sh --json)` at invocation time and read that compact output.
   It is the single bounded, deterministic fleet-state source for Bearings.
   Do not create or consult a second fleet-state reader, parser contract, status-event-tail interpretation, visible-session recap, ad-hoc project probe, or ad-hoc `gh-axi`/`gh` query.
   The command's header and `--help` output own its exact fields, bounds, opt-ins, and output contract.
   The default performs bounded concurrent remote-ledger reads for registered remote homes under one shared snapshot budget and may refresh the parent-side cache.
   Only pass `--include-prs` when the captain asks for live GitHub PR enrichment.
   For registered secondmates, use the snapshot's structured-home classification and provenance.
   A parent event or bounded terminal contradiction is fallback evidence, never authority over readable structured home state.
   A decision is simply a task held for the captain (`captain-hold-lifecycle`); every due, unblocked captain-held task appears under `decisions_open`, whatever its kind.
   A captain hold deferred by date sits under `gates` with its `until <date>:` reason until it is due, and a hold whose reason or body carries an explicit deferred/superseded marker is suppressed from the default view with an `omitted` disclosure.
   Do not scrape reports, visual-review artifacts, raw status-event tails, or visible conversation history to supplement current state.
   A queued item under `gates` only becomes "next work" when its blocker is gone and its time/date gate has arrived.
   Until then it stays queued with the reason.
   The `(main-inventory)` gate is an action-free integrity warning rather than queued work.
   Render it under Charted Next with the related `omitted` disclosure, never invent an Underway row from backlog-only state, and never move it into Captain's Call.
   The same holds for a secondmate home whose current state is unavailable, and for a readable home whose `invalidity` reports a backlog-vs-metadata mismatch: the mismatch is a repair notice about that home's own books, not a reason to drop its separately projected decisions, queued, landed, or live work.

2. **Record a later reconcile notification for any home whose own books disagree.**
   When the snapshot reports a secondmate home whose `invalidity` is `orphan_in_flight`, `unowned_current`, or `terminal_in_flight`, that home's backlog and its own task metadata disagree and only that home may fix it.
   Run `printf '%s\n' "$snapshot" | bin/fm-secondmate-reconcile.sh request --snapshot -` immediately after gathering the snapshot.
   This atomically records one local one-shot request per mismatched target and returns without sending, taking a mate lifecycle lock, or waiting behind a local or remote delivery queue.
   The supervision loop later claims the requests and runs the cooldown-limited fire-and-forget deliveries; the script header owns per-target coalescing, request durability, retries, cooldown, identity checks, and retirement.
   Continue composing the digest from the captured snapshot as soon as the local requests are recorded.
   If local request publication fails, continue composing, report that durability blocker, and never fall back to an inline send.
   A home is still asked at most once per four-hour window, while a skipped or failed later delivery leaves the request durable for another supervision pass.
   Never edit another home's backlog or metadata from here, and never expect or wait on a reply.

3. **Compose the four-section chat digest from the fresh snapshot.**
   The gather step is deterministic; your judgment is scoped to ranking the command's facts by what matters right now and writing scannable captain-facing prose.
   The chat response uses the four complete sections in the chat-response contract below, in the same order, each always present.
   Plain mode stops here and writes no report artifact.

4. **In explicit file mode only, compose and replace the detailed report file.**
   The report uses the same four complete sections as the chat, in the same order, and adds the detail the chat omits.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
   If today's file already exists, delete it first, then create a new file from scratch.
   This is the only file-mode write allowed by the skill.
   The detailed report includes:
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (use "Morning status" only when the captain specifically asks for a morning brief), followed by two or three sentences framing where things stand.
   - **Captain's Call** - every open decision summarized with its options from the structured decision record, plus each PR ready to merge and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Recently Landed** - the bounded current recent-completions baseline from structured state across the main fleet and every registered secondmate home, rendered in full on every run.
   - **Underway** - each live direct report making progress, with its current state, and the plans or main pickup pointers worth reopening (`data/<id>/report.md` files, `.lavish/*.html` boards).
   - **Charted Next** - queued or gated work, including any main-inventory integrity warning, with each item's blocker, date, or integrity reason.
   After writing the file, return the concise four-section chat digest and include the report path or link without adding a fifth section.
   For a richer review surface, offer `/bearings lavish` when the report has enough structure to deserve one, but only after the required digest is ready.

## Lavish board mode

`/bearings lavish` adds one deliverable beside the unchanged chat digest: the interactive fleet board, a myfirstmate-styled Lavish page where the captain answers Captain's Call items directly instead of replying in chat.
`bin/fm-bearings-board.sh` owns every board mechanic - the stable board path, fm-bearings-board.v1 payload validation, template injection, Lavish session establishment, the any-origin answer binding, and arm-if-absent registration - so the per-invocation work is composing the payload and running its `build`.

Compose the payload from the same snapshot with the same ranking judgment as the chat digest, plus these board rules:

- A Captain's Call decision key is the captain-held TASK ID from `decisions_open` (legacy `<origin>-decision-<key>` rows are already task ids); a merge card's key is `merge.<task-id>`; the Charted Next dispatch picker's key is `dispatch.charted`.
- Compose exactly one decision card per captain-held task id. When one task carries multiple questions, consolidate all of them and their options into that card; never emit duplicate cards with the same task-id key.
- Decision cards carry agent-authored copy: a short noun-phrase title, one-line `about` and `decide` context rows, and option labels with hints, with the recommended option marked.
- Card `type` (decision, merge, credential) is your composing judgment from the row's content; no backlog field types a card for you.
- When the card's task is a captain-gated WORK item (the answer should free it to proceed rather than complete it), set the card's `close: "release"` so the answer lifts the hold instead of closing the task; question-shaped items omit it.
- A Charted Next row's optional `kind` separates work from alarms: omit it (or set `"queued"`) for real queued work, and set `"warning"` on every action-free fleet-integrity notice - the `(main-inventory)` gate, an unavailable secondmate home, and an inventory-mismatch repair notice. The board badges a warning row `needs repair` instead of `waiting` and leaves it out of the Charted Next count, so those rows never read as dispatchable queued work.
- `charted_more` counts omitted queued rows only, while `charted_warning_more` counts omitted warning rows only; keep both counts separate whenever the board payload truncates Charted Next.
- Every Captain's Call item and every Underway, Recently Landed, and Charted Next row carries an explicit `repo` field. Fill it from the snapshot and task records wherever known; use null or an empty string only as the deliberate genuinely-no-repo marker, in which case the template may show the internal id. Ids otherwise stay in the payload only as the routing channel, and composed reasons name blockers in plain words.

Run `build` once after composing the payload.
Its serve-first sequence publishes the board, establishes or resumes its Lavish session with `lavish-axi`, and only then binds and arms the polling source; use the session URL it prints in the chat digest.
Never bind or arm the board before that session exists.
Never run `lavish-axi poll` for the board yourself: the armed source's supervised runner owns the blocking poll, and the watcher's ordinary reconcile restarts it, so no conversational turn ever blocks on the board.

### Handling a board wake

A board answer arrives as an ordinary `procevent lavish <source-id> <sequence>` check wake. Identify it by comparing the wake source id with `bin/fm-procevent-lavish.sh source-id "$(bin/fm-bearings-board.sh path)"`, regardless of which answer kinds the result contains; then load `process-event-sources` and follow its contract for the result read, adapter classification, and the handled acknowledgement.
Decision answers need no routing from you: the runner feeds the board's binding into `bin/fm-captain-hold.sh`'s one keyed-answer intake, which closes or releases each answered captain-held task at answer time; reconcile any `skipped:` key yourself with a direct `answer`, and when the captain's answer is "later", record it as a deferral with `tasks-axi hold <id> ... --until <date>` instead of a closure.
Route the non-decision keys yourself:

- `merge.<task-id>` is the captain's explicit merge order; follow the merge ruling below.
- `dispatch.charted` carries comma-separated task ids the captain picked to start now; verify each id against the current backlog - still queued, blocker and time gate actually clear - then dispatch through the normal lifecycle, and report any id that no longer qualifies instead of forcing it.

After handling, rebuild the board from a fresh snapshot so acted-on items leave Captain's Call, and echo every action taken in chat so the board and chat never diverge silently.

### The merge-click ruling (captain-decided)

A board "Merge now" answer IS the captain's explicit merge word for that one exact PR; ask no second confirmation.
The safeguards are mandatory, not optional: resolve the PR from the task's own `state/<task-id>.meta` `pr=` record, never from board bytes; re-verify at wake time that the PR is still open and CI-green; refuse and report a red or changed PR rather than merging it; merge only through `bin/fm-pr-merge.sh`; and echo every merge in chat with the full PR URL.
Only the exact answer value `merge` authorizes a merge; an answer carrying a freeform note is the captain's instruction text to read and act on with judgment, never an auto-merge.

## Chat-response contract

This skill is the one owner of the `/bearings` chat-response format; the snapshot and classifier own the data that feeds it, and no other file restates this contract.
Every `/bearings` chat response renders EXACTLY these four sections, in THIS order, and nothing else structural (there is no At Anchor section):

1. **Captain's Call** - ONLY items that need the captain's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the captain can clear.
   Empty-state: "Nothing needs your action right now."
2. **Recently Landed** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges across the main fleet and every registered secondmate home.
   Empty-state: "No recent completions are in the current baseline."
3. **Underway** - live work progressing on its own, one line of current state per direct report.
   Empty-state: "Nothing is underway."
4. **Charted Next** - queued or gated work waiting on the fleet or a date, plus action-free fleet-integrity warnings, never on the captain.
   Empty-state: "Nothing is queued."

Rules that keep the contract unambiguous:

- Every section ALWAYS renders, even when empty, with its short empty-state sentence; never omit a section.
- Every chat digest and file-mode report is a complete current snapshot, never a delta against a prior report.
- Recently Landed always renders the bounded current baseline, even when the same completions appeared in an earlier report.
- The four buckets are mutually exclusive, so every item is forced into exactly one: needs-your-action is Captain's Call, done is Recently Landed, self-progressing is Underway, and not-yet-started work or an action-free fleet-integrity warning is Charted Next.
- The strict boundary keeps action-free items OUT of Captain's Call: a working or validating task, a queued item blocked on another task or a date, landed work, a completed scout's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other three sections, never Captain's Call.
- A secondmate's own row appears Underway only for `active_child_work`; `externally_held` belongs in Charted Next, and `unknown` belongs there as an unavailable-state gate unless its reason requires the captain's action.
- Do not suppress separately projected decisions, landed records, or gates from a `partial-structured` home merely because that secondmate's own row is `unknown` or its `invalidity` reports an inventory mismatch.
- Include the required direct address to the captain inside one item or empty-state sentence.
- Every PR appears as the full `https://...` URL; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same digest.
- The chat follows `AGENTS.md` section 9 and carries one scannable line per item.
- Detailed decisions, plans, full gate reasons, and evidence stay out of chat; file mode puts them in the report, while lavish mode puts only its payload-backed interactive detail on the board.
- In file mode, include the report path or link inside the four-section digest without adding another heading.
- In lavish mode, include the board URL inside the four-section digest the same way.

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
