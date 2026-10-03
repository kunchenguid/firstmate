# Skipped Is Not Green Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a job that never runs from satisfying gates 11 and 12. A check run whose conclusion is `skipped` on every sampled pull request currently reads as a produced, green, required check — so a repository can satisfy the entire CI baseline with jobs that are all `if: false`. Teach both gates to tell a **conditional** skip (legitimate: this PR touched no Terraform) from a **structural** one (the job never runs for anybody).

**Architecture:** The two cases are already distinguishable from data zapp fetches today — it just discards the field. `ci-history.ts` asks GraphQL for check-run *names* and not conclusions, so gate 11's `produced` counter cannot see the difference. Add `conclusion` to the query, derive a second counter `ran` alongside `produced`, and both gates gain the distinction for one extra GraphQL field and no extra requests. Gate 11 gets a fifth `CheckStatus` (`inert`); gate 12 keeps `skipped` in `GREEN` only when the baseline shows the check ran at least once.

**Tech Stack:** TypeScript (ESM, `node22` target), GitHub GraphQL v4 via the existing `githubRequest`, `node --import tsx --test`, pnpm.

**Ticket:** [PLAT-1312](https://redventures.atlassian.net/browse/PLAT-1312)

## Why this is worth doing now

Measured across the 29 enrolled repositories on 2026-09-15.

**Structural skips are normal in this fleet.** Thirteen check runs across nine enrolled repos are produced on every sampled pull request and have conclusion `SKIPPED` on all of them:

| repo | check | sample |
|---|---|---|
| `auth-callback-proxy` | `Release` | 15/15 skipped |
| `bankrate-calculators` | `Build`, `Delete Ephemeral`, `Smoke Test Ephemeral` | 15/15 skipped each |
| `brand-identity-pages-app` | `Release` | 14/14 skipped |
| `conductor-api` | `Tag Release` | 15/15 skipped |
| `edge-routing-api` | `Release` | 15/15 skipped |
| `fantasia` | `Deploy to Rebrand Environment`, `Notify Shield`, `Push Image to ECR` | 15/15 skipped each |
| `nextjs-starter` | `Release` | 15/15 skipped |
| `offer-onboarding-flow` | `Release` | 14/14 skipped |
| `platform-cicd-v2-demo` | `Release` | 15/15 skipped |

**None of them is currently a baseline or blocking check name**, so the defect has not yet fired on gate 11. It is latent, not live. But "the fleet routinely carries permanently-skipped jobs" plus "gate 11 cannot see a skip" is one naming coincidence away from a repository passing its CI baseline on decoration. A `Release` job renamed to `Build and scan image`, or a `blockingChecks` override naming a job that turns out to be `if:`-gated, is all it takes.

**Gate 12's exposure is narrower and real.** Five enrolled repos have sampled pull requests where the baseline check `Build and scan image` was `SKIPPED`:

| repo | sample | example PR |
|---|---|---|
| `zapp` | 14 ran, 1 skipped | [#69](https://github.com/bankrate/zapp/pull/69) |
| `nextjs-starter` | 14 ran, 1 skipped | [#75](https://github.com/bankrate/nextjs-starter/pull/75) |
| `insiders-member-app` | 13 ran, 1 skipped | [#242](https://github.com/bankrate/insiders-member-app/pull/242) |
| `explorers-rate-tables` | 12 ran, 1 skipped | [#438](https://github.com/bankrate/explorers-rate-tables/pull/438) |
| `conversations-api` | 2 ran, 1 skipped | — |

On each of those PRs gate 12 counted an image scan that did not run as green. **All four identified PRs are human- or crank-authored and touch no dependencies**, so no candidate verdict was affected and these are all *correct* conditional skips. That is the point: the behaviour is right on this data and zapp has no way to know it. Task 4's fix must preserve every one of these as green.

## Global Constraints

- **`skipped` must stay green for the conditional case.** The comment on `GREEN` in `gates.ts` is correct as far as it goes: *"a skipped Terraform plan on a pull request touching no Terraform is not a failure."* Removing `skipped` from `GREEN` would turn all five repositories above red and make most of the fleet ineligible. The fix is a distinction, not a deletion.
- **`inert` is NOT waivable.** `ciBaselineWaivers` may excuse an `absent` check only — today's rule. Do not extend it. A waiver is the honest form of *"we will never run this"*; an inert job asserts *"we run this"* while not running it, which is a false claim rather than a missing one. The honest remedy is to delete the decorative job and accept `absent`, which **is** waivable. Say this in the code comment.
- **When the baseline is `unknown`, fall back to today's behaviour** — treat `skipped` as green. If GraphQL fails or `sampled < minSample`, gate 12 must not flip the whole fleet red on a transient error. This is safe because gate 11 already returns `unknown` in exactly those cases and `unknown` blocks candidacy on its own, so the fail-open in gate 12 is covered by a fail-closed one gate earlier. State that reasoning in the comment or the next reader will "fix" it.
- **`runGates` stays pure.** Everything gate 12 needs is already on `GateInput` via `input.ciBaseline`. Do not add a fetch, and do not thread new I/O into the gate module.
- **Only `CheckRun` can be `SKIPPED`.** `StatusContext.state` is `ERROR | EXPECTED | FAILURE | PENDING | SUCCESS` — there is no skipped state for the classic Statuses API. A classic status that appears at all has run. Do not invent a mapping.
- **Do not change `produced`'s meaning.** `conditional` and `absent` are derived from it and are correct. Add `ran` alongside; leave `produced` counting distinct names per PR exactly as it does now.
- Conventional Commits (`commitlint` runs in CI). Run `pnpm test` before every commit.

## What this plan deliberately does not fix

A check that runs on the wrong *subset* of pull requests. If a repository's `Build and scan image` path filter omits lockfiles, then every Dependabot PR gets a skipped image scan while human PRs run it — `ran > 0`, so this plan's gate 12 reads the skip as green, and gate 11 reads `met`. That is arguably the more dangerous variant, because it is invisible precisely on the population zapp automates.

It is out of scope here because catching it means comparing each check's skip pattern against the *change class* of the PR it skipped on, which is a different measurement (ledger-side, not baseline-side) and a different design conversation. **File it as a follow-up ticket during Task 6 and link it to PLAT-1312** rather than growing this plan. Do not attempt it inline.

## Sequencing

Independent of every other open plan. Touches `ci-history.ts`, `ci-baseline.ts` and gate 12 in `gates.ts`; no overlap with PLAT-1311 (classifier), PLAT-1320 (actuator) or PLAT-1313 (no zapp code at all).

---

- [ ] **Step 1: Verify the base**

```bash
cd ~/Projects/zapp
git fetch origin && git rev-list --count HEAD..origin/main
grep -n "const GREEN" src/pipeline/02-gates/gates.ts
grep -n "CheckStatus = " src/pipeline/02-gates/ci-baseline.ts
grep -n "on CheckRun" src/pipeline/02-gates/ci-history.ts
```

Expected: `0` behind. `GREEN` contains `'skipped'`. `CheckStatus` has four members. The GraphQL fragment reads `... on CheckRun { name }` with **no** `conclusion` — that absent field is the whole defect.

If `src/pipeline/02-gates/` does not exist, the src reorganisation has been reverted; stop and re-locate these three modules before continuing.

- [ ] **Step 2: Reproduce the fleet measurement yourself**

Do not skip this. The numbers in "Why this is worth doing now" are the justification for the design, and if they no longer hold the design should change. Run:

```bash
gh api graphql -f query='query($owner:String!,$name:String!){repository(owner:$owner,name:$name){pullRequests(first:15,orderBy:{field:CREATED_AT,direction:DESC}){nodes{number commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename ... on CheckRun{name conclusion}}}}}}}}}}}' \
  -F owner=bankrate -F name=zapp \
| jq -r '[.data.repository.pullRequests.nodes[] | [.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]? | select(.__typename=="CheckRun") | {name, c:(.conclusion//"PENDING")}] | unique_by(.name)] as $prs
  | [$prs[][]] | group_by(.name)
  | map({name:.[0].name, prs:length, ran:([.[]|select(.c!="SKIPPED" and .c!="PENDING")]|length), skipped:([.[]|select(.c=="SKIPPED")]|length)})
  | map(select(.skipped>0)) | .[]'
```

Note `orderBy: CREATED_AT` — that is what `ci-history.ts`'s `QUERY` uses. The evidence tables above were gathered with `UPDATED_AT`, so exact per-repo counts may differ by a PR or two. The shape of the finding (a cohort of always-skipped jobs; `Build and scan image` skipped on a minority of PRs) is what matters and is robust to the ordering. **If you find a baseline check name that is skipped on every sampled PR in any enrolled repo, the defect is live rather than latent — say so in the PR description, because it changes this ticket's priority.**

- [ ] **Step 3: `ci-history.ts` — capture conclusions**

Write the failing tests first, in `tests/ci-history.test.ts` alongside the existing ones. The response fixture helper there currently emits names only; extend it to take `{name, conclusion}` pairs without breaking the existing call sites (default the conclusion to `SUCCESS`).

Cases to cover:

1. A check with conclusion `SUCCESS` on all 3 sampled PRs → `produced: 3`, `ran: 3`.
2. A check with conclusion `SKIPPED` on all 3 → `produced: 3`, `ran: 0`. **This is the defect's fixture.**
3. A check `SUCCESS` on 2 and `SKIPPED` on 1 → `produced: 3`, `ran: 2`.
4. A check with conclusion `FAILURE` → counts toward `ran`. Running and failing is running; gate 12 handles redness separately and gate 11 must not treat a failing check as unproduced.
5. A check with `conclusion: null` (still in flight) → counts toward `produced`, **not** toward `ran`. An in-flight check has not demonstrated that it runs.
6. A `StatusContext` node → counts toward both `produced` and `ran`. There is no skipped state for classic statuses.
7. Two check runs with the same name on one PR, one `SKIPPED` and one `SUCCESS` → `ran: 1` for that PR. Matrix jobs and re-runs produce this. Per PR, a name counts toward `ran` if **any** of its runs ran; `produced` already de-duplicates by name via the existing `Set`.

Then change the code:

- Add `conclusion` to the `CheckRun` fragment and `state` to the `StatusContext` fragment in `QUERY`.
- Add to the `CiBaseline` interface, next to `produced`:

```ts
  /**
   * Check name -> how many sampled pull requests actually RAN it. A run whose
   * conclusion is `SKIPPED` counts in `produced` but not here, which is what
   * lets gate 11 tell a decorative `if: false` job from a real one and gate 12
   * tell a conditional skip from a structural one.
   */
  ran: Record<string, number>;
```

- In the per-PR loop, keep the existing `names` `Set` for `produced` and build a second `Set` of names that ran, then increment both maps. Add `ran: {}` to the `empty` fixture so the error path stays shaped correctly.

Update every construction of a `CiBaseline` literal in the test suites — `tsc` will list them.

- [ ] **Step 4: `ci-baseline.ts` — the `inert` status**

Failing tests first, in `tests/ci-baseline.test.ts`:

1. `produced === sampled`, `ran === sampled` → `met`. (Regression: the existing happy path.)
2. `produced === sampled`, `ran === 0` → **`inert`**, and the gate verdict is `fail`.
3. `produced === sampled`, `ran === 1` → `met`. One real run is enough to establish the job is not decoration; whether it *should* have run on the other fourteen is the out-of-scope problem named above.
4. `produced === 0` → `absent`, unchanged.
5. `produced < sampled` with `ran > 0` → `conditional`, unchanged.
6. An `inert` check with a valid, unexpired waiver naming it → **stays `inert`**, gate still fails. Assert the waiver is not consumed: it must still appear unused rather than in the `waived` list.
7. Baseline `error` set, or `sampled < minSample` → verdict `unknown`, no assessments. Unchanged.

Then the code. Extend the type and say why in the doc comment:

```ts
/**
 * `waived` is deliberately NOT `met`. The waiver unblocks eligibility; the
 * repository still appears in the CI-standardization finding, because that
 * number is the phase's deliverable and a waiver must not hide it.
 *
 * `inert` means the check was produced on every sampled pull request and NEVER
 * ran on any of them — an `if:`-gated job that is permanently false. It is
 * deliberately NOT waivable: a waiver is the honest form of "we will never run
 * this check", whereas an inert job asserts "we run this check" while not
 * running it. The remedy is to delete the decorative job and take `absent`,
 * which is waivable.
 */
export type CheckStatus = 'met' | 'conditional' | 'absent' | 'inert' | 'waived';
```

Add `ran` to `CheckAssessment` next to `produced` — the weekly report and the check output both need it to say anything useful.

The status ladder, replacing the current single ternary. Order matters: test `inert` before `met`, or an inert check falls through to `met`.

```ts
const produced = baseline.produced[effective] ?? 0;
const ran = baseline.ran[effective] ?? 0;
const status: CheckStatus = produced === 0 ? 'absent'
  : produced < baseline.sampled ? 'conditional'
  : ran === 0 ? 'inert'
  : 'met';
```

Then extend the waiver guard so it can only rescue `absent`:

```ts
// A waiver may excuse an ABSENT check only — not `conditional` ("runs
// sometimes" is a CI defect to fix) and not `inert` (see CheckStatus).
if (base.status !== 'absent') return base;
```

and add `'inert'` to the `unmet` filter.

- [ ] **Step 5: gate 12 — conditional-skip awareness**

Failing tests first, in `tests/gates.test.ts`. There are existing `checksGreen` tests around the skipped-is-green behaviour; **read them before writing and do not duplicate them** — extend the file with only the cases the existing ones do not cover:

1. A blocking check with conclusion `skipped` on this PR, and `ran > 0` in the baseline → gate 12 **passes**. This is the zapp#69 case; it must not regress.
2. The same check `skipped`, with `ran === 0` in the baseline → gate 12 **fails**, and the check appears in `notGreen`.
3. The same check `skipped`, with the baseline in its `unknown` state (`error` set) → gate 12 **passes**. The documented fail-open.
4. A blocking check with conclusion `success` and `ran === 0` → passes. `ran` only ever gates the `skipped` conclusion; never let it reject a check that visibly succeeded on this PR.
5. A per-repo `blockingChecks` override naming a check that is `skipped` with `ran === 0` → fails. The override bypasses shape computation, so it is the path most likely to name a decorative job.

Then the code. Keep `GREEN` as-is and add the narrower rule where the filter runs:

```ts
// `skipped` is green ONLY when the baseline shows this check runs at all. A
// Terraform plan skipped on a pull request touching no Terraform is not a
// failure; a job that is skipped on all 15 sampled pull requests is not a
// check. When the baseline itself is unknown we keep the old behaviour and
// treat the skip as green — gate 11 already reads `unknown` in exactly those
// cases, and `unknown` blocks candidacy on its own, so this fail-open sits
// behind a fail-closed gate rather than in front of one.
const baselineUsable = input.ciBaseline.error === undefined
  && input.ciBaseline.sampled >= input.rules.ciBaseline.minSample;
const ranAtLeastOnce = (name: string) =>
  !baselineUsable || (input.ciBaseline.ran[name] ?? 0) > 0;
```

and in `notGreen`, reject a completed-but-skipped run whose name never ran. Keep absence failing exactly as it does today.

Include `skippedInert` (the names rejected for this reason) in the gate's `value` alongside `notGreen`, so the check output can distinguish *"your scan failed"* from *"your scan never runs"*. A reader of the PR check cannot act on the first message when the second is true.

- [ ] **Step 6: Surface it, document it, validate it**

- `docs/policy.md` — document `inert` in the `CheckStatus` list, with the not-waivable rule and the reason. If the doc states a count of check statuses, it is now five.
- The weekly report — `inert` must not fold into the same bucket as `absent`. They have different remedies (*delete the job* versus *add the job*) and the report's value is naming the remedy. Check `src/entrypoints/report/` for where `CheckStatus` is grouped; if `inert` would silently render as "CI gap", give it its own line.
- `policy-rules.yaml` — no rule changes. If you find yourself adding a knob here, re-read the constraints.
- Live validation: re-run Step 2's query across all 29 enrolled repos after deploying, and confirm no repository's *baseline* checks are `inert`. The expected result is that `inert` appears zero times on baseline checks and the thirteen decorative jobs listed above are untouched, because none of them is required. A gate that changes no verdict today is the correct outcome — this closes a hole rather than fixing a symptom, and the PR description should say so plainly so nobody reads "no verdicts changed" as "no effect".
- File the follow-up ticket for the wrong-subset problem named in "What this plan deliberately does not fix", linked to PLAT-1312.

- [ ] **Step 7: The other two `GREEN` sets**

The same three-value set is defined independently in three modules for three different purposes. PLAT-1312 named the second; the third was found while writing this plan and is the most consequential of the three. **Verify each before changing it** — the direction of the error differs, so one fix does not transfer.

```bash
grep -rn "'success', 'neutral', 'skipped'" src/
```

**`src/pipeline/ledger/post-merge.ts:31` — over-attribution.** The green-to-red attribution rule asks whether the failing check was green on the *parent* commit, and its own comment states the doctrine:

> ABSENT IS NOT GREEN. A check that did not run on the parent cannot have gone from green to red, and treating its absence as a pass would manufacture a transition that never happened.

A `skipped` parent run is a check that did not run, so the module contradicts its own comment: `previous.conclusion === 'skipped'` passes the `GREEN.has(...)` test and an attribution is recorded. The effect is to blame a merge for a failure that has no prior green observation, inflating the post-merge failure count that feeds merge confidence. Fix: exclude `skipped` here. There is no legitimate-conditional-skip case to preserve, because the question being asked is specifically "did this check previously pass", and a skip is not a pass. This is a genuine one-line change, unlike gate 12.

**`src/pipeline/03-risk/signals/scan-findings.ts:34` (`CLEAN`) — a false `low`.** A Cycode check with conclusion `skipped` is in `CLEAN`, so it is not `missing`, not `unfinished`, not `indeterminate`, and not counted in `failed`. The signal therefore grades **`low`** — "scanners ran, no findings" — on a scan that did not run. The function's own doc comment promises `unknown` *"when any expected scanner is missing or has not finished"*; a skipped scan is neither, and the code has no category for completed-without-working.

This one matters more than the gates, for two reasons. First, a risk signal grading `low` is an affirmative safety claim, not a missing check — and `combine()` is worst-known-wins, so a false `low` is silently absorbed. Second, `scannerFindings` is one of only **three** signals that do not require parsed dependency bumps, and per PLAT-1320 a `lockfile-only` candidate reaches exactly **two** graded signals in practice. So for the change class with the thinnest evidence base, a skipped scanner supplies half the graded signal budget as a false clean.

Fix: move `skipped` out of `CLEAN` and into the `indeterminate` path so the signal reads `unknown` with the reason naming the skipped scanner. `unknown` is first-class here and already blocks candidacy through `minSignalsGraded`, so this fails closed correctly and needs no new machinery.

Tests for both, in their existing suites. For `scan-findings`, assert the `unknown` reason names the skipped scanner — a bare `unknown` is not actionable for the repo owner.

**Do not unify the three sets into one shared constant.** They answer three different questions — gate green-ness, prior-commit passed-ness, scanner clean-ness — and after this plan they no longer hold the same values. `scan-findings.ts` already carries a comment explaining why it keeps its own; preserve that reasoning and extend it to `post-merge.ts`.
