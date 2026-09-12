---
name: pr-review-cycle
description: >-
  Agent-only procedure for taking any pull request from review intake to independently verified clean.
  Load before reviewing, fixing, or declaring a PR ready, and before accepting a worker's PR-ready or done claim.
  Owns exact-head adversarial Codex review briefs, CI and configured-reviewer inspection, review-thread disposition, existing-PR fix briefs, and final independent verification.
user-invocable: false
metadata:
  internal: true
---

# pr-review-cycle

This skill is the single owner of the review-to-clean procedure for every pull request.
A firstmate uses it for intake, briefing, and independent read-only verification, while project-specific inspection and fixes remain delegated under `AGENTS.md` section 1.
The review and fix briefs below are written to paste unchanged into a crewmate brief.
Merge authority is not part of this procedure and remains owned by `AGENTS.md` section 7.

Loading this skill for a review-only request grants no authority to edit code, push, change draft state, post comments, or resolve threads.
In that case, run only the read-only inspection and report findings; enter the mutation steps only when the authorized task includes taking the PR to clean.

## Pin the review target

Set the repository and pull request explicitly, then record the current head before reviewing anything.
The command blocks in this skill are the concrete GitHub implementation.
For another supported forge, use its native CLI and API to collect the equivalent immutable head, base, checks, conversations, reviews, inline comments, discussion threads, and reviewer rerun evidence.
The evidence requirements and completion gates do not change by forge; report a gap when the forge cannot supply one rather than skipping it or forcing a GitHub command onto that pull request.

```sh
OWNER=<owner>
REPO=<repo>
PR=<number>
gh-axi api "/repos/$OWNER/$REPO/pulls/$PR" --jq '{url:.html_url,draft,headRef:.head.ref,headRepo:.head.repo.full_name,headCloneUrl:.head.repo.clone_url,headSha:.head.sha,baseRef:.base.ref,baseRepo:.base.repo.full_name,baseCloneUrl:.base.repo.clone_url,baseSha:.base.sha}'
```

Use the returned head SHA as `REVIEW_HEAD` and the returned current base repository, ref, and tip as `BASE_REPO`, `BASE_REF`, and `BASE_SHA`.
Record the computed merge base as `MERGE_BASE` when preparing the independent review.
Every review result, check result, and ready claim is stale if the PR head, base target, or merge base no longer equals the recorded identity.

## Read the complete review surface

Read every check and the complete PR conversation, review submission, inline comment, and current review thread.

```sh
gh-axi pr checks "$PR" -R "$OWNER/$REPO"
gh-axi pr view "$PR" -R "$OWNER/$REPO" --full --comments --reviews
gh-axi api "/repos/$OWNER/$REPO/issues/$PR/comments" --paginate --full
gh-axi api "/repos/$OWNER/$REPO/pulls/$PR/reviews" --paginate --full
gh-axi api "/repos/$OWNER/$REPO/pulls/$PR/comments" --paginate --full
gh-axi api "/repos/$OWNER/$REPO/commits/$REVIEW_HEAD/check-runs?per_page=100" --paginate --full
gh-axi api "/repos/$OWNER/$REPO/commits/$REVIEW_HEAD/statuses?per_page=100" --paginate --full
gh-axi api POST graphql --paginate --full --field query="query(\$endCursor: String) { repository(owner: \"$OWNER\", name: \"$REPO\") { pullRequest(number: $PR) { reviewThreads(first: 100, after: \$endCursor) { nodes { id isResolved isOutdated comments(first: 1) { nodes { databaseId url } } } pageInfo { hasNextPage endCursor } } } } }"
```

Inventory the checks that should exist before judging the observed rollup.

```sh
gh-axi api "/repos/$OWNER/$REPO/branches/$BASE_REF/protection/required_status_checks" --full
gh-axi api "/repos/$OWNER/$REPO/rules/branches/$BASE_REF" --full
rg -n --hidden 'pull_request|pull_request_target|workflow_run|paths:|paths-ignore:|if:' .github/workflows
```

Use branch protection, applicable rules, workflow triggers, and recent comparable PR runs to name every expected context.
Treat an unreadable protection or ruleset source as an evidence gap unless another authoritative source establishes the complete expected set.
An expected workflow that never creates a context because of path, actor, fork, event, or conditional logic is missing validation, not a clean or skipped check.

Treat the paginated REST inline-comment response as the complete comment body source.
Group it into threads by each comment's `id` and `in_reply_to_id`, then associate each group with the GraphQL thread through its first comment's `databaseId`.
This join keeps a thread with more than 100 replies complete without relying on a nested unpaginated GraphQL connection.
Do not treat an outdated thread as resolved.
Classify every unresolved thread as valid, already fixed, or declined.
Fix valid findings, reply with the commit or concrete correction, and resolve the thread only after the fix is present on the PR head.
For an already-fixed finding, reply with the exact evidence and resolve it.
For a declined finding, reply with the specific reason it does not apply or would violate the accepted contract, then resolve it.
Reply to an inline comment before resolving its thread when a disposition is not already visible in the conversation.

