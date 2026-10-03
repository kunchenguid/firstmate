# CI baseline gate — design

- **Date:** 2026-08-28
- **Tickets:** [PLAT-1190](https://redventures.atlassian.net/browse/PLAT-1190) (gates) primarily; [PLAT-1188](https://redventures.atlassian.net/browse/PLAT-1188) for the enrollment-record fields
- **Epic:** [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184) — Merge-policy service, Phase 0 shadow mode
- **Repo:** `bankrate/zapp` (plus three enrollment-record fields Conductor writes)
- **Status:** design approved, plan to follow

## The problem

`checksGreen` cannot pass on 7 of 8 enrolled repositories, and the reason is not
that their pull requests are unsafe. The global `blockingChecks` list declares
check names most repositories never produce, and gate 11 fails closed on an
absent check — correctly, since "this repo does not run it" is
indistinguishable from "it has not run yet" from a single pull request's
check runs.

The same defect exists in `signalChecks`, which controls *risk finality*:
`codecov/project` is absent on **6 of 8** repositories, so those evaluations
would stay provisional forever and `final` would never become true.

Measured 2026-08-28 across the eight enrolled repositories:

| Check | Repos producing it |
|---|---|
| `Cycode: SAST` / `Secrets` / `Vulnerable Dependencies` | 8 of 8 |
| `Build and scan image` | 3 of 8 |
| `codecov/project` | **2 of 8** |
| `Terraform plan (speculative)` | **1 of 8** |

The consequence is that the shadow phase currently measures *which
repositories have a job with a particular name* rather than *which pull
requests are safe to automate*, and every downstream number inherits it.

## What this design rejects, and why

Two obvious fixes are both wrong, and saying why is most of the argument.

**Discovering the required set from each repo's CI.** Observe what a repo runs,
then require exactly that. This is self-attestation: the bar becomes whatever
each team already does, and a repo with no image scan is graded as if scanning
were never expected. It is the same flaw that makes the `resiliency_tier`
custom property untrustworthy — the party being gated controls the gate. It
also silently deletes the most valuable finding available: that most of the
fleet does not meet the CI bar automation would need.

**A flat global required set.** Keep one list and let non-compliant repos be
ineligible. Closer to right, but wrong in a way the data makes obvious:
`conductor` has no Dockerfile and no Terraform. It is a CLI npm package.
Requiring an image scan of it is not a standard, it is a category error, and it
would mark the repo permanently ineligible for a check it should never run.

## The design: required checks derive from repo shape

**Shape, not CI.** What a repository *is* determines what it must prove; what
its CI happens to do determines whether it currently proves it.

| Condition | Required checks |
|---|---|
| Always | `Cycode: SAST`, `Cycode: Secrets`, `Cycode: Vulnerable Dependencies`, `codecov/project` |
| Repository builds a container image | `Build and scan image` |
| Repository contains Terraform | `Terraform plan (speculative)` |

Coverage is universal rather than shape-conditional, deliberately: every
`changeClass` sets `minCoveragePct: 60`, so automating a dependency bump with no
coverage signal at all is precisely what a floor exists to prevent. A repository
that reports no coverage is not exempt from the coverage requirement; it fails
it, and that failure is a finding.

Shape is read from **GitHub's languages API** — `GET /repos/{owner}/{repo}/languages`
— whose keys include `Dockerfile` and `HCL`. One call, and it is strictly better
than probing file paths: `crank` returns 404 for `contents/Dockerfile` but
reports `Dockerfile` in languages, because its Dockerfile is not at the root. A
path probe would have wrongly exempted it from image scanning.

Not GitHub custom properties. Those are editable by repo actors in this org, so
shape would become self-attested — the exact flaw this design exists to avoid.

**Caveat, stated because it will eventually bite:** the languages API is
computed by Linguist over byte counts, and `.gitattributes` can mark paths
`linguist-vendored`, excluding them. A repository could in principle hide a
Dockerfile from it. The `checkAliases` and waiver mechanisms below cover the
practical cases; a deliberate Linguist override to dodge a scan requirement is a
review problem, not a design problem.

## A new gate: `ciBaselineMet`

"This repository does not run the check" and "the check failed" need different
words because they need different remedies — *add a workflow* versus *fix a
test*. Today both produce `checksGreen: fail` with a name list, and `failedGate`
is what the weekly report groups on, so the split has to happen there or it does
not happen at all.

`GATE_ORDER` gains one entry, ordered **before** `checksGreen`:

```
 ... 10 tierFloor
     11 ciBaselineMet     <- NEW
     12 checksGreen
     13 coverageFloor
 ...
```

Seventeen gates become eighteen. That number appears in `src/gates.ts`'s header,
`docs/policy.md`, `docs/architecture.md`, `README.md` and the check-run body, and
every one of them has to move together.

Ordering before `checksGreen` matters: a repository missing a required check
should report *that*, not a confusing list of check names it was never going to
produce.

### Where the gate gets its answer

This is the load-bearing decision, because getting it wrong reintroduces the
original bug in a new shape. At `pull_request: opened` no checks have run, so
"never produced" and "not yet produced" look identical from the pull request's
own check runs.

**`ciBaselineMet` answers a repository question with repository data.** It reads
the union of check-run names across the repository's **last 15 pull requests**
and compares that to the shape-required set.

```
gate 11  ciBaselineMet
  shape:            Dockerfile, HCL
  required:         Cycode×3, codecov/project,
                    Build and scan image,
                    Terraform plan (speculative)
  repo produces:    Cycode×3, Build and scan image
  ❌ missing:        codecov/project,
                    Terraform plan (speculative)
```

Three properties follow, and all three are the point:

- **The verdict is definite at PR-open.** Nothing depends on CI timing, so there
  is no window in which the gate is ambiguous — which is the failure mode the
  original bug was made of.
- **It is time-invariant for a head SHA.** Adding a workflow requires a new
  commit, so `ciBaselineMet` must **not** join `CI_REPORTING_GATES`: a
  non-candidate failing it is correctly `final`, and no amount of re-evaluation
  will change it.
- **It produces the CI-standardization finding directly**, rather than as a
  by-product of pull requests settling.

Cost is one extra GitHub query per repository per Lambda invocation, cached for
the invocation. It is not cached across invocations: a repository that adds a
workflow should become eligible on its next pull request, not after a TTL.

### Frequency, not mere presence

A check produced *sometimes* can never be safely required, because gate 12 fails
closed on absence. So the union alone is not enough — the gate records **how many
of the sampled pull requests produced each check**, and requires 15 of 15.

```
Cycode: SAST                    15/15   ✅
Build and scan image            15/15   ✅
codecov/project                 11/15   ⚠️  conditional
Terraform plan (speculative)     0/15   ❌  absent
```

`platform-cicd-v2-demo` demonstrates this is real, not theoretical: it produced
`codecov/project` on PR #32's head but not on its most recent pull request. A
conditionally-produced check declared as required would fail gate 12 on every
pull request that does not trigger it — which is the original bug, reintroduced
by automation instead of by hand.

A check below 15/15 is reported as `conditional` and treated as **not met**,
with wording that says so. That is deliberately strict: a scan that runs on some
pull requests is not a scan you can automate against.

### `signalChecks` is fixed by construction

`signalChecks` — which decides when the risk grade is final — gets the same
shape-derived applicable set. A repository that does not run codecov never waits
on it, so provisional always terminates.

The never-final problem then dissolves twice over, which is worth noticing: a
repository missing `codecov/project` also fails `ciBaselineMet`, so it is a
non-candidate, so `assessRisk` never runs and completeness is never consulted at
all. Applicability is the belt; gate ordering is the braces.

## Enrollment-record fields

Three new optional fields, written by Conductor, read by zapp. These are the only
part of this design that touches PLAT-1188.

### `checkAliases` — the fast adjustment

```yaml
checkAliases:
  "Terraform plan (speculative)": "terraform / plan"
  "Build and scan image": "docker-build"
```

Preserves the *requirement* while adapting the *name*. This is strictly better
than replacing the whole required list, because it cannot lower the bar — it can
only redirect a requirement to where that repository satisfies it. Most real
divergence is a naming difference, so this covers most cases and is the first
thing to reach for.

### `ciBaselineWaivers` — the deliberate exemption

```yaml
ciBaselineWaivers:
  - check: "Build and scan image"
    reason: "image built and scanned downstream in the release pipeline"
    expiresAt: "2026-11-01"
```

This is **self-attestation, and it was chosen with that understood.** The party
who wants the exemption is the party who can grant it. Five guards keep it from
becoming a permanent invisible hole:

1. **`expiresAt` is mandatory.** A missing or absent expiry is a validation
   error, not an open-ended waiver.
2. **Capped at 90 days.** A waiver settable for ten years is a permanent
   exemption with extra steps.
3. **Expiry fails closed.** An expired waiver is ignored and the requirement
   returns automatically. No grace period, no warning-only mode.
4. **Waived is not passed.** The gate verdict for a waived check reads `waived`,
   never `pass`, and the repository **still appears in the CI-standardization
   finding** as an acknowledged gap. The waiver unblocks *eligibility* without
   hiding the *number* — which is the whole reason the guard list exists, because
   the number is the actual Phase 0 deliverable.
5. **Recorded on the eval record.** `ciBaselineWaived: ["Build and scan image"]`
   so "which candidates were eligible only because of a waiver" is a query, not
   an archaeology exercise. `reason` and actor also land in the enrollment
   history record, which PLAT-1188's design already provides.

The weekly report surfaces active and expiring waivers. A waiver nobody sees is
a permanent exemption.

### Interaction order

Aliases resolve **before** waivers, and both before the frequency test:

1. Derive the required set from shape.
2. Apply `checkAliases` to rename required checks to this repository's names.
3. Test each required name against the observed 15-PR frequency map.
4. For any still unmet, apply an unexpired waiver → `waived`.
5. Anything unmet and unwaived → `ciBaselineMet` fails.

A repository that both aliases and waives the same check is a configuration
smell — the alias should have resolved it — and the plan flags it rather than
silently preferring one.

## The reframed deliverable

Read the measurement as output rather than input:

```
finding, by remedy:
  add coverage reporting     6 repos
  add a speculative plan     6 repos
  add an image scan          3 repos   (crank included — non-root Dockerfile)
  ─────────────────────────────────────
  fully compliant            1 of 8    (the CI/CD v2 demo repo)
```

This is not a merge-policy problem. It is CI/CD v2 adoption work, surfaced as a
number with a named remedy per repository — which is a far more useful Phase 0
output than a candidate rate, and it is what makes `ciBaselineMet` worth a gate
slot rather than a log line.

The weekly report gains a line for it, and `failedGate` now separates the two
roadmaps automatically:

```
ciBaselineMet: 5    -> "add a workflow"      (platform work)
checksGreen:   2    -> "fix a failing check" (team work)
```

## Consequences for work already planned

| Plan | Change |
|---|---|
| `2026-08-28-eligibility-finality-and-blocking-checks.md` **Task 2** | **Delete it.** It shrank the global `blockingChecks` list to match what repos happen to run — the bar-lowering this design rejects. Its Task 1 (the premature-`final` fix) stays and is still needed: `ciBaselineMet` does not join `CI_REPORTING_GATES`, but `checksGreen` and `coverageFloor` still do, and the first-failing-gate bug is independent of everything here. |
| `2026-08-28-enrollment-registry-conductor.md` **Task 5** | The three override toggles (`signalChecks`, `blockingChecks`, `baseBranches`) stay but stop being load-bearing. `checkAliases` and `ciBaselineWaivers` are the mechanisms operators will actually reach for, and the form needs both. |
| `2026-08-28-enrollment-registry-and-conductor-ui-design.md` | The enrollment record schema gains three fields. |

`policy-rules.yaml` keeps its global `blockingChecks` and `signalChecks` lists,
now correctly understood as *the always-required set*, with the two conditional
requirements expressed as shape rules rather than as flat entries.

## Testing

The tests that carry the design:

- **`conductor` is exempt from image scanning and speculative plans.** No
  `Dockerfile` and no `HCL` in languages → neither is required → `ciBaselineMet`
  passes on the Cycode contexts and coverage alone. This is the test that stops
  the flat-list regression.
- **`crank` is NOT exempt from image scanning.** Languages reports `Dockerfile`
  even though `contents/Dockerfile` 404s. This pins the reason shape comes from
  languages rather than path probing.
- **A check produced on 11 of 15 pull requests is `conditional`, not met.** The
  frequency test, and the reason it exists.
- **`ciBaselineMet` is `final` for a non-candidate.** It is time-invariant for a
  head SHA, so it must not be in `CI_REPORTING_GATES` and must not leave the
  record provisional.
- **A waived check reads `waived`, not `pass`, and still counts in the
  finding.** Two assertions in one test, because the second is the one a future
  refactor will quietly break.
- **An expired waiver is ignored.** `expiresAt` in the past → requirement
  returns → gate fails.
- **A waiver longer than 90 days fails validation.**
- **An alias redirects a requirement without lowering it.** Alias
  `Terraform plan (speculative)` → `terraform / plan`; a repo producing
  `terraform / plan` on 15 of 15 passes, and one producing neither still fails.

## Out of scope

- **Auto-filing the CI gaps.** The report names the repository and the remedy;
  opening pull requests against 5 repositories to add workflows is CI/CD v2
  work with its own owner.
- **`observe` mode.** Considered and dropped: neutral check runs appearing on
  enrolled repositories is acceptable, so a check-run-suppressing mode buys
  nothing.
- **Retroactive evaluation of already-open pull requests** on newly enrolled
  repositories. Real gap — 6 of 11 open dependabot pull requests have never been
  evaluated — but it belongs with PLAT-1188's enrollment action.
- **Waiver approval workflow.** The waiver is a field with guards, not a request
  queue. If self-attestation proves too loose in practice, the fix is to require
  a second party in Conductor, and that is a change to the guards rather than to
  this design.

## Risks

| Risk | Handling |
|---|---|
| The 15-PR query costs a GitHub call per repository per invocation | Cached for the invocation. At current volumes this is well inside the 30s function timeout and the API budget; if it becomes hot, the cache gains a short cross-invocation TTL, which is safe because the value changes only when a repository changes its workflows. |
| A repository with fewer than 15 pull requests | The frequency test uses `produced / sampled`, so a repo with 4 pull requests needs 4 of 4. Below a floor of 3 sampled pull requests the gate reads `unknown` rather than guessing — a brand-new repository has not demonstrated anything either way. |
| Waivers become the default path | Mandatory expiry, a 90-day cap, `waived ≠ pass`, and report visibility. If waiver count grows rather than shrinking, that is itself the finding. |
| `ciBaselineMet` makes more repositories ineligible, not fewer | Correct and intended. Eligibility was previously blocked by a name mismatch; now it is blocked by a stated bar with a named remedy. The candidate count may not rise much — what changes is that the reason is true. |
| Adding an 18th gate churns every gate-count reference | Enumerated in the plan as a single task step rather than scattered, and `GATE_ORDER.length` is used in tests rather than a literal wherever possible. |
