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

The `retract` subcommand takes one key back out of the recorded union when a later review pass establishes that it duplicates a question already inventoried under a different key.
It exists because `complete` unions keys idempotently while the durability lookup reads the live backlog and done archive: removing a duplicate hold with `tasks-axi rm`, which is the correct de-duplication action, previously left the key recorded and absent from both durability sources, so `verify` and `complete` refused permanently and scout teardown could never clean the source up.
The required `--superseded-by` key must already be in the same origin's inventory and must itself satisfy the shared durability lookup, and a state-changing retraction requires the removed key to still belong to that inventory, so the question stays gated under one surviving identity and a retraction can never empty the union.
Retraction removes the duplicate identity from the live backlog when it is still there, which keeps `tasks-axi rm`'s own refusal to delete an id that active work still blocks on in force, and it refuses a recorded captain decision in an interrupted live resolution as well as a durably resolved decision in either the backlog or the archive.
An already absent inventory key takes an idempotent no-op path without inspecting or removing the retracted live task, changing metadata, or appending a status transfer.
An unreadable archive is deliberately asymmetric: it blocks the surviving key, because the gate must not rely on an identity it could not check, but it does not block the retracted one, because an archive that cannot be read is not evidence that the removed duplicate was resolved, and refusing there would leave the strand in place.
For an open keyed status decision it appends the same `captain-held [key=<key>]: ...` transfer event `complete` uses, so `bin/fm-classify-lib.sh` closes the live status copy without claiming the captain answered.
The gate itself is unchanged: `verify` and the shared durability lookup are the same code before and after, and only the inventory the agent asserts is editable.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The completion, verification, and retraction subcommands share one durability lookup, which reads the live backlog first and falls back to `data/done-archive.md` only when the identity is absent there.
That secondary read exists because tasks-axi Done retention prunes older resolved records out of the live backlog, which previously made a correctly filed and correctly resolved decision indistinguishable from one that was never filed.
The fallback is read-only, never restores a record into the backlog, and satisfies the gate only for an archived record that is marked done, is kind `captain`, and still carries the durable resolution record.
An identity absent from both sources, an archived record that is not resolved, and a missing, unreadable, or malformed archive all keep the same refusal.
The refusal now names what it actually found rather than reporting every case as absence: a decision that was never filed, one that is archived without a durable resolution record, and an archive that could not be read are reported distinctly, because only the first two are facts the gate can establish.
`resolve` uses the same archived record to stay idempotent for an exact retry that straddles retention, and still rejects a changed decision or routed-task set.

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

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Archived resolved decision lookup verification date: 2026-08-05.
Duplicate decision key retraction verification date: 2026-08-08.

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

### Archived resolved decision lookup

Verification date: 2026-08-05, against tasks-axi 0.2.3.

The two added cases use only synthetic `sample` identities.
The first drives a real hold through completion and resolution, then archives it with `tasks-axi prune --keep 0 --state done` so the resolved record leaves the live backlog exactly as Done retention leaves it.
The second exercises every archive shape that must not satisfy the gate: absent from both sources, unreadable, malformed, archived but not marked done, archived and done without a durable resolution record, a non-`captain` identity, a longer id that merely shares the prefix, and a neighbouring record whose resolution must not leak across the entry boundary.
It also asserts that an unreadable archive is never reported as a decision that was never filed.
Both cases fail against the pre-change script, the first with the reported `is absent from .../data/backlog.md` refusal.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - an archived resolved captain decision satisfies the completion gate
ok - only a genuinely resolved archived captain decision satisfies the gate
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

### Duplicate decision key retraction

Verification date: 2026-08-08, against tasks-axi 0.2.4 and ShellCheck 0.11.0.

The added case uses only synthetic `sample` identities.
It files three keys, two of which are the same route question under different slugs, completes the inventory, and removes the duplicate with `tasks-axi rm` exactly as an operator de-duplicates a hold.
It first asserts the strand itself: `verify` refuses naming the removed identity, a `complete` retry refuses, and non-forced scout teardown refuses while preserving the investigation's records.
`tasks-axi rm` was confirmed to succeed against an actively held item, so the removal that causes the strand needs no unusual state.
While the strand is still live the case asserts every anchor-validation refusal: a missing `--superseded-by`, a key superseding itself, a superseding key outside the reviewed inventory, and a superseding key that is in the inventory but is no longer durable.
That last refusal is what stops a removed identity from being used to justify dropping a decision that is still genuinely held, and the surviving hold is asserted to remain in the backlog after it.
The case then retracts the duplicate, asserts the reduced union, and asserts the live status fold no longer holds the retracted key open.
It asserts an identical retry is idempotent and that the retry reports that the key is already outside the inventory without mutating the backlog or status state.
It also asserts that a never-inventoried live hold and a mistyped absent key take that same pure no-op path without mutating backlog, status, or metadata state.
It then interrupts `resolve` after the captain decision is recorded and dependents are unblocked but before the final Done transition, and asserts that retraction refuses while preserving the queued hold and its resolution record.
Finally, it asserts that a durably resolved decision is not retractable either while it is in the live backlog or after `tasks-axi prune --keep 0 --state done` archives it.
It closes on the acceptance criterion: teardown now succeeds, and the second distinct captain decision is still in the backlog afterwards.

The case fails against the pre-change script at `not ok - retracting a duplicate key failed`, after every strand assertion above has already held, which is what proves the reproduction is not vacuous.

The suites covering the surfaces this change touches were also run and pass: `tests/fm-brief.test.sh`, `tests/fm-fleet-snapshot-view.test.sh`, `tests/fm-bearings-snapshot.test.sh`, `tests/fm-wake-drain-open-decisions.test.sh`, `tests/fm-wake-drain-open-decisions-cursor.test.sh`, `tests/fm-documentation-audiences.test.sh`, `tests/fm-test-run.test.sh`, and `tests/fm-test-isolation-proof.test.sh`.
`tests/fm-teardown.test.sh` reports one failure, `herdr-preflight-missing-adapter`, which is pre-existing and environment-dependent rather than caused by this change: stashing both changed files reproduces the identical single failure, one before and one after.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - an archived resolved captain decision satisfies the completion gate
ok - only a genuinely resolved archived captain decision satisfies the gate
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a de-duplicated decision key is retractable and no longer strands teardown

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=70 local_links=217
```