```sh
COMMENT_ID=<database-id-from-thread>
gh-axi api POST "/repos/$OWNER/$REPO/pulls/$PR/comments/$COMMENT_ID/replies" --field body='<specific disposition and evidence>'
THREAD_ID=<graphql-review-thread-id>
gh-axi api POST graphql --field query='mutation($thread: ID!) { resolveReviewThread(input: {threadId: $thread}) { thread { id isResolved } } }' --field thread="$THREAD_ID"
```

Count unresolved nodes across every complete response page.
If the GraphQL result reports `pageInfo.hasNextPage: true`, the `--paginate --full` command must return the later pages before the enumeration is complete.
On another forge, enumerate and resolve its equivalent discussion-thread collection through the native API, including every pagination page.

## Interpret configured reviewers

First identify every human and automated reviewer the project configures or requests from repository workflows, app configuration, review requests, ownership rules, branch rules, and recent comparable PR history.
For each configured reviewer, determine where it reports findings and verdicts, whether and how that evidence binds to a commit, what causes it to skip or defer, and how the project requests a rerun or renewed approval.
Require a current result only from configured reviewers, and record an unconfigured integration as not applicable with the evidence used to determine that status.
The absence of an expected configured reviewer is not a clean result.
Read all findings even when an earlier summary or review submission says the review is clean.
Identify automated comments by their author and content together because app login display names can change.

After each push, capture the new `REVIEW_HEAD`, wait for push-triggered CI, and rerun, re-request, or refresh every configured reviewer through the project's own mechanism.
Do not accept an older verdict for a newer head.
If a configured reviewer does not run, inspect its trigger, eligibility, and explicit skip or deferral messages.
Report missing review coverage instead of treating silence, a skip, or an unrelated old result as clean.
Use a fallback only when the project's or captain's governing contract explicitly authorizes one for that reviewer and record the evidence that activated it.

### Worked examples for common bot reviewers

These examples describe one project's reviewer setup and are not requirements for projects that do not configure these integrations.

- CodeRabbit's clean verdict can appear as a summary issue comment rather than a GitHub review object.
  Read its latest summary in full and verify that the commit range named in the comment ends at `REVIEW_HEAD`.
  A draft-skip message is not a review result; make the PR ready through the authorized workflow before requesting or awaiting its review.
  CodeRabbit reports rate limiting in a reply comment.
  When that explicit reply applies to `REVIEW_HEAD`, record its URL and use the independent adversarial review only when the governing directive authorizes that fallback.
  Request a fresh pass after a push with `gh-axi pr comment "$PR" -R "$OWNER/$REPO" --body '@coderabbitai review'` when it does not start automatically, but do not repeatedly summon it after an explicit rate-limit reply.
- The Claude review action from `anthropics/claude-code-action` can post a checklist comment after each push.
  Read the latest checklist in full, treat its last section as the verdict, and verify that it belongs to `REVIEW_HEAD` or to the review run triggered by that push.
  If the configured workflow does not run on the new head, inspect its workflow trigger and report the missing review instead of treating an older checklist as current.

## Independent Codex adversarial review

Run a fresh local Codex review against the exact checked-out PR head after the implementation is committed.
The reviewer must not be the worker that authored or fixed the change.
Firstmate dispatches this independent review as a managed scout under the existing spawn and harness contracts; it does not fetch, create a worktree, or audit project code itself.
The following preparation commands and brief belong to that scout in its isolated worktree.
Fetch both immutable commits before entering the read-only review, then detach or use a disposable worktree at `REVIEW_HEAD` and verify every prerequisite before invoking Codex.
The narrow scout omission for a hand-verified dependency bump is owned only by `dependency-bump-triage`; every other part of this cycle still applies.

```sh
git fetch --no-tags "$BASE_CLONE_URL" "$BASE_SHA"
git fetch --no-tags "$HEAD_CLONE_URL" "$REVIEW_HEAD"
test "$(git rev-parse HEAD)" = "$REVIEW_HEAD" || exit 1
git cat-file -e "$BASE_SHA^{commit}" || exit 1
git cat-file -e "$REVIEW_HEAD^{commit}" || exit 1
MERGE_BASE=$(git merge-base "$BASE_SHA" "$REVIEW_HEAD") || exit 1
git cat-file -e "$MERGE_BASE^{commit}" || exit 1
codex exec --sandbox read-only --ephemeral '<adversarial review brief>'
```

Review the three-dot PR change from `BASE_SHA...REVIEW_HEAD`, whose left side Git resolves to `MERGE_BASE`, so base-branch commits made after the PR diverged are not misclassified as reversions in the PR.
The brief itself supplies `BASE_SHA`, `MERGE_BASE`, and `REVIEW_HEAD` because the installed Codex CLI rejects a custom prompt combined with `codex exec review --base`.

