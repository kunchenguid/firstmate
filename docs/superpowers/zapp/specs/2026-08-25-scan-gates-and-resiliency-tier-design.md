# Scan gates, coverage floor, and resiliency-tier eligibility

Design for the next slice of `bankrate/zapp`, after Specs A–C. Epic
[PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184), Phase 0 shadow mode.

**This is Spec D.** It adds four eligibility gates and the rules to drive them. No new subsystem, no
new trigger path — every change lands inside structures Specs A–C already built.

Status: drafted 2026-08-25, awaiting review.

## Goal

Decide where the remaining security and quality signals belong, and turn them on:

- Cycode SAST / Secrets / Vulnerable Dependencies, the Wiz image scan, and the Terraform plan
- A minimum project-coverage floor
- Repository sensitivity, via ResiliencyTier and SOC2 status

Shadow mode is unchanged. Conclusions stay `neutral`; nothing is approved, merged or blocked.

## The framing decision

Most of this list turned out to be **one concept wearing five hats.** Cycode SAST, Cycode Secrets,
Cycode Vulnerable Dependencies, the image scan and the Terraform plan are all *"is this check
green?"* — they are not five gates and not five signals. They become **one gate fed by a declared
list**, which also solves the problem that the Terraform check's name varies between repos: it is
declared per repo rather than detected.

Two things are genuinely new axes:

- **Coverage floor** asks about *level* ("is this repo covered at all?"), where the existing
  `coverageDelta` risk signal asks about *change* ("did this PR drop coverage?"). Different question,
  no overlap, and a floor is a hard yes/no — so it is a gate.
- **Repository sensitivity** is a property of the repo, not the change, which puts it alongside
  `classificationPermits` and `tierFloor` in the eligibility ladder.

## Starting state

Verified 2026-08-25 against live systems.

| Fact | Detail |
|---|---|
| Gates today | 11, in `GATE_ORDER` in `src/gates.ts` |
| Risk signals today | 6, including `newFindings` reading Cycode check verdicts |
| Declared check lists | `rules.signalChecks` (Spec C) — when the risk grade is *final* |
| Org custom properties | **Only** `is_poc` and `is_soc2_compliant` (required). No sensitivity property exists. |
| Demo repo properties | `is_poc=true`, `is_soc2_compliant=false` |
| Demo repo coverage | 62.99% (`codecov/project`) |

### The check names, confirmed

`Build and scan image` is the **job** name in `.github/workflows/image-scan.yml`, whose *workflow*
name is `Wiz Image Scan`. GitHub surfaces the job name as the check run, so **there is one check to
read, not two** — the Wiz scan happens inside it.

`Terraform plan (speculative)` comes from Terraform Cloud's speculative-plan integration via
GitHub Actions. CI/CD v2 has not fully standardised this name across repos, which is exactly why it
is declared rather than inferred.

### ResiliencyTier

From the approved Bankrate ResiliencyTier Tagging Standard (approved 2026-03-30; tech lead Chase
Coney, product owner Alex Kaplan):

| Tier | Availability | RPO | Passive monitoring | DR plan |
|---|---|---|---|---|
| Platinum | 99.99% | < 1 hour | Required | Required |
| Gold | 99.95% | < 24 hours | Required | Optional |
| Silver | 99.9% | < 72 hours | Required | Optional |
| Bronze | 99.5% | < 72 hours | Required | Optional |
| Paper | 80% | when someone notices | Optional | No |

**This replaces DataClassification, which was considered and rejected**, for one decisive reason:
ResiliencyTier is **ordinal** and DataClassification is not. `Romeo`/`Sierra`/`India`/`Lima`/`Echo`
has no documented sensitivity ordering — zapp's own `vars.tf` annotates only `India = Internal` — so
a gate over it could only be an allow-list, and any ranking would be invented. ResiliencyTier ranks
cleanly, so the gate is a threshold. It also asks the more relevant question for unattended change:
not "how secret is the data" but "how much does it matter if this breaks".

Three properties of the tag that shape the design:

**It is environment-dependent.** Every platform repo inspected — `zapp`,
`platform-cicd-v2-demo`, `github-pr-jira-check`, `platform-agent` — carries the identical line:

```hcl
ResiliencyTier = var.environment == "prod" ? "gold" : "bronze"
```

A repository therefore has no single tier; its *deployment* has one per environment. The custom
property means **the production tier**, and the spec says so explicitly rather than leaving it to be
guessed.

**It is not GitHub metadata.** It lives in Terraform, as an AWS resource tag. Reading it would mean
parsing each repo's Terraform, which is fragile and version-dependent. So it becomes a repo custom
property, following the `is_soc2_compliant` precedent.

**Its current values are known to be wrong.** The standard says so directly — most teams did not
weight the tag carefully, and re-evaluation is one of its success criteria. This has a direct
consequence for thresholds; see below.

## Four new gates, 11 → 15

Inserted into `GATE_ORDER` after `tierFloor` and before `freezeOff` — so the four new gates take
positions 11–14 and **`freezeOff` shifts from 11th to 15th**, keeping its "checked last, atomically"
property.

