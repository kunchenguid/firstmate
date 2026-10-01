# Lane-output recoverability (repairs and recorded degradation)

Supplement to the main `SKILL.md` (progressive disclosure per the issue #2131
criterion-G ratchet). This file documents the recoverability contract added to
keep substantively-correct but format-imperfect runs completable.

## Parser-boundary repairs (recorded as salvage)

Two benign shape defects are repaired automatically at the parser boundary and
are never a reason to retry by themselves:

- **`clean-evidence-pipe-tail-merge`** — literal unescaped pipes inside a
  `[CLEAN]` row's evidence text (regex character classes like `,;|`, shell
  snippets) are tail-merged into the evidence field instead of splitting the
  row past the 4-field contract. Deterministic: evidence is the trailing field.
- **`summary-row-dropped`** — pipe-bearing non-contract marker rows
  (`[LANE_SUMMARY]`, `[NOTE]`, `[DONE]`, …) are dropped before parsing; they
  were previously miscounted as malformed candidate rows that voided an
  otherwise-valid clean attestation. Pipe-free lines are preserved (they may be
  continuation fragments).

Both repairs are recorded as salvage on the lane record. Lanes should still
escape pipes as `\|` where practical, but the review no longer fails when they
do not. The per-obligation CLEAN rules: a `[CLEAN]` conflicts with `[CANDIDATE]`
rows only for the SAME lane; a valid CLEAN for a different lane in an unscoped
parse is skipped, not an error; duplicates for the same lane still fail.

## Host-transport recovery (recorded as salvage)

Collection preserves a strict evidence hierarchy: the complete immutable
`output_ref` artifact outranks its bounded inline preview. Consequently,
`result.truncated` is not a failure when that artifact still passes identity,
digest, exact-head, scope, ownership, and row-coverage validation. The affected
workflow lane is recorded in `salvaged_workflow_lanes` even when no parser repair
was necessary. That compatibility list is paired with typed per-lane metadata in
`salvaged_workflow_lane_recoveries`.

A host `session.status` timeout means readiness is **unknown**, not busy and not
complete. Status and message calls receive separate fair bounded budgets so one
lane cannot starve later lanes. For unknown readiness, a readable transcript is
accepted only when the newest assistant message proves terminal completion; a
mid-run snapshot remains pending. Invalid output also remains pending while
readiness is unknown, because the agent may still be producing its protocol row.

When the host message window is incomplete, independently validated positive
`[CANDIDATE]` rows may be recovered only for base and micro discovery lanes;
their exact owned workflow lanes are marked salvaged. Council, reviewer, and
critic outputs remain fail-closed and require retry when incomplete. `[CLEAN]`
is absence evidence and therefore requires a complete transcript. One positive
row in a consolidated lane never salvages a sibling dimension whose only
evidence is `[CLEAN]` or missing. Recovery reasons are lane-scoped and use six
kinds: `legacy-verdict-row-recovery`, `parser-normalization`, `parser-row-recovery`,
`truncated-preview-durable-artifact`,
`transcript-incomplete-terminal-candidate`, and
`clean-attestation-salvaged` (a `[CLEAN]` attestation conflicting with a
same-lane `[CANDIDATE]` row was discredited while the candidate rows were
retained — the attestation contributes no coverage).

## Verdict-row pipe tolerance and its fidelity boundary

`[REVIEWED]` (10-field), `[CRITIC]` (6-field), and `[FEEDBACK-VERIFIED]`
(4-field) rows tail-merge extra pipe separators into the trailing free-text
field. Fidelity boundary: content-preserving when the extra pipes sit in the
trailing field; a pipe in a mid-row prose field still authenticates (all
machine-checked positions are untouched) but trailing prose fields may be
re-arranged. A debug-gated warn fires on every applied merge; the raw lane
emission is always retained verbatim in the lane-output store, so repairs are
re-derivable.

## Recorded coverage degradation (trigger evaluation)

