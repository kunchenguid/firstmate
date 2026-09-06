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

The `answer` subcommand records the captain's exact words and closes the call in the same act.
It requires a non-empty captain decision file of at most 8192 bytes, durably writes a resolution block carrying the decision digest and a `Resolution mode:` while retaining the leading hold-set stamp until `tasks-axi done` or, under `answer --release`, `tasks-axi unhold` succeeds, then restores the successful record's resolution-first body ordering (the previous body remains preserved below the block and archived through tasks-axi `--archive-body`).
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
On 0 only the close changes: after cleanup and still under the task's own lock, teardown records one `Deliverable of the finished work: ...` line at the end of the task body and runs `tasks-axi reopen`, so the row returns to Queued with its hold intact and remains on the appropriate Captain's Call or Charted Next decision surface instead of reading as work still under way.
The pending-close record teardown already stages before destructive cleanup carries that intent as a `mode=retain` line, so an interrupted cleanup replays the retention at the next session start through the same record, validator, and lock as an ordinary close and never closes the row; an answer that closed the row first simply retires the record.
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

## Reconcile: re-check reality, never a blind close

A captain call can stop being a question without the captain ever answering it.
The subject lands, the premise turns out to be false, or the choice becomes a matter of fact rather than the captain's to make.
Before this path existed the only closing act was `answer`, which requires the captain's exact words, so a call that had simply gone moot either sat live on the board forever or got closed with words the captain never said.

`reconcile` is the standing third option for that case, and its whole point is that it is NOT an answer.
It means "go verify the latest state", and it resolves in exactly one of two ways once that verification has actually been done: close the call with the evidence that made it moot, or leave it open with a note recording that it is genuinely still active.

The value remains reserved at the shared keyed-answer intake, which visibly refuses it from every channel and never passes it to `answer`.
A reconcile value delivered through chat or any ordinary keyed-answer caller therefore cannot complete a task, lift a hold, write a resolution record, or create a reconcile request.

Board request creation uses a separate captured-source seam.
The board emits `fm-bearings-answer.v1` context with the slug-shaped selected option and freeform note in separate fields, so annotating Reconcile cannot turn it into an ordinary answer value.
`bin/fm-procevent-lavish.sh answers` emits an exact non-reconcile selection, or a bare note when no option was selected, while `reconciles` emits only task ids whose structured selection is Reconcile and carries their notes as request provenance.
Both commands require the versioned shape and rows tagged `choice`; an older or structurally uncertain capture feeds neither intake, remains announced, and cannot forge a task id from freeform prose.
The adapter-agnostic runner pipes reconcile rows into `reconcile-requests` only for a bound source, and that intake verifies the named binding again before it creates anything.
Failures remain best-effort and never acknowledge or suppress the captured result.
What this board-only intake records is a durable reconcile request under `state/reconcile-requests/`, one private record per task, carrying the requesting provenance and a UTC timestamp.
The record exists so the obligation to re-check cannot be lost between the wake that carried the answer and the turn that acts on it.
It is idempotent per task: repeating a reconcile keeps one request and its original timestamp.
Only the captain's board selection creates this request; there is no standalone command that opens one.

Verification retires a request through one of two outcomes, and each one requires both the pending board-created request and the operator input that supports its claim:

- `reconcile close <task-id> --evidence-file <path>` is the moot outcome.
  It writes a resolution record whose mode is `reconciled` and whose body is the supplied EVIDENCE under a `Reconciliation evidence:` label, then closes the task.
  The distinct mode and label are what keep the record honest: it says the call dissolved against verified evidence, and it never claims the captain answered.
- `reconcile note <task-id> --note-file <path>` is the still-active outcome.
  It appends one dated `Captain hold reconciled:` note to the task body, leaves the hold in place, and retires the request.
  The call stays the captain's, now carrying what the re-check found; a marker bound to the request timestamp, provenance, and note digest lets a matching retry finish retirement without appending again while a later request with the same finding still receives its own dated note.

`reconcile list` is the read-only enumeration of pending requests filed by board answers.
A successful normal answer also retires any pending request, because an answered call has no remaining re-check obligation.
Every retirement is checked: if request removal fails after an answer, close, or note is already durable, the durable outcome stands but the command fails and leaves the pending request visible for retry.
No path here closes a captain call without either the captain's words through `answer` or the evidence through `reconcile close`.

