# Captain-hold lifecycle mechanism

The normative policy is owned by `.agents/skills/captain-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, compatibility contract, and privacy-safe regression evidence.

## Mechanism

A decision is not a separate thing in this system: it is an ordinary backlog task held for the captain, and the task id is the identity every surface and channel uses.
`bin/fm-captain-hold.sh` is the only lifecycle command layered on that primitive.
The command addresses the active home's configured data directory the same way `bin/fm-backlog-transition-lib.sh` addresses every backlog transition, so the existing backlog remains the only durable work database and a secondmate-owned captain call stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand is the mandatory captain-hold creation path: it uses an existing task or creates one when nothing exists to hold, records its UTC hold-set timestamp as the leading line of the task body, then invokes the underlying tasks-axi hold operation and verifies both records.
Publishing the stamp first ensures a snapshot cannot observe a newly captain-held task without the timestamp that defines its age.
Retries of an active hold preserve its hold-set timestamp, while re-holding released work starts a new timestamped lifecycle; a closed task is refused rather than reopened, and `--until` stores the captain's own deferral date through tasks-axi's date gate.
For a live ship record whose last event is plain `done:` with no open keyed decision, an active hold also appends one reserved-key `captain-held` declaration through the self-announced status writer.
`complete <id> <id>` repairs the same transition for an explicitly inventoried, still-completed ship whose hold was recorded directly in the backlog.
This does not exit an agent, merge a branch, or close the task; the existing watcher admits the bounded declared-wait cadence only for a confidently stopped ordinary worker, and a later worker event remains actionable.

The `answer` subcommand records the captain's exact words and resolves the call in the same act: it closes a question-shaped call, while `answer --release` frees a captain-gated work item to proceed without completing it.
It requires a non-empty captain decision file of at most 8192 bytes, durably writes a resolution block carrying the decision digest and a `Resolution mode:` while retaining the leading hold-set stamp until the selected `tasks-axi done` or `tasks-axi unhold` transition succeeds, then restores the successful record's resolution-first body ordering (the previous body remains preserved below the block and archived through tasks-axi `--archive-body`).
If the close is interrupted, the still-held task therefore keeps its original age basis.
A matching retry also completes any resolution-first normalization left unfinished after the close itself succeeded.
An exact retry is idempotent only when the requested close mode matches the newest record; a drifted answer or mode mismatch is rejected, while a re-held task accepts a new answer as a new record on top.
On a task closed outside the script, `answer` records the missing block only when the captain-hold annotations tasks-axi preserves through a close prove the captain owned it, and it verifies the task stays closed.
A hold whose `--until` date has passed keeps those annotations while tasks-axi reports it no longer held, so an expired deferral remains answerable.

The `complete` subcommand unions the reviewed captain-held task ids into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable tasks without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, refused while the origin still has a lifecycle-open keyed status decision, and verifies every listed task against tasks-axi before recording completion.
With a non-empty inventory it appends a `captain-held [key=<key>]: tracked by <inventory>` transfer event for every still-open keyed status decision, which `bin/fm-classify-lib.sh` recognizes as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the read-only `verify` subcommand after checking for the report and before removing any source state.
`verify` requires the recorded attestation, requires every recorded inventory entry to still be durable (actively captain-held, or carrying a recorded answer), and fails on any keyed status decision that opened after the last `complete`, which makes re-running `complete` the repair.
The `--force` path remains the explicit captain-approved discard escape hatch.

## Cleanup never closes a captain call

The policy prefers holding the very work item a question gates, so the backlog row a finished task's cleanup is about to close is routinely the captain's own call.
`bin/fm-teardown.sh` therefore asks the read-only `open` subcommand before its automatic close: exit 0 means the row is still an open captain call (not Done, `hold_kind: captain`), 1 means it is not, and 2 means the answer could not be established, which teardown treats as a refusal before any destructive step rather than as permission to close.
On 0 only the close changes: after cleanup and still under the task's own lock, teardown records one `Deliverable of the finished work: ...` line at the end of the task body, copies a supported pull request or canonical `data/<id>/report.md` into the row's structured artifact fields, and runs `tasks-axi reopen`, so the row returns to Queued with its hold intact and remains on the appropriate Captain's Call or Charted Next decision surface instead of reading as work still under way.
The pending-close record teardown already stages before destructive cleanup carries that intent as a `mode=retain` line, so an interrupted cleanup replays the retention at the next session start through the same record, validator, and lock as an ordinary close and never closes the row; if the captain answers before replay, `answer` validates that record and copies any supported retained pull request or report into the row before closing it, after which replay retires the record.
Two retained-delivery gaps remain bounded by tasks-axi 0.2.5 and are recorded for separate upstream work rather than representing defects introduced by this branch.
A retained local-only delivery cannot reach the row because `--note` exists on `tasks-axi done` but not on `tasks-axi update`, while the durable pending-close record carrying that note is retired when retention completes.
A relocated retained report cannot reach the row because tasks-axi accepts only `data/<id>/report.md`: `done` reports `Task report link must be a data/<id>/report.md path`, and `update` reports `--report must be a data/<id>/report.md path`.
When an interrupted retention leaves such a relocated report in the validated pending-close record, `answer` skips only that known-unsupported row artifact and closes normally, so the delivery remains absent from Recently Landed instead of wedging the captain's answer.
A pending-close record that fails validation outright is a different case and still refuses the answer, but the refusal names the record and the validation reason so the captain can repair it rather than facing a bare failure.
`--force` does not lift the deferral, because it authorizes discarding unlanded work, never the captain's question; only `answer` with the captain's words or a separately verified evidence-backed reconciliation resolves the call, by either closing the question or releasing the gated work.
`bin/fm-backlog-transition-lib.sh` owns the transition and its record, and `bin/fm-captain-hold.sh --help` owns the predicate's contract.

## Answer-time resolution through chat

"A keyed answer resolves its matching captain-held task" is one capability with one owner.
`answers` is its internal entry point: it reads `<task-id>\t<answer>\t<label>[\t<mode>]` lines and resolves each named task through the same `answer` path, so every guard applies identically.
The optional mode column carries a caller-declared resolution: `done` (default) completes the task and `release` lifts the hold so held work resumes; any other value is skipped.
A key that names no task, names a task that is not captain-held, or names a task already closed is reported as `skipped:` and feeds nothing; a replay whose answer and requested close mode match the newest record is an idempotent `closed:`, while a mode mismatch is skipped; and the command exits nonzero when any key was skipped.
`--source` is provenance text recorded in the durable decision, never a behavior switch.

The active captain-answer channel in this fork is chat.
`bin/fm-send.sh --resolve-key` is the chat channel: its status-log close for a key the status log still owns is owned by that script's header, and a key the status log no longer owns is resolved to a still-open captain-held task - the key as a task id, then the legacy derived identity - and fed as one keyed line.
The read-only Bearings board does not feed this intake, and any answer prompted by the board returns through chat.

## Evidence-backed reconciliation is not a board control

A captain call can stop being a question without the captain ever answering it because the subject lands, the premise turns out to be false, or the choice becomes a matter of fact rather than the captain's to make.
Reconciliation is an operator verification path, not an answer and not a third choice on the board.
It resolves in exactly one of two ways after the latest state has actually been checked: close the call with the evidence that made it moot, or leave it open with a note recording that it is genuinely still active.
Both outcomes require a pre-existing durable request and the operator input that supports the claim:

- `reconcile close <task-id> --evidence-file <path>` is the moot outcome.
  It writes a resolution record whose mode is `reconciled` and whose body is the supplied EVIDENCE under a `Reconciliation evidence:` label, then closes the task.
  The distinct mode and label are what keep the record honest: it says the call dissolved against verified evidence, and it never claims the captain answered.
- `reconcile note <task-id> --note-file <path>` is the still-active outcome.
  It appends one dated `Captain hold reconciled:` note to the task body, leaves the hold in place, and retires the request.
  The call stays the captain's, now carrying what the re-check found; a marker bound to the request timestamp, provenance, and note digest lets a matching retry finish retirement without appending again while a later request with the same finding still receives its own dated note.

`reconcile list` is the read-only enumeration of pending requests.
A successful normal answer also retires any pending request, because an answered call has no remaining re-check obligation.
Every retirement is checked: if request removal fails after an answer, close, or note is already durable, the durable outcome stands but the command fails and leaves the pending request visible for retry.
No path here closes a captain call without either the captain's words through `answer` or the evidence through `reconcile close`.
The Bearings board creates no request, exposes no reconciliation choice, and invokes no lifecycle mutation.

## Card hygiene: a landed subject is not a live call

`bin/fm-bearings-board.sh build` cross-checks every `decision` card before it publishes and drops stale subjects rather than trusting the composed inventory alone.

Three checks run, all on exact identity and none on prose:

- The card's key is the captain-held task id, so `bin/fm-captain-hold.sh open --distinguish-absent` is asked whether that task is still an open captain call.
  Exit 1 - present but closed, or no longer held for the captain - drops the card.
  Exit 2 means the answer could not be established and exit 3 means the task is absent from the main backlog, which includes a home carrying no backlog file at all; both keep the card, because a card wrongly shown is recoverable and a call wrongly hidden is not.
- The payload's own `landed` rows are the recently-landed artifacts.
  A decision card whose task id or `pr_url` appears among them has already shipped its subject, so it drops.
- A version decision can carry a structured `subject` with an artifact and numeric three-part version.
  A landed row carrying the same artifact at that version or a newer one supersedes the card without parsing prose.

Dropped cards are named on stderr as `dropped-landed-card:` lines so a rebuild states what it removed rather than quietly shrinking Captain's Call.
The landing procedure requires one immediate board rebuild to remove already-stale merged-PR and superseded-version cards without a committed migration or change-worktree state mutation.
A subject whose state cannot be established is kept, because a wrongly shown card is safer than a wrongly hidden call.
The emitted HTML is a read-only projection, so this hygiene creates no answer, merge, dispatch, or reconciliation operation and mutates no task.
The schema reserves the `reconcile` option value across all card types so input data cannot make the static board appear to offer a control it does not implement.
Owner-aware landedness checks for remote-secondmate decision cards remain tracked separately and must query the authoritative secondmate home while honoring the remote and local consistency principle.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)`, `(hold-kind: ...)`, and `(hold-until: ...)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records and keeps missing blockers unresolved.
It then assigns every captain hold exactly one `hold_bucket`, decided only from structured fields - `hold_kind`, `state`, `hold_until`, `unresolved_blocker_ids`, and the machine-written hold-set timestamp.
Hold reason and body prose are never matched, so no wording can hide, reveal, or reclassify a decision.
The buckets are total and mutually exclusive: `blocked` when any blocker is unresolved, else `dated` while `hold_until` is in the future, else `aged` when an undated hold's hold-set timestamp is at least `FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS` old (default 14, floored elapsed days), else `live`.
No captain hold can fall through them and none can match two, which is what keeps a hold from vanishing from every view.
`captain_actionable` - waiting on the captain now - is exactly `hold_bucket == "live"`.
Existing undated holds without a hold-set stamp fall back to the task's `since` date.
That aging is a projection safety net only.
The durable deferral remains re-holding with `--until`.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves every captain hold in the bounded queued inventory of the owning home.

`bin/fm-bearings-snapshot.sh` places each captain hold by its `hold_bucket` and inspects no prose of its own.
A `live` hold is a default Captain's Call entry.
A `blocked`, `dated`, or `aged` hold leaves the default Captain's Call, renders as a Charted Next gate stating why - the blocking work, the `until <date>`, or the floored age - and contributes to the concrete `omitted[]` disclosure.
`--all-decisions` reveals every captain hold available within the remote-summary bound and drops its gate, so an available hold is never in both Captain's Call and Charted Next.
An actively worked held task may also appear in Underway, which reports running work independently of those decision buckets.

Three accepted limits remain deliberate:

- A remote or secondmate hold retains the producer home's age and aging decision from the summary's capture time and threshold rather than being recomputed by the parent.
- A rare concurrent answer-close and re-hold race can leave the newly re-held task without its age basis.
- Cross-home summaries remain bounded by `FM_SNAPSHOT_SECONDMATE_DECISIONS` and `FM_SNAPSHOT_SECONDMATE_QUEUED`; a remote deferred hold beyond those bounds is not exported, so it can be neither gated nor revealed.

Re-holding through the wrapper with `--until` remains the durable fix rather than relying on the projection safety net.
[`bin/fm-landed-lib.sh`](../bin/fm-landed-lib.sh) owns Recently Landed's shared selection and artifact-display compatibility rules.
A local-only landing's note is written by `tasks-axi done --note` as the last of the row's indented body lines rather than into the row title, so the snapshot reads that final line as the note as well as parsing the title, and the landing is published carrying its recorded note.
A body that carries a captain resolution record is the captain's own prose and is never mined for that note, so a decision worded `local main` does not become a delivery artifact.
The projection remains read-only and uses the canonical snapshot's structured fields, including the machine-written hold-set timestamp.

The window between a merge landing and cleanup is an accepted structural residual rather than an oversight.
That local window is normally only seconds wide and requires re-holding a task whose merge has just landed.
A re-hold inside the window makes cleanup retain the row rather than publish it, so the delivery is omitted until the stale hold is cleared from that row.
Queued forge merges cannot be covered locally because the forge performs the merge asynchronously after the local command has returned, when no lock this code could hold would still be held.

## Record divergence

A captain call can have two records, and closing one does not close the other.
A `resolved [key=...]` line closes the status-log fold; the structured captain-held task closes only through `answer`.
Until this guard existed, closing on the status side alone left no trace of the disagreement: the fold went quiet, the durable record kept saying the captain owed an answer, and nothing warned.

`bin/fm-captain-hold.sh diverged` is the read-only report of that state, and `bin/fm-wake-drain.sh` prints it as a bounded `RECORD DIVERGENCE` section beside OPEN DECISIONS on every drain.
It flags exactly one condition: a task still open and still carrying the captain-hold annotations, whose key was closed on the status side by the resolve verb, resolved through the collapsed identity (the key is the task id) or the legacy derived one.
It closes nothing, ever - a captain call closed wrongly leaves review entirely, so both reconciliation directions stay human-owned and the printed hint names both.

Three states are deliberately not divergence.
A `captain-held [key=...]` close is the verified transfer `complete` writes, so the structured row staying open behind it is correct; `bin/fm-classify-lib.sh`'s `status_key_closing_verb` is what keeps the two closing verbs distinguishable.
A still-open keyed status decision belongs to the OPEN DECISIONS fold.
And the absence of a routed work item is legitimate rather than incomplete - when the decision is the deliverable there is nothing to route - so routed work is no part of the test.

Cost stays flat: one `tasks-axi list`, one key scan per status log, and the precise per-key fold only for a key that already names a still-open task.
The comparison is refused unless the status directory is the active home's own, since tasks-axi reads that home's backlog and a mismatch would report one home's logs against another's tasks.
If tasks-axi is unavailable or its listing cannot be parsed, the guard cannot read the structured record and prints nothing.

## Compatibility with pre-collapse installs

Older installs created derived `<origin>-decision-<key>` identities through the retired `bin/fm-decision-hold.sh`.
Those rows are already plain task ids, so they render, answer, verify, and close through the collapsed surfaces with no data migration.
Three legacy inputs are resolved in place: a `decision_keys=` metadata entry that names no task resolves through `<origin>-decision-<entry>`; a channel key that names no task resolves the same way when its caller supplies a concrete legacy origin; and resolution records written by the old script are recognized wherever a record is read.
On the Beads backend, an attested legacy markdown id that resolves to no task is accepted through the row the markdown-to-beads hold migration produced, found by the authoritative evidence first: a row whose notes carry the marker line `migrated from data/backlog.md id <legacy id>`, either alone or followed by ` on <date>` as fm-hold-migration wrote it on 2026-09-04.
Only when no row carries that marker line is the legacy id tried under the configured beads prefix, and that name-only guess is accepted solely for a single row still held for the captain - two such rows refuse rather than attest.
Because that acceptance rests on a name rather than on evidence, `complete` names the resolved row beside each prefix-attested legacy id in its completion line, so the guess is auditable after the fact.
A markdown home keeps its legacy rows verbatim, so its resolution is unchanged.
The shim recognizes an exact replay of a pre-collapse routed resolution by its historical answer digest and routed ids, then finishes any still-recorded dependency-edge cleanup without rewriting the old decision text.
`bin/fm-decision-hold.sh` itself remains for one release as a thin command-mapping shim over `bin/fm-captain-hold.sh`, so in-flight work briefed before the collapse keeps working; its header owns the exact mapping.

## Verification record

On 2026-09-09, the lifecycle suite additionally verifies the plain-done ship transition through both owner `hold` and direct backlog hold followed by owner `complete`, retry idempotence, preserved merge authority, and refusal to cover a later permission event.
The same end-to-end case verifies that an unmerged, in-flight captain-held ship appears in Bearings' Captain's Call rather than disappearing into a generic gate.
`tests/fm-watch-triage.test.sh` bridges the real task/hold commands to a real watcher with a synthetic stopped Codex endpoint: the declared wait stays quiet after exit and a pane change, but a subsequent blocked event wakes immediately.
Its existing stopped/live-gate and deferred-resurface cases retain the bounded recheck and live-permission safety boundaries.

The focused end-to-end regression suite is `tests/fm-captain-hold-lifecycle.test.sh`, using only synthetic `sample` identities and decision text.
It proves that cleanup of a finished task whose own row is the captain call leaves that call open, queued, held, carrying its deliverable, and visible in Bearings' Captain's Call, leaves no pending record behind, survives a `--force` cleanup, and closes only when `answer` records the captain's words, while an ordinary finished task in the same home still closes with its report link.
It proves that an interrupted cleanup leaves the row In flight and untouched with its pending record, the next session start retains it as queued and held with the deliverable recorded when it remains unanswered, and an answer before replay preserves that record's completed report while closing the call so the next session start retires the satisfied record without losing the delivery from Recently Landed.
A pending-close record that cannot be validated refuses the answer while naming the record and the reason, and a relocated data directory keeps retention in its one configured backlog.
Direct PR and local-only merge entrypoint calls refuse a still-held task before reaching the forge or moving local main, while a released pull request passes the guarded PR entrypoint, cleanup records its artifact, and Recently Landed publishes it.
An ordinary release still survives zero-retention cleanup and archives when configured, while a ship row whose captain hold cannot be read refuses cleanup before any destructive step and surfaces the read failure.
The reconstructed silent-divergence case is signalled under both collapsed and legacy identities while the backlog task, its hold, and the status log survive unchanged, and the false-signal fixtures stay silent.
A released call whose decision text is `local main`, closed with no artifact, is not published as a local-only landing; report-only unresolved calls refuse `--none` completion before teardown can erase the source; and non-forced scout teardown always requires durable inventory verification.
The recorded-answer guard rejects a bare `tasks-axi done` close until `answer` records the captain's words and prevents an ordinary finished task from masquerading as an answered call.
The same suite pins answer-time resolution with task-id keys, `release` mode, replay idempotence, refusal of drifted or ineligible keys, the chat channel reaching the shared intake, hold-set stamping before visible hold state, timestamp preservation across interruption, due-date deferral, and every legacy identity path.
The suite does not test the accepted merge-to-cleanup re-hold window or asynchronous queued-forge landing because those events occur after the locally serialized merge command has returned.
The markdown-to-beads migration family runs the same suite's beads fixture (bd-driven scratch graph, self-skipping on markdown-only tasks-axi installs) and proves: `verify` and `complete` resolve an attested legacy id through a migrated row's marker note, through the configured prefix when no row carries a note - naming the resolved row in the completion line - and through the marker note of a pre-collapse derived identity; a marker-noted row wins over an unrelated captain-held row occupying the bare prefix namesake; an unresolvable id is refused once naming the id (never an empty name); and the attested id stays in `decision_keys=` for idempotent re-verification.
One case in that family needs no beads install and always runs: a stubbed tasks-axi that fails any markdown file override proves the captain-hold hold, answer, and close mutations reach a beads-configured home without one.

The lifecycle suite separately pins evidence-backed reconciliation against pre-existing durable requests, including idempotent close and note outcomes, without treating the evidence as the captain's words.
Those cases exercise the lifecycle repair mechanism only; the read-only board originates no request and offers no reconciliation option.
The board's half is pinned in `tests/fm-bearings-board.test.sh`: it validates and injects a local HTML payload, registers no answer source, refreshes the stable file in place, drops exactly identified landed subjects, keeps uncertain or remote subjects visible, and rejects the reserved `reconcile` value instead of presenting a nonfunctional control.
`tests/fm-bearings-board-render.test.sh` verifies that decision and queued rows render without answer, merge, dispatch, or reconciliation controls.

`tests/fm-classify-decision-key.test.sh` pins `status_key_closing_verb` itself: it separates a resolution from the durable-transfer close and from a still-open key, reports the last real transition across re-openings and both key positions, and treats a prose mention as no transition.

Projection regressions live in `tests/fm-fleet-snapshot-view.test.sh` (the total structured-only bucket classifier, hold-until parsing, kind-independent captain actionability, undated-hold aging, and title stripping) and `tests/fm-bearings-snapshot.test.sh` (default and expanded decision-bucket membership, deferral explanations, blocker-overflow disclosure, working-hold dual surfaces, remote-summary schema invalidation, exact leading-kind inference, artifact-kind mismatch and answered-question exclusion, kind-bearing and kindless local-only landings publishing their recorded note, and scout-report precedence over competing pull-request links).
The exact commands and their summarized outputs are recorded in the shipping PR's evidence; run `tests/fm-captain-hold-lifecycle.test.sh`, `tests/fm-watch-triage.test.sh`, `tests/fm-fleet-snapshot-view.test.sh`, `tests/fm-bearings-snapshot.test.sh`, `tests/fm-bearings-board.test.sh`, `tests/fm-bearings-board-render.test.sh`, `tests/fm-send-resolve-key.test.sh`, and `bin/fm-lint.sh` to refresh this record.
