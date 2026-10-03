# Gate 11 Sample Honesty Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate 11 decides whether a repo runs its required checks by watching its recent pull requests. It watches 3, and two of the three conclusions it draws hard-fail with no operator lever. Make the sample big enough to support the conclusions that block, and stop blocking on the one gate 12 already covers.

**Resolves:** PLAT-1316 (Task 1), PLAT-1324 (Task 2, by removing the need for it), and completes PLAT-1312 so its gate work actually fires instead of shipping dormant.

**Architecture:** No new modules and no new data. `assessCiBaseline` already computes `produced`, `ran` and `sampled` per check. Task 1 changes which of its statuses block. Task 2 changes two numbers in `policy-rules.yaml`. That is the whole change; the rest is tests, fleet verification and docs.

**Tech Stack:** TypeScript (ESM, `node22` target), `node --import tsx --test`, pnpm.

## Read this first, because the numbers in earlier plans were wrong

**Two errors in the PLAT-1312 and PLAT-1313 plans, both from asserting config values instead of reading them:**

1. Those plans say gate 11 samples **15** pull requests. `policy-rules.yaml` has always set `samplePrs: 3`. The 15 came from the original CI-baseline design doc; the implementation shipped 3 and nobody reconciled them. Every fleet measurement in those plans was taken at 15, a window the service does not use.
2. A claim that raising the sample would immediately break `brand-identity-pages-app` and `offer-onboarding-flow` because each has a pull request with zero check runs. **False.** Measured 2026-09-15 across all 29 enrolled repos: **zero** pull requests have zero check runs, at either n=3 or n=15 (435 pull requests examined). PLAT-1316's scenario does not occur in the fleet today.

**Before you write a number in this repo about gate 11, read it from the config:**

```bash
grep -n "samplePrs\|minSample" policy-rules.yaml
```

Any measurement script must take the sample size from that value rather than hardcoding one. That single habit would have prevented both errors above.

## The actual problem

Gate 11 answers "does this repo run its required checks?" by inference from history, because it cannot answer it directly — when a pull request opens, no checks have run yet, so "this repo has no image scan" and "the scan hasn't started" look identical from one pull request.

Three conclusions come out of that inference, and they are not equally trustworthy:

| status | means | blocks? | waivable? | trustworthy at n=3? |
|---|---|---|---|---|
| `absent` | 0 of N produced it | yes | **yes** | fairly — and there is a lever if wrong |
| `conditional` | 1..N-1 produced it | yes | **no** | no — "1 or 2 of 3" is noise |
| `inert` | all N produced it, none ran | yes | **no** | no — three consecutive Terraform-only PRs do this to an image scan |

The two untrustworthy ones are the two with no escape hatch. That is the defect.

## Why `conditional` should not block

The reasoning recorded in the CI-baseline design was: *"Gate 12 fails closed on absence, so a conditionally-produced check can never be safely required."* That is an argument about gate 12, and gate 12 already acts on it. Read the filter:

```ts
if (run === undefined || run.status !== 'completed') return true;
```

If a required check is missing on the pull request being evaluated, gate 12 fails it. Gate 11 additionally hard-failing "this check ran on 14 of 15 recent pull requests" removes eligibility from a repo whose CI is working, and offers no waiver to fix it. The safety is already handled one gate over.

Keep the *message* — `` `codecov/project` ran on only 14 of 15 recent pull requests `` is useful on a check run. Stop it blocking.

## Global Constraints

- **`inert` stays a hard fail and stays unwaivable.** Task 2 makes it trustworthy by raising the sample rather than by softening it. A waiver is the honest form of "we will never run this"; an inert job claims to run and does not. The honest remedy is to delete the decorative job and take `absent`, which is waivable.
- **`absent` keeps blocking and stays waivable.** Unchanged.
- **Do not add a `minSampleForNeverRan` knob.** An earlier draft of this fix proposed guarding the `inert` conclusion behind a separate threshold. That leaves `inert` permanently dormant at `samplePrs: 3` and puts two sample thresholds in one gate. Raising the sample is the same fix with one fewer moving part.
- **`runGates` stays pure.** No new I/O.
- **Do not change `produced`, `ran` or `sampled`.** Their meanings are correct.
- Conventional Commits (`commitlint` runs in CI). Run `pnpm test` before every commit.

## Sequencing