## Card hygiene: a landed subject is not a live call

A board rebuilt from a stale inventory used to card decisions whose subject had already shipped, which put work the captain had finished back in front of him as an open call.
`bin/fm-bearings-board.sh build` therefore cross-checks every `decision` card before it publishes, and drops the stale ones rather than trusting the composer to have remembered.

Three checks run, all on exact identity and none on prose:

- The card's key is the captain-held task id, so `bin/fm-captain-hold.sh open` is asked whether that task is still an open captain call.
  Exit 1 - closed, or no longer held for the captain - drops the card.
  Exit 2 means the answer could not be established, and the card is kept, because a card wrongly shown is recoverable and a call wrongly hidden is not.
- The payload's own `landed` rows are the recently-landed artifacts.
  A decision card whose task id or `pr_url` appears among them has already shipped its subject, so it drops.
- A version decision can carry a structured `subject` with an artifact and numeric three-part version.
  A landed row carrying the same artifact at that version or a newer one supersedes the card, so the published quota-axi 0.1.38 release drops a 0.1.37 call without parsing prose.

Dropped cards are named on stderr as `dropped-landed-card:` lines so a rebuild states what it removed rather than quietly shrinking Captain's Call.
As a committed delivery step, firstmate rebuilds the board immediately after landing this change; that rebuild performs the captain-authorized one-time cleanup of already-stale cards, including merged-PR and superseded-version cards, without a committed migration or live-state mutation from the change worktree.
A subject whose state cannot be established is kept, because a wrongly shown card is safer than a wrongly hidden call.
The validator's reservation scope must equal the adapter's reconcile-classification scope, which is all card types because the captured payload carries no card type.
The reconcile option is the recovery path for whatever still slips through.

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
Recently Landed excludes a record that closed while still held for the captain (surviving `hold-kind: captain` on a Done row), so answered questions do not masquerade as shipped work; a work item released before completion keeps no hold annotations and lands normally.
The projection remains read-only and uses the canonical snapshot's structured fields, including the machine-written hold-set timestamp.

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

Verification date: 2026-09-06.

