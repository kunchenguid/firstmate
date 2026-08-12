# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity, including one whose answer has since been archived.

A hold identity carries one of five durable states, reported by the read-only `state` subcommand: actively held, resolved in the live backlog, resolved and archived out of it by Done retention, present but neither, or absent.
The first three all satisfy the gates below, because an inventory key proves a decision was inventoried rather than that it is still open.
An archived answer counts only when the archived record still carries the complete `resolve` resolution record, so a row that was collapsed into another, edited down, or deleted stays unaccounted for and still refuses.

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

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

`bin/fm-decision-ledger.sh` owns every decision FIGURE and its definition, so raw status-event counts cannot be published as open decisions.
It folds the open set through `bin/fm-classify-lib.sh`'s `status_open_decisions` rather than counting events, classifies each key through `fm-decision-hold.sh state`, and refuses to emit unless the open-decision figure equals the length of an enumerated row list in which every key carries a disposition.
Its raw event counts come from `status_line_decision_transition`, the public accessor that answers with the fold's own three gates - key grammar, reserved namespace, and verb class - so a line the fold declines to treat as a transition can never be counted as a decision opened and then superseded.
Bearings projects that record into `decision_ledger` and the never-truncated `decision_keys`, and fails rather than publish an open-decision count that no enumerated key backs.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Archived-answer and decision-coverage verification date: 2026-08-06.
Fold-agreeing transition-accessor verification date: 2026-08-11.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The archived-answer regression drives a decision through `resolve` and then `tasks-axi prune --keep 0`, so verification meets a key whose answer exists only in the archive, and pairs it with a collapsed row and a hollowed archive record that must both still refuse.
The coverage regression builds one home carrying every disposition at once, with far more raw decision events than open keys.
It also drives a reserved-namespace line the fold ignores and the same key's recognized form, so a counter that read the key grammar on its own would report a decision opened and superseded that never existed.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - an answered-and-archived key is closed while an unaccounted one still refuses
ok - an archived captain answer cannot be reopened and stays identity-checked
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/fm-decision-ledger.test.sh
ok - only the lines the authoritative fold acts on become ledger figures
ok - raw decision events stay distinct and can never stand in for the open-key count
ok - every distinct live key carries its own disposition and closed keys stay out
ok - an unclassifiable hold state is disclosed per key and never silently dropped
ok - bearings publishes the ledger and refuses a count that no enumerated key backs

$ bash tests/fm-classify-decision-key.test.sh
ok - the public transition accessor answers exactly what the fold does

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - mixed secondmate roles, partial state, and captain readiness project independently
ok - main and secondmate captain actionability use the same blocker readiness
ok - an inventory beyond the argument limit still produces a complete bearings view

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
