# Captain-hold lifecycle mechanism

The normative policy is owned by `.agents/skills/captain-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, compatibility contract, and privacy-safe regression evidence.

## Mechanism

A decision is not a separate thing in this system: it is an ordinary canonical task held for the captain, and the task id is the identity every surface and channel uses.
`bin/fm-captain-hold.sh` is the only lifecycle command layered on that primitive and the canonical per-task record.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand is the mandatory captain-hold creation path: it uses an existing task or creates one when nothing exists to hold, records its UTC hold-set timestamp as the leading line of the task body, then updates the canonical hold fields and verifies the record.
Publishing the stamp first ensures a snapshot cannot observe a newly captain-held task without the timestamp that defines its age.
Retries of an active hold preserve its hold-set timestamp, while re-holding released work starts a new timestamped lifecycle; a closed task is refused rather than reopened, and `--until` stores the captain's own deferral date in the same record.

The `answer` subcommand records the captain's exact words and resolves the call in the same act: it closes a question-shaped call, while `answer --release` frees a captain-gated work item to proceed without completing it.
It requires a non-empty captain decision file of at most 8192 bytes, durably writes a resolution block carrying the decision digest and a `Resolution mode:` while retaining the leading hold-set stamp until the selected canonical `done` or `unhold` transition succeeds, then restores the successful record's resolution-first body ordering; `--archive-body` compatibility preserves the prior body in record history.
If the close is interrupted, the still-held task therefore keeps its original age basis.
A matching retry also completes any resolution-first normalization left unfinished after the close itself succeeded.
An exact retry is idempotent only when the requested close mode matches the newest record; a drifted answer or mode mismatch is rejected, while a re-held task accepts a new answer as a new record on top.
On a task closed outside the script, `answer` records the missing block only when the canonical hold annotations preserved through the close prove the captain owned it, and it verifies the task stays closed.
A hold whose `--until` date has passed keeps those annotations, so an expired deferral remains answerable.

The `complete` subcommand unions the reviewed captain-held task ids into one current `decision_keys=` / `decisions_reviewed=1` pair while originating task metadata is live, preserving superseded assignments as audit comments under the metadata lock.
A post-teardown structured review can complete against the surviving report and durable tasks without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, refused while the origin still has a lifecycle-open keyed status decision, and verifies every listed canonical task before recording completion.
With a non-empty inventory it appends a `captain-held [key=<key>]: tracked by <inventory>` transfer event for every still-open keyed status decision, which `bin/fm-classify-lib.sh` recognizes as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the read-only `verify` subcommand after checking for the report and before removing any source state.
`verify` requires the recorded attestation, requires every recorded inventory entry to still be durable (actively captain-held, or carrying a recorded answer), and fails on any keyed status decision that opened after the last `complete`, which makes re-running `complete` the repair.
The legacy `--force` path remains the explicit captain-approved discard escape hatch; accepted or archived cleanup never uses it to discard a retained copy.

## Cleanup never closes a captain call

The policy prefers holding the very work item a question gates, so the canonical record a finished task's cleanup is about to close is routinely the captain's own call.
`bin/fm-teardown.sh` therefore asks the read-only `open` subcommand before its automatic completion transition: exit 0 means the record is still an open captain call (not Done or archived, `hold.kind: captain`), 1 means it is not, and 2 means the answer could not be established and grants no permission to change the record.
For tasks that MAIN accepted or explicitly archived, endpoint and copy handling is an independent completed-resource phase; the canonical business record remains available for a plain retry when resource readback refuses.
Legacy teardown keeps the earlier fail-closed ordering and performs no destructive cleanup when that read is uncertain.
On 0 only the close changes: after cleanup, teardown records the finished deliverable in the task body and structured artifact links, then reopens the same canonical record as Queued with its captain hold intact. It remains on the Captain's Call or Charted Next surface instead of reading as work still under way.
For MAIN-accepted or explicitly archived tasks, teardown stages the pending-close record after completed resource handling and includes the copy disposition, so session-start replay finishes only business-record bookkeeping and the cleanup receipt without repeating endpoint or copy effects.
Legacy teardown stages the pending-close record before destructive cleanup and carries a retained close as `mode=retain`; if the captain answers before replay, `answer` validates that record and applies any supported retained GitHub pull request, Codebase MR note, or report before closing it, after which replay retires the record.
The canonical record accepts the existing note, PR, and report compatibility flags directly; retained delivery no longer depends on an external tasks-axi version or shared backlog rewrite.
When an interrupted retention leaves such a relocated report in the validated pending-close record, `answer` skips only that known-unsupported row artifact and closes normally, so the delivery remains absent from Recently Landed instead of wedging the captain's answer.
A pending-close record that fails validation outright is a different case and still refuses the answer, but the refusal names the record and the validation reason so the captain can repair it rather than facing a bare failure.
`--force` does not lift the deferral, because it authorizes discarding unlanded work on the legacy path, never the captain's question, and does not relax completed-copy preservation; only `answer` with the captain's words or evidence-backed `reconcile close` resolves the call, by either closing the question or releasing the gated work.
`bin/fm-backlog-transition-lib.sh` owns the transition and its record, and `bin/fm-captain-hold.sh --help` owns the predicate's contract.

## Answer-time resolution

"A keyed answer resolves its matching captain-held task" is one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<task-id>\t<answer>\t<label>[\t<mode>]` lines and resolves each named task through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
The optional mode column carries a card-declared close: `done` (default) completes the task and `release` lifts the hold so held work resumes; any other value is skipped.
A key that names no task, names a task that is not captain-held, or names a task already closed is reported as `skipped:` and feeds nothing; a replay whose answer and requested close mode match the newest record is an idempotent `closed:`, while a mode mismatch is skipped; and the command exits nonzero when any key was skipped.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch.