| # | Gate | Passes when |
|---|---|---|
| 11 | `checksGreen` | Every check in `blockingChecks` concluded `success`, `neutral` or `skipped` |
| 12 | `coverageFloor` | `codecov/project` percentage ≥ the class's `minCoveragePct` |
| 13 | `resiliencyTierPermits` | The repo's production tier ranks at or below the class's `maxResiliencyTier` |
| 14 | `soc2Permits` | If `is_soc2_compliant` is true, the class is marked `soc2Eligible` |
| 15 | `freezeOff` | Unchanged, still last — only its position moved |

Four separate gates rather than one combined sensitivity gate. The gate map exists to say *which*
rule stopped a pull request; a single `sensitivityPermits` would be tidier in the ladder and strictly
worse in the table a human reads.

**All four fail closed on absent data.** No Codecov result fails `coverageFloor`. An unset
`resiliency_tier` fails gate 13 — unknown criticality is treated as maximum criticality, which is the
only safe direction for a control whose purpose is protecting things that matter. A missing
`is_soc2_compliant` fails gate 14, and since the property is org-*required* its absence means
something is wrong with the repo rather than with the policy.

Note `checksGreen` accepts `neutral` and `skipped`, not only `success`. A skipped Terraform plan on a
pull request touching no Terraform is not a failure, and our own checks are `neutral` by construction
— treating either as red would make every pull request ineligible.

## Reading repository properties

Both trigger paths call `GET /repos/{owner}/{repo}/properties/values`.

The tempting alternative is the webhook payload's `repository.custom_properties`, which is what
`github-pr-jira-check` reads and which costs no extra call. It is wrong here: **Spec C's
`check_suite` path does not have it.** That path fetches the pull request via `GET /pulls/{n}`, whose
`base.repo` carries no custom properties, so a payload-based gate would work on `opened` and silently
degrade on every re-evaluation — the worst kind of bug, because the first evaluation would look
correct.

One explicit call, identical on both paths, is worth more than the saved request.

The endpoint **omits unset properties entirely** rather than returning them null — verified against
the demo repo, which returns only `is_poc` and `is_soc2_compliant`. Absent and unset are therefore
the same observation, and both fail closed.

## Rules additions

```yaml
rules:
  # Must be GREEN for a pull request to be a candidate.
  #
  # DISTINCT FROM signalChecks, which decides when the risk grade is final.
  # These two lists overlap on the Cycode contexts because both care about
  # scanners, not because they are the same thing — one asks "may we automate
  # this at all", the other "have our inputs arrived". Keep them separate.
  blockingChecks:
    - "Cycode: SAST"
    - "Cycode: Secrets"
    - "Cycode: Vulnerable Dependencies"
    # The JOB name. Its workflow is named "Wiz Image Scan"; GitHub surfaces the
    # job, and the Wiz scan runs inside it. There is no separate Wiz check.
    - "Build and scan image"
    # TFC speculative plan via Actions. CI/CD v2 has not standardised this name
    # across repos, which is why it is declared and overridable per repo.
    - "Terraform plan (speculative)"

  changeClasses:
    dep-patch:
      minCoveragePct: 60
      maxResiliencyTier: gold
      soc2Eligible: false
    dep-minor:
      minCoveragePct: 60
      maxResiliencyTier: gold
      soc2Eligible: false
    dep-major:
      minCoveragePct: 60
      maxResiliencyTier: silver
      soc2Eligible: false
    lockfile-only:
      minCoveragePct: 0
      maxResiliencyTier: platinum
      soc2Eligible: false
```

Per-repo `blockingChecks` override on the enrollment record, exactly as `signalChecks` works — same
inherit-or-replace semantics, never merged.

### Why the tier thresholds start loose

`dep-patch` and `dep-minor` both permit up to `gold`, which admits every repo inspected — all of
them self-report `gold` in production.

This is deliberate and temporary. The demo repo reports `gold` because it inherited the standard
provider block, not because a demo application needs 99.95% availability. That is precisely the
inaccuracy the ResiliencyTier standard names as its motivation. A tighter threshold today would not
express real policy; it would encode a tagging error, and it would flip PR #27 — the only pull
request currently exercising the full happy path — from candidate to non-candidate, so the shadow
dataset would stop showing what a pass looks like.

Tightening is a one-line rules pull request once the org-wide re-evaluation the standard calls for
has happened. The spec records the reason so nobody later reads `gold` as a considered ceiling.

`dep-major` is capped at `silver` for symmetry and future-proofing; it remains ineligible everywhere
regardless, because its `classifications` list is empty (Spec A).

## Where the existing risk signal stands

`newFindings` stays. The gate is the hard stop — a red scanner means not a candidate, full stop —
while the signal remains the graded view of the same evidence, distinguishing one red scanner from
three. They answer different questions: *may we automate this* versus *how much does this worry us*.
PLAT-1191's six-signal criterion stays intact.

The redundancy is real and accepted. Collapsing them would mean either losing the hard stop or losing
the gradient, and both are worth keeping.

## Prerequisites this spec cannot perform

