# Risk heuristics — the six signals

Design for [PLAT-1191](https://redventures.atlassian.net/browse/PLAT-1191) (T7 — risk heuristics
evaluator). Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow
mode. Implemented in `bankrate/zapp`.

**This is Spec B of two.** Spec A
([`2026-08-25-policy-rules-and-eligibility-design.md`](./2026-08-25-policy-rules-and-eligibility-design.md))
builds the rules file, the eleven eligibility gates and the eval ledger. This spec fills the
`merge-policy/risk` check that Spec A leaves as a placeholder, and extends the same rules file and
the same eval record.

**Spec B's implementation must land after Spec A's.** It consumes Spec A's `classify()` output, its
`rules()` accessor, its `pr-files` fetcher and its eval-record shape.

Status: drafted 2026-08-25, awaiting review.

## Goal

Grade the risk of a pull request that has already passed the eligibility gates, from six
deterministic signals, recording every raw signal value alongside the grade. Replace
`renderRiskPlaceholder()` with a real rationale on `merge-policy/risk`.

The grade is never acted on. Shadow mode is unchanged: `postShadowCheck` stays the only path to the
check-runs API, and the conclusion stays structurally `neutral`.

## Starting state

Verified against live systems on 2026-08-25.

Spec A gives this spec four things it does not have to rebuild: `classify()` already returns every
dependency bump with its semver level, `rules()` already loads a validated SHA-stamped policy
document, `fetchPrFiles()` already retrieves the diff, and `recordEvaluation()` already writes an
eval record keyed on repo, PR and head SHA.

### Two prerequisites that are not in the code

**1. The App lacks `vulnerability_alerts: read`.** `neutral-planet` currently holds `checks: write`
plus `contents`, `issues`, `merge_queues`, `metadata`, `pull_requests` and `statuses` at read. Signal
3 needs `vulnerability_alerts: read` added. It is read-only, so the Phase 0 invariant — the service
cannot approve, merge or enable auto-merge — is unaffected. Adding a permission to an org App puts
the installation into **pending approval** until an org owner accepts; deliveries continue meanwhile
and the new endpoint returns 403.

**2. Dependabot alerts are disabled on the validation repo.** `GET
/repos/bankrate/platform-cicd-v2-demo/dependabot/alerts` returns 403 *"Dependabot alerts are disabled
for this repository."* That is a repository setting, not a permission — granting the App scope will
not fix it. Until someone enables Dependabot alerts on the demo repo, **signal 3 is `unknown`
there**, and the risk grade is computed from five signals rather than six.

Both 403 causes are distinguished in the log (`advisories_forbidden` with a `reason` of
`permission` or `disabled`) so the difference is diagnosable rather than a mystery.

This is a deliberate consequence of T7's own degradation rule, not a defect. It is called out here
because a reviewer seeing "graded on 4 of 6 signals" on the first live run should know why.

### The three fixture pull requests

Carried forward from Spec A, now with what each exercises for risk:

| PR | Bumps | Risk-relevant shape |
|---|---|---|
| #27 | 7, max minor | Includes a real security release: `@fastify/jwt` 10.2.2 fixes `GHSA-j4cx-787j-xjqg`. CI complete, Codecov and Cycode both green. |
| #32 | 11, max major | All development dependencies. Includes `typescript` ^6.0.3 → ^7.0.2. |
| #37 | 0 | Not a candidate at all — the risk evaluator does not run. |

PR #37 matters as a negative case: **risk is evaluated only for pull requests the gates admit.** T7
says the heuristics run on gate-passing candidates, so a non-candidate gets a risk check that says
so rather than a grade computed on nothing.

## The six signals

Each returns a value and a grade of `low` / `medium` / `high` / `unknown`. `unknown` means the data
was not available — never a guessed value, never a silent zero.

### 1 · Semver distance

From Spec A's `classify()`. No new call, no new failure mode: `maxDelta` is already the max across
every bump, read from the manifest diff rather than any title or summary table.

`none` or `patch` → low. `minor` → medium. `major` → high.

### 2 · Publish age

How long the new version has been public. A version published hours ago is the supply-chain attack
window; one published weeks ago has been under the world's scrutiny.

**Source: `api.deps.dev`, not `registry.npmjs.org`.** This is the one place this spec reaches outside
GitHub and AWS, and it deserves its reasoning written down:

npm exposes publish timestamps **only** in the full packument — `GET /{pkg}`. The per-version
endpoint `GET /{pkg}/{version}` carries no time field at all (verified: its key set contains no
`time`, `created` or `published`). And the full packument for a popular package is enormous —
`fastify`'s is **1,780,110 bytes**. A grouped bump of eleven packages would pull roughly 15–20 MB
per evaluation into a 256 MB Lambda, to read eleven timestamps.

