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

The `answer` subcommand records the captain's exact words and resolves the call in the same act.
It requires a non-empty captain decision file of at most 8192 bytes and durably writes a resolution block carrying the decision digest and a `Resolution mode:` while retaining the leading hold-set stamp until the close succeeds, with the previous body preserved below the block and archived through tasks-axi `--archive-body`.
The default close delegates to `bin/fm-backlog-transition-lib.sh` so its completion-provenance contract also applies, while `--release` uses `tasks-axi unhold` so a captain-gated work item resumes instead of closing.
After either close succeeds, it restores the successful record's resolution-first body ordering.
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
On 0 only the final state transition changes: after cleanup and still under the task's own lock, teardown records one machine-owned `firstmate-completion.v1` JSON record at the end of the task body and runs `tasks-axi reopen`, so the row returns to Queued with its hold intact and remains on the appropriate Captain's Call or Charted Next decision surface instead of reading as work still under way.
`bin/fm-backlog-transition-lib.sh` applies the same completion-provenance writer to ordinary close and retained captain-call paths, and `bin/fm-fleet-snapshot.sh` tolerates the earlier `Deliverable of the finished work: ...` shape written on this branch.
The pending-close record teardown already stages before destructive cleanup carries that intent as a `mode=retain` line, so an interrupted cleanup replays the retention at the next session start through the same record, validator, and lock as an ordinary close and never closes the row; an answer that closes the row first preserves the retained completion before replay retires the satisfied record.
`--force` does not lift the deferral, because it authorizes discarding unlanded work, never the captain's question, and `answer` remains the only act that closes the call.
`bin/fm-backlog-transition-lib.sh` owns the transition and its record, and `bin/fm-captain-hold.sh --help` owns the predicate's contract.

## Answer-time closure

