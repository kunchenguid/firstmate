# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It records the decision digest and routed task identities as a retry identity in the hold body, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

The optional `--from-ruling <path>:<line>` argument records which ruling document answered the hold.
It is verified before any mutation rather than trusted: the argument is passed to `bin/fm-ruling-reconcile.sh closure-test`, and a provenance that fails either closure condition refuses the resolve and leaves the hold open.
The hold body then carries a `Ruling provenance:` line above the blank line that `verify_resolution_identity` parses on, so retry identity is unaffected.
The work file that verification uses is removed on a signal as well as on exit, and the signal still terminates the process rather than being absorbed, so an interrupted `resolve` leaves the hold open exactly as any other failure before the final step does.

A hold body no longer carries a `State:` line.
A hold that reports its own state is a claim rather than a verdict, and that string outlived the captain's answer often enough for an investigation to build on a hold that had already been ruled.
The structured `state`, `held`, and `hold_kind` fields are the single state owner.

## Ruling-to-hold reconciliation

`bin/fm-ruling-reconcile.sh` matches open captain holds against the ruling documents that name them, and writes a derived index under `$FM_HOME/state/ruling-index`.
The index is content-fingerprinted over the open-hold set and the ruling-document inventory, so an unchanged corpus and hold set reach a `no_delta` terminal before any ruling document is opened for matching.
It is derived and never authority: deleting it is always safe, decision truth stays in the ruling documents, and hold truth stays in the backlog.

The script produces candidates, excerpts, and an eligibility verdict, and never grades or closes.
Document class is decided structurally from naming: the `<what>commission.md` suffix form is tested first and is decisive, then the anchored `<who>-rulings-<when>` or `<who>-ruling-<when>` prefix form, then the containing directory.
The commission suffix wins because a document that declares itself a commission must never satisfy the captain's condition 1, however much the rest of its name resembles a ruling, and an unrecognised name is `other`, which escalates.
A hold identifier matches only when it is bounded by delimiters, so a row that rules a longer identifier containing this one cannot stand in for it, and the index scan and the closure test share that single pattern.
A dot is legal inside a hold identifier, so a trailing dot counts as a boundary only when it ends the line or is followed by whitespace: an identifier ending a sentence is recognised, while `a.b` still cannot stand in for a line naming `a.b.c`.
That distinction matters because a silent false-unmatch reports `unmatched: no ruling document names this hold` and is believed, which is the failure this increment exists to eliminate rather than merely a missed closure.
A verdict token counts only inside single-line markdown emphasis and only as a whole word with an optional verb inflection, so an emphasised word that merely contains a token does not qualify.
A markdown table row is scanned alone rather than through a window, because a windowed scan attributed one table row's verdict to a different row six lines above it.
Eligibility is necessary and not sufficient: closure additionally requires a caller grade of `rules` and a separate `fm-decision-hold.sh resolve` call.

The empty-set law is enforced as a terminal refusal, over both inputs.
A ruling-class document that is symlinked, outside the corpus root, or unreadable yields `verdict=NO_RULING_READ` and exit 3, and a `tasks-axi` hold listing that fails yields `verdict=NO_HOLD_READ` and exit 3.
No index is published in either case, because an unmatched hold must never rest on a ruling nobody read and `open_holds=0` must never rest on a backlog nobody could list.
Symlinks are listed by the corpus walk specifically so they can be refused rather than silently dropped.

`closure-test` enforces corpus containment on its own `--ruling` argument rather than trusting the caller, because that argument is what authorises a closure.
An absolute path outside the corpus root, a `../` traversal, and a symlinked path component are each refused with `reason=ruling-document-outside-corpus-root`.
`resolve --from-ruling` then reads the `closure=` field of that test's stdout and requires it to be exactly `permitted`, because the caller-supplied path is echoed back in the same output and any search of the whole stream can be satisfied by a crafted filename.

`bin/fm-session-start.sh` surfaces one bounded line when open captain decisions exist and stays silent otherwise.
A read-only session reads the existing index instead of rebuilding it, because publishing the index is a mutation.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Ruling-to-hold reconciliation verification date: 2026-08-06.

Every case in `tests/fm-ruling-reconcile.test.sh` was shown able to reject its defect before being trusted.
Each assertion was re-run against a deliberately broken copy of the production script and observed failing, then re-run against the real code and observed passing.
Three real defects surfaced during that work, listed here by how each was actually discovered, because crediting a defect to a control that did not find it would overstate what the controls prove.
Exactly one was hidden by a green suite and revealed by its mutation control: the two `grep -qv` assertions were passing, and restoring the retired `State: awaiting captain decision.` string failed to turn the case red, which exposed that `grep -qv` succeeds whenever any line differs and so asserted nothing at all.
One was an ordinary first-run failure and never hidden: the new case requiring an unreadable ruling document to exit 3 failed immediately with `rc=0`, exposing a `find -type f` corpus walk that skipped a symlinked ruling document instead of refusing it.
One came from measuring the real corpus before any test for it existed: running the closure test across every row of this home's flagship ruling table showed a hold reporting the `**RESOLVED**` verdict that belongs to a different row six lines below its own, and `test_table_row_does_not_inherit_the_next_rows_verdict` was written afterwards as a regression and only then proven red-capable.

Closure-gate hardening verification date: 2026-08-06.
Six further cases cover the ways the two-condition test could be satisfied without being met, and each was mutation-controlled the same way by reverting exactly one guard in the production script and observing the case fail.
They cover a hold identifier that is only a prefix of the identifier the cited row actually rules, an emphasised English word that merely contains a verdict token, a ruling document reached by absolute path, `../` traversal, or symlink from outside the corpus root, a commission whose filename resembles a ruling, a `--from-ruling` path crafted to plant `closure=permitted` in the closure test's own echoed output, and a `tasks-axi` hold listing that fails.
The fixture corpus gained three ruling rows and one commission that exist only to be refused, so the suite fails rather than passes if any of those guards is removed.

A further case covers the identifier boundary itself, and asserts all three of its outcomes together because they once shared one wrong answer.
It requires that an identifier ending a sentence is matched, that a shorter dotted hold is still not matched by a longer dotted identifier, and that a hold named nowhere still reports its unmatched row, so a boundary widened until everything matches fails it just as a boundary that refuses everything does.

Interrupt handling verification date: 2026-08-06.
A further case interrupts `resolve` while its closure-test subprocess is open and requires that the process terminates with a signal status, that the captain hold is left open, and that the work file is gone, with the ordinary refusal and ordinary success paths asserted alongside it.
Both halves are needed together: removing the trap satisfies the interrupt half while reopening the leak it closed, and a handler that absorbs the signal satisfies the cleanup half while letting the resolve run on and close the hold the operator was aborting.

`bin/fm-ruling-reconcile.sh` was additionally measured against this home's real corpus rather than fixtures alone.
Across the twelve documents it classifies as rulings, the flagship ruling table yielded 15 eligible rows of 24 when measured; the other nine state their verdict without emphasis and therefore escalate.
That figure is an upper bound now that tokens match only as whole words, and it is reported rather than tuned, because widening the token vocabulary until it reproduced a hoped-for count would defeat the condition it implements.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
all teardown safety cases passed

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```