`api.deps.dev` (Google-operated, public, unauthenticated) returns the same timestamp in **834
bytes** — `2026-08-13T15:59:58Z` against npm's `2026-08-13T15:59:58.502Z` for `fastify@5.12.0` —
and handles scoped names via URL encoding. That is a ~2000× reduction for identical data.

The cost is a dependency on a third party neither Bankrate nor GitHub operates. It is acceptable
here **because the failure mode was already designed**: if deps.dev is slow, down, or changes shape,
the signal records `unknown`, which T7 explicitly specifies. No evaluation fails, no check run is
lost. If that trade is unacceptable, the documented fallback is the npm packument with a strict
response-size cap — same signal, much heavier.

One lookup per bumped package, in parallel, capped at 8 concurrent with a 3-second per-request
timeout. The signal takes the **youngest** age across all bumps: a single fresh package among ten
mature ones is the actual exposure, which is why this is per-package rather than only the governing
bump.

Below `risk.cooldownDays` → medium. At or above → low. All lookups failed → unknown; some failed →
graded on those that succeeded, with the failures recorded by name.

### 3 · Closes a known finding

Does this bump resolve an open Dependabot alert? A security remediation is *less* risky to merge
than an equivalent routine bump, and this is the signal that says so.

`GET /repos/{owner}/{repo}/dependabot/alerts?state=open`, matched on package name and on the bump's
new version being at or above the alert's `first_patched_version`.

Subject to both prerequisites above. On 403, `unknown` with the cause logged.

**This signal only ever lowers the grade.** See "Grading" below.

### 4 · New scanner findings

Cycode's verdict on the head SHA, from the same check-runs call as signal 5:
`GET /repos/{owner}/{repo}/commits/{headSha}/check-runs`.

Three checks are expected — `Cycode: SAST`, `Cycode: Secrets`, `Cycode: Vulnerable Dependencies` —
and the signal is how many are `failure`.

A precise finding *count* would need the Cycode API, for which there are no credentials available to
this service. "Which scanners are red on this commit" is the honest available signal and satisfies
T7's requirement that new findings be zero.

**Absence is `unknown`, never zero.** If an expected Cycode check has no run for this SHA, or has one
that is not `completed`, the signal is `unknown`. This is the same fail-closed rule the epic
specifies for the required-checks snapshot, applied early: a scanner that has not reported yet must
never read as a clean scan.

Zero failures → low. More than `risk.maxNewFindings` → high.

### 5 · Coverage versus base

Parsed from the `codecov/project` check run's output title, which on this repo reads
`62.99% (+0.00%) compared to 62d5a6a` — the percentage and the signed delta are both there.

Absent or unparseable → unknown. A drop within `risk.maxCoverageDropPct` → low; a larger drop →
medium.

Dependency bumps rarely move coverage, so this signal is usually a quiet `low`. It earns its place
by catching the case where a bump silently drops instrumented code.

### 6 · Development versus production dependency

A devDependency bump cannot reach production; a runtime dependency can.

**Read from the head `package.json`, not from the patch.** Patch hunks do not reliably contain the
section header: PR #27's first hunk starts at line 43 and does include `"dependencies": {`, but PR
#32's single hunk starts at line 65 and never shows `"devDependencies": {` even though every changed
line is one. Parsing section context out of the patch therefore works on some PRs and silently
guesses on others, which is worse than not having the signal.

`GET /repos/{owner}/{repo}/contents/package.json?ref={headSha}`, one call, parsed once into a
name → section map that every bump is looked up in.

All bumps in `devDependencies` → low. Any in `dependencies` → medium. Manifest unreadable →
unknown.

### Timing: signals 4 and 5 are usually unknown on `opened`

Both read CI results for the head SHA. zapp evaluates on `opened`, which fires **before** CI has run,
so on a freshly opened pull request both will normally be `unknown`. A later `synchronize` re-runs
the evaluation and picks up real values.

The consequence, stated plainly: **a pull request opened and merged without a second push never gets
signals 4 or 5.** That is a known hole in the shadow dataset. Closing it is PLAT-1192's reconcile
sweep, which re-evaluates open enrolled pull requests on a schedule; it is out of scope here.

## Grading

`policy-rules.yaml` gains a `risk` section holding **only thresholds** — which is what PLAT-1189
already specifies belongs there. The signal-to-grade mapping stays in code, where it is tested;
the file holds the numbers a human would tune.

```yaml
risk:
  cooldownDays: 3
  maxNewFindings: 0
  maxCoverageDropPct: 0
```

