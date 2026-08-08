# Bead Acceptance Projection

Date: 2026-08-08
Owner: Firstmate repository, `docs/architecture.md` section "Durable implementation capacity and attempt lifecycle design"
Composes with: `docs/superpowers/plans/2026-08-08-fleet-refill-terminal-lifecycle.md` and its active implementation branch
Audience: maintainer-architecture

## 1. Purpose and authority

The Bead Acceptance Projection is the read-only classifier that turns live Decision OS bead rows plus authoritative evidence into typed candidate dispositions with evidence, reason codes, revision identity, and a next action.
It answers the admission half of fleet refill: the capacity projection says how many implementation slots are free or reserved, and this projection says which beads may fill a free slot and why.
Decision OS beads remain the sole authority for work identity, priority, readiness, dependencies, ownership, and closure.
The projection is derived on demand from live beads plus authoritative decisions, Git/forge facts, Closure-Receipts, active task ownership, and isolated-copy/branch evidence.
It is not a second tracker, not a mutable truth store, and it never writes bead state.

The projection is staged in two phases.
Phase A is read-only classification and ships first.
Phase A proves its accuracy against the completed full P0/P1 reconciliation audit before any refill consumer may trust an `admit` row.
Phase B is a narrow, attended allowlist of mechanical tracker corrections under existing authority, enabled only after the Phase A accuracy proof and a separate captain authorization.
The captain-approved staged rollout is preserved: ship Phase A, prove accuracy, then separately authorize and enable Phase B.

## 2. Composition with existing owners

The projection composes the accepted fleet-refill owners instead of duplicating them.

- `bin/fm-capacity-lib.sh` remains the only classifier of implementation rows and aggregate capacity.
- `bin/fm-crew-state.sh` remains the only semantic worker-state parser.
- `bin/fm-attempt-lib.sh` remains the owner of immutable attempt envelopes and effect receipts.
- `bin/fm-disposition-lib.sh` (plan Task 4) remains the only live disposition reader for landed, preserved-unlanded, and unknown deliveries.
- `bin/fm-br-receipt.sh` (plan Task 5) remains the only Decision OS steward transaction owner.
- `bin/fm-terminal.sh` (plan Task 11) remains the sole attempt-to-terminal orchestrator.
- `bin/fm-cleanup-lib.sh` (plan Tasks 8-9) remains the only structured cleanup operation.
- `bin/fm-fleet-refill.sh --refill` (plan Task 12) remains the refill admission entry point.

The projection adds one new read-only classifier owner: `bin/fm-bead-projection.sh --json` plus `bin/fm-bead-projection-lib.sh`, emitting schema `fm-bead-acceptance.v1`.
It consumes the outputs of the owners above as evidence and never re-parses worker state, Git refs, forge state, or tracker internals itself.
A candidate row may carry a bounded evidence snapshot naming the owner that produced each fact and the exact revision observed.

The projection has exactly two consumption surfaces, both through one command:

1. `bin/fm-fleet-refill.sh --refill` admission (plan Task 12) consumes the projection's rows to select which beads to claim and dispatch.
2. Fleet review paths (`bin/fm-fleet-snapshot.sh`, bearings, and the human refill verdict) embed the exact projection object or call the same function; they never re-classify candidates.

The private sentinel, when it needs candidate facts, consumes the same object; it retains only cadence, query, logging, and notification policy.
No daemon, dashboard, scheduler, `.beadscope`, declaration registry, parallel database, or duplicated worker/Git/forge parser is added.

## 3. Phase A: read-only candidate classification

Phase A classifies every candidate bead row into exactly one disposition.
A candidate is any bead surfaced by the live tracker query (open, ready, unclaimed, dependency-safe, priority-relevant) plus every bead the refill admission might consider, including the rows the audits proved are wrongly surfaced.
The minimum disposition set is fixed: `admit`, `owned`, `gated`, `parked`, `needs-spec`, `landed-awaiting-closure`, `tracker-inconsistent`, and `non-executable-parent`.

Each emitted row carries five mandatory fields:

