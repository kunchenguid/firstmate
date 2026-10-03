# Merge as the App, and Delete the Approval PAT

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Ticket:** [PLAT-1332](https://redventures.atlassian.net/browse/PLAT-1332) established the mechanism. **Closes** [PLAT-1327](https://redventures.atlassian.net/browse/PLAT-1327) (the PAT expires 2026-12-01).

**Goal:** in `auto-merge` mode, zapp merges the pull request itself as `bankrate-bender` instead of approving as `BankrateBot` and arming GitHub's auto-merge. `approver.ts` comes out and zapp stops calling `BankrateBot` entirely, dropping to two acting identities. **The credential itself is deleted in a separate follow-up PR (Task 4b), not this one** — Terraform destroys the secret resource, so removing it here would make the deploy the point of no return and leave no rollback except re-minting a PAT under pressure.

**Scope is deliberately narrow.** `auto-merge` mode only. `assisted` mode keeps `enablePullRequestAutoMerge` unchanged — a human approves there, so nothing about it needs to move. No bug fixes, no adjacent cleanups, no follow-ups folded in. Anything discovered along the way gets its own ticket, not a commit in this PR.

---

## This is measured, not theorised

Every claim below was validated on `bankrate/platform-agent` on 2026-09-17. Receipts, so no one has to re-derive them:

| claim | evidence |
| --- | --- |
| GraphQL `mergePullRequest` as bender merges past `require_code_owner_review` | [#56](https://github.com/bankrate/platform-agent/pull/56), [#58](https://github.com/bankrate/platform-agent/pull/58), [#60](https://github.com/bankrate/platform-agent/pull/60) — `merged_by: bankrate-bender[bot]` |
| code-owner review is **bypassed, not satisfied** | zero approving reviews ever existed on any of the three |
| the narrow `bypass_mode: pull_request` suffices | #58 and #60 merged at that mode; `always` is not needed |
| `expectedHeadOid` fails closed on a stale head | #58/#60 test A — `UNPROCESSABLE "Head branch was modified"`, pull request stayed open |
| works with org **and** repo rulesets both in force | #60, with `is_poc` absent and all three rulesets active |
| bender already holds `contents: write` | since 2026-09-02, installation `158320327`, in every probe's token output |

**The REST endpoint does NOT work.** `PUT /repos/{o}/{r}/pulls/{n}/merge` returns `405 Repository rule violations found — Waiting on code owner review` for the identical operation, twice measured. Only the GraphQL mutation succeeds. Do not "simplify" this to REST later.

Ruleset bypass entries are already in place: `Integration:4797210:pull_request` on org ruleset `15978123` and repo ruleset `18782234`. Chase Coney signed off; removing the PAT was his ask.

## What changes, and the one principle that has to move

Today the ladder is **enable, then approve** — both reversible, and a failure at either step lands on the rung below (`assisted` state, which is safe and already shipped). The DOWN direction is **dismiss, then disable**.

A direct merge has no rung below it. So the ordering principle — *add the dangerous capability last, remove it first* — cannot be satisfied by sequencing any more. It has to be satisfied by the **guard**, and the guard is `expectedHeadOid`.

Two properties replace what the ladder gave us:

1. **`expectedHeadOid` = the head SHA gate 12 actually observed.** If the head moved between evaluation and merge, GitHub refuses with `UNPROCESSABLE` and nothing happens. Measured. This is a tighter answer to [PLAT-1192](https://redventures.atlassian.net/browse/PLAT-1192)'s race than auto-merge ever gave, because auto-merge would merge whatever the branch became.
2. **The freeze re-read stays exactly where it is.** `maybeApprove` already re-reads the freeze immediately before approving and calls that comment "THE POINT OF NO RETURN". That hook does not move — the point of no return simply becomes the merge instead of the approval.

For `auto-merge` mode, `enablePullRequestAutoMerge` is **not** called at all. Arming auto-merge and then merging directly would be two mechanisms racing for the same outcome.

---

## Task 1 — `mergePullRequest` in the actuator's dependency surface

- [ ] Add to `ActuatorDeps`:
      `mergePullRequest: (repoFullName: string, prNumber: number, headSha: string, method: 'MERGE'|'SQUASH'|'REBASE') => Promise<void>`
- [ ] Implement it beside `enableAutoMerge` in `src/pipeline/05-actuate/actuator.ts`, authenticating as the actor App through the existing `actorDeps` — the same path `enableAutoMerge` uses. It reuses `fetchPullRequestNodeId`.

The mutation, verbatim from what was measured:

```graphql
mutation($id: ID!, $oid: GitObjectID!, $method: PullRequestMergeMethod!) {
  mergePullRequest(input: { pullRequestId: $id, expectedHeadOid: $oid, mergeMethod: $method }) {
    pullRequest { merged mergedBy { login } }
  }
}
```

- [ ] `expectedHeadOid` is **mandatory**, never optional, never defaulted. Passing it is the safety property; a caller that forgets it silently loses the race guard. Make that impossible in the type, not a convention in a comment.

**Verification:** a unit test proving the mutation is sent with `expectedHeadOid` set to the supplied SHA, and a test proving the function cannot be called without one (type-level or runtime assertion).

## Task 2 — Classify the GraphQL error shapes

`graphqlErrorStatus` already maps `NOT_FOUND`/`FORBIDDEN`/`UNPROCESSABLE` to HTTP-style statuses. `mergePullRequest` needs four outcomes distinguished, and they all arrive as `UNPROCESSABLE`, so the **message** is the discriminator.

- [ ] `Head branch was modified` → new outcome `merge_head_stale`. Not a failure. The evaluation was against a SHA that no longer exists; the next webhook re-evaluates. Log it, return normally.
- [ ] Already merged → new outcome `already_merged`. **Idempotent** — SQS redelivery must not treat this as an error. This is the redelivery-safety requirement and it needs its own test.
- [ ] Merge conflict / not mergeable → new outcome `merge_conflict`. Terminal for this delivery; a human has to rebase.
- [ ] Anything else → existing `failed`, with the message carried through.

- [ ] Remove from `ActionOutcome` the variants that become unreachable in `auto-merge` mode: `approved`, `already_approved`, `dismissal_failed`. Keep them if and only if `assisted` mode still produces them — check before deleting.

**Verification:** one test per error shape, asserting the outcome. Capture the exact message strings from this plan's receipts rather than inventing them.

## Task 3 — Rewire `actuate` for `auto-merge` mode

- [ ] Rename `shouldApprove` → `shouldMerge`. The bar does not change: it stays strictly stronger than `shouldEnable` and keeps the `signalsGraded` / `minSignalsGradedExempt` logic. The merge is now the irreversible act, so it takes the stricter gate. Its doc comment needs rewriting — "the grade is the only reviewer the change gets" is now literally true rather than nearly true.
- [ ] `maybeApprove` → `maybeMerge`. Keep the freeze re-read immediately before the call. Replace the `findOwnApproval` / `approvePullRequest` pair with one `mergePullRequest`.
- [ ] In `actuate`, for `mode === 'auto-merge'`: skip the enablement block entirely and go to `maybeMerge`. `mode === 'assisted'` keeps the existing enable path untouched.
- [ ] Merge-method order: keep `chooseMergeMethod`'s `MERGE → SQUASH → REBASE` preference and the per-repo `EnrollmentRecord.mergeMethod` override. `platform-agent` permits merge commits only; the demo permits all three. A method the repo forbids must be distinguishable from a rule violation so the loop can try the next one.
- [ ] The revoke path for `auto-merge` mode loses its dismissal step — there is no standing approval to dismiss. A merged pull request cannot be revoked at all, which is the honest consequence of this design and should be stated in the code comment, not hidden.

**Verification:** tests covering assisted-unchanged, auto-merge-merges, freeze-blocks-the-merge, and `shouldMerge: false` does nothing.

## Task 4 — Stop calling the approver, but leave the credential standing

**This task is deliberately incomplete, and that is the point.** The code path goes; the secret stays. See "Rollback" below for why — in short, Terraform destroys the secret resource, so removing it here would make the deploy itself the point of no return.

- [ ] Delete `src/pipeline/05-actuate/approver.ts` and its tests. Nothing calls it after Task 3.
- [ ] Remove `getApproverConfig` / `ApproverConfig` from `src/platform/secrets.ts`.
- [ ] Remove `APPROVER_SECRET_NAME` from `src/entrypoints/contract.ts`'s required-env list.

**DO NOT, in this PR:**

- Touch the `/zapp/approver` secret in Terraform (`init.tf`, `secrets.tf`, `iam.tf`'s resources list, `main.tf`'s `environment` block).
- Remove the `approver_auth_failed` metric filter from `infrastructure/terraform/alarms.tf`.
- Revoke, delete or rotate `BankrateBot`'s PAT.
- Remove `@BankrateBot` from any repository's `CODEOWNERS`.

Leaving `main.tf`'s `environment` block intact means the Lambda still receives `APPROVER_SECRET_NAME` as an unread env var. That is intentional dead configuration for the length of one deploy cycle. Note it in the PR description so a reviewer does not "tidy" it.

**Verification:** `grep -ri approver src/` returns nothing but intentional history. `grep -ri approver infrastructure/` still returns the secret and the alarm — that is the expected state, not an oversight. The contract test proves the env var is no longer required.

## Task 4b — Delete the credential (SEPARATE PR, AFTER a real merge is observed)

Its own pull request, opened only after a real dependabot pull request has been merged end to end on `platform-agent` by `bankrate-bender` in production. Its own ticket, so it cannot be swept into the first PR's review.

- [ ] Remove the `/zapp/approver` secret from Terraform — **all four places**: `init.tf`, `secrets.tf`, `iam.tf`'s resources list, and `main.tf`'s `environment` block. PLAT-1267 shipped three of four once; do not repeat that.
- [ ] `approver_auth_failed` is a **load-bearing log string** — `alarms.tf` has a log metric filter matching it literally. Remove the alarm in the same change or it silently monitors a string nothing emits.
- [ ] Revoke `BankrateBot`'s PAT.
- [ ] Remove `@BankrateBot` from `CODEOWNERS` across the enrolled repositories (roughly 25 files).
- [ ] Close [PLAT-1327](https://redventures.atlassian.net/browse/PLAT-1327).

**Verification:** `grep -ri approver src/ infrastructure/` returns nothing but intentional history.

## Task 5 — Human-facing output

The check run is the product in shadow mode, and it currently tells people zapp "approved" things.

- [ ] Update `src/pipeline/04-render/render.ts` and `src/entrypoints/report/{index,render,query}.ts` so nothing claims an approval happened.
- [ ] Write the new wording plainly, in the natural-writing register the rest of these checks use. Say what is true: zapp merged this, under a ruleset bypass, because these gates passed and these signals graded. Do not say "approved" and do not invent a euphemism for "bypassed" — the audit trail is more honest than the old one and should read that way.
- [ ] `src/pipeline/ledger/outcomes.ts`'s `Outcome` union already has `merged`. Confirm the actuator's new outcomes map onto it correctly and that `#pkg#` rows still get written on a merge.

**Verification:** a render test asserting no output string contains "approve" in any casing.

## Task 6 — Docs, and the stale claims this plan tripped over twice

- [ ] `README.md:255` says bender holds "permissions exactly `metadata: read`/`pull_requests: write`". It has held `contents: write` since 2026-09-02. Fix it.
- [ ] `src/pipeline/05-actuate/actuator.ts:446` justifies skipping a repo-settings pre-read on the grounds that reading merge settings "would mean push access on every repo in the org" — describing a grant that already happened. Rewrite it to state the real reason the pre-read is skipped (the mutation is authoritative), without the false premise.
- [ ] Update `docs/architecture.md` and `docs/call-flows.md` for the two-identity model and the new merge path.
- [ ] Document the ruleset bypass as a **deployment prerequisite**: `Integration:4797210:pull_request` must be present on every ruleset governing an enrolled repo's default branch. Name the two that exist today (`15978123`, `18782234`) and the one that does not yet (`15746207`, SOC2).

---

## Risks. Both are real; neither is a reason not to ship.

**1. This rests on a REST/GraphQL inconsistency.** The same operation, against the same rule, with the same credential: REST returns 405, GraphQL returns 200. That is not documented intent — it reads like a GitHub bug that happens to favour us. If GitHub aligns the two, **dependency pull requests stop merging silently**.

- [ ] Accept the risk explicitly, in the PR description, not a comment.
- [ ] Add detection: a merge attempt that fails with a code-owner rule violation must emit a distinct, alarmable log string. The failure mode to protect against is not an error — it is silence.
- [ ] Record the fallback in the plan doc: re-enable the approval path. Keeping `assisted` mode's `enablePullRequestAutoMerge` intact means that fallback stays one config change away rather than a rewrite.

**2. The bypass also exempts bender from `required_status_checks`.** A bypass is per-ruleset, not per-rule. Today GitHub's auto-merge independently waits for the ruleset's required checks — a second line of defence that direct merging removes. After this change, **zapp's gate 12 is the only thing enforcing checks.**

Gate 12 fails closed on a check it cannot see (it looks for a name, does not find it, treats it as not green), so the dangerous direction is covered. The real gap is coverage: if a ruleset requires a check that `policy-rules.yaml`'s `blockingChecks` does not list, nothing enforces it once bender bypasses.

- [ ] Before enabling this per repo, verify zapp's blocking-check list is a **superset** of that repo's ruleset `required_status_checks`. For `platform-agent` it is today (zapp's `always` list is 3 Cycode + `codecov/project`; the ruleset requires 3 Cycode). That is a coincidence of configuration, not a guarantee — make it a checked precondition.
- [ ] Note but do not fix: gate 12 reads `fetchCheckRuns` (Checks API only) while gate 11 reads `statusCheckRollup` (both APIs). Out of scope here. Its own ticket.

## Rollout

- [ ] Ship behind the existing two-key promotion. No new flag — enrollment `mode` already gates this.
- [ ] `platform-agent` first. It is a sandbox not in use by anyone, which is what made it the right validation target.
- [ ] Watch one real dependabot merge end to end before touching `platform-cicd-v2-demo`.

## Rollback

The whole reason Task 4 is split. Terraform **destroys** the secret resource, so removing `/zapp/approver` in the same pull request would make the deploy itself the point of no return: reverting the code would not bring the secret value back, and you would be re-minting a PAT under time pressure while dependency merges are broken.

- [ ] Revert the PR. `assisted` mode is untouched, so `enablePullRequestAutoMerge` still exists and the approval path is one revert away rather than a rewrite.
- [ ] Because Task 4 leaves the secret, its IAM grant and the alarm in place, a revert restores a **working** approval path with no infrastructure change and no credential re-issue.
- [ ] `@BankrateBot` also stays in `CODEOWNERS` until Task 4b, so a reverted build can still satisfy code-owner review immediately.
- [ ] Only after a real production merge is observed does Task 4b close the door.

## Explicitly out of scope

Gate 12's Checks-API blindness. The pnpm `overrides` gap ([PLAT-1333](https://redventures.atlassian.net/browse/PLAT-1333)). Nested manifests ([PLAT-1311](https://redventures.atlassian.net/browse/PLAT-1311)). BankrateBot's standing `admin` on every repo and its membership in a team with write on 375. The SOC2 ruleset bypass. The retroactive enrollment sweep. Each gets its own ticket; none belongs in this PR.