The validator from Spec A's `scripts/build-rules.mjs` is extended to cover this section, so a bad
threshold still fails the deploy rather than the Lambda, and `rulesSha` continues to stamp every
evaluation.

**Worst known signal wins.** Four signals participate in the comparison — semver distance, publish
age, new findings, coverage delta — plus `depType`. `closesFinding` never does; see below. Signals
grading `unknown` are excluded from the comparison but counted, and the count is reported.

Worked against PR #27: semver distance `medium` (minor) and `depType` `medium` (6 of 7 packages are
production) are the worst of the five known signals, so the grade is **medium** — not `low`, even
though three signals grade `low`. Worst-of means worst-of. A grade computed from one `low` and four `unknown`s must not render as
confident green — so every rendering states *"graded on N of 6 signals"*.

**`closesFinding` is asymmetric on purpose.** It is not part of the worst-of comparison. When true,
it lowers the final grade by one step (`high` → `medium`, `medium` → `low`, `low` → `low`) and can
never raise it. This is what the epic means by security-remediation bumps grading lower risk: a
patch that closes a known vulnerability is safer to take than the same patch arriving routinely, and
the grade should say so — but a bump that closes nothing is not thereby riskier.

## Runtime budget — the constraint that forces an infrastructure change

The Lambda's `timeout` is **10 seconds** and the delivery queue's `visibility_timeout_seconds` is
**60** (6×, per AWS guidance). A PR #32-shaped evaluation now needs: the files call, the manifest
call, the alerts call, the check-runs call, **eleven parallel deps.dev lookups**, two check-run
posts, and a DynamoDB write. Ten seconds does not cover it.

PLAT-1233 put the worker behind SQS precisely so it would stop being bound by GitHub's ten-second
webhook expectation — that constraint belongs to the receiver, which still answers in milliseconds
and is untouched here.

So: **function timeout 10 → 30 seconds, queue visibility timeout 60 → 180 seconds.** The 6× ratio is
preserved; a message must not become visible again while a worker still holds it.

Concurrency for the registry lookups is capped at 8 with a 3-second per-request `AbortSignal`
timeout. A slow registry degrades the signal to `unknown`; it never delays the check run past the
function timeout.

## The eval record

Spec A's record gains a `risk` object alongside `eligibility`, completing the epic's schema:

```json
{
  "grade": "medium",
  "signalsGraded": 5,
  "signals": {
    "semverDistance": { "grade": "medium", "value": "minor" },
    "publishAge":     { "grade": "low",    "value": { "youngestDays": 11, "package": "@fastify/jwt" } },
    "closesFinding":  { "grade": "unknown", "value": null, "reason": "alerts-disabled" },
    "newFindings":    { "grade": "low",    "value": { "failed": 0, "checked": 3 } },
    "coverageDelta":  { "grade": "low",    "value": { "deltaPct": 0.0, "currentPct": 62.99 } },
    "depType":        { "grade": "medium", "value": { "production": 6, "development": 1 } }
  }
}
```

Every raw value persists, not just the grade — Phase 1 threshold tuning is a query over these, and a
grade alone cannot answer "what would `cooldownDays: 7` have changed?".

Written by the existing `recordEvaluation`, which keeps its best-effort behaviour: a ledger failure
is logged and does not lose the check run.

## What the check says

For PR #27, once CI has completed:

> **Risk: medium** — graded on 5 of 6 signals
>
> Largest version jump is a **minor** (`fastify` 5.11.2 → 5.12.0), and 6 of the 7 updated packages
> are production dependencies — either alone grades medium. The youngest package in this update was
> published 11 days ago, above the 3-day cooldown. No scanner findings on this commit (3 checks).
> Coverage unchanged at 62.99%.
>
> Not available: whether this closes a known security advisory — Dependabot alerts are not enabled
> on this repository.
>
> This check is informational. It is **not required** and **will never block your pull request**.

For a non-candidate such as PR #37:

> **Risk not evaluated**
>
> This pull request is not a candidate for automated merge, so no risk grade was computed. See the
> `merge-policy/eligibility` check for why.

## Files

| File | Responsibility |
|---|---|
| `src/signals/publish-age.ts` | deps.dev lookups, concurrency cap, youngest-age reduction |
| `src/signals/advisories.ts` | Dependabot alerts, package/version matching, 403 cause detection |
| `src/signals/scan-findings.ts` | Cycode check-run verdicts |
| `src/signals/coverage.ts` | `codecov/project` title parsing |
| `src/signals/dep-type.ts` | Head manifest fetch, name → section map |
| `src/check-runs.ts` | One head-SHA check-runs fetch, shared by scan-findings and coverage |
| `src/risk.ts` | Grade each signal, combine worst-of, apply the `closesFinding` modifier |
| `src/render.ts` | `renderRisk()` replaces `renderRiskPlaceholder()` |
| `src/evaluate.ts` | Orchestrate: run risk only for candidates, extend the eval record |
| `policy-rules.yaml` | New `risk` threshold section |
| `scripts/build-rules.mjs` | Validate that section |