1. `bead_id` - the immutable Decision OS bead identifier.
2. `disposition` - exactly one of the eight dispositions.
3. `reason_codes` - a bounded list of machine-readable codes naming the evidence that produced the disposition.
4. `evidence` - a bounded snapshot of the authoritative facts consulted, each tagged with its source owner and revision.
5. `next_action` - the concrete next step for a consumer, never a bare state name.

The row also carries `revision_identity`: the exact observed revision of every authoritative source consulted, so a later reader can detect staleness.
A consumer must re-read the authoritative bead immediately before dispatch and re-classify whenever the live bead revision differs from the row's revision identity.
Uncertainty never fabricates readiness or a free capacity slot: a missing, stale, multiply claimed, or contradictory authoritative fact yields a conservative disposition with the gap named, never `admit`.

### 3.1 Dispositions

`admit` - the bead is open, unassigned or lawfully reclaimable, unblocked, dependency-safe, bounded, and conflict-safe on the current evidence, matching the accepted admission-band ruling.
Next action: dispatch through the plan's claim-before-allocation handshake after a fresh live-bead re-read.

`owned` - the bead carries an assignee or an active claim that is not lawfully reclaimable.
Next action: preserve ownership; escalate only when the ownership evidence is stale or contradictory.

`gated` - the bead is genuinely blocked by a dependency edge, an operator gate, a spec gate, a proof gate, or a dated trigger that remains unmet.
Next action: wait on the named gate and recheck on the named trigger.

`parked` - the bead carries an explicit park disposition or `parked` label with a recorded revive trigger.
Next action: wait for the revive trigger; never dispatch while parked.

`needs-spec` - the bead has a `needs-spec` or equivalent label and no executable acceptance contract.
Next action: spec work only; never dispatch implementation from an unexecutable contract.

`landed-awaiting-closure` - the delivery content is provably landed, but the canonical bead closure remains outstanding.
Next action: complete the terminal lifecycle and closure, never re-dispatch the landed content.

`tracker-inconsistent` - tracker fields contradict authoritative evidence, for example a captain ruling recorded only in comments, a stale `blocked` field with all blockers closed, a landed-but-open row, or an open-ready row whose own recorded NO-GO blocks it.
Next action: bookkeeping under existing authority through the Phase B allowlist, or escalate the ruling to the captain when the correction needs a decision.

`non-executable-parent` - the bead is a program parent or epic whose children carry execution.
Next action: never dispatch the parent; surface its executable children for separate classification.

A row whose evidence is insufficient for any disposition is emitted as `tracker-inconsistent` with the missing owner named, never silently promoted or demoted.

### 3.2 Evidence sources and reason codes

The projection reads evidence only through the authoritative owners:

- Live bead state through the Decision OS `br` CLI on the registered clone: status, priority, assignee, labels, dependency edges, and `br ready --json` / `br show --json` output, pinned to the installed command contracts.
- Authoritative decisions: captain rulings recorded in bead comments or decision files, and the accepted admission-band ruling.
- Git and forge facts: merge and landing evidence through the existing disposition and PR owners, never a new Git/forge parser.
- Closure-Receipts: the recorded operative receipt or its absence, through the closure-gate and steward owners.
- Active task ownership: the current attempt inventory and `fm-crew-state.sh` verdicts for live ownership.
- Isolated-copy and branch evidence: the attempt records' provider-copy identity, branch fate receipts, and preservation refs.

Reason codes are a bounded vocabulary owned by the projection library, one per named evidence condition, for example `open`, `unassigned`, `unblocked`, `dependency-safe`, `bounded`, `conflict-safe`, `assignee-present`, `active-claim`, `dep-edge-open`, `operator-gate`, `spec-gate`, `proof-gate`, `dated-trigger-unmet`, `label-parked`, `needs-spec`, `landed`, `closure-outstanding`, `ruling-in-comments`, `stale-blocked`, `landed-but-open`, `program-parent`, and `evidence-gap`.
A disposition is explained by the union of its reason codes plus the evidence snapshot, so a reviewer can reproduce the classification from the row alone.

