# Findings Persistence Contract (Profile A)

## Executable dialect parity

The following machine-readable block mirrors `src/background/pr-review-contract.ts`. CI parses it structurally; changing a skill dialect without the executable schema (or vice versa) fails the contract test.

<!-- PR_REVIEW_EXECUTABLE_DIALECT_START -->
reviewer_fields: marker | item_id | classification | evidence_type | severity | introduced_by_pr | file:line | rationale | probe | reviewer_notes | risk_impact | risk_tags
reviewer_classifications: CONFIRMED | DISPROVED | UNVERIFIED | PRE_EXISTING
reviewer_evidence_types: STRUCTURALLY_PROVEN | EXECUTION_PROVEN | STATIC_TRACE_PROVEN | PLAUSIBLE_BUT_UNVERIFIED
critic_fields: marker | item_id | status | severity | rationale | required_change
critic_statuses: UPHELD | DOWNGRADED | DISPROVED | NEEDS_MORE_EVIDENCE
severities: CRITICAL | HIGH | MEDIUM | LOW | INFO | NONE
finding_statuses: PENDING | CONFIRMED | DISPROVED | PRE_EXISTING
finding_actions: route_to_reviewer | route_to_critic | report | suppress_with_reason | handoff_to_feedback
artifact_boundaries: post_explorer | post_reviewer | post_critic
<!-- PR_REVIEW_EXECUTABLE_DIALECT_END -->