`bind`, `unbind`, and `binding` record that a captured-answer source feeds this intake, as a private record under `state/decision-bindings/`; an unbound source feeds nothing, so the path is opt-in per source, and `bind` deliberately does not require the source to exist yet.

Two channels feed that one intake today, and both are ordinary callers rather than special cases.
`bin/fm-send.sh --resolve-key` is the chat channel: its status-log close for a key the status log still owns is owned by that script's header, and a key the status log no longer owns is resolved to a still-open captain-held task - the key as a task id, then the legacy derived identity - and fed as one keyed line.
`bin/fm-procevent.sh` is the captured-result channel: after capture, a bound built-in source has its result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>` and whatever that prints is piped into the intake, so any built-in adapter with an `answers` command works and the runner names no adapter, parses no result, and carries no decision rule.
Trusted external process-event adapters intentionally expose no answer operation and cannot feed this authority-bearing intake; [`extension-bindings.md`](extension-bindings.md#trust-boundary) owns that boundary.
The retired `bin/fm-procevent-lavish.sh answers` compatibility command remains able to recover choices from already captured legacy results without reintroducing the old provider dependency.

## Reconcile: re-check reality, never a blind close

A captain call can stop being a question without the captain ever answering it because the subject lands, the premise turns out to be false, or the choice becomes a matter of fact rather than the captain's to make.
`reconcile` is the standing third option for that case, and its whole point is that it is NOT an answer.
It means "go verify the latest state", and it resolves in exactly one of two ways once that verification has actually been done: close the call with the evidence that made it moot, or leave it open with a note recording that it is genuinely still active.

The value remains reserved at the shared keyed-answer intake, which visibly refuses it from every channel and never passes it to `answer`.
A reconcile value delivered through chat or any ordinary keyed-answer caller therefore cannot complete a task, lift a hold, write a resolution record, or create a reconcile request.

Captured-source request creation uses a separate seam.
The legacy `fm-bearings-answer.v1` context keeps the slug-shaped selected option and freeform note in separate fields, so annotating Reconcile cannot turn it into an ordinary answer value.
`bin/fm-procevent-lavish.sh answers` emits an exact non-reconcile selection, or a bare note when no option was selected, while `reconciles` emits only task ids whose structured selection is Reconcile and carries their notes as request provenance.
Current rows require the versioned shape and the `choice` tag; a time-limited rollout branch accepts ordinary answers from the old question/answer shape but refuses its bare and separator-annotated reconcile values from both intakes because those rows do not separate the selected option from its note.
Every other structurally uncertain capture feeds neither intake, remains announced, and cannot forge a task id from freeform prose.
The adapter-agnostic runner pipes reconcile rows into `reconcile-requests` only for a bound source, and that intake verifies the named binding again before it creates anything.
Failures remain best-effort and never acknowledge or suppress the captured result.
What this captured-source intake records is a durable reconcile request under `state/reconcile-requests/`, one private record per task, carrying the requesting provenance and a UTC timestamp.
The record exists so the obligation to re-check cannot be lost between the wake that carried the answer and the turn that acts on it.
It is idempotent per task: repeating a reconcile keeps one request and its original timestamp.
The supported creator is the runner carrying a bound captured selection; the binding-checked `reconcile-requests` command is that internal intake rather than an operator reconciliation outcome.

Verification retires a request through one of two outcomes, and each one requires both the pending captured-source request and the operator input that supports its claim:

- `reconcile close <task-id> --evidence-file <path>` is the moot outcome.
  It writes a resolution record whose mode is `reconciled` and whose body is the supplied EVIDENCE under a `Reconciliation evidence:` label, then closes the task.
  The distinct mode and label are what keep the record honest: it says the call dissolved against verified evidence, and it never claims the captain answered.
- `reconcile note <task-id> --note-file <path>` is the still-active outcome.
  It appends one dated `Captain hold reconciled:` note to the task body, leaves the hold in place, and retires the request.
  The call stays the captain's, now carrying what the re-check found; a marker bound to the request timestamp, provenance, and note digest lets a matching retry finish retirement without appending again while a later request with the same finding still receives its own dated note.

`reconcile list` is the read-only enumeration of pending requests filed by captured-source selections.
A successful normal answer also retires any pending request, because an answered call has no remaining re-check obligation.
Every retirement is checked: if request removal fails after an answer, close, or note is already durable, the durable outcome stands but the command fails and leaves the pending request visible for retry.
No path here closes a captain call without either the captain's words through `answer` or the evidence through `reconcile close`.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` reads canonical `hold.reason`, `hold.kind`, and `hold.until` fields from the task record.
It resolves every repeated `blocked-by:` edge against structured Done records and keeps missing blockers unresolved.
It then assigns every captain hold exactly one `hold_bucket`, decided only from structured fields - `hold_kind`, `state`, `hold_until`, `unresolved_blocker_ids`, and the machine-written hold-set timestamp.
Hold reason and body prose are never matched, so no wording can hide, reveal, or reclassify a decision.
The buckets are total and mutually exclusive: `blocked` when any blocker is unresolved, else `dated` while `hold_until` is in the future, else `aged` when an undated hold's hold-set timestamp is at least `FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS` old (default 14, floored elapsed days), else `live`.
No captain hold can fall through them and none can match two, which is what keeps a hold from vanishing from every view.
`captain_actionable` - waiting on the captain now - is exactly `hold_bucket == "live"`.
Existing undated holds without a hold-set stamp fall back to the task's `since` date.
That aging is a projection safety net only.
The durable deferral remains re-holding with `--until`.