The focused end-to-end regression suite is `tests/fm-captain-hold-lifecycle.test.sh`, using only synthetic `sample` identities and decision text.
It proves: cleanup of a finished task whose own row is the captain call leaves that call open, queued, held, carrying its deliverable, and visible in Bearings' Captain's Call, leaves no pending record behind, survives a `--force` cleanup, and closes only when `answer` records the captain's words, while an ordinary finished task in the same home still closes with its report link; an interrupted cleanup leaves the row In flight and untouched with its pending record, and the next session start retains it as queued and held with the deliverable recorded; a relocated data directory keeps the retention in its one configured backlog; a ship row whose captain hold cannot be read refuses cleanup before any destructive step and surfaces the read failure; the reconstructed silent-divergence case is signalled - a status resolution over a still-open captain-held task reaches both `diverged` and the drain's `RECORD DIVERGENCE` section, under the collapsed and the legacy identity alike, while the backlog task, its hold, and the status log all survive the report unchanged and the printed hint names both reconciliation directions; the false-signal boundary holds - a captain call with no routed work item, a verified `captain-held` transfer, a still-open status decision, an already answered call, and an ordinary task whose keyed question was answered all stay silent; a report-only unresolved captain call refuses `--none` completion before teardown can erase the source; non-forced scout teardown always requires the durable inventory verification; the recorded-answer guard (a bare `tasks-axi done` close fails `verify` until `answer` records the captain's word, and an ordinary finished task cannot be dressed up as an answered call); answer-time closure through a bound channel with task-id keys, including the `release` close mode, mode-matched replay idempotence, and the refusal of drifted, mode-mismatched, absent, unheld, and already-closed keys; the chat channel reaching the same intake; hold-set stamping that precedes visible hold state, preserves an active lifecycle's timestamp, and resets after release; interrupted answer closure retaining the stamp until close and restoring resolution-first ordering on retry; deferral through `--until` leaving `captain_actionable` false until due; and every legacy path (composed identities through the shim, pre-collapse `decision_keys=` metadata, routed-resolution replay, and a concrete-origin binding).
The markdown-to-beads migration family runs the same suite's beads fixture (bd-driven scratch graph, self-skipping on markdown-only tasks-axi installs) and proves: `verify` and `complete` resolve an attested legacy id through a migrated row's marker note, through the configured prefix when no row carries a note - naming the resolved row in the completion line - and through the marker note of a pre-collapse derived identity; a marker-noted row wins over an unrelated captain-held row occupying the bare prefix namesake; an unresolvable id is refused once naming the id (never an empty name); and the attested id stays in `decision_keys=` for idempotent re-verification.
One case in that family needs no beads install and always runs: a stubbed tasks-axi that fails any markdown file override proves the captain-hold hold, answer, and close mutations reach a beads-configured home without one.

The reconcile path is pinned in the same suite: a reconcile answer arriving through the keyed-answer intake, in the default close mode and in the `release` mode a captain-gated work card declares, leaves both tasks held with no resolution record, is reported and counted as a reconcile rather than a close, and records one durable request per task idempotently across a replay.
It also proves the two verification outcomes - an evidence-backed `reconciled` close that records the evidence under its own label and never as the captain's words, and a note that leaves the call queued, held, and dated - while both outcomes refuse without a pending board request, each durable mutation applies only once across close, probe, and request-retirement failures, a later distinct request with the same note still appends its own dated record, every failed retirement is surfaced with its pending request retained, incompatible resolution modes cannot replay as captain answers, and normal close, release, and replay paths retire pending requests.
The captured-source coverage proves Lavish deduplicates each card before separating versioned structured selections from notes, bare and annotated Reconcile choices never reach keyed answers, genuine choices with and without notes still close normally, unversioned choices feed neither intake, mixed repeated selections preserve every other card's final value, the generic runner creates a request only through a verified bound source, chat reconcile text creates none, and the resulting board request authorizes evidence-backed closure.
The board's half is pinned in `tests/fm-bearings-board.test.sh`: every published decision card carries exactly one reconcile option, authored options reserve that value across every card type, recommendations name authored options, a decision card whose structured subject appears in the payload's landed rows is dropped while a genuinely open one is kept even when an unrelated landed id contains its key after a newline, a build requires a fresh authoritative listed-open result before binding or arming, a reopen retires the pre-reopen source generation and waits for a fresh live listener, and a rebuild of an already-armed board with no live listener starts one.
That suite drives its Lavish session through a stub reproducing the shapes verified against lavish-axi 0.1.61, and `tests/fm-bearings-board-lavish-live-e2e.test.sh` is the opt-in guard that re-proves those shapes and the reopen against the installed lavish-axi (`FM_BEARINGS_LAVISH_LIVE=1`), ending the session it opens through the same server route the browser's End session button calls.
`tests/fm-procevent.test.sh` pins the ownership half: a dead generation whose recorded state-root identity no longer matches is reclaimed by reconcile into a replacement that actually runs, `retire` releases the same claim instead of refusing, and neither a live generation nor a crashed leader whose owned group survives is reclaimed under that same drift.

`tests/fm-classify-decision-key.test.sh` pins `status_key_closing_verb` itself: it separates a resolution from the durable-transfer close and from a still-open key, reports the last real transition across re-openings and both key positions, and treats a prose mention as no transition.

Projection regressions live in `tests/fm-fleet-snapshot-view.test.sh` (the total structured-only bucket classifier, hold-until parsing, kind-independent captain actionability, undated-hold aging, and title stripping) and `tests/fm-bearings-snapshot.test.sh` (default and expanded decision-bucket membership, deferral explanations, blocker-overflow disclosure, working-hold dual surfaces, remote-summary schema invalidation, and the landed exclusion by surviving captain-hold annotations).
The exact commands and their summarized outputs are recorded in the shipping PR's evidence; run the four suites above plus `tests/fm-send-resolve-key.test.sh`, `tests/fm-bearings-board.test.sh`, `tests/fm-procevent.test.sh`, and `bin/fm-lint.sh` to refresh this record, and `FM_BEARINGS_LAVISH_LIVE=1 tests/fm-bearings-board-lavish-live-e2e.test.sh` after a lavish-axi upgrade.
