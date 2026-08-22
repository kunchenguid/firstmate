# Captain-hold lifecycle mechanism

The normative policy is owned by `.agents/skills/captain-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, compatibility contract, and privacy-safe regression evidence.

## Mechanism

A decision is not a separate thing in this system: it is an ordinary backlog task held for the captain, and the task id is the identity every surface and channel uses.
`bin/fm-captain-hold.sh` is the only lifecycle command layered on that primitive.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned captain call stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

Two files hold real records, and only one of them is ever written.
Backlog retention does not delete a closed task, it moves it out of the active backlog and into the configured archive, so an answered captain call lives in `data/backlog.md` until retention trims it and in `data/done-archive.md` afterwards.
Every read that asks whether a durable record exists therefore consults both files: archived means the answer was recorded and the row was later trimmed, never that the record is missing.
Every mutation still targets the active backlog alone, the only file tasks-axi writes, so a record found in the archive can be reported on and replayed but never changed or re-minted.
`bin/fm-tasks-axi-lib.sh` owns the archive read itself, and `bin/fm-captain-hold.sh`'s header owns the one deliberate exception among its own reads, `diverged`, whose subject is by definition an open task the archive cannot hold.

The `hold` subcommand places an existing task under an active captain hold, or creates the task when nothing exists to hold, then verifies the hold through `tasks-axi hold <id> --reason <reason> --kind captain`.
Repeats are idempotent, a closed task is refused rather than reopened whether its row is still in the active backlog or has been archived out of it, and `--until` stores the captain's own deferral date through tasks-axi's date gate.

The `answer` subcommand records the captain's exact words and closes the call in the same act.
It requires a non-empty captain decision file of at most 8192 bytes, writes a resolution block carrying the decision digest and a `Resolution mode:` at the top of the task body (the previous body is preserved below the block and archived through tasks-axi `--archive-body`), then runs `tasks-axi done` - or `tasks-axi unhold` under `--release`, so a captain-gated work item resumes instead of closing.
An exact retry is idempotent only when the requested close mode matches the newest record; a drifted answer or mode mismatch is rejected, while a re-held task accepts a new answer as a new record on top.
On a task closed outside the script, `answer` records the missing block only when the captain-hold annotations tasks-axi preserves through a close prove the captain owned it, and it verifies the task stays closed.
On a record retention has already archived, an exact replay returns what it returned before the trim and every other shape is refused naming the archive and the fact that it cannot be written, rather than claiming the task is absent.
A hold whose `--until` date has passed keeps those annotations while tasks-axi reports it no longer held, so an expired deferral remains answerable.

The `complete` subcommand unions the reviewed captain-held task ids into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable tasks without recreating volatile task metadata.
The ownership check `complete` runs on that origin falls back to the archive as well, so an investigation whose own row retention has already trimmed out of the backlog still owns a later review pass, and an archive that cannot be searched refuses in the archive's own words rather than disowning the origin.
It accepts `--none` as an explicit semantic inventory result, refused while the origin still has a lifecycle-open keyed status decision, and verifies every listed task against tasks-axi before recording completion.
With a non-empty inventory it appends a `captain-held [key=<key>]: tracked by <inventory>` transfer event for every still-open keyed status decision, which `bin/fm-classify-lib.sh` recognizes as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the read-only `verify` subcommand after checking for the report and before removing any source state.
`verify` requires the recorded attestation, requires every recorded inventory entry to still be durable (actively captain-held, or carrying a recorded answer, in either file), and fails on any keyed status decision that opened after the last `complete`, which makes re-running `complete` the repair.
Its three refusals are worded apart because they need opposite repairs: an entry with no record in either file names both searched files, a recorded entry closed with no recorded answer names the file its record is in and the command that records one, and a recorded entry open without the captain hold says it is not the captain's item.
A pass earned by records retention already archived says how many, so a reader can tell a confirmed answer from a looser check.
The `--force` path remains the explicit captain-approved discard escape hatch.

## Answer-time closure

"A keyed answer closes its matching captain-held task" is one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<task-id>\t<answer>\t<label>[\t<mode>]` lines and closes each named task through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
The optional mode column carries a card-declared close: `done` (default) completes the task and `release` lifts the hold so held work resumes; any other value is skipped.
A key that names no task in either file, names a task that is not captain-held, or names a task already closed is reported as `skipped:` and feeds nothing, with the reason distinguishing those cases and naming the archive when that is where the record is; a replay whose answer and requested close mode match the newest record is an idempotent `closed:`, while a mode mismatch is skipped; and the command exits nonzero when any key was skipped.
An archive-read skip names the identity that actually reached the archive, the derived one for a legacy key, while a genuine miss names the delivered key the channel has to correct.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch.