The trigger-eval writer accepts only an exact eleven-row v2 receipt whose
`MATCHED` rows are backed by exact-head artifacts from lanes that declared
ownership of their families through a verifiable provenance chain (identity,
ownership, digest, retained artifact). A lane whose coverage QUALITY is
imperfect — it ended `error`/`cancelled` after exhausting retries, or its
artifact has no covered `[CANDIDATE]`/`[CLEAN]` row for the row's own family —
no longer dead-ends the run: the writer records the failure on the durable
receipt as a `coverage_degradations` entry (trigger id, source lane, reason,
row-scoped so a consolidated lane's covered families are never misattributed)
and proceeds. The tool result reports `coverage_degradation_count`; the
synthesis phase MUST disclose every degraded family, with its recorded reason,
in the final review report. Retries remain the first resort (COVERAGE GATE); a
missing provenance chain still fails closed, and the reviewer/critic inventory
skips exactly the receipt-disclosed dispatch tuples.

## Bounded merge-base fallback (`base_verification`)

Every v2 receipt now records how its `base_sha` was verified at write time:

- **`live`** — the writer re-derived the merge base with a bounded
  `git merge-base -- <base_ref> <pr_head_sha>` and it matched the supplied
  `base_sha` exactly. This is the normal path.
- **`bound_fallback`** — that re-derivation was **unavailable**, and the writer
  proceeded because the supplied `base_ref`/`base_sha` exactly equalled the
  review scope already bound durably at dispatch time.

The distinction matters because the git helper collapses every failure mode
into a bare `null`: a timed-out git call, a git process that failed to spawn, a
`base_ref` that is unresolvable in this checkout, and a ref rejected as an
unsafe revision token are indistinguishable to the caller. Treating that `null`
as *refutation* rather than *unavailability* made review completion permanently
unsatisfiable — every retry re-failed identically, the trigger-eval receipt was
never written, an omission dispatch could not repair it, and the only exit was
`abort_pr_workflow`. The bound scope is not a weaker fact: it was itself derived
by a real `git merge-base` at dispatch and only trimmed/lowercased on the way
into durable state, so re-deriving it at write time is a redundant re-check.

What `bound_fallback` does and does not mean:

- It does **not** widen what was reviewed. The reviewed range stays SHA-scoped
  (`base_sha...pr_head_sha`), identical to the `live` path.
- It does mean post-bind movement or deletion of the base ref would go
  undetected for this run — the one staleness signal the live re-check provides.
- It never relaxes a mismatch. If the re-check is unavailable **and** the
  supplied scope differs from the bound scope in either half, the writer fails
  closed with an enriched message naming the possible causes and the recovery
  options. If the gate has no bound base at all, the writer fails closed before
  attempting resolution.

**Synthesis obligation (skill-directed):** when the trigger-eval result or the persisted receipt
reports `base_verification: bound_fallback`, the final review report MUST
disclose it. State that the merge base could not be re-verified live at write time and that the review was
scoped to the durably bound base. Do not silently present the review as if the
base had been re-verified. (Unlike `coverage_degradations`, which the workflow gate reads as a machine-enforced waiver filter, `bound_fallback` disclosure is skill-directed.)

## Provenance fields: dispatch ledger vs. writer rows

Two different row shapes carry the trigger evaluation, and mixing them up is a
recurring source of first-dispatch failures:

- **Dispatch-time `trigger_evaluation` rows** (the inline ledger frozen by the
  first micro dispatch) use the strict inline schema: `trigger_id`, `result`,
  and `evidence`, and nothing else. Adding `source_batch_id` or
  `source_lane_id` there is rejected — at dispatch time no lane has run yet, so
  there is no provenance to cite, and the frozen-ledger digest is computed over
  exactly those three fields.
- **Writer `rows`** (passed to `write_pr_review_trigger_eval` after the lanes
  settle) carry the provenance: every `MATCHED` row adds the `source_batch_id`
  and `source_lane_id` returned by its completed micro lane, and every
  `NOT_TRIGGERED` row must omit both.

Classifications must be identical across the two — the writer rejects
classification drift from the frozen ledger — while `evidence` may be reworded
in the writer call and is simply ignored (the frozen values are authoritative).

## Gate-level recovery: stuck lanes, corrupted state, amended inventory

Three wedge states used to leave a workflow with no exit through any tool. Each
now degrades with disclosure; the contradiction cases still fail closed.

### Stale lanes no longer block abort or completion

A lane whose background process dies without writing a terminal snapshot used to
count as "in flight" forever, and the same predicate gates `abort_pr_workflow`,
the PR_REVIEW to PR_FEEDBACK transition, and `complete_pr_workflow` — so the
escape hatch was refused by the very condition it exists to resolve.

A lane whose delegation record has not advanced its `updatedAt` for 30 minutes is
now **presumed stale** and settles instead of blocking. The disclosure appears as
`presumed_stale_lanes` / `presumed_stale_disclosure` on the `abort_pr_workflow`
and `complete_pr_workflow` responses, as a `pr_workflow_lanes_presumed_stale`
record in `.swarm/events.jsonl`, and on the `pr_workflow_aborted` audit event.
The delegation record itself is transitioned to `stale`.

A lane with a **recent** `updatedAt` still blocks — a check that can run and
reports "still progressing" is not softened. Collect it with
`collect_lane_results`, or wait for the horizon.

### A live session past the horizon is retained, not discarded

Nothing heartbeats `updatedAt`, so age alone cannot tell a dead lane from a slow
one. Before settling anything, the gate now runs a **liveness probe** over the
stale candidates: if the host affirmatively reports a lane's session as `busy` or
`retry`, that lane is **retained** — it keeps blocking, its record stays
`pending`/`running`, and its transcript stays collectable.

The probe is deliberately **fail-open**. For its error and no-data cases that is
the inverse of the collector's readiness check, which refuses to collect a lane it
cannot verify; the two agree rather than invert on a host that exposes no
`session.status` at all, where the collector proceeds and the probe reports
`probe-unavailable`. Only a probe that RAN and named a live session may contradict
staleness. Every other outcome settles exactly as age alone would, and says why:

| Outcome | `probe_status` |
| --- | --- |
| No session handle, or the host exposes no `status` | `probe-unavailable` |
| The call threw | `probe-error` |
| The call exceeded the 5s probe deadline | `probe-timeout` |
| The response carried an `error` | `probe-error` |
| The response carried no `data` | `probe-no-data` |

The collection-time `pending_liveness` **advisory** shares that probe core and
therefore most of those reasons, with two advisory-only additions
(issue #2815): `advisory-unavailable` (the advisory's own accounting failed
after the past-threshold set was known) and `probe-skipped-no-budget` (the
caller's probe budget was already exhausted — typically an expired `wait:
true` deadline or a `timeout_ms: 0` snapshot — so **no probe was attempted at
all**). `probe-skipped-no-budget` is an observer-side budget artifact: it says
nothing about the lane's session, and it must never be read as the host being
unable to reach it. `probe-timeout` remains reserved for a probe that actually
ran and hit its deadline.

Where it surfaces: `probe_retained_lanes` on the `complete_pr_workflow` response,
`probe_status` on both tool responses, `probedAliveLanes` / `probeStatus` on the
`pr_workflow_lanes_presumed_stale` record, and `probeRetainedLanes` /
`probeStatus` / `probeRetentionOverrideLanes` on the `pr_workflow_aborted` event.
Note that the event's `openLanes` now counts fresh open lanes PLUS probe-retained
lanes, so a successful force abort can record a non-zero value where it always
recorded `0` before. The settled-lane disclosure
appends either `liveness probe found no live session` or `settled despite
liveness probe failure (<reason>)`, so "re-verified" and "not re-verified" are
never confused.

**Retention has one override, and it is human-only.** A session that never goes
idle would otherwise make the workflow permanently unexitable. `/swarm
abort-pr-workflow` (the `force` path, not agent-callable) clears the gate when
probe-retained lanes are the ONLY thing still blocking, and discloses exactly
which lanes it overrode — those sessions are not stopped and their output is not
collected. A lane with a fresh `updatedAt` is never overridden.

On that override path only, the overridden lanes' delegation records are also
finalized to `stale` — immediately **after** the gate clears, never before.
Without that finalization the session would be left un-restartable:
`prepare_pr_workflow_checkout` refuses while any `pending` / `running`
`swarm-pr-*` record of the session exists, with no age filter, and an overridden
lane never terminates on its own. So an override is the one case where a retained
lane's record does NOT stay `pending` and its transcript stops being collectable,
and the disclosure says so explicitly.

The ordering matters for recoverability, which is what this document is about.
The clear is CAS-guarded and can legitimately lose its compare-and-swap and
throw; the finalization is irreversible. Doing the irreversible half second means
a failed clear abandons no RETAINED lane and the operator's retry is a real
override — so **a `pr_workflow_abort_not_completed` retraction in
`.swarm/events.jsonl` means the lanes named in `probeRetentionOverrideLanes` were
not finalized by the override, and their output is still collectable**
(`probeRetentionOverrideFinalized: false`).

Read that scope literally. It does NOT mean the abort finalized nothing:
settlement durably sweeps the same batch's probe-DEAD lanes to `stale` *before*
the clear is attempted, so those are already terminal when the retraction is
written. Nor does it guarantee the named lanes are still `pending` by the time
you read the record — a concurrent force abort for the same session can clear and
finalize them, and that is itself one of the ways this CAS loses. Treat
`.swarm/delegations.jsonl` as the authority and re-read it rather than inferring
record state from the retraction alone.

The override's disclosure separates three facts that used to be conflated, and
every one of them is a POSITIVE observation rather than an inference from
absence:

1. Which overridden records went terminal `stale` — named by `correlationId`.
   Only these have output that is no longer collectable.
2. Which overridden records the sweep left INTACT because they had already moved
   on — named as `correlationId (status)` with the status actually observed on
   disk. **This abort did not discard them, so check `collect_lane_results`
   before assuming that work is gone.** The clause deliberately stops at "left
   intact" rather than promising collectable output: an `error` or
   `ingestion_error` record comes back as `failed` with no result text, and an
   `ingesting` one is filtered out of `lane_results` until it settles, so the
   status is what tells you whether there is anything to read. An earlier
   version inferred (1) from a lane's absence from the still-open set, and a
   raced-to-`completed` lane is absent for the opposite reason a finalized one
   is, so it was reported as gone while its transcript sat on disk.
3. Whether the session can start a new PR workflow. This is read back over EVERY
   still-open `swarm-pr-*` record of the session, not just the overridden ones —
   because the ordinary settlement sweep swallows a store-lock timeout and
   returns `0`, so a lane the abort reported as settled can still be `pending` on
   disk and refuse the next checkout preparation. When that happens the
   disclosure names the blocking `correlationId`s instead of claiming
   restartability.

`.swarm/delegations.jsonl` remains the authority on which rows actually went
terminal.

### A corrupted gate state no longer defeats abort

If the durable gate-state file fails schema validation but is still valid JSON,
`abort_pr_workflow` and `pr_workflow_status` read it through a **recovery-only**
reader that salvages `sessionID`, `mode`, `prHeadSha`, and — when each is
individually well-formed — `revision`, `prFeedbackReadyToPublish` and
`checkoutRecovery`. Every other reader, including all write and completion paths,
still refuses the file, so a salvaged view can never be acted on as if it were
valid. `stateSalvaged` / `stateSalvageDisclosure` name the schema errors.

Boundaries that deliberately did NOT soften:

- **Unparseable bytes fail everywhere.** There is nothing to salvage.
- **Unreadable identity fails everywhere.** Without a readable `sessionID` and
  `mode` there is no provable subject to act on.
- **An unreadable `prFeedbackReadyToPublish` is treated as ARMED**, so abort
  still refuses. Corrupting that one record must never become a way past the
  armed-abort refusal.
- When `revision` cannot be salvaged, abort takes the documented
  compare-and-swap escape and says so:
  `state revision unsalvageable; cleared without compare-and-swap`.

### The PR_FEEDBACK inventory is append-only, not immutable

A finding discovered after `declarePrFeedbackInventory` used to require
`abort_pr_workflow` plus a full restart, discarding completed verification work
for correctly-declared items. Re-declaring with **additional** items is now
accepted; every previously-declared entry must still be present, so mutation and
removal still hard-fail (`inventory is append-only after declaration`).

What an amendment costs, and what it preserves:

- Completed **verification** batches for the original items are preserved. Cover
  the appended item with a new verification batch owning just that item.
- Stage A must be re-recorded over the full amended inventory, and each ordered
  gate phase must be re-run with a lane owning every current inventory item —
  a gate batch recorded before the amendment no longer settles its phase. This
  is deliberate: it is the control that stops an appended item reaching
  publication with no verdict.
- Publication is disarmed by an amendment (the armed record attested coverage of
  the pre-amendment inventory). Re-arm with one `complete_pr_workflow` call.
- Every appended entry is recorded in an audit ledger surfaced as
  `inventory_amendments` on the completion response and `inventoryAmendments` on
  `pr_workflow_status`. The ledger is bounded at 128 entries and is never pruned;
  further amendments are refused at the cap.

## Liveness-terminal dead-family settlement at trigger-eval (issue #2835)

A `MATCHED` trigger row whose cited micro lane is liveness-terminal — settled
by the presumed-stale sweep with `workflowLaneFailureClass: 'liveness'`,
terminal status `stale` or `error`, and no retained artifact — is admitted by
`write_pr_review_trigger_eval` as a disclosed dead family instead of
provenance-backed. The writer verifies the exception from the durable
delegation record itself (micro mode, family ownership, exact pr_head_sha
identity via `workspace.prHeadSha` and `workspace.gitHead`, typed liveness
class, no `outputRef` and no retained artifact); the receipt then carries a
`coverage_degradations` entry naming the dead batch/lane with the terminal
status, and the review proceeds as a disclosed PARTIAL — that family is
UNATTESTED and can never support an APPROVE verdict. This disclosure is the
settlement of last resort for a dead family: retry the family first (the
initial attempt plus up to 2 retries — aborting after only the first retry is
one bounded retry early), then disclose, and only then is `abort_pr_workflow`
legitimate.

The retry budget is mechanically enforced (issue #2878): every micro-family
dispatch acknowledgment (`dispatch_lanes_async` with mode
`swarm-pr-review:micro`) appends one record to the persisted per-family
micro-family dispatch ledger in PR-workflow gate state, and the dead-family
admission requires three recorded dispatch attempts (initial dispatch plus 2
retries, `PR_REVIEW_MICRO_FAMILY_RETRY_BUDGET`) for the cited family under
the same `pr_head_sha` — with the cited batch among the counted attempts —
before it stops failing closed with an actionable budget message that names
the recorded count. Crash-window disposition of the ledger: each attempt is
durably recorded at acknowledgment time, strictly before any lane session is
created, so no dead lane can exist whose dispatch was not first counted; a
crash between the acknowledgment and the lane launch leaves a benign orphan
entry (batchId idempotence prevents double-counting on a retry of the same
dispatch call, and the over-count direction is conservative because the cited
batch must still exist as a real stale delegation record to be disclosed at
all); the ledger is bounded at 128 records with a fail-closed BLOCKED refusal
at the cap — never silent eviction. An operator-cancelled lane does NOT qualify — it was ended by
`cancel_lane_batch` (or the human force abort), an explicit controller act
recorded as the distinct `operator_cancelled` class; re-dispatch the family
instead of disclosing it.

## Incident classification and parser-vs-gate proof scope (issue #2859 relocation)

Classify the incident from actual user-visible harm and the first failed
predicate, not from the number of retries or the eventual result. A successful
post-hoc fallback is recovery evidence; it does not justify the protocol
deviation or erase the original failure. Conversely, the candidate tool and
the coverage gate use a shared row parser, while the gate separately verifies
durable provenance such as batch, session, lane, role, head, digest, and
artifact identity. Parser success therefore proves row structure only; it does
not settle the durable coverage obligation.
