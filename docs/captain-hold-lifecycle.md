# Captain-hold lifecycle mechanism

This document explains how a captain call is held, answered, reconciled, shown, and verified.
It is for maintainers changing `bin/fm-captain-hold.sh` or any surface that reads or closes a captain hold.

The normative policy is owned by `.agents/skills/captain-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, compatibility contract, and privacy-safe regression evidence.

## Find a topic

| Question | Section |
| --- | --- |
| What is a captain call, and which subcommand does what? | [Mechanism](#mechanism) |
| Why does cleanup of finished work leave a captain call open? | [Cleanup never closes a captain call](#cleanup-never-closes-a-captain-call) |
| How does a keyed answer from chat or a board reach the call? | [Answer-time resolution](#answer-time-resolution) |
| How is a call closed when it stopped being a question? | [Reconcile](#reconcile-re-check-reality-never-a-blind-close) |
| Why did a decision card disappear from the board? | [Card hygiene](#card-hygiene-a-landed-subject-is-not-a-live-call) |
| Where does a hold appear in snapshots and Bearings? | [Structured read surfaces](#structured-read-surfaces) |
| What does a `RECORD DIVERGENCE` section mean? | [Record divergence](#record-divergence) |
| How do rows from older installs still work? | [Compatibility with pre-collapse installs](#compatibility-with-pre-collapse-installs) |
| Which tests prove this, and how is the record refreshed? | [Verification record](#verification-record) |

## Mechanism

A decision is not a separate thing in this system.
It is an ordinary backlog task held for the captain, and the task id is the identity every surface and channel uses.
`bin/fm-captain-hold.sh` is the only lifecycle command layered on that primitive.
The command addresses the active home's configured data directory.
As a result, the existing backlog remains the only durable work database, and a secondmate-owned captain call stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

### Subcommands at a glance

| Subcommand | What it does | Details |
| --- | --- | --- |
| `hold` | Creates or reuses a task and holds it for the captain. | [Creating a hold](#creating-a-hold-hold) |
| `answer` | Records the captain's exact words and resolves the call. | [Answering a call](#answering-a-call-answer) |
| `complete` | Records the reviewed captain-held task ids in the originating task's metadata. | [Recording a reviewed inventory](#recording-a-reviewed-inventory-complete) |
| `verify` | Read-only check that scout teardown runs before removing source state. | [Checking before scout teardown](#checking-before-scout-teardown-verify) |
| `open` | Read-only check of whether a row is still an open captain call. | [Cleanup never closes a captain call](#cleanup-never-closes-a-captain-call) |
| `answers` | Channel-agnostic entry point for keyed answers. | [Answer-time resolution](#answer-time-resolution) |
| `bind`, `unbind`, `binding` | Record that a captured-answer source feeds the keyed-answer intake. | [Source bindings](#source-bindings) |
| `reconcile-requests` | Internal intake that records a reconcile request from a board selection. | [Reconcile](#reconcile-re-check-reality-never-a-blind-close) |
| `reconcile close`, `reconcile note`, `reconcile list` | Retire or list pending reconcile requests. | [Verifying and retiring a request](#verifying-and-retiring-a-request) |
| `diverged` | Read-only report of a call whose two records disagree. | [Record divergence](#record-divergence) |

### Creating a hold (`hold`)

The `hold` subcommand is the mandatory captain-hold creation path.
It works in this order:

1. It uses an existing task, or creates one when nothing exists to hold.
2. It records the task's UTC hold-set timestamp as the leading line of the task body.
3. It invokes the underlying tasks-axi hold operation.
4. It verifies both records.

Publishing the stamp first ensures a snapshot cannot observe a newly captain-held task without the timestamp that defines its age.

Repeat and edge cases:

- Retries of an active hold preserve its hold-set timestamp.
- Re-holding released work starts a new timestamped lifecycle.
- A closed task is refused rather than reopened.
- `--until` stores the captain's own deferral date through tasks-axi's date gate.

### Answering a call (`answer`)

The `answer` subcommand records the captain's exact words and resolves the call in the same act.

| Form | Effect |
| --- | --- |
| `answer` | Closes a question-shaped call. |
| `answer --release` | Frees a captain-gated work item to proceed without completing it. |

It requires a non-empty captain decision file of at most 8192 bytes.
It then works in this order:

1. It durably writes a resolution block carrying the decision digest and a `Resolution mode:`.
2. It retains the leading hold-set stamp until the selected `tasks-axi done` or `tasks-axi unhold` transition succeeds.
3. It then restores the successful record's resolution-first body ordering.
   The previous body remains preserved below the block and archived through tasks-axi `--archive-body`.

If the close is interrupted, the still-held task therefore keeps its original age basis.
A matching retry also completes any resolution-first normalization left unfinished after the close itself succeeded.

### Answer retries and tasks closed elsewhere

- An exact retry is idempotent only when the requested close mode matches the newest record.
- A drifted answer or a mode mismatch is rejected.
- A re-held task accepts a new answer as a new record on top.

On a task closed outside the script, `answer` records the missing block only when the captain-hold annotations tasks-axi preserves through a close prove the captain owned it.
It also verifies the task stays closed.

A hold whose `--until` date has passed keeps those annotations while tasks-axi reports it no longer held.
An expired deferral therefore remains answerable.

### Recording a reviewed inventory (`complete`)

While originating task metadata is live, the `complete` subcommand unions the reviewed captain-held task ids, called the reviewed inventory, into `decision_keys=` and appends `decisions_reviewed=1`.
A post-teardown visual review can complete against the surviving report and durable tasks without recreating volatile task metadata.

`complete` accepts `--none` as an explicit semantic inventory result.
`--none` is refused while the origin still has a lifecycle-open keyed status decision.
Before recording completion, `complete` verifies every listed task against tasks-axi.

With a non-empty inventory, `complete` appends a `captain-held [key=<key>]` transfer event for every still-open keyed status decision.
The event names the reviewed inventory.
`bin/fm-classify-lib.sh` recognizes it as closing the live status copy without claiming that the captain has answered it.

### Checking before scout teardown (`verify`)

Scout teardown calls the read-only `verify` subcommand after checking for the report and before removing any source state.
`verify` checks three things:

- The recorded attestation exists.
- Every recorded inventory entry is still durable: actively captain-held, or carrying a recorded answer.
- No keyed status decision opened after the last `complete`.

A keyed status decision opened after the last `complete` makes `verify` fail, and re-running `complete` is the repair.
The `--force` path remains the explicit captain-approved discard escape hatch.

## Cleanup never closes a captain call

The policy prefers holding the very work item a question gates.
So the backlog row a finished task's cleanup is about to close is routinely the captain's own call.

`bin/fm-teardown.sh` therefore asks the read-only `open` subcommand before its automatic close:

| `open` exit | Meaning | What teardown does |
| --- | --- | --- |
| 0 | The row is still an open captain call (not Done, `hold_kind: captain`). | Retains the row, as described below. |
| 1 | The row is not an open captain call. | Proceeds with its automatic close. |
| 2 | The answer could not be established. | Treats it as a refusal before any destructive step, never as permission to close. |

### Retaining the row on exit 0

On 0 only the close changes.
After cleanup, and still under the task's own lock, teardown does three things:

- It records one `Deliverable of the finished work: ...` line at the end of the task body.
- It copies a supported pull request or canonical `data/<id>/report.md` into the row's structured artifact fields.
- It runs `tasks-axi reopen`.

The row returns to Queued with its hold intact.
It remains on the appropriate Captain's Call or Charted Next decision surface instead of reading as work still under way.

### Interrupted cleanup

Teardown already stages a pending-close record before destructive cleanup.
That record carries the retention intent as a `mode=retain` line.
An interrupted cleanup therefore replays the retention at the next session start through the same record, validator, and lock as an ordinary close, and never closes the row.

If the captain answers before replay, `answer` validates that record and copies any supported retained pull request or report into the row before closing it.
Replay then retires the record.

### Known retained-delivery gaps

Two retained-delivery gaps remain bounded by tasks-axi 0.2.6.
They are recorded for separate upstream work rather than representing defects introduced by this branch.

- A retained local-only delivery cannot reach the row.
  `--note` exists on `tasks-axi done` but not on `tasks-axi update`, while the durable pending-close record carrying that note is retired when retention completes.
- A relocated retained report cannot reach the row, because tasks-axi accepts only `data/<id>/report.md`.
  `done` reports `Task report link must be a data/<id>/report.md path`, and `update` reports `--report must be a data/<id>/report.md path`.

When an interrupted retention leaves such a relocated report in the validated pending-close record, `answer` skips only that known-unsupported row artifact and closes normally.
The delivery then remains absent from Recently Landed instead of wedging the captain's answer.

A pending-close record that fails validation outright is a different case, and it still refuses the answer.
The refusal names the record and the validation reason, so the captain can repair it rather than facing a bare failure.

### What `--force` does not lift

`--force` does not lift the deferral, because it authorizes discarding unlanded work, never the captain's question.
Only `answer` with the captain's words or evidence-backed `reconcile close` resolves the call, by either closing the question or releasing the gated work.
`bin/fm-backlog-transition-lib.sh` owns the transition and its record, and `bin/fm-captain-hold.sh --help` owns the predicate's contract.

## Answer-time resolution

"A keyed answer resolves its matching captain-held task" is one capability with one owner.
`answers` is its channel-agnostic entry point.
It reads `<task-id>\t<answer>\t<label>[\t<mode>]` lines and resolves each named task through the same `answer` path.
Every guard therefore applies identically no matter which channel the answer arrived on.

The optional mode column carries a card-declared close:

| Mode | Effect |
| --- | --- |
| `done` (default) | Completes the task. |
| `release` | Lifts the hold so held work resumes. |
| Any other value | Skipped. |

Each key is reported as follows:

| Key | Result |
| --- | --- |
| Names no task, names a task that is not captain-held, or names a task already closed | Reported as `skipped:` and feeds nothing. |
| A replay whose answer and requested close mode match the newest record | An idempotent `closed:`. |
| A replay with a mode mismatch | Skipped. |

The command exits nonzero when any key was skipped.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch.

### Source bindings

`bind`, `unbind`, and `binding` record that a captured-answer source feeds this intake, as a private record under `state/decision-bindings/`.
An unbound source feeds nothing, so the path is opt-in per source.
`bind` deliberately does not require the source to exist yet.

### Channels that feed the intake

Two channels feed that one intake today, and both are ordinary callers rather than special cases.

`bin/fm-send.sh --resolve-key` is the chat channel:

- For a key the status log still owns, that script's header owns the status-log close.
- A key the status log no longer owns is resolved to a still-open captain-held task and fed as one keyed line.
  The script tries the key as a task id first, then the legacy derived identity.

`bin/fm-procevent.sh` is the captured-result channel:

- After capture, the runner passes a bound built-in source's result to `bin/fm-procevent-<adapter>.sh answers <result-file>`.
- The runner pipes whatever that prints into the intake.
- Any built-in adapter with an `answers` command therefore works.
- The runner names no adapter, parses no result, and carries no decision rule.

`bin/fm-procevent-lavish.sh answers` is one such built-in adapter command.
It reads only rows tagged `choice` and relays a card's declared close mode.
It can never let freeform captain prose forge a task id or a mode.

Trusted external process-event adapters intentionally expose no answer operation and cannot feed this authority-bearing intake; [`extension-bindings.md`](extension-bindings.md#trust-boundary) owns that boundary.

## Reconcile: re-check reality, never a blind close

A captain call can stop being a question without the captain ever answering it.
That happens when the subject lands, the premise turns out to be false, or the choice becomes a matter of fact rather than the captain's to make.
`reconcile` is the standing third option for that case, and its whole point is that it is NOT an answer.
It means "go verify the latest state".
Once that verification has actually been done, it resolves in exactly one of two ways:

- Close the call with the evidence that made it moot.
- Leave it open with a note recording that it is genuinely still active.

### The keyed-answer intake refuses reconcile

The value remains reserved at the shared keyed-answer intake, which visibly refuses it from every channel and never passes it to `answer`.
A reconcile value delivered through chat or any ordinary keyed-answer caller therefore cannot complete a task, lift a hold, write a resolution record, or create a reconcile request.

### How a board selection creates a request

Board request creation uses a separate captured-source seam.
The board emits `fm-bearings-answer.v1` context with the slug-shaped selected option and the freeform note in separate fields.
Annotating Reconcile therefore cannot turn it into an ordinary answer value.

The Lavish adapter splits each capture between two commands:

| Command | What it emits |
| --- | --- |
| `bin/fm-procevent-lavish.sh answers` | An exact non-reconcile selection, or the typed words of a card that offers no answer option besides Reconcile, which the board marks `intent: answer`. |
| `reconciles` | Only task ids whose structured selection is Reconcile, carrying their notes as request provenance. |

A note sent with no option selected on a card that offers answer options is the captain's comment, not a decision.
It feeds neither intake, the call stays held, and the note still reaches firstmate through the announced result, so a question can never close the call it asks about.
A current-shape row without an `intent` is read the same way, so a board built before the field existed never closes a call from a bare note.

Current rows require the versioned shape and the `choice` tag.
A time-limited rollout branch accepts ordinary answers from the old question/answer shape.
That branch refuses the old shape's bare and separator-annotated reconcile values from both intakes, because those rows do not separate the selected option from its note.
Every other structurally uncertain capture feeds neither intake, remains announced, and cannot forge a task id from freeform prose.

The adapter-agnostic runner pipes reconcile rows into `reconcile-requests` only for a bound source.
That intake verifies the named binding again before it creates anything.
Failures remain best-effort and never acknowledge or suppress the captured result.

### The reconcile request record

This captured-source intake records a durable reconcile request under `state/reconcile-requests/`.
There is one private record per task, carrying the requesting provenance and a UTC timestamp.
The record exists so the obligation to re-check cannot be lost between the wake that carried the answer and the turn that acts on it.
It is idempotent per task: repeating a reconcile keeps one request and its original timestamp.
The supported creator is the runner carrying the captain's board selection.
The binding-checked `reconcile-requests` command is that internal intake rather than an operator reconciliation outcome.

### Verifying and retiring a request

Verification retires a request through one of two outcomes.
Each outcome requires both the pending board-created request and the operator input that supports its claim:

- `reconcile close <task-id> --evidence-file <path>` is the moot outcome.
  It writes a resolution record whose mode is `reconciled` and whose body is the supplied EVIDENCE under a `Reconciliation evidence:` label, then closes the task.
  The distinct mode and label are what keep the record honest: it says the call dissolved against verified evidence, and it never claims the captain answered.
- `reconcile note <task-id> --note-file <path>` is the still-active outcome.
  It appends one dated `Captain hold reconciled:` note to the task body, leaves the hold in place, and retires the request.
  The call stays the captain's, now carrying what the re-check found.
  A marker bound to the request timestamp, provenance, and note digest lets a matching retry finish retirement without appending again.
  A later request with the same finding still receives its own dated note.

`reconcile list` is the read-only enumeration of pending requests filed by board answers.
A successful normal answer also retires any pending request, because an answered call has no remaining re-check obligation.

Every retirement is checked.
If request removal fails after an answer, close, or note is already durable, the durable outcome stands, but the command fails and leaves the pending request visible for retry.
No path here closes a captain call without either the captain's words through `answer` or the evidence through `reconcile close`.

## Card hygiene: a landed subject is not a live call

`bin/fm-bearings-board.sh build` cross-checks every `decision` card before it publishes and drops stale subjects rather than trusting the composed inventory alone.

Three checks run, all on exact identity and none on prose:

- The card's key is the captain-held task id, so `bin/fm-captain-hold.sh open --distinguish-absent` is asked whether that task is still an open captain call.
  - Exit 1 means the task is present but closed, or no longer held for the captain, and drops the card.
  - Exit 2 means the answer could not be established, and keeps the card.
  - Exit 3 means the task is absent from the main backlog, which includes a home carrying no backlog file at all, and keeps the card.

  Exits 2 and 3 keep the card because a card wrongly shown is recoverable and a call wrongly hidden is not.
- The payload's own `landed` rows are the recently-landed artifacts.
  A decision card whose task id or `pr_url` appears among them has already shipped its subject, so it drops.
- A version decision can carry a structured `subject` with an artifact and numeric three-part version.
  A landed row carrying the same artifact at that version or a newer one supersedes the card without parsing prose.

### Dropped and kept cards

Dropped cards are named on stderr as `dropped-landed-card:` lines, so a rebuild states what it removed rather than quietly shrinking Captain's Call.
The landing procedure requires one immediate board rebuild to remove already-stale merged-PR and superseded-version cards without a committed migration or change-worktree state mutation.
A subject whose state cannot be established is kept, because a wrongly shown card is safer than a wrongly hidden call.
The validator's reservation scope must equal the adapter's reconcile-classification scope.
That scope is all card types, because the captured payload carries no card type.

### Remote-secondmate cards

Owner-aware routing for remote-secondmate decision cards is tracked separately.
That follow-up must query landedness and route reconciliation in the authoritative secondmate home while honoring the remote and local consistency principle.
Until then, an absent main-home task passes through this hygiene check unchanged.
Its Reconcile selection remains announced but cannot create a main-home request, because the main intake refuses an absent task.
For a main-home call, the reconcile option is the recovery path for whatever still slips through.

## Structured read surfaces

### Fleet snapshot buckets

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)`, `(hold-kind: ...)`, and `(hold-until: ...)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records and keeps missing blockers unresolved.
It then assigns every captain hold exactly one `hold_bucket`.
The bucket is decided only from structured fields: `hold_kind`, `state`, `hold_until`, `unresolved_blocker_ids`, and the machine-written hold-set timestamp.
Hold reason and body prose are never matched, so no wording can hide, reveal, or reclassify a decision.

The buckets are total and mutually exclusive.
The first matching row in this order decides the bucket:

| Order | `hold_bucket` | Condition |
| --- | --- | --- |
| 1 | `blocked` | Any blocker is unresolved. |
| 2 | `dated` | `hold_until` is in the future. |
| 3 | `aged` | An undated hold's hold-set timestamp is at least `FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS` old (default 14, floored elapsed days). |
| 4 | `live` | None of the above. |

No captain hold can fall through them and none can match two, which is what keeps a hold from vanishing from every view.
`captain_actionable` - waiting on the captain now - is exactly `hold_bucket == "live"`.

Existing undated holds without a hold-set stamp fall back to the task's `since` date.
That aging is a projection safety net only.
The durable deferral remains re-holding with `--until`.

The fleet snapshot's secondmate-home summary classifies an actionable captain hold as `captain_decision`.
It preserves every captain hold in the bounded queued inventory of the owning home.

### Bearings placement

`bin/fm-bearings-snapshot.sh` places each captain hold by its `hold_bucket` and inspects no prose of its own.

| `hold_bucket` | Where the hold appears |
| --- | --- |
| `live` | A default Captain's Call entry. |
| `blocked`, `dated`, or `aged` | Leaves the default Captain's Call, renders as a Charted Next gate stating why - the blocking work, the `until <date>`, or the floored age - and contributes to the concrete `omitted[]` disclosure. |

`--all-decisions` reveals every captain hold available within the remote-summary bound and drops its gate.
An available hold is therefore never in both Captain's Call and Charted Next.
An actively worked held task may also appear in Underway, which reports running work independently of those decision buckets.

### Accepted limits

Three accepted limits remain deliberate:

- A remote or secondmate hold retains the producer home's age and aging decision from the summary's capture time and threshold rather than being recomputed by the parent.
- A rare concurrent answer-close and re-hold race can leave the newly re-held task without its age basis.
- Cross-home summaries remain bounded by `FM_SNAPSHOT_SECONDMATE_DECISIONS` and `FM_SNAPSHOT_SECONDMATE_QUEUED`.
  A remote deferred hold beyond those bounds is not exported, so it can be neither gated nor revealed.

Re-holding through the wrapper with `--until` remains the durable fix rather than relying on the projection safety net.

### Recently Landed notes

[`bin/fm-landed-lib.sh`](../bin/fm-landed-lib.sh) owns Recently Landed's shared selection and artifact-display compatibility rules.
A local-only landing's note is written by `tasks-axi done --note` as the last of the row's indented body lines rather than into the row title.
The snapshot therefore reads that final line as the note as well as parsing the title, and the landing is published carrying its recorded note.
A body that carries a captain resolution record is the captain's own prose and is never mined for that note, so a decision worded `local main` does not become a delivery artifact.
The projection remains read-only and uses the canonical snapshot's structured fields, including the machine-written hold-set timestamp.

### Merge-to-cleanup window

The window between a merge landing and cleanup is an accepted structural residual rather than an oversight.
That local window is normally only seconds wide and requires re-holding a task whose merge has just landed.
A re-hold inside the window makes cleanup retain the row rather than publish it, so the delivery is omitted until the stale hold is cleared from that row.
Queued forge merges cannot be covered locally.
The forge performs the merge asynchronously after the local command has returned, when no lock this code could hold would still be held.
The away-posture restriction on queued merges and its residual limits are owned by [architecture.md](architecture.md#delivery-modes-are-explicit-per-task).

## Record divergence

A captain call can have two records, and closing one does not close the other.
The status-log fold is the open-decision set `bin/fm-classify-lib.sh` reads from a task's status log, where a keyed `needs-decision` or `blocked` line opens a decision.
A `resolved [key=...]` line closes the status-log fold.
The structured captain-held task closes only through `answer`.

Until this guard existed, closing on the status side alone left no trace of the disagreement.
The fold went quiet, the durable record kept saying the captain owed an answer, and nothing warned.

### What the guard reports

`bin/fm-captain-hold.sh diverged` is the read-only report of that state.
`bin/fm-wake-drain.sh` prints it as a bounded `RECORD DIVERGENCE` section beside OPEN DECISIONS on every drain.

It flags exactly one condition, where all of these hold:

- The task is still open.
- The task still carries the captain-hold annotations.
- The task's key was closed on the status side by the resolve verb, resolved through the collapsed identity (the key is the task id) or the legacy derived one.

It closes nothing, ever.
A captain call closed wrongly leaves review entirely, so both reconciliation directions stay human-owned, and the printed hint names both.

### States that are not divergence

Three states are deliberately not divergence:

- A `captain-held [key=...]` close is the verified transfer `complete` writes, so the structured row staying open behind it is correct.
  `bin/fm-classify-lib.sh`'s `status_key_closing_verb` is what keeps the two closing verbs distinguishable.
- A still-open keyed status decision belongs to the OPEN DECISIONS fold.
- The absence of a routed work item is legitimate rather than incomplete.
  When the decision is the deliverable, there is nothing to route, so routed work is no part of the test.

### Cost and scope

Cost stays flat: one `tasks-axi list`, one key scan per status log, and the precise per-key fold only for a key that already names a still-open task.
The comparison is refused unless the status directory is the active home's own.
Because tasks-axi reads that home's backlog, a mismatch would report one home's logs against another's tasks.
If tasks-axi is unavailable or its listing cannot be parsed, the guard cannot read the structured record and prints nothing.

## Compatibility with pre-collapse installs

The collapse is the change that made a decision an ordinary captain-held task whose key is its task id.
Older installs created derived `<origin>-decision-<key>` identities through the retired `bin/fm-decision-hold.sh`.
Those rows are already plain task ids, so they render, answer, verify, and close through the collapsed surfaces with no data migration.

Three legacy inputs are resolved in place:

- A `decision_keys=` metadata entry that names no task resolves through `<origin>-decision-<entry>`.
- A channel key that names no task resolves the same way when the source's binding carries a concrete legacy origin.
- Resolution records written by the old script are recognized wherever a record is read.

### Legacy ids on the Beads backend

On the Beads backend, an attested legacy markdown id that resolves to no task is accepted through the row the markdown-to-beads hold migration produced.
That row is found by the authoritative evidence first: a row whose notes carry the marker line `migrated from data/backlog.md id <legacy id>`, either alone or followed by ` on <date>` as fm-hold-migration wrote it on 2026-09-04.

Only when no row carries that marker line is the legacy id tried under the configured beads prefix.
That name-only guess is accepted solely for a single row still held for the captain.
Two such rows refuse rather than attest.
Because that acceptance rests on a name rather than on evidence, `complete` names the resolved row beside each prefix-attested legacy id in its completion line, so the guess is auditable after the fact.

A markdown home keeps its legacy rows verbatim, so its resolution is unchanged.

### The `fm-decision-hold.sh` shim

`bin/fm-decision-hold.sh` itself remains for one release as a thin command-mapping shim over `bin/fm-captain-hold.sh`.
In-flight work briefed before the collapse therefore keeps working, and the shim's header owns the exact mapping.
The shim recognizes an exact replay of a pre-collapse routed resolution by its historical answer digest and routed ids.
It then finishes any still-recorded dependency-edge cleanup without rewriting the old decision text.

## Verification record

The focused end-to-end regression suite is `tests/fm-captain-hold-lifecycle.test.sh`, using only synthetic `sample` identities and decision text.
It proves the behaviors below.
The suite does not test the accepted merge-to-cleanup re-hold window or asynchronous queued-forge landing because those events occur after the locally serialized merge command has returned.

### Cleanup of a captain-held row

- Cleanup of a finished task whose own row is the captain call leaves that call open, queued, held, carrying its deliverable, and visible in Bearings' Captain's Call.
  That cleanup leaves no pending record behind.
  The call survives a `--force` cleanup and closes only when `answer` records the captain's words.
  An ordinary finished task in the same home still closes with its report link.
- An interrupted cleanup leaves the row In flight and untouched with its pending record.
  When the row remains unanswered, the next session start retains it as queued and held with the deliverable recorded.
  An answer before replay preserves that record's completed report while closing the call, so the next session start retires the satisfied record without losing the delivery from Recently Landed.
- A pending-close record that cannot be validated refuses the answer while naming the record and the reason.
- A relocated data directory keeps the retention in its one configured backlog.

### Merges, releases, and unreadable holds

- Direct PR and local-only merge entrypoint calls refuse a still-held task before reaching the forge or moving local main.
- A released pull request passes the guarded PR entrypoint, cleanup records its artifact, and Recently Landed publishes it.
- An ordinary release still survives zero-retention cleanup and archives when configured.
- A ship row whose captain hold cannot be read refuses cleanup before any destructive step and surfaces the read failure.
- A released call whose decision text is `local main`, closed with no artifact, is not published as a local-only landing.

### Divergence coverage

- The reconstructed silent-divergence case is signalled.
  A status resolution over a still-open captain-held task reaches both `diverged` and the drain's `RECORD DIVERGENCE` section, under the collapsed and the legacy identity alike.
  The backlog task, its hold, and the status log all survive the report unchanged, and the printed hint names both reconciliation directions.
- The false-signal boundary holds.
  A captain call with no routed work item, a verified `captain-held` transfer, a still-open status decision, an already answered call, and an ordinary task whose keyed question was answered all stay silent.

### Completion and verification

- A report-only unresolved captain call refuses `--none` completion before teardown can erase the source.
- Non-forced scout teardown always requires the durable inventory verification.
- The recorded-answer guard holds: a bare `tasks-axi done` close fails `verify` until `answer` records the captain's word, and an ordinary finished task cannot be dressed up as an answered call.

### Answers, stamps, and deferral

- Answer-time resolution works through a bound channel with task-id keys.
  This includes the `release` mode, mode-matched replay idempotence, and the refusal of drifted, mode-mismatched, absent, unheld, and already-closed keys.
- The chat channel reaches the same intake.
- Hold-set stamping precedes visible hold state, preserves an active lifecycle's timestamp, and resets after release.
- Interrupted answer closure retains the stamp until close and restores resolution-first ordering on retry.
- Deferral through `--until` leaves `captain_actionable` false until due.

### Legacy paths

- Every legacy path works: composed identities through the shim, pre-collapse `decision_keys=` metadata, routed-resolution replay, and a concrete-origin binding.

### Task-body read-back cases

Two of the suite's cases pin how a task body is read back rather than any decision behavior, because both paths that read one are otherwise silent when they get it wrong.

The first case covers holding a task that carries a body, and cleanup's retention of a captain-held row.
Both work where the installed JSON::PP defaults `allow_nonref` off and therefore rejects the JSON-encoded bare string a shown scalar field arrives as.
The case forces that older default back off and probes that the simulation really does reject a bare scalar, so it cannot pass vacuously on a lenient library.
A fleet host does carry such a library, and both failures reproduce on it natively with no shim, so that behavior is observed and not only simulated.
The case still forces the older default rather than depending on the installed one, which is what makes it deterministic on any host.

The second case covers a retained body's non-ASCII characters, which survive cleanup's rewrite as their exact UTF-8 bytes.
The case asserts bytes rather than decoded strings.
A codepoint at or below U+00FF is the one a stream with no raw layer emits as a single latin-1 byte, and comparing decoded strings cannot see that.
It uses one row per character class, because any character above U+00FF makes the whole string print as UTF-8 and would mask the latin-1 case in a mixed body.
That latin-1 byte loss also reproduces natively on the fleet host carrying the older library, with no shim.

### Markdown-to-beads migration family

The markdown-to-beads migration family runs the same suite's beads fixture (bd-driven scratch graph, self-skipping on markdown-only tasks-axi installs).
It proves:

- `verify` and `complete` resolve an attested legacy id through a migrated row's marker note.
- They resolve it through the configured prefix when no row carries a note, naming the resolved row in the completion line.
- They resolve it through the marker note of a pre-collapse derived identity.
- A marker-noted row wins over an unrelated captain-held row occupying the bare prefix namesake.
- An unresolvable id is refused once naming the id (never an empty name).
- The attested id stays in `decision_keys=` for idempotent re-verification.

One case in that family needs no beads install and always runs.
It uses a stubbed tasks-axi that fails any markdown file override, and proves the captain-hold hold, answer, and close mutations reach a beads-configured home without one.

### Reconcile coverage

The reconcile path is pinned in the same suite:

- A reconcile answer arriving through the keyed-answer intake is refused, in the default close mode and in the `release` mode a captain-gated work card declares.
  It leaves both tasks held with no resolution record or request.
- Only the separately bound captured-source intake records one durable request per task, idempotently across a replay.

It also proves the two verification outcomes:

- An evidence-backed `reconciled` close records the evidence under its own label and never as the captain's words.
- A note leaves the call queued, held, and dated.

Around those outcomes, it proves:

- Both outcomes refuse without a pending board request.
- Each durable mutation applies only once across close, probe, and request-retirement failures.
- A later distinct request with the same note still appends its own dated record.
- Every failed retirement is surfaced with its pending request retained.
- Incompatible resolution modes cannot replay as captain answers.
- Normal close, release, and replay paths retire pending requests.

The captured-source coverage proves:

- Lavish deduplicates each card before separating versioned structured selections from notes.
- Bare and annotated Reconcile choices never reach keyed answers.
- Genuine current and legacy choices still close normally.
- Legacy bare and separator-annotated reconcile values feed neither intake.
- Mixed repeated selections preserve every other card's final value.
- The generic runner creates a request only through a verified bound source.
- Chat reconcile text creates none.
- The resulting board request authorizes evidence-backed closure.

### Board suite

The board's half is pinned in `tests/fm-bearings-board.test.sh`:

- Every published decision card carries exactly one reconcile option.
- Authored options reserve that value across every card type.
- Recommendations name authored options.
- A decision card whose structured subject appears in the payload's landed rows is dropped.
  A genuinely open one is kept even when an unrelated landed id contains its key after a newline.
- A build requires a fresh authoritative listed-open result before binding or arming.
- A reopen retires the pre-reopen source generation and waits for a fresh live listener.
- A rebuild of an already-armed board with no live listener starts one.

That suite drives its Lavish session through a protocol-shaped stub.
`tests/fm-bearings-board-lavish-live-e2e.test.sh` is the default-on capability guard for the installed provider, and [`verification/process-event-sources.md`](verification/process-event-sources.md) owns the version-scoped evidence.
[`verification/process-event-sources.md`](verification/process-event-sources.md) owns the process-event ownership and reclamation evidence exercised by `tests/fm-procevent.test.sh`.

### Classifier and projection suites

`tests/fm-classify-decision-key.test.sh` pins `status_key_closing_verb` itself.
It separates a resolution from the durable-transfer close and from a still-open key.
It reports the last real transition across re-openings and both key positions, and treats a prose mention as no transition.

Projection regressions live in two suites:

| Suite | What it covers |
| --- | --- |
| `tests/fm-fleet-snapshot-view.test.sh` | The total structured-only bucket classifier, hold-until parsing, kind-independent captain actionability, undated-hold aging, and title stripping. |
| `tests/fm-bearings-snapshot.test.sh` | Default and expanded decision-bucket membership, deferral explanations, blocker-overflow disclosure, working-hold dual surfaces, remote-summary schema invalidation, exact leading-kind inference, artifact-kind mismatch and answered-question exclusion, kind-bearing and kindless local-only landings publishing their recorded note, and scout-report precedence over competing pull-request links. |

### Refreshing this record

The exact commands and their summarized outputs are recorded in the shipping PR's evidence.
To refresh this record, run:

- The four suites above: `tests/fm-captain-hold-lifecycle.test.sh`, `tests/fm-classify-decision-key.test.sh`, `tests/fm-fleet-snapshot-view.test.sh`, and `tests/fm-bearings-snapshot.test.sh`.
- `tests/fm-send-resolve-key.test.sh`, `tests/fm-bearings-board.test.sh`, and `tests/fm-procevent.test.sh`.
- `bin/fm-lint.sh`.

After a lavish-axi upgrade, run `FM_BEARINGS_LAVISH_LIVE=1 tests/fm-bearings-board-lavish-live-e2e.test.sh`.
