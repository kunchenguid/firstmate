# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only filing command for captain decisions, whether an investigation or visual review discovered them or they gate a work item that already exists.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
The `link` subcommand is the supported HTTPS-only backfill for an existing active hold and preserves every other body field.
It rejects an identity collision, a changed title, attempts to reopen an already resolved identity, malformed links, and non-HTTPS links.

## Structured decision context

A captain decision records its context as separate structured body fields rather than as one free-text hold reason: a required `Decision question`, optional `Decision options`, optional `Decision kind` with a required `Decision expects` and optional `Decision fact fields` when that kind is `fact`, optional `Decision group`, required `Why now`, `What it affects`, and `Recommendation`, and exactly one of `Decision URL` or `No decision surface`.
`Decision options` is an explicit ordered set of two to four distinct labels, each at most 80 bytes, for a decision whose useful answers are already a clean small pick.
It is absent rather than inferred when the decision needs free text or when no options were filed.
`Decision kind` currently accepts only `fact`, which marks a decision that asks the captain to supply a specific fact or classification rather than choose a course.
`Decision expects` is a 160-byte hint for the useful answer shape and the free-text fallback, is valid only with that explicit kind, and is required once that kind is set.
A fact request the captain cannot answer in the expected shape is not answerable, so the hint travels with the kind rather than being optional beside it.
`Decision fact fields` is an optional ordered JSON array supplied with `--fact-fields` for a fact request that is better answered as discrete values than as prose.
Each entry has a display `label`, stable `key`, `type` from `text`, `number`, `date`, `money`, `enum`, or `longtext`, and boolean `required`, plus optional `hint`, `example`, and `unit` strings.
An `enum` entry also carries two to twenty distinct `enum_options`.
Keys begin with a letter, contain only letters, digits, underscores, or hyphens, are at most 64 characters, and are distinct within the array.
The schema accepts one to eight fields, while filings should normally use roughly three to eight fields for one sub-question.
A fact pack that needs repeated rows is split into separate grouped decisions in v1 rather than encoded as a repeater or grid.
[`bin/fm-decision-readiness.jq`](../bin/fm-decision-readiness.jq) owns the exact bounds and shape validation used by both the filing command and read projections.
None of the fact-intake fields is inferred from the question, recommendation, or other prose.
`Decision group` is an optional privacy-safe slug of at most 80 bytes that the filer assigns when separate captain decisions share one originating investigation or report.
It changes only Mission Control presentation, never the durable identity, resolution, dependency, inventory, or Answer path of any member.
Omitting `--group` preserves a stored group on retry, supplying it later adds or replaces that field, and a decision with no group remains unchanged.
The structure makes the required context dimensions and conscious surface choice enforceable.
A single reason string lets a dimension be skipped silently, and an optional link flag lets the surface question be forgotten, which is what produced decisions that could not be acted on without re-reading their investigation.
Prose quality is deliberately not machine-checked, because clarity and jargon-freeness are semantic judgements a script cannot make; the skill owns them, and `data/captain-shared.md` states the bar they are judged against.

Each required dimension is supplied on the first filing and may be omitted from a retry when the item already records it.
A first filing therefore cannot omit one, while the idempotent retry that `hold` is designed for supplies none and preserves what is stored.
The two surface fields are one choice, so recording either clears the other and an item can never claim a built surface and no built surface at once; `link` clears a recorded `No decision surface` for the same reason.
The schema is additive: an old-style hold that carries only a plain hold reason keeps that reason and renders unchanged, while a hold that already records the earlier optional question or URL keeps those fields too.
Supplying options on a later idempotent filing replaces that one structured set, while a retry that supplies none preserves whatever was already recorded.
Supplying `fact`, its expected-answer hint, or its fact-field schema on a later filing likewise replaces that field, while omission preserves it; a hint-only or schema-only retry is valid once the stored kind is already `fact`.
Options and grouping remain optional independently, while a field schema always requires explicit fact intake and none of these additions changes a decision that carries none.
`resolve`, `complete`, `verify`, `retract`, and `link` are untouched on such a hold.
Re-arming one with `hold` does require the full bar, because the presence check reads the stored body and finds nothing there; that is the going-forward contract rather than a compatibility gap, and it converts an old hold into a complete one at the moment it is next touched.
Structured context currently reaches the captain through Mission Control only.
`bin/fm-bearings-snapshot.sh` and the session-start digest still surface the hold reason alone, so a decision relayed from Bearings carries the reason and the board carries the context.

