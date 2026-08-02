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

Creating a new identity while the home already holds other open captain decisions exits 3 and prints that open set with each decision's age.
Exact-key repetition never reaches this branch, so idempotent retry and recovery are unaffected.
The refusal is deliberate rather than a warning: success output is not reliably read, and semantic duplicate matching needs the open set in context before the write, not after it.
It is not a hard block, because a genuinely distinct decision must still be registrable; `--distinct` clears it and records the attestation in the new decision's body.
The `open` subcommand prints the same listing on demand, with `--aging-only` for the threshold subset.

The `fold` subcommand is the alternative path when the finding belongs to a decision that is already open.
It appends `Also raised by <origin>: <note>` to the target's body through `tasks-axi update --body-file`, skipping the write when the same marker is already present, and unions the target identity into the origin's `decision_folds=` metadata.
It refuses a target that is not an actively held captain decision and refuses an origin folding into its own decision namespace.
Reading the target body decodes the JSON string literal tasks-axi emits, so `jq` is required for `fold` and `resolve`.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It accepts `--folded` when every unresolved decision the pass found is already owned by a hold the origin folded into, and refuses `--none` while any fold is recorded, so folding cannot become a way to attest an empty surface.
It verifies every listed identity and every recorded fold identity against tasks-axi before recording completion; `verify` applies the same check, so the teardown gate is strictly stronger than before folds existed.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve` subcommand takes the captain's answer as `--decision <text>` or `--decision-file <path>`, and routes dependent work with `--routed-to` or declares its absence with `--no-routed-work`.
`--routed-to` still requires every named task to exist and to carry a structured `blocked-by` edge to the hold.
`--no-routed-work` is refused whenever `tasks-axi list --blocked` reports any task blocked by the hold, so the routing requirement is enforced by observed state rather than by the caller's claim, and survives wherever dependent work genuinely exists.
The two lighter inputs exist because the previous shape - write a file, invent a dependent task, block it - made recording an answer more expensive than repeating the question, which is how an answered decision came to be lost while its authority was cited elsewhere.
It records the decision digest and routed task identities as a retry identity in the hold body, carries the prior registration record forward under `Origin record:` so the distinctness attestation and any folded findings survive closure, clears each dependency edge through tasks-axi, and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation and does not nest the carried-forward record, while a changed decision or routed-task set is rejected.
A failed intermediate step leaves the hold open.

## What counts as durably resolved

`verify_hold_durable` backs both the completion gate and the teardown gate, and accepts four shapes.
A decision is still actively held; or it carries this script's canonical resolution record; or it is closed with some other decision record in its body; or Done retention has rotated it into `data/done-archive.md`.

The third and fourth shapes exist because the gate was rejecting on formatting rather than on substance.
A decision closed by hand with a written record - because firstmate decided it, or because an earlier captain answer already settled it - is resolved, and a decision that aged out of the live backlog through ordinary retention is resolved too.
Rejecting either strands the finished investigation that found the decision, which is a failure of the gate rather than a defence of it.

The gate is not weakened, because each accepted shape still requires durable evidence that the decision was answered.
A closed decision whose body is empty, or whose body still carries the untouched registration record saying `State: awaiting captain decision.`, is refused: it says in its own words that no answer was ever written down, which is exactly the loss this gate exists to prevent.
`--decided-by firstmate` records a firstmate-decided closure honestly rather than attributing it to the captain.

## Ageing

Every captain-actionable backlog row carries `waiting_days`, the whole days since its `since` date, and `decision_aging`, true once that reaches `FM_SNAPSHOT_DECISION_AGING_DAYS` (default 3).
Both are computed in `bin/fm-fleet-snapshot.sh` from the existing `since` metadata that `tasks-axi add` already writes, so every decision registered before this behavior existed reports its age with no migration and no schema change.
`bin/fm-bearings-snapshot.sh` carries `since`, `waiting_days`, and `aging` into `decisions_open` and orders it ageing-first then oldest-first, so an ageing decision leads the section and cannot be truncated away by the bounded cap.
The threshold is three days because that is the shortest span that always covers a full working day plus a weekend edge, so it cannot fire on a decision the captain has simply not reached yet, while still surfacing a stalled decision long before the week-long silences it exists to prevent.

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
Duplicate refusal, folding, ageing, lightweight resolution, and externally closed recognition verification date: 2026-08-02.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - externally closed and archived decisions are durably resolved, recordless closure is not
ok - a firstmate-decided closure is first-class and attributed honestly
ok - a second pass cannot silently duplicate an open decision and can fold into it
ok - an answer is recorded in one call and routing survives where dependent work exists
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
ok - an ageing open decision carries its age, leads the section, and survives the cap
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