### 3.3 Revision identity and re-read-before-dispatch

Every row records the observed revision of each authoritative source it consulted.
At minimum the identity covers the bead snapshot revision, the comment set, the dependency edge set, the assignee and claim state, the landing evidence revision, and the Closure-Receipt identity.
The refill admission must re-read the live bead and the live landing evidence immediately before creating the claim request, and must refuse dispatch when the live revision differs from the row's revision identity.
The projection is a snapshot, never a cache that outlives its observation: the row's revision identity is what makes staleness detectable, and staleness forces re-classification, not dispatch.

## 4. Phase A accuracy proof against the P0/P1 audit

Phase A must prove its accuracy against the completed full P0/P1 state-reconciliation audit at `/home/holu/fmate/firstmate/data/dos-p0p1-state-reconciliation-audit-0808/report.md`.
That audit is the reference for the P0/P1 non-closed universe: 129 rows with per-row dispositions, the 21-row ready-band challenge, false-ready rows, stale assignments, comment-carried rulings, landed-but-unclosed work, program parents, preserved branches, and tracker serialization ordering.
Its evidence files (`all_p0p1_nonclosed.json`, `comments_p0p1.json`, `deps_p0p1.json`, `p0p1_table.txt`) are the frozen shadow-validation fixtures.

The proof runs the projection over the full audit universe in shadow mode and compares each row's disposition against the audit's disposition.
Acceptance is measurable and has two parts:

1. Zero unsafe admissions: every `admit` row must match the audit's own evidence for that bead (unassigned or lawfully reclaimable, unblocked, dependency-safe, bounded, conflict-safe), and no audit-rejected row may be admitted.
2. An explained disposition for every disagreement: any row whose disposition differs from the audit's disposition must carry a reason code and evidence explaining the difference, because the audit is a point-in-time observation and the live tracker may have moved since it was taken.

The proof must exercise each audit class explicitly: false-ready rows (`dos-dedou`, `dos-t1pk2`, `dos-bars-pg-cutover-env-scope-w1zzz`), stale-blocked rows (`dos-arrival-wire-false-bargain-guard-wwuqi`), comment-carried rulings, landed-but-unclosed work (`dos-lr5yz`, `dos-cydb1.22.2`, `dos-weekly-letter-xwwp8`, `dos-ui-provisional-action-inbox-architecture-65t1p`, `dos-5tsm7`), program parents (`dos-raswd.4`, `dos-wo30o`), preserved branches (`work/dos-cydb1.8.1`, `work/dos-ljr3i-omp-adapter`), and the audit's tracker serialization ordering.
The proof also verifies that the projection never emits a free capacity slot from ambiguity: every evidence-gap row stays conservative and reserved.

The proof outcome is recorded in the maintained verification owner `docs/verification/bead-acceptance-projection.md` with the date, the projection version, the exact commands, the audit revision used, and the exact comparison output.
No refill consumer may trust an `admit` row until the recorded proof shows zero unsafe admissions and every disagreement explained.
The proof is a gate, not a one-time ceremony: re-running it against the frozen audit fixtures must stay green, and a changed classifier must re-prove before consumers trust it.

## 5. Full terminal lifecycle integration

The projection integrates the complete delivery lifecycle through the `landed-awaiting-closure` disposition and the evidence it consumes.

A bead is `landed-awaiting-closure` when the exact content is in the authorized target or joined through an authorized local-only merge, but the canonical bead closure remains outstanding.
The disposition requires merge or landing evidence from the forge and Git owners, the current Closure-Receipt identity or its absence, the exact branch fate, the isolated-copy return state, and the explicit preservation or archive disposition.
A pushed branch or merged PR alone is not terminal completion when bead closure remains: the row stays `landed-awaiting-closure` until the operative Closure-Receipt is verified or appended, the canonical bead closes through the serialized steward transaction, the exact branch fate is recorded, the provider copy returns, and the attempt retires.
The plan's ordered terminal composition owns that sequence; the projection only classifies and names the next action.