Use this brief verbatim after filling in the placeholders:

```text
Review pull request <full URL> adversarially at exact head <full SHA from REVIEW_HEAD> against the exact three-dot change <full BASE_SHA>...<full REVIEW_HEAD>, whose verified merge base is <full MERGE_BASE>.
Do not modify files.
Read the complete `git diff <full BASE_SHA>...<full REVIEW_HEAD>` and the surrounding implementation, tests, contracts, and relevant history.
Focus on correctness, regressions, unsafe state transitions, concurrency or recovery gaps, security boundaries, compatibility, and missing user-visible behavior.
For changed tests, judge their negative controls: identify whether each test would fail under the plausible broken implementation it is meant to exclude, and call out vacuous, mock-only, or same-implementation assertions.
Do not request unrelated cleanup or speculative scope expansion.
Report only actionable findings grouped as P1, P2, or P3, each with file and line, concrete failure mode, evidence, and smallest valid correction.
End with exactly `Verdict: ready` when there are no actionable findings, or `Verdict: needs-fixes` when any finding remains.
```

Treat the report as evidence, not authority.
Validate each finding against the accepted intent and route any genuinely ambiguous scope decision through the existing decision owner rather than silently expanding the PR.

## Existing-PR fix brief

Use this brief verbatim after filling in the placeholders:

```text
Fix the actionable findings on existing pull request <full URL>.
Work on that PR's own head branch <head branch> in its head repository <head repository>.
Do not create a new branch or a new pull request.
Before editing, verify the checked-out branch and head SHA against the PR.
Read every CI result, review, issue comment, inline comment, and review thread.
Fix valid findings with focused tests, reply to each thread with the fix evidence, and resolve it only after the fix is pushed.
For every declined finding, reply with the concrete reason and resolve the thread.
Commit and push only to the existing PR branch.
After every push, capture the new exact head and rerun the independent Codex adversarial review plus every configured human or automated reviewer through the project's review mechanism.
Repeat until the exact head has all CI checks green, no actionable independent Codex or configured-reviewer findings, and zero unresolved review threads.
Do not merge.
Report the full PR URL, final head SHA, check rollup, reviewer verdict evidence, and unresolved-thread count.
```

## Verify a ready claim independently

Never accept a worker's `done:` or ready claim without a fresh firstmate-side read.
Fetch the PR again and verify all of the following against one unchanged head:

- The current full head SHA still equals the captured `REVIEW_HEAD`; when a worker also reported a SHA, it equals both.
- The current base repository and ref equal `BASE_REPO` and `BASE_REF`; after fetching its current tip, `git merge-base <current-base-tip> "$REVIEW_HEAD"` still equals `MERGE_BASE`.
- The pull request is open, non-draft, and `MERGEABLE`, its active `reviewDecision` has no change request, and every required approval is present.
- `statusCheckRollup` and `gh-axi pr checks` show every current CI context and no pending, skipped-without-explanation, cancelled, or failing required work.
- Every context expected from branch protection, applicable rules, and workflow-trigger analysis exists on `REVIEW_HEAD`; no required workflow is silently absent.
- The forge's complete paginated thread or discussion query reports zero unresolved review threads.
- Every configured automated reviewer that emits a head-bound verdict has a current clean result covering the exact head, or a documented reviewer-specific fallback explicitly authorized by its governing contract is satisfied for that head.
- Every requested human review and every other reviewer surface has been inspected, all findings have a recorded disposition, and any approval or renewed-approval rule the project applies to the current head is satisfied.
- The latest reviewer comments and verdict surfaces have been read in full, and none contains an actionable finding that is absent from the thread count.
- The independent Codex report covers the exact head and ends `Verdict: ready`, unless `dependency-bump-triage` proves and records its narrow scout exception for this head.
- Every valid finding was fixed and every declined finding has a visible reason before its thread was resolved.

Use this query to bind the check rollup to the current commit rather than trusting a worker's copied terminal output:

```sh
gh-axi api POST graphql --paginate --full --field query="query(\$endCursor: String) { repository(owner: \"$OWNER\", name: \"$REPO\") { pullRequest(number: $PR) { state isDraft mergeable reviewDecision headRefOid baseRefName baseRefOid baseRepository { nameWithOwner url } commits(last: 1) { nodes { commit { oid statusCheckRollup { state contexts(first: 100, after: \$endCursor) { nodes { __typename ... on CheckRun { name status conclusion detailsUrl } ... on StatusContext { context state targetUrl } } pageInfo { hasNextPage endCursor } } } } } } } } }"
```

Require every page when the context query reports `pageInfo.hasNextPage: true`.
If the head, base target, or merge base changes during verification, discard the partial result and restart the cycle at the new identity.
The PR is ready only when all items are clean at the same exact head.
Follow `AGENTS.md` section 7 after readiness is established; this skill grants no merge authority.
