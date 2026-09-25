# internalConfidence Abstains Without Evidence

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `internalConfidence` grades `high` when no other enrolled repo has taken a package version. That is absence of data being reported as evidence of risk, and it blocks every bump the moment the fleet crosses `minFleetForConfidence`. Make the signal abstain unless it has real evidence, so the floor stops being the only thing keeping the fleet unblocked.

**Ticket:** [PLAT-1319](https://redventures.atlassian.net/browse/PLAT-1319)

**Decision, made 2026-09-16:** grade `unknown` at 0 and at 1–2 corroborating repos. Keep `low` at 3+.

**Architecture:** One line in `internal-confidence.ts`, one branch in `render.ts`, one number in `policy-rules.yaml`. No new modules, no new fetches, no schema change.

## Why the ticket's own recommendation was not enough

The ticket recommended `unknown` at zero and keeping `medium` at 1–2. Measured against the real corroboration corpus on 2026-09-16, that does not clear the cliff.

42 `#pkg#` rows, 32 distinct `package@version` keys:

| corroborating repos | keys | grade under the ticket's proposal |
|---|---|---|
| 3+ | **1** | `low` |
| 1–2 | **31** | `medium` |
| 0 (not in the corpus at all) | every other bump | `unknown` |

`maxRiskGrade` is `low` and `combine()` is worst-known-wins, so **`medium` blocks just as hard as `high`**. Keeping `medium` at 1–2 would move the cliff from "not in the corpus" to "in the corpus with one or two repos", and 31 of the 32 known keys sit in that band. Nearly everything would still block.

Hence `unknown` at 1–2 as well. The signal speaks when three repos have taken a version and abstains otherwise.

## Why abstaining is safe

Abstaining is what every other signal already does with missing input. `semverDistance` returns `unknown` with no bumps. `publishAge` returns `unknown` with no publish date. `scanFindings` returns `unknown` when a scanner has not reported. `combine()` ignores `unknown` by design.

And the compensating controls are already there. Eighteen gates run first. `shouldApprove` requires `minSignalsGraded: 4`, so a pull request cannot be approved on thin evidence just because one signal went quiet. The actuator needs both an acting enrollment mode and a place on the allowlist.

What this does give up: the signal stops saying "nobody in this org has proven this version." That claim is worth having, and it is not lost — it still renders in the check output. It just stops setting the grade on no data.

## One more thing the numbers expose

`internal-confidence.ts:144` excludes the current repository from its own corroboration, which is correct. But combined with the corpus above it has a sharp edge: for the 28 keys corroborated by exactly one repo, that one repo gets its own row dropped and reads zero. The repo that established the corroboration is the one repo that never benefits from it.

That is out of scope here and the exclusion should stay. Worth knowing, because it explains why the corpus looks better than it behaves.

## Global Constraints

- **Do not touch `combine()`, `maxRiskGrade`, or any gate.** This is one signal's grade function.
- **Do not change the self-exclusion at `:144`.** A repo vouching for itself is not corroboration.
- **Keep weakest-link.** `:172` takes the minimum across a grouped pull request's packages, and that is right — one unproven package in a group is the exposure. It does mean a grouped PR abstains whenever any one package is thin, which is the common shape. That is the intended behaviour, not a bug to route around.
- **Human-facing strings follow the natural writing style.** Short sentences, plain words, no marketing tone, no em-dash pivots, no hedging. The reader is a repo owner looking at a check run, not a reviewer of this plan. Write what is true and stop.
- Conventional Commits (`commitlint` runs in CI). Run `pnpm test` before every commit.

## Sequencing

Independent of everything currently open. Touches `internal-confidence.ts`, `render.ts` and `policy-rules.yaml`. No overlap with PLAT-1318, which touches `deploy-health.ts` and the worker.

---

- [ ] **Step 1: Verify the base and the corpus**

```bash
cd ~/Projects/zapp
git fetch origin && git log --oneline -1 origin/main
grep -n "weakest.repos >= 3" src/pipeline/03-risk/signals/internal-confidence.ts
grep -n "minFleetForConfidence" policy-rules.yaml
```

Expected: the grade line reads `weakest.repos >= 3 ? CLEAN : weakest.repos >= 1 ? 'medium' : 'high'`, and `minFleetForConfidence: 50`.

Then measure the corroboration corpus yourself. Scan `zapp-evaluations` in the QA account, take the rows whose `sk` contains `#pkg#`, group by `pkgVersion`, and count distinct `repo` per key.

Expected roughly: 42 rows, 32 keys, 1 key with 3+ repos, 31 with 1–2.

**If more than a handful of keys have 3+ repos, stop and say so.** The decision to abstain at 1–2 rests on almost nothing being corroborated three times yet. If that has changed, the trade-off has changed with it.

- [ ] **Step 2: The grade**

Tests first, in the existing internal-confidence test file. Read what is there before writing and do not duplicate it.

1. `weakest.repos === 0` → `unknown`, and the reason names the package and version.
2. `weakest.repos === 1` → **`unknown`**.
3. `weakest.repos === 2` → **`unknown`**.
4. `weakest.repos === 3` → `low`.
5. `weakest.repos === 7` → `low`.
6. A grouped pull request where one package has 0 repos and the others have 5 → **`unknown`**, because weakest-link. Name this test after the behaviour, because it is the path that actually bites and the next reader will assume it averages.
7. The fleet-size short circuit still fires first when the fleet is under the floor. Unchanged.

Then the code:

```ts
// `unknown`, not `medium`, below three repos. `combine()` is worst-KNOWN-wins
// against `maxRiskGrade: low`, so `medium` blocks exactly as hard as `high`
// does — and measured 2026-09-16, 31 of the 32 corroborated package versions
// in the ledger had only one or two repos. Grading those `medium` would keep
// nearly every bump blocked, which is the cliff this change exists to remove.
// Abstaining is what every other signal does with too little input, and
// `minSignalsGraded` already stops a thin grade from approving anything.
const grade = weakest.repos >= 3 ? CLEAN : 'unknown';
```

Check how `unknown` is constructed elsewhere in this file. There is an `unknownSignal(reason)` helper and it carries a reason string; the early returns use it. Decide whether this path should return `unknownSignal` with a reason or a graded shape with `grade: 'unknown'` and keep `value.weakest` — the render branch at `render.ts:491` reads `value.weakest`, so **if you drop the value, the check output loses the package name.** Keep the value.

- [ ] **Step 3: The message**

`render.ts:498-500` already says the right thing for zero:

> `` `pkg@1.2.3` — no other enrolled repo has taken this ``

and for non-zero:

> `` `pkg@1.2.3` — 2 other repos ``

Both are fine as written. What changes is that 1–2 repos now abstains, so the row shows `unknown` beside a sentence that reports two repos. That reads as a contradiction unless the sentence says why it is not enough.

Add the threshold to the non-zero branch so the two halves agree. Something like:

> `` `pkg@1.2.3` — 2 other repos have taken this, and 3 are needed to grade it ``

Keep it one clause. Do not explain the reasoning in the check run; that belongs in `docs/policy.md`.

Tests in `tests/render.test.ts` for both branches. Assert the singular and plural forms.

- [ ] **Step 4: `minFleetForConfidence` stops being load-bearing**

The floor exists only because the signal used to block on no data. It does not any more, so it can go back to something honest.

The floor's real job now is the one its comment already describes: with one enrolled repository, "nobody else has taken this" means nothing because there is nobody else. That argument needs a small number, not 50.

Set it to **5** and rewrite the comment to say what it is for. Then record in the PR description that the raises to 30 and to 50 are no longer doing anything, and that this is why.

Leave both raises in the git history. This plan makes them unnecessary; it does not pretend they were wrong at the time.

- [ ] **Step 5: Docs, and measure the effect**

- `docs/policy.md` — state that `internalConfidence` grades `low` at three or more corroborating repos and abstains below that, and why abstaining rather than grading `medium`. Mention that a repo cannot corroborate itself, since that surprises people.
- Re-run the fleet's open bot pull requests and record how many change grade. Expect very few today, because the fleet is 29 and the floor was 50, so the signal was already quiet. **That is the point, and the PR description has to say it plainly:** this change has almost no effect today and removes a cliff that would otherwise hit the moment enrolment crossed 50.
- Verify against a live pull request. Toggle a non-blocking label to force a re-evaluation, read the `merge-policy/risk` check output, and confirm the "Taken elsewhere" row shows `unknown` with a sentence that explains the threshold. Remove the label afterwards.
