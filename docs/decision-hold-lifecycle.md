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
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
Every live completion also binds the exact `endpoint_task_id=` dispatch to the report path and digest in a script-owned origin receipt, including for `--none`.
For each unresolved hold, `complete` requires a fresh Bearings snapshot that exposes the exact hold, then records a cleanup receipt bound to the origin, dispatch, hold identity, backlog-object digest, and Bearings-evidence digest.
An exact post-teardown visual-review pass can add an open hold and rerun `complete` only while the retained report still matches that trusted origin receipt and its dispatch binding.
An open historical hold with a surviving exact binding can reconstruct a missing cleanup receipt through the same full-inventory retry.
Missing or mismatched binding evidence, and already-resolved historical or hand-written rows without script-owned receipts, remain preserved and refused because no safe automatic migration is shipped.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
For an unresolved hold, verification requires the exact dispatch binding, trusted origin and cleanup receipts, a matching nonzero backlog-object digest, and a fresh Bearings appearance.
For a resolved hold, verification instead requires the trusted resolution chain described below.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand requires a decision file and at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It first requires the trusted cleanup receipt, retains the captain's exact bytes in a canonical decision object, and records the decision digest and complete routed-task identity set as the retry identity in the hold body.
It clears each dependency edge through tasks-axi and marks the hold Done only after those writes succeed.
After closure it writes a resolution receipt bound to the origin, dispatch, hold, canonical decision object and digest, routed identities, and unique live-or-archived row object and digest.
An exact retry can finish a partial routing operation or a missing resolution receipt only while the cleanup receipt and canonical decision object survive; a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open unless the row already closed, in which case verification still refuses until the matching script-owned resolution receipt exists.
The read-only `verify-resolution` subcommand revalidates that full chain and every routed task.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-08-03.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the teardown gate refuses to erase the source.
The regression also covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
It exercises origin and dispatch binding, fresh Bearings visibility, nonzero object digests, post-teardown review, partial resolution retry, canonical decision retention, live-or-archived row uniqueness, and refusal of malformed, duplicated, hand-written, or historically unprovable authority objects.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - post-teardown completion rejects hand-written resolved rows
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - historical open and binding-less refusals name only safe operator remedies
ok - absent, malformed, duplicate, wrong-origin, hand-written, and zero-digest resolution rows refuse
```

`bin/fm-doc-audience-check.sh` and `git diff --check` are the documentation-phase structural checks.