**This work folds into [zapp#77](https://github.com/bankrate/zapp/pull/77), it does not follow it.** #77 currently ships `inert` firing off a 3-pull-request sample. Merging it and then fixing it means knowingly shipping the defect. Land these tasks on the same branch so #77 is correct when it merges.

[zapp#78](https://github.com/bankrate/zapp/pull/78) (PLAT-1322, lockfile parsing) is independent and has no known issues. **Merge #78 first**, then rebase #77. Both touch `gates.ts` and `policy-rules.yaml`, on different lines; expect a small textual conflict and keep both sides.

---

- [ ] **Step 1: Verify the base and the premises**

```bash
cd ~/Projects/zapp
git fetch origin && git log --oneline -1 origin/fm/zapp-skipped-is-not-green
grep -n "samplePrs\|minSample" policy-rules.yaml
grep -n "const unmet = checks.filter" src/pipeline/02-gates/ci-baseline.ts
```

Expected: `samplePrs: 3`, `minSample: 3`, and an `unmet` filter listing `conditional`, `absent` and `inert`.

Then confirm the zero-check-run premise yourself, because Task 2 depends on it:

```bash
gh api graphql -f query='query($o:String!,$n:String!){repository(owner:$o,name:$n){pullRequests(first:15,orderBy:{field:CREATED_AT,direction:DESC}){nodes{number commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename}}}}}}}}}}' \
  -F o=bankrate -F n=brand-identity-pages-app \
| jq '[.data.repository.pullRequests.nodes[]|{n:.number,checks:([.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?]|length)}]'
```

Every entry must show a non-zero `checks`. **If any pull request has zero check runs, stop** — PLAT-1316 is live after all, and Task 2 must wait for it to be fixed by excluding those pull requests from `sampled`.

- [ ] **Step 2: `conditional` stops blocking**

Tests first, in `tests/ci-baseline.test.ts`:

1. `produced=14, sampled=15, ran=14` → status stays **`conditional`**, gate verdict is **`pass`**. The status and the verdict are now separate facts; assert both.
2. `produced=0` → `absent`, verdict `fail`. Unchanged.
3. `produced=15, sampled=15, ran=0` → `inert`, verdict `fail`. Unchanged.
4. A repo with one `conditional` check and one `absent` check → verdict `fail`, and the rendered message names **both**, because the author still needs to know about the flaky one.
5. A waiver against a `conditional` check → still not consumed, still `conditional`. Waivers remain `absent`-only.

Then the code, in `assessCiBaseline`:

```ts
// `conditional` is reported but does NOT block. Gate 12 already fails closed
// when a required check is missing from the pull request being evaluated
// (`run === undefined` → not green), so hard-failing a repo here for "ran on
// 14 of 15 recent pull requests" removes eligibility from working CI and
// offers no waiver to fix it. The status is kept so render.ts can still say so.
const unmet = checks.filter((c) => c.status === 'absent' || c.status === 'inert');
```

`render.ts` needs no change — it already filters on the statuses rather than the verdict, so a `conditional` check keeps its sentence. Confirm that with a test in `tests/render.test.ts` asserting the sentence appears while the gate passes.

- [ ] **Step 3: Raise the sample**

`policy-rules.yaml`:

```yaml
    # Recent pull requests to sample. 15, not 3: gate 11 draws two conclusions
    # that block and cannot be waived (`absent`, `inert`), and three pull
    # requests cannot support either. Three consecutive Terraform-only pull
    # requests will make a working image scan look like it never runs.
    samplePrs: 15
    # Below this many sampled pull requests the gate reads `unknown` rather than
    # guessing — a brand-new repository has demonstrated nothing either way.
    # 10, not 3, for the same reason as above: below ten the sample cannot
    # support an unwaivable conclusion, and `unknown` is the honest answer.
    minSample: 10
```

Then `pnpm run build:rules`, commit the regenerated `src/policy/generated/rules.ts`, and confirm nothing else drifted.

**Cost check, state the result in the PR:** `ci-history.ts`'s query is `pullRequests(first: $prs)` × `contexts(first: 100)`. Going 3 → 15 multiplies the worst-case node count by five, and that file already flags the cost as "bounded but real." Time one real invocation before and after and report both numbers. If the GraphQL request starts timing out or hitting node limits, say so rather than shipping it.

**Decision recorded, flag it if you disagree:** raising `minSample` to 10 means a repository with fewer than 10 pull requests of history reads `unknown` on gate 11 instead of being judged. `unknown` is not a pass, so such a repo cannot be a candidate. That is the correct answer — it genuinely has not demonstrated anything — but it is a real behaviour change for new repos, and it should be named in the PR description rather than discovered later.

- [ ] **Step 4: Verify against the fleet, before and after**

Run this at both `first: 3` and `first: 15` against all 29 enrolled repositories and put both tables in the PR description. The point is to show what the config change does to real verdicts, not to assert it is safe.

```bash
gh api graphql -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequests(first:$p,orderBy:{field:CREATED_AT,direction:DESC}){nodes{commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename ... on CheckRun{name conclusion}}}}}}}}}}}' \
  -F o=bankrate -F n=<repo> -F p=<3|15>
```

For each repo, classify every required check name into `met` / `conditional` / `absent` / `inert` using the same ladder as `ci-baseline.ts`. Get the enrolled repo list from the `zapp-enrollments` table in the QA account, filtering to records that have a `mode` attribute — the table also holds audit rows, which have no `mode` and are not repositories.

Known result at n=3, measured 2026-09-15, for `Terraform plan (speculative)` across the 28 enrolled repos with `HCL`: 3 `met`, 0 `conditional`, 25 `absent`. At n=15 it was 2 `met`, 2 `conditional`, 24 `absent`. **So expect the raise to move two repos from a blocking state to a reported-but-passing one** (`conductor-api`, `brand-identity-pages-app`) once Step 2 lands. Confirm that, and report any repo whose verdict changes in the blocking direction.

- [ ] **Step 5: Docs, and close the loop on the tickets**

- `docs/policy.md` — state which gate 11 statuses block and which only report, and why `conditional` does not block (gate 12 covers the specific pull request). State the sample size and that `minSample: 10` means new repos read `unknown`.
- Remove any remaining "15 sampled pull requests" phrasing that predates this change from `docs/` and `AGENTS.md`. It was accidentally correct only after Step 3; make sure nothing still asserts a number it does not read.
- In the PR description, note that **PLAT-1316 is resolved by Step 2** (a single unusual pull request can no longer make every check blocking, because `conditional` no longer blocks) and that **PLAT-1324 is resolved by Step 3** (the sample now supports the `inert` conclusion, so no separate threshold is needed).
- PLAT-1325 (a check that skips only on Dependabot pull requests) is **not** resolved here and needs change-class data. Leave it open.
