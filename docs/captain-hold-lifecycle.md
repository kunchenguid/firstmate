# Captain-hold lifecycle mechanism

The normative policy is owned by `.agents/skills/captain-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, compatibility contract, and privacy-safe regression evidence.

## Mechanism

A decision is not a separate thing in this system: it is an ordinary backlog task held for the captain, and the task id is the identity every surface and channel uses.
`bin/fm-captain-hold.sh` is the only lifecycle command layered on that primitive.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned captain call stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand places an existing task under an active captain hold, or creates the task when nothing exists to hold, then verifies the hold through `tasks-axi hold <id> --reason <reason> --kind captain`.
Repeats are idempotent, a closed task is refused rather than reopened - including one retention has already moved into the archive - and `--until` stores the captain's own deferral date through tasks-axi's date gate.
When `--origin` names an origin whose task metadata is live, `hold` also extends that origin's stored `decision_keys=` inventory with the held task, so a captain call found by a later review pass is checked by the completion gate without waiting for another `complete` call to name it.
It never writes `decisions_reviewed=1`, because holding a task for the captain is not an attestation that the review is finished.

The `answer` subcommand records the captain's exact words and closes the call in the same act.
It requires a non-empty captain decision file of at most 8192 bytes, writes a resolution block carrying the decision digest and a `Resolution mode:` at the top of the task body (the previous body is preserved below the block and archived through tasks-axi `--archive-body`), then runs `tasks-axi done` - or `tasks-axi unhold` under `--release`, so a captain-gated work item resumes instead of closing.
An exact retry is idempotent only when the requested close mode matches the newest record; a drifted answer or mode mismatch is rejected, while a re-held task accepts a new answer as a new record on top.
On a task closed outside the script, `answer` records the missing block only when the captain-hold annotations tasks-axi preserves through a close prove the captain owned it, and it verifies the task stays closed.
Because that retroactive record is the gate's only escape hatch, it reaches an archived task too, rewriting that one archived entry in place through the archive owner in `bin/fm-tasks-axi-lib.sh` and applying every guard above to the archived record first.
A hold whose `--until` date has passed keeps those annotations while tasks-axi reports it no longer held, so an expired deferral remains answerable.

The `complete` subcommand unions the reviewed captain-held task ids into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable tasks without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, refused while the origin still has a lifecycle-open keyed status decision, and verifies every listed task against tasks-axi before recording completion.
With a non-empty inventory it appends a `captain-held [key=<key>]: tracked by <inventory>` transfer event for every still-open keyed status decision, which `bin/fm-classify-lib.sh` recognizes as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the read-only `verify` subcommand after checking for the report and before removing any source state.
`verify` requires the recorded attestation, requires every recorded inventory entry to still be durable (actively captain-held, or carrying a recorded answer), and fails on any keyed status decision that opened after the last `complete`, which makes re-running `complete` the repair.

Read-only inspection resolves an inventory entry against the live backlog first and against the archive named by the home's `.tasks.toml` second.
tasks-axi prunes a closed task out of the live backlog on every close once the `done_keep` window is full and keeps it permanently in that archive, so an origin with more captain calls than the window has answers in the archive from the moment they are answered, and both the keyed and the `--none` attestation read them there.
`--none` continues to union the stored inventory rather than replace it, because an empty attestation must never be able to wave through a call the origin already registered.
An archived entry that carries no recorded captain answer still fails, so the gate's refusal-on-uncertainty direction is unchanged.
The `--force` path remains the explicit captain-approved discard escape hatch.

## Answer-time closure

"A keyed answer closes its matching captain-held task" is one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<task-id>\t<answer>\t<label>[\t<mode>]` lines and closes each named task through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
The optional mode column carries a card-declared close: `done` (default) completes the task and `release` lifts the hold so held work resumes; any other value is skipped.
A key that names no task, names a task that is not captain-held, or names a task already closed is reported as `skipped:` and feeds nothing; a replay whose answer and requested close mode match the newest record is an idempotent `closed:`, while a mode mismatch is skipped; and the command exits nonzero when any key was skipped.
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

## Compatibility with pre-collapse installs

Older installs created derived `<origin>-decision-<key>` identities through the retired `bin/fm-decision-hold.sh`.
Those rows are already plain task ids, so they render, answer, verify, and close through the collapsed surfaces with no data migration.
Three legacy inputs are resolved in place: a `decision_keys=` metadata entry that names no task resolves through `<origin>-decision-<entry>`; a channel key that names no task resolves the same way when the source's binding carries a concrete legacy origin; and resolution records written by the old script are recognized wherever a record is read.
The shim recognizes an exact replay of a pre-collapse routed resolution by its historical answer digest and routed ids, then finishes any still-recorded dependency-edge cleanup without rewriting the old decision text.
`bin/fm-decision-hold.sh` itself remains for one release as a thin command-mapping shim over `bin/fm-captain-hold.sh`, so in-flight work briefed before the collapse keeps working; its header owns the exact mapping.

## Verification record

Verification date: 2026-08-20.

The focused end-to-end regression suite is `tests/fm-captain-hold-lifecycle.test.sh`, using only synthetic `sample` identities and decision text.
It proves: a report-only unresolved captain call refuses `--none` completion before teardown can erase the source; non-forced scout teardown always requires the durable inventory verification; the recorded-answer guard (a bare `tasks-axi done` close fails `verify` until `answer` records the captain's word, and an ordinary finished task cannot be dressed up as an answered call); answer-time closure through a bound channel with task-id keys, including the `release` close mode, mode-matched replay idempotence, and the refusal of drifted, mode-mismatched, absent, unheld, and already-closed keys; the chat channel reaching the same intake; deferral through `--until` leaving `captain_actionable` false until due; and every legacy path (composed identities through the shim, pre-collapse `decision_keys=` metadata, routed-resolution replay, and a concrete-origin binding).
It also proves the retention boundary: an answered call that retention moved into the archive still clears `complete`, `--none`, and `verify` and still rejects a drifted retry or a reused id; a retroactive record reaches an archived call in place without rewriting a neighbouring archived entry; an archived call carrying no answer still refuses; and a call held after the first completion enters the inventory the gate checks.

Projection regressions live in `tests/fm-fleet-snapshot-view.test.sh` (hold-until parsing, the due gate, kind-independent captain actionability, deferred_marker, title stripping) and `tests/fm-bearings-snapshot.test.sh` (Captain's Call membership, the dated-gate rendering, prose-deferral suppression with disclosure, and the landed exclusion by surviving captain-hold annotations).
The exact commands and their summarized outputs are recorded in the shipping PR's evidence; run the three suites above plus `tests/fm-send-resolve-key.test.sh`, `tests/fm-bearings-board.test.sh`, and `bin/fm-lint.sh` to refresh this record.
