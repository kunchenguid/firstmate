# Make deploymentHealth Countable

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `deploymentHealth` counts one observation per terminal `deployment_status`, which is not one deployment. GitHub creates several Deployment objects per commit and each posts its own status, so the denominator varies two to three times over depending on nothing meaningful. Record the deployment id, count one observation per deployment object, and ignore rows that predate the id because they cannot be grouped. Then the thresholds can be set from a number that means something.

**Ticket:** [PLAT-1318](https://redventures.atlassian.net/browse/PLAT-1318)

**Decision, made 2026-09-16:** record `deploymentId`, count by it, do **not** backfill, and re-derive `minDeployments` / `lowAbove` / `mediumAbove` in a follow-up once real rows exist.

**Architecture:** One field added where the row is written. One filter and one grouping step in the signal. No new fetches — the id is already in the webhook payload zapp already receives.

## What the data actually says, and what the ticket got wrong

The ticket's central hypothesis is that a per-release denominator puts `platform-agent` at or near 100% and the blocking problem disappears. **It does not.** Measured across all 169 `#deploy#` rows on 2026-09-16:

| denominator | `platform-agent#qa` | grade at `lowAbove: 0.90` |
|---|---|---|
| every terminal status (today) | 13 observed, **77%** | `medium`, blocks |
| final state per `deploymentSha` | 6 observed, **67%** | worse |
| final state per pull request | 2 observed, 50% | worse |

It gets worse under every alternative, and under per-sha **no repository in the fleet reaches `minDeployments: 10`**, so the signal goes fully inert rather than getting more accurate.

The reason is visible in GitHub's own records. `platform-agent` commit `a058ea43` has two Deployment objects, same environment, same ref, same `task: deploy`, both created by `dependabot[bot]`:

* deployment `6449568248`, created 01:07:35 → `success` at 01:11:03
* deployment `6449607203`, created 01:11:03 → `failure` at 01:13:39

The same commit was deployed to qa twice and the second attempt failed. The ticket read PR #46's five rows as one release retrying its way to success; they are two different commits, and one of them ended failed.

**So `platform-agent` has real deployment failures.** Do not expect a denominator change or a threshold change to rehabilitate it. Three of its six commits had a failure somewhere. That is a fact about the repository, not an artefact of the counting.

## The actual defect

`src/pipeline/ledger/outcomes.ts` writes the row with `deploymentSha`, `mergeCommitSha`, `prNumber`, `environment` and `state`. `src/entrypoints/worker/worker.ts:463-492` reads `payload.deployment_status.state`, `payload.deployment.environment` and `payload.deployment.sha`.

It never reads `payload.deployment.id`, which is right there in the same payload.

Without it, statuses cannot be grouped by the deployment they belong to. Every candidate denominator in the ticket is a guess at that grouping from the outside, which is why they all measure something other than "did this deployment succeed".

## Why filtering old rows is the right move, not a compromise

Pre-existing rows have no `deploymentId`, so they cannot be grouped correctly. Counting them means counting statuses again, which is the defect. So the signal should ignore them.

Two things fall out of that, both good.

The backfill question answers itself. There is nothing to backfill — the id was never in those rows and cannot be recovered from them without re-querying GitHub for every historical deployment. "Not backfilling" becomes the implementation rather than a decision to defend.

And it stops the clock on the pilot. `platform-agent` has **zero** indexed rows today so it reads `unknown`, but at roughly 13 deploys per 30 days it crosses `minDeployments: 10` within about three weeks and blocks itself at 77%. Counting only id-bearing rows resets that to zero and buys the time to set thresholds from evidence instead of from one repository's current numbers.

The cost is real and worth stating: the signal reads `unknown` fleet-wide for weeks. It already does, so nothing is lost today, but it does mean this plan ships no observable behaviour change. Say so in the PR description.

## Global Constraints

- **Do not change `lowAbove`, `mediumAbove` or `minDeployments` in this plan.** They were chosen against a denominator that inflated volume and depressed the rate. Re-deriving them needs data that does not exist yet. Changing them now would be fitting numbers to `platform-agent`'s current figures, which is the thing to avoid.
- **Do not rewrite any existing `#deploy#` row.** The ledger is append-only. No delete-plus-put, and no `sk` rewrite.
- **Do not widen `deployHealth.environments`.** `report` is zapp's own weekly-report environment and `Tugboat` is ephemeral previews. Neither is a deployment of code, and `fantasia#Tugboat` rows already exist in the table to prove the exclusion is doing work.
- **Do not touch `combine()`, `maxRiskGrade`, or any gate.**
- **Human-facing strings follow the natural writing style.** Short sentences, plain words, no hype, no em-dash pivots, no hedging. The reader is a repo owner looking at a check run. `render.ts:503` currently says `"3 of 13 deploys failed (77% success) across prod, qa"`, which is the right register — match it.
- Conventional Commits (`commitlint` runs in CI). Run `pnpm test` before every commit.

## Sequencing

Independent. Touches `worker.ts`, `outcomes.ts`, `deploy-health.ts` and its tests. No overlap with PLAT-1319, which touches `internal-confidence.ts`.

---

- [ ] **Step 1: Verify the base and reproduce the finding**

```bash
cd ~/Projects/zapp
git fetch origin && git log --oneline -1 origin/main
grep -n "deployment_status?.state\|deployment?.environment\|deployment?.sha" src/entrypoints/worker/worker.ts
grep -n "deploymentSha\|deployRepo" src/pipeline/ledger/outcomes.ts
grep -n "minDeployments\|lowAbove\|mediumAbove" policy-rules.yaml
```

Expected: the worker reads `state`, `environment` and `sha` and no id. The row carries `deploymentSha` but no `deploymentId`.

Then confirm the two-objects-per-commit finding yourself:

```bash
gh api "repos/bankrate/platform-agent/deployments?environment=qa&per_page=10" \
  --jq '.[]|"id=\(.id) sha=\(.sha[0:8]) created=\(.created_at)"'
```

Expected: the same short sha appearing under two different ids. Then read both of `a058ea43`'s deployments' statuses and confirm one succeeded and one failed.

**If each sha has exactly one deployment object, stop.** The premise is wrong, the grouping buys nothing, and this plan needs rewriting.

- [ ] **Step 2: Record the deployment id**

Tests first.

In the worker's `handleDeploymentStatus` tests: a payload carrying `deployment.id` results in a `recordDeployment` call that includes it. A payload missing `deployment.id` still records the row — do **not** start dropping deployments over a missing field, because that would silently stop recording if GitHub's payload shape ever changes. Log a warning instead.

In the `recordDeployment` tests: the id reaches the item, and the `sk` is unchanged.

Then the code:

* `worker.ts` — read `payload?.deployment?.id` and pass it through. It is a number in GitHub's payload; store it as a string so the attribute type stays stable if GitHub ever widens it.
* `outcomes.ts` — add `deploymentId: { S: String(record.deploymentId) }` to the item, and add the field to the record type as optional so nothing else breaks.

Leave the `sk` alone. It is `outcome#${at}#deploy#${environment}` and changing it would rewrite what a row's identity means.

- [ ] **Step 3: Count one observation per deployment**

Tests first, in the deploy-health test file.

1. Six rows, three distinct `deploymentId`s, all terminal `success` → `observed: 3`, `succeeded: 3`.
2. Two rows for the same `deploymentId`, `success` then `failure` → **one** observation, and it takes the **later** state by `at`. A deployment object should only post one terminal status, but do not assume it.
3. Rows with **no** `deploymentId` → excluded entirely. `observed` counts only id-bearing rows. Assert with a mixed set: three id-bearing and ten without gives `observed: 3`, not 13.
4. All rows lack the id → `observed: 0`, which is below `minDeployments` → `unknown`. This is today's fleet and it must read `unknown`, not `low`.
5. `environments` in the returned value still echoes config, not whichever environments happened to have rows. Unchanged behaviour, worth a regression test since the grouping touches the same function.

Then the code. `queryDeployHealth` currently returns `{ state: string }[]`. It needs the id and the timestamp to group and order:

```ts
): Promise<{ state: string; deploymentId?: string; at: string }[]>
```

and in `deploymentHealth`, before counting:

```ts
// One observation per DEPLOYMENT, not per status. GitHub creates several
// Deployment objects per commit — platform-agent's a058ea43 has two, one
// that succeeded and one that failed — and each posts its own terminal
// status, so counting statuses counts the pipeline's shape rather than its
// outcomes.
//
// Rows without `deploymentId` predate that field and CANNOT be grouped, so
// they are not countable evidence and are dropped. That is also why there is
// no backfill: the id was never in those rows to recover.
```

Take the last row by `at` per `deploymentId`, then count.

- [ ] **Step 4: Docs, and say plainly that nothing changes yet**

- `docs/policy.md` — define the denominator as one terminal status per GitHub Deployment object, say that rows without the id are not counted, and say that `minDeployments` / `lowAbove` / `mediumAbove` are unchanged pending real data.
- `policy-rules.yaml` — leave the three numbers alone, but extend the `deployHealth` comment to record that the denominator changed and the thresholds have not been re-derived against it yet. The current comment cites `platform-agent`'s 7 deploys at 71%, which is now 13 at 77% and measured against the wrong unit. Correct that sentence rather than leaving a stale number in the file.
- In the PR description, state three things: the signal reads `unknown` fleet-wide after this and did before, so there is no observable change today; the pilot's failures are real and no threshold change is coming to hide them; and `minDeployments` / `lowAbove` / `mediumAbove` still need deriving once rows accumulate.
- Verify against a live deployment. Trigger or wait for one on an enrolled repo, then confirm the new row carries `deploymentId` and the signal still reads `unknown`. Reading the row back from DynamoDB is enough; do not force a deployment just for this.

- [ ] **Step 5: Leave the follow-up findable**

The thresholds are unfinished work and this plan deliberately does not do them. Before closing out, add a comment to PLAT-1318 recording:

* the denominator that shipped, and why
* that `platform-agent`'s failures are genuine, with the two deployment ids as evidence, so nobody re-opens the "better denominator will fix it" theory
* the count of id-bearing rows at merge time, as the baseline for when there is enough data to set thresholds
* that `minDeployments`, `lowAbove` and `mediumAbove` remain unset against the new unit

If PLAT-1318 is closed by this work rather than left open for the thresholds, file the threshold half as its own ticket instead. Do not let it live only in this plan.