`bin/fm-bearings-snapshot.sh` places each captain hold by its `hold_bucket` and inspects no prose of its own.
A `live` hold is a default Captain's Call entry.
A `blocked`, `dated`, or `aged` hold leaves the default Captain's Call, renders as a Charted Next gate stating why - the blocking work, the `until <date>`, or the floored age - and contributes to the concrete `omitted[]` disclosure.
`--all-decisions` reveals every captain hold available within the remote-summary bound and drops its gate, so an available hold is never in both Captain's Call and Charted Next.
An actively worked held task may also appear in Underway, which reports running work independently of those decision buckets.

One accepted limit remains deliberate:

- A rare concurrent answer-close and re-hold race can leave the newly re-held task without its age basis.

Re-holding through the wrapper with `--until` remains the durable fix rather than relying on the projection safety net.
[`bin/fm-landed-lib.sh`](../bin/fm-landed-lib.sh) owns Recently Landed's shared selection and artifact-display compatibility rules.
A local-only landing's note is stored in canonical task history rather than in the title, and the landing projection publishes that recorded note.
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

Cost stays flat: one canonical record inventory, one key scan per status log, and the precise per-key fold only for a key that already names a still-open task.
The comparison is refused unless the status directory is the active home's own, since a mismatch would report one home's logs against another home's task records.
If the record inventory cannot be parsed, the guard prints nothing.

## Compatibility with pre-collapse installs

`bin/fm-task-import.sh` is the explicit migration owner for retained markdown backlog and archive evidence.
It creates canonical task records without rewriting or deleting either legacy source.
Existing captain-hold ids and resolution bodies remain ordinary task ids and body text after import, so current hold, answer, verify, and close commands consume them without a second live backend.

## Verification record

The focused end-to-end regression suite is `tests/fm-captain-hold-lifecycle.test.sh`, using only synthetic identities and decision text.
It proves that hold, answer, and release mutate one canonical task record without rewriting retained backlog evidence; completion records the canonical captain-call inventory while leaving the call open; and ordinary Done work cannot be relabeled or revived through the answer path.
`tests/fm-teardown.test.sh` owns cleanup ordering, semantic acceptance, retained resources, artifact recording, unsafe-copy preservation, and interrupted-close replay.
`tests/fm-send-resolve-key.test.sh` and `tests/fm-procevent.test.sh` own the chat and captured-result answer intakes.
[`verification/process-event-sources.md`](verification/process-event-sources.md) owns process-event ownership and reclamation evidence.

`tests/fm-classify-decision-key.test.sh` pins `status_key_closing_verb` itself: it separates a resolution from the durable-transfer close and from a still-open key, reports the last real transition across re-openings and both key positions, and treats a prose mention as no transition.

Projection regressions live in `tests/fm-fleet-snapshot-view.test.sh` (the total structured-only bucket classifier, hold-until parsing, kind-independent captain actionability, undated-hold aging, and title stripping) and `tests/fm-bearings-snapshot.test.sh` (default and expanded decision-bucket membership, deferral explanations, blocker-overflow disclosure, working-hold dual surfaces, remote-summary schema invalidation, exact leading-kind inference, artifact-kind mismatch and answered-question exclusion, kind-bearing and kindless local-only landings publishing their recorded note, and scout-report precedence over competing pull-request links).
The exact commands and their summarized outputs are recorded in the shipping PR's evidence; run the named focused suites and `bin/fm-lint.sh` to refresh this record.