The `hold-item` subcommand applies that same bar to a backlog item that already exists, under whatever kind the item carries.
It is the supported replacement for filing a captain decision with a bare `tasks-axi hold <id> --kind captain`, which reached the captain without passing any bar.
It never creates the item, never rewrites its title, kind, or repo, and never touches the `decision_keys` inventory that `complete`, `verify`, and scout teardown read.
It requires a queued item because a captain hold leaves an in-flight row in flight, where the snapshot classifies it as work under way rather than as an actionable decision, so a decision filed there would never reach the captain.
Setting a decision aside and bringing it back stay outside this bar because they restore stored text rather than file a decision; `bin/fm-mission-control.sh` owns both, including the reason-rewriting hazard.

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

## Structural readiness

The fields above are each required as they are supplied.
On top of them one structural readiness checklist decides whether a filed decision is answerable at all, and [`bin/fm-decision-readiness.jq`](../bin/fm-decision-readiness.jq) owns it so the filing command, the read-only sweep, and Mission Control apply exactly one rule.
A decision carrying structured context is ready when all of the following hold:

- `Decision question` is present and non-empty.
- `Recommendation` is present and non-empty.
- Exactly one of `Decision URL` or `No decision surface` is recorded, never both and never neither.
- `Decision options`, when present, is two to four distinct non-empty labels of at most 80 bytes each.
- `Decision expects` is present and non-empty whenever `Decision kind` is `fact`.
- `Decision fact fields`, when present, carries the supported schema shape and accompanies `Decision kind: fact`.

Options, fact intake, and fact fields are validated only when present, because they remain optional.
A hold carrying only a free-text reason predates structured context, carries none of these fields, and is deliberately outside the checklist, so it is never reported as incomplete.
The checklist judges presence and shape only.
Whether the question is clear, the recommendation sound, or the linked surface genuinely built stays the semantic judgement the skill owns.

