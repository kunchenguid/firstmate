# portkey: Upload Coverage Even When Lint Fails — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Get `codecov/project` from 12/15 to 15/15 on `bankrate/portkey` so gate 11 (`ciBaselineMet`) stops failing on it.

**Architecture:** One job, one file. `Lint & Test` runs Lint → Type check → Test with coverage → Upload as sequential steps, so a **lint** failure short-circuits the job and coverage never runs. Adding `if: always()` to the steps after `Install dependencies` lets coverage run and upload regardless of lint, while the job still fails if any step fails.

**Repo:** `bankrate/portkey`, `.github/workflows/pr.yml`

**Related:** `bankrate-ci-baseline` skill. Terraform is deliberately out of scope — [PLAT-1313](https://redventures.atlassian.net/browse/PLAT-1313).

## Global Constraints

- **Do not restyle the codecov step.** It already works — that is why 12 of 15 PRs have the check. Change only what is needed. In particular **leave `token:` under `with:`**; moving it to `env:` is a fleet-convention preference that turns a working step into a red PR for no gate benefit.
- **The coverage file is `coverage/lcov.info`.** `vitest.config.mts` sets `reporter: ["text", "lcovonly"]` and `reportsDirectory: "./coverage"`. There is **no** `coverage-final.json` — the `bankrate-ci-baseline` snippet's `files: ./coverage/coverage-final.json` is wrong for this repo and would upload nothing.
- **Keep the job named `Lint & Test`.** Splitting it into separate `lint` and `test` jobs would change check-run names and may break branch protection. Not worth it here.
- **Match existing action pins.** This file pins SHAs with version comments (`checkout` v7.0.1, `codecov-action` v7.0.0). Do not introduce a bare tag.
- **No `paths:` filters, ever.** A workflow that does not trigger produces no check run, which is an instant `conditional`.
- Conventional commit, **Jira key in the subject, never as the scope**. portkey has no `commitlint.config.js`, so scope-case is not enforced here — but keep the convention.

---

### Task 1: Let coverage run and upload regardless of lint

**Files:**
- Modify: `.github/workflows/pr.yml` (the `ci` job, lines 32-46)

- [ ] **Step 1: Confirm the diagnosis still holds**

```bash
cd ~/Projects && for pr in 113 108 104; do
  sha=$(gh pr view $pr --repo bankrate/portkey --json headRefOid --jq '.headRefOid')
  rid=$(gh api "repos/bankrate/portkey/actions/runs?head_sha=$sha" --jq '[.workflow_runs[]|select(.name=="PR Checks")][0].id')
  gh api "repos/bankrate/portkey/actions/runs/$rid/jobs" \
    --jq '.jobs[]|select(.name=="Lint & Test")|"#'"$pr"'  " + ([.steps[]|"\(.name)=\(.conclusion)"]|join("  "))'
done
```

Expected on all three: `Lint=failure`, then `Type check=skipped`, `Test with coverage=skipped`, `Upload coverage to Codecov=skipped`.

**That skipped `Test with coverage` is the whole point.** If the failures were in `Test with coverage` instead, `if: always()` on the upload alone would fix it, because vitest writes its report before exiting non-zero. They are not — so the fix has to be further up the job.

- [ ] **Step 2: Verify the coverage path before touching the upload**

```bash
cd /tmp && rm -rf portkey-cov && gh repo clone bankrate/portkey portkey-cov -- --depth 1 && cd portkey-cov
pnpm install --frozen-lockfile
pnpm test:coverage || true          # may fail; we only care what it wrote
ls -la coverage/
```

Expected: `coverage/lcov.info` exists. **No `coverage-final.json`** — `vitest.config.mts` sets `reporter: ["text", "lcovonly"]`.

If the filename differs from `lcov.info`, use what is actually on disk. Guessing this is the single most common way this change ships red.

- [ ] **Step 3: Make the change**

In `.github/workflows/pr.yml`, replace lines 32-46 with:

```yaml
      # `if: always()` on each of these so a failure in one does not skip the
      # rest. Lint failed on PRs #104, #108 and #113, which skipped `Test with
      # coverage` entirely — so no coverage report was produced and
      # `codecov/project` never appeared. That put the check at 12/15, which
      # merge-policy reads as `conditional` and cannot be waived.
      #
      # The job still fails when any step fails; these only stop one failure
      # from hiding the others.
      - name: Lint
        if: always()
        run: pnpm lint

      - name: Type check
        if: always()
        run: pnpm build

      - name: Test with coverage
        if: always()
        run: pnpm test:coverage

      - name: Upload coverage to Codecov
        if: always()
        uses: codecov/codecov-action@fb8b3582c8e4def4969c97caa2f19720cb33a72f # v7.0.0
        with:
          token: ${{ secrets.CODECOV_TOKEN }}
          url: https://codecov.core.bankrate.com
          flags: unit
          # vitest.config.mts uses reporter: ["text", "lcovonly"], so the
          # artifact is lcov.info — there is no coverage-final.json here.
          files: ./coverage/lcov.info
          disable_search: true
          # Default is false, which reports success on a failed upload — the
          # exact failure mode that lets a missing check go unnoticed.
          fail_ci_if_error: true
```

Leave everything above `Lint` untouched, and leave the `image-scan` job alone — it is already 15/15.

- [ ] **Step 4: Lint the workflow**

```bash
actionlint .github/workflows/pr.yml
```

Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/pr.yml
git commit -m "ci: upload coverage even when lint fails (PLAT-1313)

Lint, type check and test ran as sequential steps, so a lint failure skipped
Test with coverage and no coverage report was produced. codecov/project was
therefore absent on 3 of the last 15 PRs, which merge-policy gate 11 reads as
conditional -- and conditional cannot be waived."
```

Use whichever project prefix portkey's own merged PRs use — check with
`gh pr list --repo bankrate/portkey --state merged --limit 20`. If portkey tickets
are not `PLAT`, use the repo's own project.

---

### Task 2: Prove it with a deliberate lint failure

The fix is only worth anything if coverage uploads when lint is red. Do not wait
15 PRs to find out.

- [ ] **Step 1: Open the PR with a deliberate lint error**

On the same branch as Task 1, add a file that fails `pnpm lint` but does not
break the build or tests — e.g. an unused variable in a scratch file under a
linted path.

```bash
cat > app/_codecov-probe.ts <<'EOF'
// TEMPORARY: proves the coverage upload survives a lint failure. Removed
// before merge.
const unusedOnPurpose = 1;
EOF
git add app/_codecov-probe.ts && git commit -m "ci: temporary lint failure to verify the coverage upload"
git push
```

- [ ] **Step 2: Confirm the outcome on that PR**

```bash
PR=<number>; SHA=$(gh pr view $PR --repo bankrate/portkey --json headRefOid --jq '.headRefOid')
gh api "repos/bankrate/portkey/commits/$SHA/check-runs" --jq '.check_runs[]|"\(.conclusion // .status)  \(.name)"' | sort
```

Expected, and **both halves matter**:

- `Lint & Test` → **failure** (lint is genuinely broken; the job must still fail)
- `codecov/project` → **present** (this is the fix working)

If `codecov/project` is still absent, the upload ran with nothing to upload —
re-check Step 2 of Task 1 for the real coverage path.

- [ ] **Step 3: Remove the probe and confirm green**

```bash
git rm app/_codecov-probe.ts && git commit -m "ci: remove the temporary lint failure" && git push
```

Expected: `Lint & Test` success, `codecov/project` present. Then merge.

**This PR touches `.github/**`, which every merge-policy change class denies — it
cannot be auto-merged and needs a human approval.** Do not wait for automation.

---

### Task 3: Report the ramp and what is still blocking

- [ ] **Step 1: Re-read the gate's own sample**

```bash
cd ~/Projects && gh api graphql -f owner=bankrate -f name=portkey -F prs=15 -f query='
query($owner:String!,$name:String!,$prs:Int!){repository(owner:$owner,name:$name){
  pullRequests(first:$prs,orderBy:{field:CREATED_AT,direction:DESC}){nodes{number
    commits(last:1){nodes{commit{checkSuites(first:20){nodes{checkRuns(first:100){nodes{name}}}}}}}}}}}' \
  --jq '[.data.repository.pullRequests.nodes[]|{n:.number,
    checks:[.commits.nodes[0].commit.checkSuites.nodes[].checkRuns.nodes[].name]|unique}]
    |{sampled:length, produced:(map(.checks)|flatten|group_by(.)|map({key:.[0],value:length})|from_entries)}'
```

- [ ] **Step 2: State the ramp honestly**

`codecov/project` will **not** read 15/15 immediately. The three PRs without it
(#104, #108, #113) cannot gain the check retroactively; they have to age out of
the 15-PR window. #113 is the newest of them, so roughly **12 more PRs** must be
opened before the window clears — fewer than a fresh ramp, because 12 of 15
already have it.

- [ ] **Step 3: Say what this does NOT fix**

Gate 11 clearing is not eligibility. After this lands, portkey still fails:

| Gate | Status | Owner |
|---|---|---|
| `ciBaselineMet` | `Terraform plan (speculative)` still 0/15 | [PLAT-1313](https://redventures.atlassian.net/browse/PLAT-1313) — fleet TFC migration, or a waiver plus a matching per-repo `blockingChecks` override |
| `checksGreen` | same check, same cause | same |
| `coverageFloor` | **5.28% against a 60% floor** | portkey team — dispatch C, weeks of work |
| `classificationPermits` | `dep-minor` on a `prod-service` repo | policy: `dep-minor` gains `prod-service` in zapp's `policy-rules.yaml` |

`resiliencyTierPermits` is **no longer** a blocker — `resiliency_tier = Silver`
is now set, though the 2026-09-09 check run still shows it failing.

Put this table in the PR body. A reviewer who reads a green gate 11 as
"portkey can auto-merge now" will be wrong by four gates.

---

## Self-review notes

**Why this is not the skill's stock fix.** `bankrate-ci-baseline` prescribes `if: always()` on the *upload* step, which assumes the failing step is the test — vitest writes its report before exiting, so the upload still has something to send. portkey's failures were all **`Lint=failure`**, which skipped `Test with coverage` outright. The stock fix would have uploaded nothing and left the check absent. Verified against runs 34375134900, 33173594792 and 32911353759.

**Why not split the job.** Separate `lint` and `test` jobs would be faster and cleaner, but it renames check runs and may break branch protection. Not worth the risk for this gate.

**Why `files:` is explicit.** `vitest.config.mts` sets `reporter: ["text", "lcovonly"]`, so the artifact is `coverage/lcov.info`. The skill's snippet names `coverage-final.json`, which does not exist in this repo — the one thing in this plan most likely to be copied wrong.

**One thing I could not pre-verify.** Whether `codecov/project` appears when the *upload succeeds but coverage is empty or unparseable*. Task 2's probe answers it empirically on a real PR, which is why that task exists rather than being folded into Task 1.