`preserved_unlanded` deliveries are never reported as product success and never closed merely because a bead is closed.
Preserved branches stay preserved, with their exact recovery refs recorded; the projection surfaces them for disposition authority rather than treating them as reclaimable or closable work.
Tracker serialization ordering is preserved: the projection's `next_action` for tracker-inconsistent and landed-awaiting-closure rows respects the single-writer order the audit recorded, so corrections and closures never race an in-flight tracker lane.

## 6. Phase B: narrow attended allowlist

Phase B enables a narrow, attended allowlist of mechanical tracker corrections under existing authority.
It is enabled only after the Phase A accuracy proof passes and the captain separately authorizes the allowlist.
Every Phase B correction is performed by firstmate or the attended steward through the existing `bin/fm-br-receipt.sh` transaction in the audit's serialization order, never autonomously by the projection and never by a worker.

The allowlist is exactly the bookkeeping class the audit already determined under existing authority:

- Recording already-ruled captain decisions, such as deferring `dos-dedou` and `dos-t1pk2` per the recorded 2026-08-06 rulings and re-blocking `dos-bars-pg-cutover-env-scope-w1zzz` per its recorded NO-GO.
- Amending recorded notes, such as the `dos-72n4n` revive-trigger amendment.
- Removing stale dependency edges, such as the `dos-cydb1.22.2` to `dos-cydb1.8.1` edge.
- Closing landed beads with valid Closure-Receipts, such as `dos-cydb1.22.2`, `dos-weekly-letter-xwwp8`, `dos-ui-provisional-action-inbox-architecture-65t1p`, and `dos-5tsm7`, and re-attempting closure for `dos-lr5yz`.

Phase B must never reprioritize, never reclaim ownership, never make product decisions, never waive gates, never close without valid receipts, never merge, and never delete preserved work.
A correction that needs any of those is not in the allowlist and returns to the captain as a decision.
The allowlist is explicit and bounded; enabling Phase B does not authorize anything outside it.

## 7. Staged rollout

The rollout is the captain-approved staged sequence.

1. Ship Phase A: the read-only projection command, its library, schema, and behavior tests, with no runtime admission change.
2. Run the accuracy proof against the frozen P0/P1 audit fixtures and record the outcome in the maintained verification owner.
3. Only after zero unsafe admissions and explained disagreements may refill admission and fleet review consume `admit` rows.
4. Separately authorize Phase B, then enable its narrow allowlist through the attended steward path.

Rollback for Phase A is trivially safe because it is read-only: consumers stop trusting the rows and nothing else changes.
Rollback for Phase B disables the allowlist and preserves every attempt, bead, branch, ref, copy, and receipt; it never restores legacy arithmetic and never converts missing evidence into capacity.

## 8. Verification and tests

Behavior tests cover the public projection interface, one fixture per disposition, the re-read-before-dispatch refusal, and the evidence-gap conservatism.

Shadow-validation tests replay the frozen audit fixtures and assert the two-part acceptance: zero unsafe admissions and an explained disposition for every disagreement.
Composition tests assert that refill admission and fleet review consume the exact projection object and never re-classify candidates.
Negative tests assert that the projection adds no daemon, dashboard, scheduler, `.beadscope`, declaration registry, parallel database, or second worker/Git/forge parser, and that it never writes bead state.
The maintained verification owner records the proof run and its exact output.

## 9. Acceptance criteria

The design is accepted when one command exposes the full read-only Phase A projection with the eight minimum dispositions, evidence, reason codes, revision identity, and next action per row; when the projection composes the accepted owners without duplicating a parser, tracker, or capacity classifier; when Phase A proves zero unsafe admissions and explained disagreements against the full P0/P1 audit before any refill consumer trusts it; when the complete delivery lifecycle is integrated so that a pushed branch or merged PR alone is never terminal completion while bead closure remains; when Phase B is a narrow attended allowlist under existing authority that can never reprioritize, reclaim, decide, waive, close without receipts, merge, or delete preserved work; and when the staged rollout ships Phase A, proves accuracy, and only then enables Phase B.