One module per signal, because each fails independently and degrades to `unknown` on its own terms.
A single `signals.ts` would be six tangled try/catch blocks in one function, and the whole point of
this spec is that a partial failure is a first-class outcome rather than an error path.

## Error handling

| Condition | Behaviour |
|---|---|
| Not a candidate | Risk is not evaluated; the check says so |
| deps.dev slow, down, or reshaped | That package's age is `unknown`; others still count |
| All publish-age lookups fail | Signal `unknown`; grade computed from the rest |
| Dependabot alerts 403 | Signal `unknown`; `permission` vs `disabled` distinguished in the log |
| Expected Cycode check missing or incomplete | Signal `unknown` — **never** read as a clean scan |
| `codecov/project` absent or title unparseable | Signal `unknown` |
| Head `package.json` unreadable | `depType` `unknown` |
| Every signal unknown | Grade `unknown`; the check says so plainly |
| Ledger write fails | Logged, check still posts (unchanged from Spec A) |

No signal failure fails the delivery. The check run is the user-visible product; a degraded grade is
worth more than a lost check. This inverts the worker's usual "throw and let SQS retry" posture, and
does so knowingly — retrying will not make a disabled alerts API start answering.

Logging follows `src/log.ts`: package names, versions, grades and counts are safe. PR title and body
are not, and are not read by any signal in this spec.

## Testing

- **Per signal**: a present case, a missing case, and a malformed case. `unknown` is a first-class
  outcome here, so its paths get the same coverage as the happy ones.
- **Captured fixtures**, alongside Spec A's: deps.dev responses for the packages in PRs #27 and #32,
  the head-SHA check-runs response for both, a representative `dependabot/alerts` response, and both
  403 bodies (`permission` and `disabled`) so the branch that tells them apart is tested.
- **Grading matrix**: worst-of across every combination of the five comparable signals; `unknown`
  excluded from the comparison but counted; `closesFinding` lowering each grade by exactly one step
  and never raising any.
- **Concurrency**: eleven lookups run with no more than 8 in flight; a hung request is abandoned at
  its timeout and recorded `unknown` without delaying the others past the budget.
- **Non-candidate**: PR #37's fixture produces the "not evaluated" rendering and no signal fetches
  at all, asserted by the fetchers never being called.
- **Rendering**: every output states the signal coverage, states it never blocks, and names any
  unavailable signal with its reason.

### Live validation

Push a second commit to PRs #27 and #32 so CI completes and a `synchronize` re-evaluation runs with
signals 4 and 5 populated. Success is a real grade on both, the eval records carrying all six signal
values, and the check text naming the unavailable signals and why.

## Out of scope

- **PLAT-1192 (T8)**, the required-checks snapshot and the 10-minute reconcile sweep — the sweep is
  what would eventually populate signals 4 and 5 on pull requests that never get a second push.
- **Routing `check_run` / `check_suite` / `status` / `push`** — still dropped by the worker.
- **A precise Cycode finding count** — needs Cycode API credentials this service does not have.
- **Enabling Dependabot alerts** on the demo repo — a repository setting, and someone's decision to
  make, not this spec's.
- **Acting on the grade.** Shadow mode is unchanged. Nothing is approved, merged, or blocked.
- **Prod rollout** — QA only, as with Spec A.

## Definition of done

- [ ] `vulnerability_alerts: read` added to the `neutral-planet` App and the installation approved
- [ ] `policy-rules.yaml` carries a validated `risk` threshold section; a bad value fails the build
- [ ] All six signals implemented, each with present, missing and malformed tests
- [ ] Every signal degrades to `unknown` rather than a guessed value
- [ ] A missing or incomplete Cycode check reads `unknown`, never a clean scan — tested
- [ ] Publish age uses one lookup per bumped package, capped at 8 concurrent, 3-second timeouts
- [ ] Grade is the worst known signal; `unknown` excluded from the comparison but counted
- [ ] `closesFinding` lowers the grade by one step and can never raise it — tested
- [ ] Every rendering states how many of the six signals it was graded on
- [ ] Risk is not evaluated for non-candidates; the check says so
- [ ] Function timeout raised to 30s and queue visibility timeout to 180s
- [ ] Eval records carry `risk.grade` plus all six raw signal values
- [ ] PRs #27 and #32 produce real grades after a `synchronize` re-evaluation
- [ ] Both checks remain `neutral` and on no required-checks configuration
