# Replace the Approval PAT With an App Bypass

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** zapp approves pull requests as `BankrateBot`, a user account with a personal access token, because a GitHub App cannot be a code owner. Find out whether adding `bankrate-bender` to a ruleset's bypass list removes the need for the approval entirely. If it does, the PAT goes away, roughly 25 `CODEOWNERS` edits go away, and zapp drops from three identities to two.

**This is an experiment, not a migration.** It runs on `bankrate/platform-cicd-v2-demo` and every step is reversible. The org-wide change is the last task and needs Chase's sign-off before it happens.

**Context:** Slack thread with Chase Coney, 2026-09-16. His position: everything that can be a GitHub App should be a GitHub App, and the repo-specific rulesets are near-duplicates of the org one that could just be deleted. **Related:** [PLAT-1327](https://redventures.atlassian.net/browse/PLAT-1327) (the PAT expires 2026-12-01) closes if this works.

## Why the obvious version of this test gives a false pass

`platform-cicd-v2-demo` has the custom property **`is_poc: true`**, and the org ruleset `All Repos - Default Branch Policy` (15978123) excludes exactly that property:

```json
"repository_property": { "exclude": [{ "name": "is_poc", "property_values": ["true"], "source": "custom" }] }
```

Confirmed by asking GitHub which rulesets apply to the repo. Only two do: `No Public Repos` (org) and `Default Branch Protection` (repo, 20475255). **The org default-branch policy does not apply to this repo at all.**

So "delete the repo ruleset and see if the pull request merges" would pass for the wrong reason. With the repo ruleset gone and `is_poc: true` still set, the repo has no `pull_request` rule and no `required_status_checks`. Anything would merge. That proves nothing about the App bypass and nothing about whether the org ruleset is sufficient.

The two questions have to be separated, and they need opposite `is_poc` states. Hence Tasks 2 and 3.

## What the rulesets actually differ on

Measured 2026-09-16. Chase's read that they are near-identical is right, and three differences matter.

| | org 15978123 | repo 20475255 |
|---|---|---|
| `strict_required_status_checks_policy` | **false** | **true** |
| `dismiss_stale_reviews_on_push` | **false** | **true** |
| `do_not_enforce_on_create` | true | false |
| required contexts | the 3 Cycode checks, **pinned to integration 39308** | the same 3, unpinned |
| `deletion` rule | **present** | absent |
| `non_fast_forward` rule | **present** | absent |

**The repo ruleset is the cause of the auto-merge parking problem.** `strict: true` requires the head branch to be up to date, GitHub does not auto-update a behind branch, so an armed auto-merge waits forever. That was measured and then seen in production on `platform-agent#35`, which sat approved and armed until a human updated the branch. The org ruleset has `strict: false`.

`dismiss_stale_reviews_on_push: true` is a second parking source — it discards the bot's approval every time Dependabot rebases.

So the org ruleset is **strictly better for auto-merge**, and it additionally protects against branch deletion and non-fast-forward pushes, which the repo one does not. Deleting repo rulesets is an improvement rather than a tidy-up. Say that in the thread; it strengthens Chase's case for his stronger option.

## Global Constraints

- **Record the current state before changing anything, and keep the exports.** Task 1 exists for this. A ruleset cannot be un-deleted; it has to be recreated from its JSON.
- **Do not touch the org ruleset until Task 5**, and not without Chase's explicit agreement. A bypass actor on 15978123 affects every repository in the org.
- **Bypass is per-ruleset, not per-rule.** The bypassed actor skips `required_status_checks` too, not only `pull_request`. That is the real trade in this plan and Task 4 exists to test what still holds it back.
- **Do not set `is_poc: true` on a real repository to dodge a review requirement.** It is being changed on a demo repo here to make the org ruleset apply, which is the opposite direction.
- **Do not delete `No Public Repos` (19979700) or touch the SOC2 rulesets.** Out of scope. The demo repo is `is_soc2_compliant: false` so they do not apply to it anyway.
- **Every task ends in a reversible state.** If a task fails, stop and restore from Task 1's exports rather than pressing on.
- Report findings in the natural writing style: short sentences, plain words, what happened and what it means. This feeds a Slack thread, not a document.

---

- [ ] **Task 1: Record and export everything first**

Nothing here changes state. Do it anyway — Task 3 deletes a ruleset that can only be restored from its own JSON.

```bash
mkdir -p /tmp/ruleset-experiment && cd /tmp/ruleset-experiment
gh api "orgs/bankrate/rulesets/15978123" > org-15978123.json
gh api "repos/bankrate/platform-cicd-v2-demo/rulesets/20475255" > repo-20475255.json
gh api "repos/bankrate/platform-cicd-v2-demo/rulesets" > applied-before.json
gh api "repos/bankrate/platform-cicd-v2-demo/properties/values" > properties-before.json
gh api "repos/bankrate/platform-cicd-v2-demo/contents/.github/CODEOWNERS" --jq .content | base64 -d > codeowners-before
```

Then find `bankrate-bender`'s id for a ruleset bypass actor. Its **app id** is `4797210` and its installation is `158320327`, but a ruleset `bypass_actors` entry of `actor_type: Integration` may want a different identifier — note that `required_status_checks` above references Cycode as `integration_id: 39308`, which is not an app id.

**Confirm which number GitHub wants before Task 2.** Try the App's id from `GET /app` using the App's own JWT, or read an existing ruleset elsewhere in the org that already has an Integration bypass actor and copy the shape. **Do not guess** — a wrong actor id will either be rejected or silently grant bypass to something else.

- [ ] **Task 2: Does an Integration bypass actor work at all?**

This is the question everything else depends on. Run it while `is_poc` is still `true`, so the repo ruleset is the only thing enforcing and the result is unambiguous.

1. Add `bankrate-bender` to ruleset `20475255`'s `bypass_actors` as `actor_type: Integration`. Start with `bypass_mode: pull_request` rather than `always` — it is the narrower of the two and enough for a merge.
2. Remove the `@BankrateBot` lines from the repo's `CODEOWNERS`. Leave the `@bankrate/platform` lines alone. **Keep `/.github/` owned by the team only** — never grant the bot or the App that path, because it makes workflow changes self-approvable.
3. Put the repo in `mode: auto-merge` if it is not already, and confirm it is in `rules.autoMergeRepos`. It is already in the allowlist; check the enrollment record's `mode` in the `zapp-enrollments` table.
4. Take a Dependabot pull request that currently reads `candidate` and force a re-evaluation by toggling a non-blocking label. Watch whether `bankrate-bender` merges it with no approving review present.

**Record which actor GitHub evaluated.** That is the unknown. `bankrate-bender` performs the merge but `enablePullRequestAutoMerge` is a separate call, and it is not documented whether the rule is checked against the merging actor or the enabling one. If the merge is blocked, that answers it and Tasks 3 to 5 are moot in their current form.

If it does not merge, **stop and report**. Do not start adding BankrateBot to the `ci-bot` team as a fallback — teams hold users, not Apps, so that is a different experiment with a different conclusion.

- [ ] **Task 3: Is the org ruleset sufficient on its own?**

Only if Task 2 worked. This tests Chase's stronger option — delete repo rulesets rather than maintaining a bypass list on each.

1. **Clear `is_poc` on the demo repo** (set it to `false` or remove the value). This is the step that makes the org ruleset apply, and skipping it is what produces the false pass described above.
2. Confirm the change took: `gh api repos/bankrate/platform-cicd-v2-demo/rulesets` must now list `All Repos - Default Branch Policy` (15978123).
3. **Delete repo ruleset 20475255.** You have its JSON from Task 1.
4. Re-list the applied rulesets and confirm what is left: `No Public Repos`, and the org default-branch policy.

Then verify the org ruleset is genuinely enforcing rather than silently absent. Open a throwaway pull request, confirm it **cannot** be merged without a code-owner approval, and confirm the three Cycode checks are required. That is the control — if an unapproved PR merges here, the org ruleset is not applying and the rest of this task's conclusions are worthless.

Note what improves as a side effect: `strict: false` and `dismiss_stale_reviews_on_push: false` should end the armed-but-parked behaviour. Check whether any previously parked pull request on this repo becomes mergeable.

- [ ] **Task 4: What still stops a bad merge?**

The part nobody would think to test, and the one a reviewer will ask about.

Bypass skips the whole ruleset, so `required_status_checks` is bypassed along with `pull_request`. GitHub will no longer refuse to merge a pull request with failing CI. The only thing left is zapp's gate 12.

Prove gate 12 holds the line:

1. Find or create a Dependabot pull request on the demo repo with a **failing** required check — a red `Cycode: SAST`, or deliberately break one.
2. Force a re-evaluation.
3. Confirm zapp reads `checksGreen` as failed, does **not** approve, and does **not** merge.
4. Confirm GitHub would have allowed it, by checking that the ruleset no longer blocks the merge for a bypass actor.

**Write down which guarantee moved from structural to behavioural.** Before this change, GitHub physically prevented a red merge. After it, only zapp's own code does. That is a real reduction in defence depth and it belongs in the thread and on PLAT-1327, not buried in a plan.

If gate 12 does **not** hold, stop immediately and restore from Task 1. That would mean the bypass removes the last guard.

- [ ] **Task 5: The org-wide change — needs Chase's sign-off**

Do not start this without an explicit yes in the thread.

Adding `bankrate-bender` to org ruleset 15978123's bypass list affects every repository in the org. The upside is that the ~25 `CODEOWNERS` edits the top-25 rollout would otherwise need disappear, along with the PAT.

1. Report Tasks 2 to 4 in the thread first: whether the bypass works, which actor is evaluated, whether the org ruleset is sufficient alone, and what Task 4 found about gate 12.
2. Get agreement on the status-checks trade explicitly. It is the one thing being given up and it should be a decision on the record.
3. Then add the bypass actor, and verify on `platform-agent` — which has no `is_poc`, so both rulesets apply to it today and it is the honest test of the org-wide path.
4. Only after that is proven, decide whether repo rulesets get deleted fleet-wide or just get the App added. Chase leans toward deleting; the measured differences above support him.

- [ ] **Task 6: Close the loop, or restore**

If it worked:

- Comment on **PLAT-1327** with the result. If the PAT is no longer needed, close it and say so — do not leave a rotation deadline live for a credential nothing uses.
- Record the actor-evaluation answer somewhere durable. It is undocumented GitHub behaviour that cost an experiment to learn, and the next person will need it.
- Note that `strict: true` on repo rulesets was a parking cause, and check whether **PLAT-1192** (the required-checks sweep) is still needed once it is gone.
- Update the `CODEOWNERS` guidance for the rollout. If no bot entry is needed, the per-repo work for the top 25 shrinks a lot.

If it did not:

- Restore `is_poc`, recreate ruleset 20475255 from `repo-20475255.json`, and put the `@BankrateBot` lines back in `CODEOWNERS` **at the end of the file** — CODEOWNERS resolves by last match, and an earlier `/.github/` line otherwise wins for `dependabot.yml`. List both `.yml` and `.yaml`.
- Verify the restore by merging nothing: confirm an unapproved Dependabot PR is blocked again.
- Report what failed and why. PLAT-1327 stands, and the PAT still needs rotating before 2026-12-01.

---

# Findings — 2026-09-16

**Verdict: inconclusive, not negative.** An earlier reading of this experiment
called it a clean negative. That reading was wrong. Double-checking it found two
problems with the test itself, so the question the experiment was built to answer
is still open.

Everything changed on `platform-cicd-v2-demo` has been restored and verified.

## What the experiment actually established

These are measured, not inferred.

**1. The org ruleset never applied to the test repo.** `platform-cicd-v2-demo`
carries `is_poc: true`, and org ruleset 15978123 has that exact property in its
`repository_property.exclude` list. Only repo ruleset 20475255 governs `main`
here. So Chase's instinct that the org ruleset was the blocker is wrong for this
repo, and the plan's own warning about a false pass held up.

```
$ gh api orgs/bankrate/rulesets/15978123 --jq '.conditions.repository_property.exclude'
[{"name":"is_poc","property_values":["true"],"source":"custom"}]
```

**2. zapp has exactly one way to merge and exactly one way to approve.**

| | call | identity |
|---|---|---|
| approve | `POST /repos/{r}/pulls/{n}/reviews` `{event: APPROVE}` — `src/pipeline/05-actuate/approver.ts:67` | `BankrateBot`, PAT |
| merge | GraphQL `enablePullRequestAutoMerge` — `src/pipeline/05-actuate/actuator.ts:201` | `bankrate-bender` App |

There is no merge-endpoint call anywhere in `src/`. zapp arms auto-merge and
GitHub finishes the job later.

**3. GitHub credits an armed auto-merge to the App that armed it.** This is the
finding that killed the earlier conclusion. On `platform-cicd-v2-demo#63` and
`#62`, `merged_by` is `bankrate-bender[bot]` and the timeline's `merged` event
names bender too. The claim that "GitHub merges as itself, so the App's bypass
never applies" is not supported.

**4. bender cannot merge directly today.** Its installation permissions are
exactly `metadata: read` and `pull_requests: write` (`README.md:255`). A
`PUT /pulls/{n}/merge` needs `contents: write`. Note what that combination
means: bender arms auto-merge and gets credited with the merge while holding no
write access to repository contents. GitHub is doing privileged work on bender's
behalf, which is why the attribution question above is not the same as the
authorization question.

**5. A direct merge call IS evaluated against the caller's bypass.** Confirmed
twice, on `#66` and `#67`. Both were `mergeable: MERGEABLE`,
`mergeStateStatus: BLOCKED`, `reviewDecision: REVIEW_REQUIRED`, and both merged
on a `PUT /pulls/{n}/merge` because of a `RepositoryRole:5:pull_request` bypass.
So bypasses do work on the merge path. The open question is only whether they
reach the auto-merge path.

## Why the result is inconclusive

**The `always` state was never exercised.** Bypass mode went to `always` at
13:56:02 UTC. The last event on PR #49 was 13:44:31 UTC. Nothing touched the PR
after the ruleset changed.

```
ruleset 20475255 history       PR #49 timeline
13:17:46  Integration:pull_request   13:43:37  auto_merge_enabled (bender)
                                     13:43:39  reviewed APPROVED (BankrateBot)
                                     13:44:31  unlabeled (recheck toggle)
13:56:02  Integration:always         (nothing)
14:47:59  restored
```

Auto-merge is event-driven. A ruleset edit is not an event on the pull request,
so GitHub had no reason to re-evaluate. Reading `mergeStateStatus: BLOCKED`
afterward measured a stale decision.

**The window that WAS exercised had a second blocker.** During the
`pull_request`-mode window, PR #49's head branch was behind `main`. Repo ruleset
20475255 sets `strict_required_status_checks_policy: true`, and GitHub does not
bring a behind branch up to date for an armed auto-merge. That parks the merge
on its own, with or without a review bypass. So the one real observation cannot
distinguish "the bypass didn't apply" from "the branch was behind."

A note in the working record claimed the branch was current. It was not.

## What a clean re-test needs

1. A pull request whose head is **current with `main`**, or `strict` switched off
   for the duration.
2. The bypass in place **before** auto-merge is armed.
3. `BankrateBot` not a code owner, so reviews are the only remaining blocker.
4. A real trigger **after** the last ruleset change — a push, a check completion,
   or a review event. Not a ruleset edit.
5. Read `mergeStateStatus` only after that trigger.

Cost is roughly fifteen minutes and one throwaway PR on the demo repo.

## The three routes off the PAT, ranked

**A. Ruleset bypass for bender.** Best outcome if it works: no new permissions,
no policy relaxed, no code change in zapp. Status: unproven, needs the re-test
above.

**B. Drop `require_code_owner_review` and let bender approve.** bender already
holds `pull_requests: write`, which is the permission needed to submit an
approving review. No PAT, no bypass, no new grant. Two problems. The code-owner
requirement lives on the ruleset, not on a path, so dropping it drops it for
everything landing on `main`. And no GitHub App has ever submitted an approving
review in `platform-cicd-v2-demo`, `conductor-api`, or `zapp` — the reviewer
histories there are `iscooter`, `chaseconey`, `Halima-RV`, and `BankrateBot`,
all user accounts. App approval is documented GitHub behavior but untested in
this org, so it needs its own five-minute probe before anyone plans around it.

**C. bender merges directly instead of arming auto-merge.** This works
mechanically — finding 5 proves the bypass applies to a merge call. It costs
more than it looks. It needs `contents: write` added to bender, which is the
exact permission this design deliberately withheld. And it gives up the one
thing auto-merge provides: GitHub *holding* the PR until conditions are met. A
direct call means zapp decides the moment is now, on a gate-12 snapshot that may
already be stale. That race is
[PLAT-1192](https://redventures.atlassian.net/browse/PLAT-1192), and auto-merge
absorbs it for free today. It also inverts the ordering rule this design runs
on: add the dangerous capability last, remove it first. A single merge call has
no rung below it.

Order of work: probe A, then probe B's App-approval question, and treat C as the
fallback that needs a design conversation rather than an experiment.

## Restore — verified

| item | state |
|---|---|
| repo ruleset 20475255 | restored, `diff` against the pre-experiment snapshot is empty |
| `.github/CODEOWNERS` | restored via [#67](https://github.com/bankrate/platform-cicd-v2-demo/pull/67), byte-identical to backup |
| repo custom properties | never changed (`is_poc: true` was pre-existing) |
| `test/plat-1184-app-bypass` | already deleted on #66's merge |
| `restore/codeowners-bankratebot` | deleted on #67's merge |

PR #49 still has auto-merge armed by bender with a `BankrateBot` approval. That
is zapp's normal behavior on an enrolled repo, not experiment residue, so it was
left alone.
