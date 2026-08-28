# Eligibility finality and blocking-check alignment — design

- **Date:** 2026-08-28
- **Epic:** [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184) — Merge-policy service, Phase 0 shadow mode
- **Repo:** `bankrate/zapp`
- **Status:** design approved, plan to follow

## What's wrong

Two defects, found by reading a live evaluation
([bankrate/portkey#110](https://github.com/bankrate/portkey/pull/110)) rather
than by reading code. They present as one symptom — an eligibility check that
reports checks as not-green when they are green — and they are independent.

**Both corrupt the dataset the shadow phase exists to produce**, and the second
one closes the eligibility funnel entirely.

| Defect | Kind | Measured impact |
|---|---|---|
| 1. Premature `final`, freezing stale CI evidence | Code bug in `src/evaluate.ts:295` | **16 of 97** eval records wrongly `final`; `coverageFloor` fail-counts inflated 52%, `checksGreen` 32% |
| 2. Global `blockingChecks` declares checks most repos never produce | Configuration mismatch | `checksGreen` **cannot pass on 7 of 8** enrolled repos |

## Defect 1: an evaluation marked final before CI reported

### Evidence

`bankrate/platform-cicd-v2-demo#32`, head `e6d599df`. The eligibility check
permanently reports:

```
❌ checksGreen     Cycode: SAST, Cycode: Secrets, Cycode: Vulnerable
                   Dependencies, Build and scan image, Terraform plan (speculative)
❌ coverageFloor   codecov/project has not reported a coverage percentage
```

Every one of those checks is `success` on that commit today — including
`Terraform plan (speculative)`. The GitHub timeline for `portkey#110` shows the
mechanism plainly:

| Time | Event |
|---|---|
| 18:28:31Z | PR opened |
| **18:28:35Z** | `merge-policy/*` evaluated — four seconds later, zero CI reported |
| 18:28:36Z | `Cycode: Secrets` ✅ (one second too late) |
| 18:32:32Z | `Build and scan image` ✅ |

The `neutral-planet` check suite's `updated_at` is still `18:28:35Z`. It never
re-evaluated.

### Cause

`src/evaluate.ts:290-296`:

```ts
// A non-candidate waited on no risk SIGNAL, so it is final for every gate
// whose verdict cannot change on this head SHA. CI_DEPENDENT_GATES are the
// exception: their failure can resolve with no new commit ...
const nonCandidateFinal = eligibility.failedGate === null
  || !CI_DEPENDENT_GATES.has(eligibility.failedGate);
```

`failedGate` is only the **first** failure in `GATE_ORDER`. On both affected
PRs that is `classificationPermits` (gate 9), which is not CI-dependent — so
`nonCandidateFinal` is `true` even though gates 11 and 12 were failing purely
because CI had not spoken. `src/worker.ts`'s `handleCheckSuite` then closes the
door:

```ts
const existing = await deps.findOurCheckRun(repoFullName, headSha, RISK_CHECK);
if (existing?.externalId === 'final') return;
```

**The comment above the defect already states the correct rule** — "final for
every gate whose verdict cannot change on this head SHA." Intent and
implementation diverged; the code reads one gate where the rule covers all of
them.

### Blast radius, measured

Scan of `zapp-evaluations` (97 eval records):

```
final=true : 60      final=false: 35      absent: 2

AFFECTED (final=true AND checksGreen/coverageFloor still fail|unknown): 16
  distinct PRs: 3           distinct head SHAs: 6
  first failure: classificationPermits in all 16
  share of final=true non-candidates: 16 of 51  (31%)

  platform-cicd-v2-demo#32  x12
  portkey#108               x3
  portkey#110               x1

checksGreen   = fail: 50 records, 16 of them wrongly final  (32% inflated)
coverageFloor = fail: 31 records, 16 of them wrongly final  (52% inflated)

failedGate = checksGreen: 34 records — ALL correctly final=false
candidates affected: 0
```

Three things this measurement settles:

- **The report's `checksGreen: 34` headline is NOT inflated by this defect.**
  Every one of those 34 records has `checksGreen` as its *first* failure, so
  `nonCandidateFinal` correctly returned `false` and they stayed provisional. An
  earlier reading of this claimed otherwise; the data contradicts it.
- **What is inflated is the per-gate verdict count.** Any analysis asking "how
  often did `checksGreen` fail" across all records — rather than "how often was
  it the first failure" — is overstated by 16.
- **The candidate path is unaffected.** Candidates use
  `assessed.completeness.final`, a different expression. Zero affected.

### Why the wrong flag matters more than the wrong display

`final` is written to the eval record, and `docs/policy.md` tells the reader to
filter Phase 1 analysis on it — the field exists precisely to exclude
evaluations made on incomplete inputs. A record that is wrongly `final` sails
straight through that filter. **The safeguard fails silently on exactly the
records it exists to catch.**

### Fix

```ts
/**
 * Gates whose failure resolves when CI reports — which is what fires
 * `check_suite: completed` and therefore what a re-evaluation would see.
 *
 * A SUBSET of CI_DEPENDENT_GATES, not the same set. `freezeOff` and
 * `notBlocked` also clear without a new commit, but lifting a freeze or
 * removing a label emits no check-suite event, so gating finality on them
 * would strand the record as provisional forever.
 */
const CI_REPORTING_GATES: ReadonlySet<GateName> = new Set(['checksGreen', 'coverageFloor']);

const nonCandidateFinal = ![...CI_REPORTING_GATES].some((gate) => {
  const verdict = eligibility.gates[gate].verdict;
  return verdict === 'fail' || verdict === 'unknown';
});
```

**`skipped` is deliberately excluded, and that exclusion is load-bearing.**
`portkey#102` fails `changeClass` (a workflow-file-only diff), so its CI gates
read `skipped` — not evaluated, and unable to resolve via CI because there is no
recognised change class to evaluate against. Counting `skipped` as unresolved
would leave every unclassified pull request provisional forever, re-evaluating
on every check suite for no benefit. That record is correctly `final` today and
must stay that way.

This is the same subset Plan J introduces for the weekly report's wording, so it
becomes one shared exported constant rather than two definitions that can drift.

## Defect 2: `checksGreen` cannot pass on most enrolled repos

### Evidence

Sampling the most recent pull request on each enrolled repository and listing
which of the five globally-declared `blockingChecks` actually appear:

| Check | Repos producing it |
|---|---|
| `Cycode: SAST` | 8 of 8 |
| `Cycode: Secrets` | 8 of 8 |
| `Cycode: Vulnerable Dependencies` | 8 of 8 |
| `Build and scan image` | **3 of 8** — `platform-cicd-v2-demo`, `conductor-api`, `portkey` |
| `Terraform plan (speculative)` | **1 of 8** — `platform-cicd-v2-demo` |

Gate 11 fails closed on an absent check, correctly: absence is never green, and
"this repo does not run it" is genuinely indistinguishable from "it has not run
yet" without a per-repo declaration. So `checksGreen` is **unpassable on 7 of
the 8 enrolled repositories**, permanently, no matter what a pull request
contains.

Six of eight have an `infrastructure/terraform/` directory, so this is not "they
have no Terraform" — it is that CI/CD v2 has not standardised the job name.
`policy-rules.yaml` predicts this in its own comment:

> TFC speculative plan via Actions. CI/CD v2 has not standardised this name
> across repos, which is why it is declared and overridable per repo.

The override mechanism exists and works. **No repo uses it.**

### Why this is the bigger defect

`checksGreen` is the first failure on 34 of 97 records — the largest single
category. With the gate unpassable on 7 of 8 repos, the shadow phase is
currently measuring *which repositories have a job with a particular name*
rather than *which pull requests are safe to automate*. Every downstream number
inherits that: candidate rate, gate-failure breakdown, and the risk corpus,
since risk is only graded for candidates.

Fixing Defect 1 alone makes this worse in a specific way: re-evaluation would
start working, run correctly, and still report `checksGreen: fail` on 7 of 8
repos. The staleness would be gone and the verdict would still look wrong.

### Fix

Invert the arrangement. **The global list holds only checks that essentially
every enrolled repository produces; per-repo overrides add the rest.**

```yaml
  # Global list: the three Cycode contexts, which all eight enrolled repos
  # produce. A check that most repos do not run does not belong here — gate 11
  # fails closed on absence, so declaring it globally makes the gate unpassable
  # everywhere it is missing.
  blockingChecks:
    - "Cycode: SAST"
    - "Cycode: Secrets"
    - "Cycode: Vulnerable Dependencies"
```

with per-repo overrides for the repositories that genuinely run more:

```yaml
  - repo: bankrate/platform-cicd-v2-demo
    blockingChecks:
      - "Cycode: SAST"
      - "Cycode: Secrets"
      - "Cycode: Vulnerable Dependencies"
      - "Build and scan image"
      - "Terraform plan (speculative)"
```

**A per-repo list REPLACES the global one — it never merges.** So every override
must restate the Cycode contexts. That is verbose and it is the existing
documented semantic, for a good reason: merging would make it impossible to
*remove* a check a repository does not run, which is the main reason to override
at all. Not changing it here.

This is a **policy loosening**, and it should be named as such rather than filed
as a bug fix. Before: seven repositories could never produce a candidate. After:
they can. In shadow mode nothing merges either way, so the risk of loosening is
confined to the dataset — but the dataset is the deliverable, so a candidate
count that jumps is the expected and desired outcome, not a regression to
investigate.

### What this does not do

It does not discover check names. `docs/architecture.md` rejects discovery
explicitly — "declared rather than discovered, because both ways of inferring it
are wrong" — and that reasoning still holds. Repositories that later add an
image scan or a speculative plan need an override added deliberately, and the
weekly report's coverage numbers are what should surface the omission.

## Repairing the 16 records

The eval ledger is **append-only**: `sk = eval#<ISO timestamp>`, so
re-evaluating a pull request adds a record rather than overwriting one. The 16
wrong records therefore persist in the corpus unless something is done about
them.

**Decision: correct the `final` flag in place, and mark that it was corrected.
Never delete evidence.**

```
final              true -> false
finalCorrectedAt   2026-08-28T...Z
finalCorrectionReason  "PLAT-1184: nonCandidateFinal read only the first failing
                        gate; checksGreen/coverageFloor were unresolved at
                        evaluation time"
```

Three reasons this is the right shape:

- **It is derivable from the record itself.** The gate map already stores
  `checksGreen: fail` and `coverageFloor: fail`; the flag simply contradicts the
  evidence beside it. Correcting it is reconciliation, not revision — and it
  makes the repair idempotent and independently verifiable.
- **The two marker fields keep it honest.** A reader can tell a repaired flag
  from an originally-computed one. A silent flip would leave the corpus
  indistinguishable from one that never had the bug, which is worse than the bug.
- **Deleting or rewriting the gate verdicts would destroy evidence.** The stale
  verdicts are a true record of what the service observed at 18:28:35Z. They
  should stay; `final: false` is what tells analysis to exclude them.

**Re-evaluation is forward-only.** No forced webhook redelivery for the three
affected pull requests. Redelivery inside the 7-day confirmation TTL would be
rejected as a duplicate by `src/deliveries.ts` anyway, and after the two fixes
land, the next ordinary `pull_request` or `check_suite` event on those PRs
produces a correct record. The corrected flag is what makes the existing corpus
analysable; a fresh record is a bonus, not a requirement.

`scripts/backfill-outcomes.mjs` is the precedent for a one-off keyed data
repair, and the new script should follow its shape — dry-run by default,
explicit `--apply`.

## Out of scope

**Enrollment is not retroactive, and that is a bigger coverage hole than either
defect here.** Of 11 open dependabot pull requests across the enrolled
repositories, **6 have no evaluation at all** — `conductor#447`, `#448`,
`conductor-api#636`, `#643`, `#644`, `portkey#101`. All predate the 2026-08-28
12:50Z fleet-enrollment deploy and have not been touched since. Evaluation fires
only on `pull_request` opened/synchronize/reopened/edited or
`check_suite: completed`, and a dormant dependabot pull request emits none of
those.

Nothing is behaving incorrectly, so it is not a defect — it is a missing sweep,
and it belongs with the enrollment-registry work (PLAT-1188), where "enrol a
repository" is the action that should trigger it. Folding it in here would
couple a two-line fix to a feature.

Also out of scope: teaching `RECORDED_FIELDS` in `src/report/query.ts` about
the corrected-flag markers, and any change to `CI_DEPENDENT_GATES` itself —
that set is correct for what it is used for (the "can clear without a new
commit" question); this work adds a narrower sibling rather than editing it.

## Testing

The three tests that carry the design:

- **A non-candidate whose first failure is not CI-dependent, but which also
  fails `checksGreen`, is `provisional`.** This is the defect, stated directly.
  Build the fixture from `platform-cicd-v2-demo#32`'s real shape:
  `classificationPermits` fail, `checksGreen` fail, expect
  `externalId: 'provisional'`.
- **A non-candidate whose CI gates are `skipped` stays `final`.** The
  `portkey#102` case. Without this test the obvious "treat anything not-pass as
  unresolved" implementation ships and every unclassified pull request
  re-evaluates forever.
- **`checksGreen` passes on a repo whose override omits the checks it does not
  run.** The Defect 2 fix, asserted as behaviour rather than as configuration:
  given a repo override of the three Cycode contexts and three green Cycode
  runs, gate 11 passes even with no image scan and no speculative plan present.

Plus a `scripts/build-rules.mjs` validation test that a per-repo
`blockingChecks` override is accepted and replaces rather than extends — the
semantic the whole Defect 2 fix depends on, currently exercised only indirectly.

## Sequencing — this collides with the enrollment work

Both fixes touch files that PLAT-1188's zapp plan also modifies:

| This work | Collides with |
|---|---|
| `src/evaluate.ts` — `nonCandidateFinal` | Plan K **Task 5** (the `evaluate` signature change) |
| `policy-rules.yaml` — `repos[].blockingChecks` | Plan K **Task 6** (deletes the `repos:` section entirely) |

**Recommendation: land this before Plan K reaches Task 5.** It is small, it is
independently valuable, and enrolling more repositories on top of an unpassable
`checksGreen` would scale a broken measurement. Plan K's Tasks 5 and 6 then
rebase onto it, which is a smaller adjustment than the reverse.

If Plan K has already passed Task 6 when this starts, the per-repo overrides
move from `policy-rules.yaml` into the `zapp-enrollments` table's
`blockingChecks` attribute — same values, different store, and the seed script
in Plan K Task 3 must carry them.

## Risks

| Risk | Handling |
|---|---|
| Loosening `blockingChecks` lets through candidates that should not be | Shadow mode: conclusions are structurally `neutral` and nothing merges. A jump in candidate count is the intended outcome, and the weekly report is where it should be read. |
| The finality fix causes repeated re-evaluation churn | Bounded by check suites completing on one head SHA — four per commit on these repos. `upsertShadowCheck` is idempotent, and the `skipped` exclusion prevents the unbounded case. |
| The repair script corrupts records | Dry-run by default, keyed writes only, idempotent, and the correction is derivable from each record's own gate map so it can be re-verified after the fact. |
| Candidate volume rises and the risk signals get exercised for the first time at scale | That is the point of Phase 0, and it is why this should land before enrollment expands rather than after. |