Two org-level actions, both needing sign-off, neither in the implementation plan:

1. **Create the `resiliency_tier` org custom property.**
   `PUT /orgs/bankrate/properties/schema/resiliency_tier`, `single_select`, allowed values
   `platinum`, `gold`, `silver`, `bronze`, `paper`. Needs org-admin rights. Its description should
   state that it means the **production** tier, since the underlying tag varies by environment.
2. **Set it on every enrolled repository.** Until it is set, gate 13 fails and no pull request on
   that repo is a candidate — correct fail-closed behaviour, and worth knowing before the first
   validation run reads as a regression.

Until both are done the gate reports a clear reason rather than a mystery: *"resiliency_tier is not
set on this repository"*.

## Error handling

| Condition | Behaviour |
|---|---|
| `GET properties/values` fails | Gates 13 and 14 fail with the fetch error as their reason. Never assumed permissive. |
| `resiliency_tier` unset | Gate 14 fails: unknown criticality is treated as maximum |
| `is_soc2_compliant` unset | Gate 15 fails; the property is org-required, so absence means the repo is misconfigured |
| A `blockingChecks` entry has no run | Gate 12 fails, naming the missing check. Absence is not green. |
| A `blockingChecks` entry is still running | Gate 12 fails, naming it. Spec C's re-evaluation will revisit once it reports. |
| `codecov/project` absent or unparseable | Gate 13 fails, naming the reason |
| Change class is `unclassified` | Gates 11–14 record `skipped`, like the existing class-dependent gates |

Gates 11–14 read the class's thresholds, so they follow the existing rule: when gate 5 yields
`unclassified`, they are `skipped`, never `fail`.

## Testing

- **`checksGreen`** — all green passes; one `failure` fails and names it; a missing declared check
  fails and names it; an `in_progress` check fails; `neutral` and `skipped` both pass; undeclared red
  checks are ignored (a failing `Commit lint` is not a security finding).
- **`coverageFloor`** — 62.99% against a floor of 60 passes; against 70 fails; absent fails; an
  unparseable title fails; a floor of 0 passes with any reported value.
- **`resiliencyTierPermits`** — `gold` against a `gold` ceiling passes; `platinum` against `gold`
  fails; `paper` against `gold` passes; unset fails; an unrecognised tier value fails rather than
  ranking as 0.
- **`soc2Permits`** — a non-SOC2 repo passes regardless of `soc2Eligible`; a SOC2 repo passes only
  when `soc2Eligible` is true; unset fails.
- **Property fetch** — parses the live response shape; an unset property is absent, not null; a
  failed fetch produces failing gates with the error as the reason.
- **Both trigger paths** see the same properties — the test that guards against the payload-versus-fetch
  asymmetry described above.
- **Fixtures** — the three existing PR fixtures still produce their expected verdicts, with PR #27
  still a candidate under the loose starting thresholds.
- **Rules validation** — `blockingChecks` must be an array of strings; `minCoveragePct` a number in
  0–100; `maxResiliencyTier` one of the five tiers; `soc2Eligible` a boolean. Each fails the build.

### Live validation

PR #27 stays a candidate, now passing 15 of 15 gates, with the four new rows visible in the table.
A deliberate negative: temporarily set the demo repo's `resiliency_tier` to `platinum` and confirm
the pull request becomes a non-candidate with `resiliencyTierPermits` named as the failure, then set
it back.

## Out of scope

- **PLAT-1192 (T8)**, the required-checks snapshot. `blockingChecks` is a declared list of checks
  *we* require; T8 enumerates what the *repository* requires, from rulesets and classic branch
  protection. They will overlap and must not be merged.
- **Reading ResiliencyTier from Terraform.** The custom property is the source of truth for this
  service.
- **Per-environment tiers.** One property, meaning production.
- **Re-tagging repos** to accurate resiliency tiers — the org-wide effort the standard calls for.
- **Acting on any verdict.** Shadow mode is unchanged.

## Definition of done

- [ ] `resiliency_tier` org custom property created, `single_select`, five tiers, documented as production
- [ ] Set on `bankrate/platform-cicd-v2-demo`
- [ ] `rules.blockingChecks` declared, validated at build time, overridable per repo
- [ ] `minCoveragePct`, `maxResiliencyTier` and `soc2Eligible` on every change class, all validated
- [ ] Gates 11–14 implemented in `GATE_ORDER`, with `freezeOff` still last
- [ ] All four fail closed on absent data, each with a reason a reader can act on
- [ ] `checksGreen` treats `neutral` and `skipped` as green, and absent as red
- [ ] Repo properties read via `GET properties/values` on **both** trigger paths, with a test proving parity
- [ ] `newFindings` risk signal unchanged; still six signals
- [ ] Each new gate has a passing and a failing test, plus its absent-data case
- [ ] The check-run table shows 15 rows
- [ ] PR #27 is still a candidate at 15 of 15; setting the demo repo to `platinum` makes it a
      non-candidate naming `resiliencyTierPermits`, and reverting restores it
- [ ] Both checks remain `neutral` and on no required-checks configuration