The enforced write order, per-boundary disposition matrix, severity semantics,
error-reporting shape, and handoff schema for `write_pr_review_artifact`
(issue #2277). The entry SKILL.md carries the summary; this reference is the
full contract.

## Enforced write order and prerequisites

The controller admits findings checkpoints in this exact sequence, each
step a hard prerequisite for the next:

1. Base lanes settle (all six dimensions successful and parsed).
2. Optional base-only `boundary: "post_explorer"` checkpoint (issue #2280):
   admissible immediately after base settlement, BEFORE the micro wave. It
   is the one exception to trigger-eval-before-findings. Records must
   exactly cover the BASE-DERIVED candidate inventory — micro candidates are
   not yet discoverable, so a micro id is refused as `extra:` here — and
   every record is `PENDING` with `next_action: "route_to_reviewer"`. The
   coverage refusal lists the `missing:`, `extra:`, and `duplicates:` ids.
   The early write BINDS the run: use the same `run_id` for it and for the
   later `write_pr_review_trigger_eval` — a receipt under a different run is
   refused against the bound one.
3. Micro lanes settle and `write_pr_review_trigger_eval` completes — every
   OTHER findings boundary is refused until this artifact exists (the
   refusal names the producing call). A `post_explorer` write after this
   point is validated against the FULL base+micro inventory.
4. `boundary: "post_reviewer"` checkpoint: requires the persisted
   `post_explorer` checkpoint (either variant), a settled reviewer phase, and
   exact coverage of the FULL base+micro candidate inventory.
5. `boundary: "post_critic"` checkpoint: requires the persisted
   `post_reviewer` checkpoint and a settled critic phase whenever any
   CONFIRMED CRITICAL/HIGH/MEDIUM verdict exists.

Writing a boundary after a later checkpoint already exists is also refused.
Every ordering refusal names the missing prerequisite boundary. The base-only
`post_explorer` checkpoint is the durable recovery point for context
compaction immediately after base settlement. From trigger-eval completion
onward the durable state is the trigger-eval receipt plus the retained lane
artifacts — the full candidate inventory stays re-derivable from them — so a
full-inventory `post_explorer` rewrite is OPTIONAL hardening rather than a
guaranteed artifact: `post_reviewer` accepts the early checkpoint as its
prerequisite and must itself carry the full (base+micro) inventory.
(Before issue #2280 there was no durable findings checkpoint between
explorer settlement and trigger-eval completion — the base-only write closes
that gap.)

## Disposition matrix

Records are validated against the authenticated reviewer/critic verdict rows,
never against caller claims.

| Reviewer verdict | expected `status` | expected `next_action` |
| --- | --- | --- |
| CONFIRMED CRITICAL/HIGH/MEDIUM | `CONFIRMED` | `route_to_critic` |
| CONFIRMED LOW/INFO | `CONFIRMED` | `report` |
| PRE_EXISTING | `PRE_EXISTING` | `report` |
| DISPROVED | `DISPROVED` | `suppress_with_reason` |
| UNVERIFIED | `PENDING` | `route_to_reviewer` |

At `post_critic`, records the reviewer did NOT route to the critic keep the
reviewer disposition above; critic-routed records follow the critic verdict:

| Critic verdict | expected `status` | expected `next_action` |
| --- | --- | --- |
| DISPROVED | `DISPROVED` | `suppress_with_reason` |
| UPHELD / DOWNGRADED (any non-DISPROVED) | `CONFIRMED` | `report` or `handoff_to_feedback` |
| no critic verdict for a critic-routed record | (defensive) | (defensive) |

The "no critic verdict" row is defensive: through the controller the critic
phase must already be settled over every critic-routed item before the
`post_critic` boundary is admitted, so a critic-routed record without a critic
verdict indicates an invariant break, not a caller mistake — the rejection
reports `no authoritative critic verdict (absent from the settled critic map)`
(and any reviewer-severity mismatch alongside it).

At `post_explorer` every record must be `PENDING` with
`next_action: "route_to_reviewer"`.

## Version-1 final finding policy

The terminal report vocabulary is deliberately closed to the three registered
machine values: `APPROVE`, `REQUEST_CHANGES`, and `INCOMPLETE`. There is no
internal `APPROVE_WITH_NOTES` verdict. The policy consumes the latest final
finding projection after critic settlement; it never trusts an earlier
candidate/reviewer severity or a caller-supplied handoff list.

| Final coverage / finding state | Final severity/action rule | Permitted report verdicts |
| --- | --- | --- |
| `NO_COVERAGE`, invalid provenance, or non-`COMPLETE` final status | No code-review claim is admissible | `INCOMPLETE` |
| `COMPLETE` with an active `UNRESOLVED`, `UNVERIFIED`, or `CONFIRMED` `CRITICAL`/`HIGH` finding | The finding remains reportable or handoff-actionable; `suppress_with_reason` does not hide an active finding | `REQUEST_CHANGES`, `INCOMPLETE` |
| `COMPLETE` with an active `MEDIUM` finding whose final action is not `report` | The conservative final action remains reviewer/critic/handoff work | `REQUEST_CHANGES`, `INCOMPLETE` |
| `COMPLETE` with only terminal `DISPROVED`, `PRE_EXISTING`, `NON_ACTIONABLE`, `NONE`, or reportable `LOW`/`INFO` records | Advisory records may be reported, but do not restrict the registered approval vocabulary | `APPROVE`, `REQUEST_CHANGES`, `INCOMPLETE` |
| `PARTIAL` or valid `DEGRADED_DISCLOSED` coverage without an active blocking finding | Coverage is truthful but not complete; no approval may claim a full review | `REQUEST_CHANGES`, `INCOMPLETE` |

The version-1 critic settlement projection is authoritative for the final
finding fields:

| Critic outcome | Terminal state | Final severity | Final action / handoff |
| --- | --- | --- | --- |
| `UPHELD` | terminal | reviewer severity, unchanged | reviewer action; handoff only when final action is `handoff_to_feedback` |
| `DOWNGRADED` | terminal | critic-provided lower severity | critic action; handoff only when final action is `handoff_to_feedback` |
| `DISPROVED` | terminal | `NONE` | `suppress_with_reason`; never handed off |
| `NEEDS_MORE_EVIDENCE` | nonterminal | retain current severity | retain current action; completion remains blocked |

The micro-family has no silent waiver. Base, reviewer, critic, and (when
enabled) council receipts must be present and valid. Micro provenance failures
block readiness. A retry/degradation may be terminal only when its provenance
is valid and the degradation is explicitly disclosed; that disclosure projects
to `DEGRADED_DISCLOSED`, which permits only `REQUEST_CHANGES` or `INCOMPLETE`.
Candidate confidence is categorical (`LOW`, `MEDIUM`, `HIGH`); independent
provenance identities may boost agreement, while conflicting severity or
confidence remains conservative. Final policy evidence is persisted under the
canonical `.swarm/pr-review/<run_id>/finding-policy.json` and paired with
identity-only core events.

## Severity semantics

`severity` is REQUIRED on every findings record, at every boundary. Omitting it
is a violation, not a shortcut — the rejection names the value you owed, e.g.
`severity expected "MEDIUM", got (omitted)` (issue #2279).

The vocabulary is the VERDICT dialect — `INFO | LOW | MEDIUM | HIGH | CRITICAL |
NONE` — because a findings record is a projection of an authenticated
`[REVIEWED]`/`[CRITIC]` row. `NONE` is a first-class value here: a `DISPROVED`
critic verdict is required to carry it, and a CONFIRMED-but-cosmetic reviewer
verdict legitimately does. (This is a WIDER set than the `[CANDIDATE]` row
severities, which exclude `NONE` — a discovered candidate asserting "no severity"
is a contradiction.)

Exactly one authority applies per record; there is never a value that must
satisfy two:

| Boundary | Routing | `severity` must equal |
| --- | --- | --- |
| `post_explorer` | has a `[CANDIDATE]` row | the severity that row declared (never `NONE`) |
| `post_explorer` | `CLEAN-REVIEW` with no row | `NONE` |
| `post_reviewer` | any | the reviewer `final_severity` |
| `post_critic` | not critic-routed | the reviewer `final_severity` |
| `post_critic` | critic-routed | the **critic** `final_severity` — the final word |

A record is critic-routed by the shared typed predicate (issue #2383): reviewer
classification `CONFIRMED` AND one of — severity `CRITICAL`/`HIGH`; severity
`MEDIUM` with `risk_impact: "HIGH_IMPACT"`; severity `MEDIUM` with any
`risk_tags` entry (`SECURITY`, `AUTH_PERMISSIONS`, `STATE_INTEGRITY`,
`WRITE_PATH`, `EVIDENCE_INTEGRITY`, `GIT`, `CONFIGURATION`); or
`risk_impact: "UNKNOWN"`. An `ORDINARY` MEDIUM with no tags is NOT
critic-routed; `LOW` follows the existing no-critic policy once its metadata
is known. Every CONFIRMED finding record must carry `risk_impact` and
`risk_tags`; unknown tag values are rejected, and no path- or dimension-based
inference ever substitutes for the typed values.

Because the critic is authoritative for critic-routed records, a **downgrade is
encodable verbatim**: reviewer `MEDIUM` + critic `LOW` persists as
`severity: "LOW"` and validates. The former rule — omit the field when the two
authorities disagree — is gone; it disabled the comparison against both
authorities and is now itself rejected.

At `post_explorer` the authority is the `[CANDIDATE]` row the record projects:
the severity must equal what that row declared, compared exactly (issue #2320).
Because candidate rows validate against the candidate vocabulary, `NONE` can
never match one.

The one exception is the mechanically derived `CLEAN-REVIEW` sentinel, emitted
as the whole inventory when discovery found nothing at all. It has no
`[CANDIDATE]` row, so its severity is `NONE` — the same value its mandated
reviewer row carries — and a zero-finding review never has to invent a severity
and then change it.

`CLEAN-REVIEW` is **not a reserved id**: `candidate_id` is free text, so a lane
may name a real finding that. The rule is therefore keyed on the authority, not
the name — whenever a `[CANDIDATE]` row exists for the id, that row wins and its
severity is compared exactly. The sentinel rule applies only when no row exists.

## Error reporting

An invalid records payload is rejected in ONE call: every violation across
every record is listed with the field, the expected value, and the actual
value, sorted by finding_id — for example:

```
BLOCKED: PR_REVIEW post_reviewer artifact invalid — 4 violation(s):
  C-0: status expected "DISPROVED", got "CONFIRMED"
  C-0: next_action expected "suppress_with_reason", got "report"
  C-1: next_action expected "route_to_critic", got "report"
  C-1: severity expected "HIGH", got "LOW"
```

A critic-downgraded record is compared against the critic alone, so carrying the
stale reviewer value is reported plainly: `severity expected "LOW", got "MEDIUM"`.
An omitted severity is reported the same way: `severity expected "LOW", got
(omitted)`. Repair every listed violation and resubmit in a single round trip; do
not guess-and-retry one record at a time.

## Handoff artifact schema

The `kind: "handoff"` write is a different schema from findings records — no
`boundary` and no `records` keys; it takes
`handoff: {pr_url, finding_ids, summary, provenance}`, and `finding_ids` must
exactly equal the set of latest records whose status is `CONFIRMED` and whose
`next_action` is `handoff_to_feedback`.

## Resume/reload detail

Before continuing any compacted or resumed review, read the latest
`findings.jsonl` artifact and reconstruct the candidate/reviewer/critic ledger
from disk before dispatching more lanes. If the artifact is missing but a
review context says prior lanes ran, stop and surface the missing artifact as
a coverage gap instead of reclassifying from memory. Append new records rather
than overwriting history unless the artifact format explicitly tracks
revisions; the latest record for a `finding_id` wins during reload.
There are two durable recovery points (issue #2280). The base-only
`post_explorer` checkpoint — written right after base settlement — is
sufficient to reconstruct the base candidate ledger and resume a compacted
session ahead of the micro wave: re-dispatch micro lanes, re-run trigger
evaluation, then continue. From trigger-eval completion onward the
full-inventory ledger is the recovery point: `post_reviewer` and
`post_critic` must cover the FULL (base+micro) inventory, and later boundary
writes upsert any base-only records the micro wave extended (latest record
wins).

All non-I/O rejections name the offending field, its received value, and the
legal value/domain. The first omitted `run_id` is atomically reserved and
returned; later omission is legal only when the active run is unambiguous.

## Profile A run identity and verdict-row codec

On the first trigger-evaluation or findings write, an omitted `run_id` is
atomically reserved at millisecond precision, returned to the caller, and
persisted in active workflow state; every later write must reuse it. Omission
is accepted only when exactly one active/reserved run exists, otherwise the
operation fails closed. `[REVIEWED]` and `[CRITIC]` free-text fields use the
controller codec: `\\` represents a literal backslash, `\|` a pipe, `\n` a
newline, and `\r` a carriage return. The byte-zero contract card injected into
each Profile A lane is authoritative for the live enums and includes positive
and explicitly discarded negative examples. Discarded examples are
documentation only and must never be emitted as live marker rows.