`bind`, `unbind`, and `binding` record that a captured-answer source feeds this intake, as a private record under `state/decision-bindings/`; an unbound source feeds nothing, so the path is opt-in per source, and `bind` deliberately does not require the source to exist yet.

Two channels feed that one intake today, and both are ordinary callers rather than special cases.
`bin/fm-send.sh --resolve-key` is the chat channel: its status-log close is unchanged for a key the status log still owns, and a key the status log no longer owns is resolved to a still-open captain-held task - the key as a task id, then the legacy derived identity - and fed as one keyed line.
`bin/fm-procevent.sh` is the captured-result channel: after capture, a bound source has its result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>` and whatever that prints is piped into the intake, so any adapter with an `answers` command works and the runner names no adapter, parses no result, and carries no decision rule.
`bin/fm-procevent-lavish.sh answers` is one such adapter command; it reads only rows tagged `choice`, relays a card's declared close mode, and can never let freeform captain prose forge a task id or a mode.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)`, `(hold-kind: ...)`, and `(hold-until: ...)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies a captain hold as `captain_actionable` - waiting on the captain now - only when it is queued, unblocked, and due, whatever kind its row carries.
It also emits a presentation-only `deferred_marker` when a hold's reason or body carries an explicit SUPERSEDED / NOT REQUIRED / DEFERRED marker.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked or deferred captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
A date-deferred captain hold renders as a gate with its `until <date>:` reason; a prose-deferred one leaves the default views with an `omitted[]` disclosure, revealed by `--all-decisions` / `--all-queued`.
Recently Landed excludes a record that closed while still held for the captain (surviving `hold-kind: captain` on a Done row), so answered questions do not masquerade as shipped work; a work item released before completion keeps no hold annotations and lands normally.
The projection remains read-only and does not inspect historical prose beyond the canonical snapshot's marker.

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
The shim recognizes an exact replay of a pre-collapse routed resolution by its historical answer digest and routed ids, then finishes any still-recorded dependency-edge cleanup without rewriting the old decision text.
`bin/fm-decision-hold.sh` itself remains for one release as a thin command-mapping shim over `bin/fm-captain-hold.sh`, so in-flight work briefed before the collapse keeps working; its header owns the exact mapping.

## Verification record

Verification date: 2026-08-22.

The focused end-to-end regression suite is `tests/fm-captain-hold-lifecycle.test.sh`, using only synthetic `sample` identities and decision text.
It proves: the reconstructed silent-divergence case is signalled - a status resolution over a still-open captain-held task reaches both `diverged` and the drain's `RECORD DIVERGENCE` section, under the collapsed and the legacy identity alike, while the backlog task, its hold, and the status log all survive the report unchanged and the printed hint names both reconciliation directions; the false-signal boundary holds - a captain call with no routed work item, a verified `captain-held` transfer, a still-open status decision, an already answered call, and an ordinary task whose keyed question was answered all stay silent; a report-only unresolved captain call refuses `--none` completion before teardown can erase the source; non-forced scout teardown always requires the durable inventory verification; the recorded-answer guard (a bare `tasks-axi done` close fails `verify` until `answer` records the captain's word, and an ordinary finished task cannot be dressed up as an answered call); answer-time closure through a bound channel with task-id keys, including the `release` close mode, mode-matched replay idempotence, and the refusal of drifted, mode-mismatched, absent, unheld, and already-closed keys; the chat channel reaching the same intake; deferral through `--until` leaving `captain_actionable` false until due; and every legacy path (composed identities through the shim, pre-collapse `decision_keys=` metadata, routed-resolution replay, and a concrete-origin binding).

It also proves the retention read scope, in both directions.
An answered captain call that retention moved into the archive keeps the captain's exact words, passes the completion gate with the archived count named, passes it through the retired shim spelling too, and lets the finished investigation be cleaned up.
The gate is not looser for it: an inventory entry with no record in either file, a recorded entry closed with no recorded answer, that same entry after retention archives it, and a recorded entry that is open without the captain hold all still fail, each of the three refusals is asserted, every pair of them is asserted to differ, and cleanup is refused by the gate itself while any of them stands.
The no-record refusal is also what proves a missing archive file stays quiet: it is raised in a home retention has never trimmed, so the lookup reaches an archive that does not exist yet and reads it as "no entry" rather than as a failure, which is why that message names both searched files instead of blaming the archive.
The same boundary is driven again on the path that genuinely consults the archive: once retention has moved the only copy of a record there, taking that archive file away must still read as no record rather than as an archive that could not be read.
An archive that still carries the entry is refused in its own words in each of the two ways a read of a record it does carry can fail, a section heading the parser no longer accepts and a copy that could not be staged at all, and each of those messages is asserted to be neither the no-record wording nor any of the other refusals, which is what keeps an archive that cannot be read from ever collapsing back into a false "absent".
An archive the read could not settle at all is the third such refusal, and it covers two causes rather than one: the path exists but is not a readable regular file, or the read of it did not complete, which is a file unlinked under the open, an EIO, or a stale network handle.
That refusal states both causes and prescribes no single repair, because telling an operator to fix a mode or a symlink on a file whose mode is fine is the same misdirection as reporting an archived record absent; it is proved to stop the gate rather than pass it, to stop `hold` from minting a second row for a call the archive may already hold, and to say that the archive could not be searched rather than that both files were.
It also names the right KIND of record: the record reads say "captain call", while the origin-ownership check says "investigation origin", and both subjects are asserted on the paths that raise them, because an operator sent to look for a captain-held task by an origin's id finds nothing.
Origin ownership is proved on the same two files: an investigation whose own row retention archived still completes a later review pass, while an archive that could not be searched refuses in the archive's own words instead of reading as an origin this home does not own.
An archive read that cannot be settled outranks an answered legacy identity rather than falling through to it, and `test_an_unsettled_archive_read_outranks_the_legacy_identity` pins both halves over one fixture whose only difference is the archive's readability: with no archive file the gate passes through the pre-collapse derived identity that is answered in the live backlog, and with that path unreadable the same fixture refuses naming the archive read.
Falling through would settle a different record from the one the gate was asked about, which is how an unanswered captain call could pass, so the accepted cost is that a scout whose calls were all answered waits for the archive path to be repaired.
No staged copy of the archive survives either reader entry point, and `test_no_staged_archive_view_survives_a_reader` drives `verify` here and `resolve` through the retired shim against a home whose only copy of the record is archived, with `TMPDIR` pointed at a fixture directory that must be empty of staged views afterwards; the two entry points are opposite shapes on purpose, one owning an exit handler of its own that the removal must not displace and one owning none.
That one copy is shared by every lookup in a process, so `test_a_row_archived_mid_batch_is_still_read_out_of_the_archive` pins the case where the archive grows under it: a keyed batch whose own close trims an older answered row into the archive still reads that row out of the archive, instead of reporting a healthy file as a layout it cannot read.
On the write side, an archived record takes an exact `answer` replay and a replayed keyed delivery while leaving both files byte-identical, and refuses a drifted answer, a `--release`, and a `hold` that would mint a second row for the same call.
Every archive fixture is built by running `tasks-axi prune --keep 0 --state done` inside the throwaway home, never by hand-editing a backlog or archive file.
Each error path is then driven by a failure scoped to that same fixture: the parse failure rewrites only the disposable archive's own section heading, the unsearchable-path case changes only the readability of its path, the unstageable-copy case points `TMPDIR` at a directory that does not exist, and the read failure puts a `grep` stub on `PATH` that exits nonzero for that one archive file and hands every other call to the real `grep`.
Which `.tasks.toml` spellings name the `[markdown]` table, and which value forms are read from it, are bounded by what tasks-axi itself accepts, because tasks-axi is the file's real reader.
The suite proves both directions over the scope that mirror claim actually covers - one declaration of the key in the home's own `.tasks.toml` - so every form tasks-axi honors there still locates the configured archive while a form it ignores falls back here exactly as it does there.
`bin/fm-tasks-axi-lib.sh` owns that rule, the exact scope it holds over, and the measured divergences outside that scope which the tracked config keeps latent.

`tests/fm-classify-decision-key.test.sh` pins `status_key_closing_verb` itself: it separates a resolution from the durable-transfer close and from a still-open key, reports the last real transition across re-openings and both key positions, and treats a prose mention as no transition.

Projection regressions live in `tests/fm-fleet-snapshot-view.test.sh` (hold-until parsing, the due gate, kind-independent captain actionability, deferred_marker, title stripping) and `tests/fm-bearings-snapshot.test.sh` (Captain's Call membership, the dated-gate rendering, prose-deferral suppression with disclosure, and the landed exclusion by surviving captain-hold annotations).
The exact commands and their summarized outputs are recorded in the shipping PR's evidence; run the four suites above plus `tests/fm-send-resolve-key.test.sh`, `tests/fm-bearings-board.test.sh`, and `bin/fm-lint.sh` to refresh this record.