"A keyed answer closes its matching captain-held task" is one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<task-id>\t<answer>\t<label>[\t<mode>]` lines and closes each named task through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
The optional mode column carries a card-declared close: `done` (default) completes the task and `release` lifts the hold so held work resumes; any other value is skipped.
A key that names no task, names a task that is not captain-held, or names a task already closed is reported as `skipped:` and feeds nothing; a replay whose answer and requested close mode match the newest record is an idempotent `closed:`, while a mode mismatch is skipped; and the command exits nonzero when any key was skipped.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch.

`bind`, `unbind`, and `binding` record that a captured-answer source feeds this intake, as a private record under `state/decision-bindings/`; an unbound source feeds nothing, so the path is opt-in per source, and `bind` deliberately does not require the source to exist yet.

Two channels feed that one intake today, and both are ordinary callers rather than special cases.
`bin/fm-send.sh --resolve-key` is the chat channel: its status-log close for a key the status log still owns is owned by that script's header, and a key the status log no longer owns is resolved to a still-open captain-held task - the key as a task id, then the legacy derived identity - and fed as one keyed line.
`bin/fm-procevent.sh` is the captured-result channel: after capture, a bound built-in source has its result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>` and whatever that prints is piped into the intake, so any built-in adapter with an `answers` command works and the runner names no adapter, parses no result, and carries no decision rule.
Trusted external process-event adapters intentionally expose no answer operation and cannot feed this authority-bearing intake; [`extension-bindings.md`](extension-bindings.md#trust-boundary) owns that boundary.
`bin/fm-procevent-lavish.sh answers` is one such adapter command; it reads only rows tagged `choice`, relays a card's declared close mode, and can never let freeform captain prose forge a task id or a mode.

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
`bin/fm-landed-lib.sh` owns the shared Recently Landed predicate: machine-owned completion provenance is authoritative when present, while its named legacy fallback handles rows written before provenance existed.
This lets captain-approved deliveries land regardless of surviving `hold-kind: captain` metadata while recorded non-deliveries remain excluded.
The projection remains read-only and uses the canonical snapshot's structured fields, including the machine-written hold-set timestamp and completion-provenance marker.

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
Three legacy inputs are resolved in place: a `decision_keys=` metadata entry that names no task resolves through `<origin>-decision-<entry>`; a channel key that names no task resolves the same way when the source's binding carries a concrete legacy origin; and resolution records written by the old script are recognized wherever a record is read.
On the Beads backend, an attested legacy markdown id that resolves to no task is accepted through the row the markdown-to-beads hold migration produced, found by the authoritative evidence first: a row whose notes carry the marker line `migrated from data/backlog.md id <legacy id>`, either alone or followed by ` on <date>` as fm-hold-migration wrote it on 2026-09-04.
Only when no row carries that marker line is the legacy id tried under the configured beads prefix, and that name-only guess is accepted solely for a single row still held for the captain - two such rows refuse rather than attest.
Because that acceptance rests on a name rather than on evidence, `complete` names the resolved row beside each prefix-attested legacy id in its completion line, so the guess is auditable after the fact.
A markdown home keeps its legacy rows verbatim, so its resolution is unchanged.
The shim recognizes an exact replay of a pre-collapse routed resolution by its historical answer digest and routed ids, then finishes any still-recorded dependency-edge cleanup without rewriting the old decision text.
`bin/fm-decision-hold.sh` itself remains for one release as a thin command-mapping shim over `bin/fm-captain-hold.sh`, so in-flight work briefed before the collapse keeps working; its header owns the exact mapping.

## Verification record

Verification date: 2026-09-05.

The focused end-to-end regression suite is `tests/fm-captain-hold-lifecycle.test.sh`, using only synthetic `sample` identities and decision text.
It proves: cleanup of a finished task whose own row is the captain call leaves that call open, queued, held, carrying its deliverable, and visible in Bearings' Captain's Call, leaves no pending record behind, survives a `--force` cleanup, and closes only when `answer` records the captain's words, while an ordinary finished task in the same home still closes with its report link; an interrupted cleanup leaves the row In flight and untouched with its pending record, the next session start retains it as queued and held with the deliverable recorded when it remains unanswered, and an answer before replay preserves that record's completed report while closing the call so the next session start retires the satisfied record without losing the delivery from Recently Landed; a relocated data directory keeps the retention in its one configured backlog and preserves the exact report operand into Recently Landed after answer; merge approval releases the held work before cleanup records the shipped PR and closes it, including when completed rows are immediately archived; a ship row whose captain hold cannot be read refuses cleanup before any destructive step and surfaces the read failure; the reconstructed silent-divergence case is signalled - a status resolution over a still-open captain-held task reaches both `diverged` and the drain's `RECORD DIVERGENCE` section, under the collapsed and the legacy identity alike, while the backlog task, its hold, and the status log all survive the report unchanged and the printed hint names both reconciliation directions; the false-signal boundary holds - a captain call with no routed work item, a verified `captain-held` transfer, a still-open status decision, an already answered call, and an ordinary task whose keyed question was answered all stay silent; a report-only unresolved captain call refuses `--none` completion before teardown can erase the source; non-forced scout teardown always requires the durable inventory verification; the recorded-answer guard (a bare `tasks-axi done` close fails `verify` until `answer` records the captain's word, and an ordinary finished task cannot be dressed up as an answered call); answer-time closure through a bound channel with task-id keys, including the `release` close mode, mode-matched replay idempotence, and the refusal of drifted, mode-mismatched, absent, unheld, and already-closed keys; the chat channel reaching the same intake; hold-set stamping that precedes visible hold state, preserves an active lifecycle's timestamp, and resets after release; interrupted answer closure retaining the stamp until close and restoring resolution-first ordering on retry; deferral through `--until` leaving `captain_actionable` false until due; and every legacy path (composed identities through the shim, pre-collapse `decision_keys=` metadata, routed-resolution replay, and a concrete-origin binding).
The markdown-to-beads migration family runs the same suite's beads fixture (bd-driven scratch graph, self-skipping on markdown-only tasks-axi installs) and proves: `verify` and `complete` resolve an attested legacy id through a migrated row's marker note, through the configured prefix when no row carries a note - naming the resolved row in the completion line - and through the marker note of a pre-collapse derived identity; a marker-noted row wins over an unrelated captain-held row occupying the bare prefix namesake; an unresolvable id is refused once naming the id (never an empty name); and the attested id stays in `decision_keys=` for idempotent re-verification.
One case in that family needs no beads install and always runs: a stubbed tasks-axi that fails any markdown file override proves the captain-hold hold, answer, and close mutations reach a beads-configured home without one.

`tests/fm-classify-decision-key.test.sh` pins `status_key_closing_verb` itself: it separates a resolution from the durable-transfer close and from a still-open key, reports the last real transition across re-openings and both key positions, and treats a prose mention as no transition.

Projection regressions live in `tests/fm-fleet-snapshot-view.test.sh` (the total structured-only bucket classifier, hold-until parsing, kind-independent captain actionability, undated-hold aging, and title stripping) and `tests/fm-bearings-snapshot.test.sh` (default and expanded decision-bucket membership, deferral explanations, blocker-overflow disclosure, working-hold dual surfaces, remote-summary schema invalidation, and provenance-based Recently Landed selection with its legacy fallback).
The exact commands and their summarized outputs are recorded in the shipping PR's evidence; run the four suites above plus `tests/fm-send-resolve-key.test.sh`, `tests/fm-bearings-board.test.sh`, and `bin/fm-lint.sh` to refresh this record.