Both filing paths refuse an incomplete filing before anything is created or held, reporting every gap at once with the flag that fixes each.
`bin/fm-decision-hold.sh doctor` is the read-only sweep of the same checklist: with no argument it checks every open captain decision in the active home, meaning an item that is not done and carries an active captain hold, and with a task id it checks that one item.
A parked decision is out of scope, because the captain set it aside and re-surfacing it would undo that choice.
The sweep names the specific failed check rather than a bare verdict and exits non-zero when anything is incomplete.
Nobody has to remember to run it, because the same verdict travels on the snapshot and surfaces on the board.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields, preserving internal commas in the free-text hold reason while short metadata fields remain comma-delimited.
It also parses every structured decision-context field written by `bin/fm-decision-hold.sh`, including the ordered option labels, fact-intake framing, ordered fact fields, and shared group key, then carries them through the main-home record and secondmate-home decision projection.
It reads them for any row whose hold kind is `captain` or `parked`, not only a row whose own kind is `captain`, because a captain hold can gate an item of any kind and setting one aside changes only its hold kind.
`bin/fm-mission-control.sh` renders the context fields it finds on the decision card and falls back to the plain hold reason for a decision that carries none.
Each such row also carries `decision_readiness`, the structural verdict as `{structured, ready, gaps}`, where every gap names its failed check and the flag that fixes it, so no reader restates the checklist.
A record from a home that predates the field carries no verdict, which reads as unrecorded rather than as ready.
The verdict is scoped to the home whose backlog the snapshot reads, so a decision owned by a secondmate home carries none and never reaches this home's fleet health; that home runs its own sweep over its own backlog.
Once the direct board-reply service proves it is available, a valid option set becomes quick-answer buttons without replacing the free-text Answer path; the legacy Lavish transport remains Answer-only.
An explicit `fact` kind with a valid non-longtext-only field schema renders a fielded Answer form in Mission Control, while a fact with no usable schema keeps the free-text Answer form and expected-answer hint.
[`docs/mission-control.md`](mission-control.md#sections) owns when the visual wrapper appears, how grouped answered ordering works, and which sections remain unchanged.
An open captain decision the checklist reports as incomplete appears in the board's fleet health section with the specific gaps as its hint, and counts toward fleet health, so an unanswerable decision is visible without running a separate command.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies any unblocked row with hold kind `captain` and a non-empty hold reason as actionable regardless of the row's own kind.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Archived resolved decision lookup verification date: 2026-08-05.
Fact-field schema verification date: 2026-08-10.
Duplicate decision key retraction verification date: 2026-08-08.
Decision-context field and HTTPS-link verification date: 2026-08-08.
Structured decision context and one filing bar verification date: 2026-08-09.
Structural readiness checklist verification date: 2026-08-10.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.
The decision-context regression records exact questions and private HTTPS links through the supported hold interface in both main and secondmate homes, backfills an existing hold without changing its other body fields, and rejects malformed or non-HTTPS destinations without fetching them.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - an archived resolved captain decision satisfies the completion gate
ok - only a genuinely resolved archived captain decision satisfies the gate
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - exact questions and private HTTPS links use one supported hold interface across homes
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a de-duplicated decision key is retractable and no longer strands teardown

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

### Structured decision context and one filing bar

Verification date: 2026-08-09, against tasks-axi 0.2.4, ShellCheck 0.11.0, and Chrome for the rendered assertions.

Two cases are added to `tests/fm-decision-hold-lifecycle.test.sh`; `tests/fm-mission-control.test.sh` gains one case and extends its existing cross-home decision case. All use synthetic `sample`, `alpha`, and `brain` identities.

The schema case asserts that each dimension refuses on its own naming the flag it wants, that a refusal creates no partial backlog identity, that the surface choice refuses both when silent and when both answers are given, that a complete filing stores every dimension as a separate snapshot field beside an unchanged `hold_reason`, that an idempotent retry supplying nothing preserves the stored context rather than demanding or blanking it, and that recording a surface either way clears the opposite claim so an item never holds both.
The `hold-item` case asserts that the ad-hoc path now refuses a bare filing, refuses an absent item, refuses an in-flight item whose captain hold could never be classified as actionable, gates a queued item of another kind without rewriting its title or kind, reaches the snapshot as an actionable decision carrying its context, and leaves the `decision_keys` inventory and originating-task metadata untouched.
The render case builds one fixture home holding a structured and an old-style decision, asserts each labelled section by its exact rendered markup, and pins the rendered context-block count to one so leaving the old-style decision alone is proven rather than inferred.
It then renders a SECOND board whose structured decision carries a recorded PR, because only a decision with a link has its row title wrapped in an anchor, and a placement assertion against a decision with nothing to link would pass wherever the context sat.
That board is measured in headless Chrome at 1280px and 390px to assert the context block is outside the row link and overflows neither width; the measurement self-skips when Chrome or Node is absent, so CI without them still runs the markup half.
The existing cross-home case is extended to assert the same labelled sections on a decision projected from a secondmate home, because that path reaches the renderer through different key names than the main-home one and the bar applies to decisions filed in any home.

Both placement guards were shown to bite by rebuilding the renderer with the context emitted inside the row anchor.
The rendered measurement reports `decision context rendered inside the row link at 1280px, so reading it navigates away` and fails the case, which the markup assertion alone did not catch in that build because a second correctly placed copy still satisfied the string match.
That is the reason the rendered measurement exists alongside the markup assertion rather than instead of it.

Non-vacuity was established by reverting only `bin/fm-decision-hold.sh`, `bin/fm-fleet-snapshot.sh`, and `bin/fm-mission-control.sh` while keeping the new cases.
Both new lifecycle cases then fail at their first assertion, `not ok - a decision with no stated reason for needing a call was filed`, and the render case fails at `not ok - the reason a decision is needed now must be its own labelled section`.
The fourteen pre-existing lifecycle cases were updated to pass one standard synthetic context set, because a first filing must now address every dimension; that change is the contract, not a workaround.

The suites covering the surfaces this change touches were run and pass: `tests/fm-fleet-snapshot-view.test.sh`, `tests/fm-bearings-snapshot.test.sh`, `tests/fm-brief.test.sh`, `tests/fm-documentation-audiences.test.sh`, `tests/fm-wake-drain-open-decisions.test.sh`, `tests/fm-test-run.test.sh`, and `tests/fm-test-isolation-proof.test.sh`.
`tests/fm-teardown.test.sh` again reports only the pre-existing environment-dependent `herdr-preflight-missing-adapter` failure; stashing every changed file reproduces the identical single failure before and after.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - an archived resolved captain decision satisfies the completion gate
ok - only a genuinely resolved archived captain decision satisfies the gate
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - exact questions and private HTTPS links use one supported hold interface across homes
ok - each decision dimension is separately required, stored, and retrievable
ok - an existing work item of any kind is gated under the same due-diligence bar
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a de-duplicated decision key is retractable and no longer strands teardown

$ bash tests/fm-mission-control.test.sh
ok - structured decision context renders as labelled sections and leaves old-style decisions unchanged
ok - a captain decision inside a secondmate home is surfaced and counted

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=70 local_links=222
```

### Structural readiness checklist

Verification date: 2026-08-10, against tasks-axi 0.2.4, ShellCheck 0.11.0, jq 1.7.1, and Chrome for the rendered check.

One case is added to each of `tests/fm-decision-hold-lifecycle.test.sh`, `tests/fm-fleet-snapshot-view.test.sh`, and `tests/fm-mission-control.test.sh`, all using synthetic `sample` identities.

The lifecycle case asserts that a filing with no question is refused before any backlog identity exists, that a fact request with no expected-answer hint is refused and reports every gap at once rather than one per retry, that a complete decision carrying neither options nor a fact kind passes, that a hold filed with only a free-text reason is reported as outside the checklist rather than incomplete, and that one sweep names the specific failed check and its flag for each of six fixtures missing exactly one dimension.
The same sweep is asserted to omit the complete decision, the free-text hold, and a decision the captain set aside.
The malformed-option fixture is written directly into the backlog rather than filed, because `--option` already refuses that shape at filing, so a fixture built through the filing flags would have asserted nothing.
The snapshot case asserts the verdict reaches `backlog.records[]` as `{structured, ready, gaps}` with each gap naming its check and flag, and pins the malformed-option row to a null `decision_options` alongside an `options` gap, which is what proves the verdict reads the raw body: the parsed field alone cannot distinguish a malformed set from an absent one.
The board case asserts the incomplete decision renders as a fleet health row by its exact markup with every gap as its hint, counts toward fleet health, and widens the attention bar from "blocked or failed" to "fleet health item needs attention", while the complete, free-text, and set-aside decisions produce no health row.
The rendered board was also read at 1280px and 390px in Chrome; the row reuses the existing state, subject, and hint shape already used by every other health row, and neither width overflows.

Non-vacuity was established by reverting `bin/fm-decision-hold.sh`, `bin/fm-fleet-snapshot.sh`, and `bin/fm-mission-control.sh` and removing `bin/fm-decision-readiness.jq` while keeping the new cases.
Each new case then fails at its first assertion: `not ok - a decision with no question was filed`, `not ok - a complete structured decision was not reported ready`, and `not ok - an incomplete decision must reach fleet health naming every gap`.

Two pre-existing contracts tightened, and the existing cases were updated to match them rather than around them.
`Decision question` is now required, so the suite's one shared synthetic context set gained a question, as did the three places that write a decision body directly.
`Decision expects` is now required whenever `Decision kind` is `fact`, so the fact-intake case files its hint from the start and still proves that a later hint-only retry replaces it.
The state that case previously asserted, a fact decision carrying no hint, is no longer reachable through the filing flags and is covered instead by the new sweep fixture.

The sweep was also run read-only against the live main home, which is the no-regression evidence the synthetic fixtures cannot give.
Six open captain decisions were present.
The two carrying structured context both passed every check, and the four filed under the older plain-reason shape were skipped entirely rather than reported, so nothing already landed is newly flagged and the board's fleet health count is unchanged by this work.

```text
$ FM_HOME=<main home> bin/fm-decision-hold.sh doctor
checked 2 structured captain decisions; all ready for the captain
exit status 0
```

```text
$ FM_HOME=<fixture> bin/fm-decision-hold.sh doctor
gappy-one: not ready for the captain
  - the decision question is missing (--question)
  - the recommendation is missing (--recommendation)
badopts-one: not ready for the captain
  - the answer options are not two to four distinct short labels (--option)
2 of 3 structured captain decisions not ready for the captain
exit status 1

$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - an archived resolved captain decision satisfies the completion gate
ok - only a genuinely resolved archived captain decision satisfies the gate
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - exact questions and private HTTPS links use one supported hold interface across homes
ok - each decision dimension is separately required, stored, and retrievable
ok - an existing work item of any kind is gated under the same due-diligence bar
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a de-duplicated decision key is retractable and no longer strands teardown
ok - structural readiness is refused at filing and swept with the specific failed check

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - empty fleet snapshot and view use explicit absence markers
ok - fixture snapshot covers task rows, backlog rows, pointers, and stable ordering
ok - main_inventory discloses orphan/unstructured and clears when inventory is consistent
ok - backlog normalization preserves strict roles, blocker readiness, and reverse dependencies
ok - parked captain holds project optional choices, fact intake, and decision groups without cross-interference
ok - snapshot event hints follow reconciled current state
ok - durable fold keeps an open decision past a later unrelated event
ok - a live secondmate endpoint preserves unrelated open decisions
ok - durable captain-held transfer closes the duplicate live status decision
ok - durable fold clears a decision only on a keyed resolution
ok - a completed scout's stale decision surfaces as a report pointer, not pending
ok - a scout still parked at a decision stays pending (terminal clear does not over-fire)
ok - snapshot includes durable scout reports after teardown
ok - snapshot parses tasks-axi rows and respects operational overrides
ok - the lifecycle stage is derived from live state, one rung per proven step
ok - secondmate Setup uses its existing agent-liveness evidence
ok - the recorded model reaches the task row, and an unrecorded one stays empty
ok - fleet view renders the snapshot without secondmate peek guidance
ok - fleet view renders secondmate agent liveness
ok - the structural readiness verdict travels on the snapshot record

$ bash tests/fm-mission-control.test.sh
ok - the attention bar reaches fleet health once health sits behind a tab
ok - an unanswerable captain decision surfaces in fleet health with its gap
(55 cases, all ok)

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=72 local_links=237

$ bin/fm-test-run.sh --check-coverage
FM_TEST_COVERAGE ok total=136 parallel=24 serial=100 serial_shards=4 herdr=12
```
