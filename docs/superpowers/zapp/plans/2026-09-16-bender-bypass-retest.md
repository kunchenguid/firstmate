# Re-test the bankrate-bender Ruleset Bypass

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Ticket:** [PLAT-1332](https://redventures.atlassian.net/browse/PLAT-1332)
**Closes if it passes:** [PLAT-1327](https://redventures.atlassian.net/browse/PLAT-1327) (the PAT expires 2026-12-01)
**Prior attempt:** `2026-09-16-app-bypass-instead-of-pat.md`, findings section — inconclusive, not negative

**The question, stated precisely:** when `bankrate-bender` (App ID `4797210`) is in a ruleset's `bypass_actors` and arms auto-merge on a pull request that has no code-owner approval, does GitHub complete the merge?

Nothing else. Not whether bender can merge directly (already proven yes), not whether the org ruleset applies (already proven no for this repo), not whether GitHub credits bender for auto-merges (already proven yes). Just this one thing.

## Why the last attempt failed to answer it

Two defects, both of which this plan designs around.

**Auto-merge is event-driven and a ruleset edit is not an event.** The bypass went to `always` at 13:56:02 UTC. The last event on PR #49 was 13:44:31 UTC. GitHub never re-evaluated, so `mergeStateStatus: BLOCKED` read afterward was a decision made before the bypass existed. Every read in this plan must follow a real pull-request event.

**A second blocker masked the first.** PR #49's head was behind `main`, and repo ruleset `20475255` sets `strict_required_status_checks_policy: true`. GitHub will not update a behind branch for an armed auto-merge, so the merge parks regardless of reviews. The test PR here is created fresh from `main` so it cannot be behind.

## Preconditions

All four must hold at the moment auto-merge is armed, or the result means nothing.

| # | precondition | how to confirm |
|---|---|---|
| 1 | test PR head is current with `main` | `compare/main...<branch>` shows `behind_by: 0` |
| 2 | `Integration:4797210` is in ruleset `20475255` bypass_actors | `GET rulesets/20475255` |
| 3 | `BankrateBot` is NOT a code owner on the changed path | `.github/CODEOWNERS` on `main` |
| 4 | required status checks are green on the head sha | `GET commits/<sha>/check-runs` |

Precondition 3 is the one that makes the test meaningful. With BankrateBot as a code owner, its approval satisfies the rule and the bypass is never consulted — that is a false pass.

## Repo under test

`bankrate/platform-cicd-v2-demo`. It carries `is_poc: true`, and org ruleset `15978123` excludes exactly that property, so **only repo ruleset `20475255` governs `main` here.** That is why the demo is the right place: one ruleset to reason about instead of two.

Confirm it, do not assume it:

```bash
gh api orgs/bankrate/rulesets/15978123 --jq '.conditions.repository_property.exclude'
gh api repos/bankrate/platform-cicd-v2-demo/properties/values \
  --jq 'map({(.property_name): .value})|add'
```

---

## Task 1 — Snapshot everything before touching it

- [ ] Create the snapshot directory and capture the ruleset, CODEOWNERS, and properties.

```bash
mkdir -p /tmp/bypass-retest && cd /tmp/bypass-retest
R=bankrate/platform-cicd-v2-demo
gh api repos/$R/rulesets/20475255 > ruleset-before.json
jq '{name,target,enforcement,conditions,rules,bypass_actors}' ruleset-before.json > ruleset-restore.json
gh api repos/$R/contents/.github/CODEOWNERS --jq '.content' | base64 -d > codeowners-before
gh api repos/$R/properties/values > properties-before.json
gh api repos/$R/git/ref/heads/main --jq '.object.sha' > main-sha-before
```

- [ ] Confirm `ruleset-restore.json` has exactly two bypass actors: `RepositoryRole:5:pull_request` and `Team:2966890:exempt`. If it has more, someone changed it since 2026-09-16 and this plan's restore step is wrong — stop and re-read.

**Verification:** `jq -c '.bypass_actors' ruleset-restore.json` prints those two and nothing else.

## Task 2 — Remove BankrateBot from CODEOWNERS

Precondition 3. Without this the test gives a false pass.

- [ ] Strip `@BankrateBot` from the six dependency-manifest lines, leaving `@bankrate/platform`. Keep those lines **last** in the file — CODEOWNERS resolves by last match. Never add `/.github/` to the bot's paths; that would make workflow changes bot-approvable.
- [ ] Land it via a pull request. GitHub refuses direct pushes to `main` here. Merge it with `PUT /pulls/{n}/merge`, which your `RepositoryRole:5:pull_request` bypass covers even at `mergeStateStatus: BLOCKED`.

**Verification:** `gh api repos/$R/contents/.github/CODEOWNERS --jq '.content' | base64 -d | grep BankrateBot` returns nothing.

## Task 3 — Create a test PR that cannot be behind main

- [ ] Branch from the **current** `main` sha, not a stale one.
- [ ] Change one dependency-manifest file so the CODEOWNERS rule is actually in play — a `package.json` devDependency patch bump is enough. Do not touch `pnpm-workspace.yaml` (see the pnpm classification gap; it classifies `unclassified` and zapp will not act on it).
- [ ] Open the PR.

**Verification:** `gh api repos/$R/compare/main...<branch> --jq '{behind_by,ahead_by}'` shows `behind_by: 0`.

## Task 4 — Add the bypass, then wait for checks

Order matters. The bypass must exist before auto-merge is armed.

- [ ] Add `Integration:4797210` at `bypass_mode: pull_request` to ruleset `20475255`, preserving the two existing actors.

```bash
jq '.bypass_actors += [{"actor_id":4797210,"actor_type":"Integration","bypass_mode":"pull_request"}]' \
  ruleset-restore.json > ruleset-pr-mode.json
gh api -X PUT repos/$R/rulesets/20475255 --input ruleset-pr-mode.json --jq '.bypass_actors'
```

- [ ] Wait for all three Cycode checks plus `Lint & Test` and `Build and scan image` to reach `success` on the head sha. Poll; do not guess.

**Verification:** ruleset shows three bypass actors; every required check is `success`.

## Task 5 — Arm auto-merge and read the result AFTER an event

This is the measurement.

- [ ] Arm auto-merge as bender. zapp does this itself on an enrolled repo — trigger it with a `recheck` label toggle rather than calling GraphQL by hand, so the test exercises the real code path (`actuator.ts:201`).
- [ ] Record the `auto_merge_enabled` timestamp from the PR timeline.
- [ ] Wait for a **real event after** that timestamp — a check completion, a push, or a review. If none is coming, force one with an empty commit to the head branch. A ruleset edit does not count.
- [ ] Only then read the state.

```bash
gh pr view <n> --repo $R --json mergeable,mergeStateStatus,reviewDecision,autoMergeRequest,state
gh api repos/$R/issues/<n>/timeline?per_page=100 \
  --jq '.[] | "\(.created_at // .submitted_at)\t\(.event)\t\(.actor.login // .user.login)"'
```

- [ ] Record the outcome. Merged means the bypass reaches the auto-merge path. Still `BLOCKED` with `reviewDecision: REVIEW_REQUIRED` after a post-arm event means it does not.

**Verification:** the timeline shows at least one event with a timestamp later than `auto_merge_enabled`, and the state was read after it. Write both timestamps down.

## Task 6 — If `pull_request` mode fails, repeat at `always`

- [ ] Change the bypass to `bypass_mode: always`.
- [ ] Force a real event on the PR — an empty commit is the reliable way. This is the exact step the last attempt skipped.
- [ ] Re-read the state as in Task 5.

**Verification:** an event timestamp later than the ruleset change timestamp. Without it the result is void, the same way the first attempt was.

## Task 7 — Restore and verify byte-for-byte

Do this whatever the outcome, including a pass. Shipping it beyond the demo is an org-wide change needing Chase's sign-off.

- [ ] Restore the ruleset.

```bash
gh api -X PUT repos/$R/rulesets/20475255 --input ruleset-restore.json
diff <(jq -S . ruleset-restore.json) \
     <(gh api repos/$R/rulesets/20475255 | jq -S '{name,target,enforcement,conditions,rules,bypass_actors}')
```

- [ ] Restore `.github/CODEOWNERS` from `codeowners-before` via a pull request.
- [ ] Close the test PR and delete its branch.
- [ ] Confirm repo properties are unchanged against `properties-before.json`.

**Verification:** both `diff`s are empty. An empty ruleset diff and a byte-identical CODEOWNERS are the only acceptable end state.

## Task 8 — Write the answer down

- [ ] Append a findings section to this file: yes or no, the API calls, and both timestamps proving the read followed an event.
- [ ] Update [PLAT-1332](https://redventures.atlassian.net/browse/PLAT-1332).
- [ ] On a pass, open the follow-up for removing `approver.ts` and the PAT, and note that the org-wide ruleset change needs Chase's sign-off. On a fail, open the two fallback tickets described on PLAT-1332.

---

## Traps

Each of these produced a wrong answer once already, or would have.

**Reading state after a ruleset edit.** A ruleset edit is invisible to an armed auto-merge. Always force a pull-request event first.

**A behind branch under `strict: true`.** Parks the merge on its own and looks exactly like a bypass failure. Check `behind_by: 0`.

**Leaving BankrateBot as a code owner.** Its approval satisfies the rule, the bypass is never consulted, and the test passes for the wrong reason.

**Testing on a repo the org ruleset governs.** Two rulesets means a bypass on one still leaves the other blocking. The demo's `is_poc: true` is what avoids this — verify the property is still set.

**`gh api --jq` with `--arg`.** Silently returns nothing. Use a shell variable inside the jq string instead.

**zsh does not word-split unquoted `$var`.** `for s in $shas` iterates once over the whole blob. Put loops in a bash script file.

**Assuming auto-merge and a merge call authorize the same way.** bender holds `pull_requests: write` and no `contents: write`, yet gets credited with merges. GitHub does privileged work on its behalf. That is the whole reason this question is empirical instead of readable from the docs.
