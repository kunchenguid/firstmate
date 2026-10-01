---
name: swarm-pr-feedback
audience: swarm-plugin
description: >
  Ingest and resolve known pull request feedback with skeptical source verification.
  Use when addressing pasted PR feedback, GitHub review comments or threads,
  requested changes, CI/check failures, merge conflicts, stale PR branches, or
  PR follow-up work that must close all known issues without dropping findings.
  Supports multi-round bot reviews when the repo uses an auto-review bot that
  posts a new review after every push, via the iterative pattern documented in
  the body. Stage A
  (structural pre-checks) and Stage B (reviewer + test_engineer) gates and the
  reviewer + critic closeout gate are MANDATORY for any change made as part of
  this process.
swarm-contract-digest: 143d9443a82d
---

# Swarm PR Feedback

Use this skill to close known PR feedback. This is not a fresh broad PR review.
Repository-specific bot names and examples below are illustrative; substitute the repo's actual bot and branch-state surfaces when they differ.
`swarm-pr-review` discovers new findings; `swarm-pr-feedback` ingests existing
feedback surfaces, verifies each claim, clusters related problems, fixes confirmed
issues, validates the branch, and reports closure status for every item.

**Mandatory gate contract.** Stage A (structural pre-checks) and Stage B
(reviewer + test_engineer) gates and the reviewer + critic closeout gate are
MANDATORY for any change made as part of this process. No fix lands, no closure
ledger row is marked FIXED, and no PR is published until all three gates pass on
the current diff. There is no speed, efficiency, or time exception. See
"Mandatory Gates" below for the full protocol.

When the work starts from a prior Profile-A `swarm-pr-review` run, use the exact
user command `/swarm pr-feedback <PR_URL> continue from
.swarm/pr-review/<run_id>/feedback-handoff.json`. The controller validates the
terminal review and artifact before atomically creating an unbound feedback
gate; the artifact alone is not write authorization. Profiles B/C ingest their
task-workspace handoff directly before triage.
Carry forward the original review finding IDs, classifications, reviewer/critic
provenance, and any operational blockers instead of renumbering them as new
discoveries.

Feedback closure is not the end of the PR lifecycle: when PR monitoring is
enabled (`pr_monitor.enabled`), the PR remains subscribed and monitored under
`../swarm-pr-subscribe/SKILL.md` until it is merged or closed. Events that
arrive after closure (a new bot round, a CI change, fresh review activity) are
triaged through that skill and route back into this discipline when they need
fixes.

## Multi-Round Bot Reviews (Iterative Pattern)

When the repo uses an auto-review bot that posts a new review comment after
**every push** to the PR branch, identify that bot from the repository contract
and apply this pattern (for example `hermes-pr-review` in this repo). Expect N
rounds of review for N pushes, and budget for it.

**Round N+1 deltas vs Round N:**
- Fresh `FB-###` ledger IDs for new findings (do not reuse IDs from earlier rounds)
- Findings from prior rounds that remain unfixed will reappear with the same evidence
- Findings you marked DISPROVED with new evidence may reappear if the bot disagrees
- New findings may be introduced that the prior round did not see (the bot's read scope
  is the new commit, not the full diff history)

**Operating principles for multi-round triage:**

1. **Continue the ledger, do not start over.** Append to the same `FB-###` counter
   across rounds. Track each finding's state per round (open, fixed, disproved,
   awaiting-decision, repeated).
2. **Carry forward unresolved items.** Findings you marked `PARTIAL` or `NEEDS_USER_DECISION`
   in round N will still be open in round N+1. The closure ledger should show their
   evolution (e.g., "PARTIAL round 1 → CONFIRMED round 2 after evidence collected").
3. **Apply the 3-strikes evidence-escalation rule.** When the same finding is
   raised 3+ times across rounds, re-run source verification with a fresh
   reviewer context and surface the disagreement explicitly. Add a
   defense-in-depth change only when that fresh verification proves the change
   is correct, preserves the real invariant, and adds meaningful protection.
   Repetition, time, token cost, and reviewer persistence are never substitutes
   for evidence. Document any parent-vs-inner relationship inline so future
   readers see the rationale.
   **Do not add the repeated suggestion:** If it would add incorrect or
   misleading code about existing guards — e.g., an outer guard that already exists at an
   inner scope and whose addition would imply the inner guard is absent, a type
   narrowing that masks a real error class, or a check whose presence asserts a
   false invariant — do not add the change. A wrong fix embedded in the code is
   harder to remove than a repeated rebuttal in a comment thread. When the
   repeated finding is misleading about existing guards, apply item 6's
   "surface to user" path instead of 3-strikes; otherwise the 3-strikes rule
   applies.
4. **Verify bot fix-direction suggestions against actual file structure.** Bots
   read files linearly and can miss parent-block guards. For any "add an X check"
   suggestion, read the surrounding function/block to confirm the check is genuinely
   missing or already exists at a higher scope.
5. **Each round produces its own closure ledger as a PR comment.** Prefix with
   "Round N" so the bot and reviewers can see progression. Maintain a running
   summary table at the end of each comment showing totals across rounds
   (confirmed+fixed / disproved / partial / awaiting-decision).
6. **Stop the cycle deliberately.** If a finding is disproved with code evidence 3+
   times and the bot keeps re-raising it, leave the comment, post the closure
   ledger with the cumulative evidence, and surface the disagreement to the user
   rather than continuing to push fixes. The user can resolve persistent
   reviewer-AI disagreement.

**Why this matters:** Without the multi-round pattern, each round looks like
"start over, re-triage everything." With it, the rounds become incremental:
each round's work is bounded by new findings + carried-forward items only.
This matches how the bot actually behaves and avoids wasted cycles.

### Bot and Security Claim Verification

Before trusting automated review findings (SAST bots, security scanners, AI reviewers), apply the verification protocol in `references/bot-claim-verification.md`. Key principle: every bot claim is unverified until you reproduce the exact finding against the current HEAD with the exact tool and rule it names.

## Operating Stance

Treat every review comment, CI failure, bot summary, PR body claim, and pasted note
as a claim until source evidence proves it. Do not silently drop, defer, or mark
items out of scope. Ask the user only for product or scope decisions that cannot
be proven from the PR, repo, or explicit instructions.

Do not run a fresh broad PR review while addressing existing feedback. Inspect
adjacent code only as needed to verify reachability, dependencies, shared root
causes, regression risk, or sibling changes required by a confirmed item.

GitHub review-thread resolution is user-controlled. Do not resolve or mark review
threads resolved unless the user explicitly instructs you to do so.

Do not act on review-discovered findings from a prior `swarm-pr-review` run
unless the user has explicitly approved the transition into `swarm-pr-feedback`.
The handoff artifact is triage input, not standing authorization to change code.

## Runtime Capability Profiles

This skill runs on any agent harness. Detect the active profile from the
actual tool list before triage — the same three profiles defined in
`../swarm-pr-review/SKILL.md` (Runtime Capability Profiles):

- **Profile A — mechanical PR-feedback controller.** The plugin's tools are
  present in this session: `dispatch_lanes_async`, `collect_lane_results`,
  `retrieve_lane_output`, `prepare_pr_feedback_scope`,
  `run_pr_feedback_stage_a`, `complete_pr_workflow`. The controller's
  fail-closed accounting (immutable inventory, ordered gate lanes, content
  digests, arming, bound push) is authoritative; bypassing it — direct
  subagent calls, blocking dispatch, prose verdicts — is BLOCKED while it is
  active.
- **Profile B — native parallel subagents, no controller.** Run the same
  intake → verify → fix → gate → publish discipline using your harness's
  subagent tool for verification lanes and gate roles; you maintain the
  ledger, the ownership partition, and the digest accounting yourself in
  session/task workspace files (never under `.swarm/`, which belongs to the
  plugin runtime).
- **Profile C — single context, no subagents.** Same discipline as strictly
  separated sequential passes that re-derive rather than restate earlier
  reasoning, plus explicit disclosure in the closure ledger that gate
  independence was procedural.

Controller-tool absence is NOT a blocker; Profiles B and C are first-class
execution paths. BLOCKED is reserved for bypassing an active controller and
for verification or coverage gaps that stay unclosable after bounded retries.

## Pre-flight: Check Out the PR Branch Locally

Before verifying any claim or making any fix, ensure the PR branch is the working
tree:

- If `head_ref` is a remote branch that is not checked out locally, fetch it
  (`git fetch origin <head_ref>`).
- **Check for parallel work first.** Before checkout, use the repository or
  runtime's parallel-work check. When the bundled
  `parallel-work-check` skill exists, it is one conditional implementation to
  detect concurrent pushes from other agents (for example the repo's
  auto-review bot following up, a maintainer pushing fixes, or parallel swarm
  work). If remote has new commits: read `git log local..remote`, evaluate whether the parallel work
  supersedes your planned fixes, and prefer the parallel work if it's more
  comprehensive (more tests, better edge coverage, clearer error handling).
  Abort your rebase, take the remote state, then add minor improvements on top.
- Verify the working tree is clean first (`git status --porcelain`). If any
  tracked or untracked changes exist, call `prepare_pr_workflow_checkout`
  before binding (Profile A). Omit `paths` to auto-discover and atomically
  preserve every dirty path, including untracked files; pass explicit `paths`
  only for an exact bounded tracked-file set. It creates an auditable stash
  receipt containing the original branch/HEAD and a structured
  `operation: "restore"` recovery instruction. Do not issue `git stash`
  through shell.
  Without the controller, surface dirty state to the user or abort the checkout
  — do not blind-stash.
- Treat `recovery-required` and `indeterminate` controller results as terminal
  for the current attempt: report the typed `required_action`, abort/clear any
  already-active gate, and stop. Only `stashable` permits one preparation call;
  retry only when the controller explicitly returns `retryable: true`.
- **Check out the head branch locally before dispatching feedback lanes.** Feedback verification reads the working-tree
  filesystem (`Read`/`Glob`/`Grep`), and fixes must land on the PR branch — without a
  checkout you would verify and patch the base branch's code instead. Record the
  exact `merge_base...head_ref` range for diff-scoped inspection.
 - Pass the exact `merge_base...head_ref` commit range in every read-only verification or
   explorer/advisory-lane delegation so lane agents can inspect specific revisions
   with `git show` when needed.
- If no PR reference was provided (a pasted-feedback session on the current branch),
   confirm the current branch is the intended PR branch before editing.
- A detached checkout at the authoritative full PR head is a valid pre-bind
  intake state. On the first Profile-A bind, the controller attaches it only
  when Git reports exactly one safe candidate: an existing local branch at
  that SHA whose upstream is an exact remote ref at the same SHA, or one exact
  remote-tracking ref. It never guesses a remote/name boundary. Zero
  candidates, multiple candidates, a linked-worktree-owned local branch, or an
  existing mismatched upstream fails closed without publishing the bind. Retry
  is idempotent if switching succeeded but state persistence failed.
- The existing constrained tracked-branch and safe `gh pr checkout` pre-bind
  forms remain supported on every profile after proving the exact SHA and a
  unique intended remote ref. Never use force, submodule-recursive, or detached
  `gh pr checkout` variants.
- Immediately after the first bind and before feedback verification dispatch,
  prove that `git rev-parse HEAD` equals the authoritative full `pr_head_sha`,
  `git status --porcelain` is empty, and the current branch tracks the intended
  PR head remote/branch. A detached exact-head checkout is intake-only; the
  bind must attach it before feedback dispatch or publication.

When a verification lane result includes `output_ref`, treat `output` as a
preview and call `retrieve_lane_output` before using it to classify, resolve,
disprove, or group feedback items. If the result is `output_degraded`,
`transcript_incomplete`, or truncated without a usable ref, keep the affected
ledger items as `NEEDS_MORE_EVIDENCE` or re-dispatch a narrower read-only lane.
(Profile A. On Profiles B/C, read each verification subagent's or pass's full
report directly — a truncated or summary-only report is a preview, not
verification evidence, and keeps its items open the same way.)

## Pre-flight: Dirty Worktree Handling

Before staging any files for the PR commit, check the working tree state:

**The problem:** `git add -A` stages every uncommitted change in the working tree,
including pre-existing changes from other branches or prior work.

**The check:** Run `git status --porcelain` first. If output is non-empty, identify
which files are PR-related vs pre-existing uncommitted changes.

**The rule:** Stage files explicitly by path when the working tree contains files
unrelated to the PR. For example:

```bash
git add src/foo.ts tests/foo.test.ts
```

Never use `git add -A` when the working tree has pre-existing changes from other
branches or prior work sessions.

## Batch Collection (mandatory before any fix)

When the runtime provides a CI-failure-batching workflow, load it before
proceeding. The bundled `ci-failure-batching` skill is one conditional
implementation; otherwise apply the host-neutral complete-ledger protocol
below.

For the detailed 6-step batch collection protocol, read `file:.swarm/bundled-skills/ci-failure-batching/SKILL.md`. The steps below are a summary:

1. `gh pr checks <number> --json name,bucket,state,link` to collect all check results
2. Filter to `bucket == "fail"` or `bucket == "cancel"`
3. `gh run view <id> --log-failed` for each failing run
4. Group failures by root cause before fixing

**Rule:** The complete failure ledger must be collected before any
modification is proposed. Verifying the ledger is complete is a prerequisite
for the Fix Planning step.

## Pre-flight: Scope Discipline

When the plugin's mechanical controller is available, every coder Task must be
preceded by `prepare_pr_feedback_scope({ task_id, files })`. The controller is
available only after the immutable feedback-verification lanes have settled and
binds the exact file set to the current feedback revision, parent session, and
next matching Task call. The coder prompt must use the same numeric `task_id`,
contain matching `FILE:` directives, and include a literal `ACCEPTANCE:` line.
Once a Task consumes that scope, its `task_id` is immutable for the current
feedback revision. Any retry must prepare and dispatch a fresh nested numeric
task identity (for example `1.1.1`), never re-declare the consumed ID.

Do not create a synthetic `save_plan` merely to authorize feedback work, and do
not use `declare_scope`; those tools belong to the normal implementation-plan
lifecycle. There is no one-file or single-function carve-out from the dedicated
PR-feedback scope controller.

In runtimes without this controller, use the native scope mechanism. If none
exists, put exact allowed files and non-goals in the delegation and verify the
resulting diff mechanically. Never bypass an available scope controller merely
to reduce ceremony.

## Intake Surfaces

Build a complete feedback ledger before editing. Include every available source:

- validated findings and operational blockers handed off from `swarm-pr-review`,
- pasted user or reviewer feedback,
- GitHub review threads, inline review comments, and review summaries,
- PR issue comments and requested-changes reviews,
- CI/check failures, check annotations, and relevant logs,
- mergeability, conflicts, base drift, and stale PR branch state,
- local validation failures,
- PR body checkboxes, test-plan claims, linked issues, and acceptance criteria,
- commit history and bot/app commits on the PR branch.

If a source is unavailable, retry with alternative access paths. If unavailable after retry, the source is a coverage gap that must be reported to the user — do not silently "record that limitation" and proceed as if the source doesn't matter.

### Async advisory verification lanes

After the complete feedback ledger exists and before editing, run independent
read-only verification lanes. Under Profile A, use
`dispatch_lanes_async` with `mode: "swarm-pr-feedback:verification"`, the
complete immutable `feedback_inventory` ID list, the exact current
`pr_head_sha`, and each lane's exact
`feedback_item_ids` ownership list for independent read-only verification lanes:
comment classification, CI/log root-cause inspection, test impact mapping,
release/docs claim checks, and stale-branch/conflict analysis. Partition the
ledger so each `FB-###` item is owned by exactly one verification lane and the
union of lanes covers the entire ledger — no feedback item may be left
unassigned to a lane; state each lane's owned IDs both structurally and in its
prompt. The runtime rejects missing, duplicate, overlapping, or unknown item
ownership and blocks mutation until the verification batch settles. Scale
the lane count to the ledger size: a 1–3 item round may use a single combined
lane, while a large multi-round intake may warrant one lane per category above.
Cap each `dispatch_lanes_async` batch at 8 lanes (`MAX_LANES`); if the ledger
needs more than 8 verification lanes, dispatch in sequential batches and settle
each batch's COVERAGE GATE before the next — do not over-spawn lanes for a
trivial round. Record each returned `batch_id`, then continue only ledger-safe
architect work: normalize feedback IDs, gather deterministic PR metadata, prepare
reproduction commands, and plan likely fix groups. Do not edit, close items, or
mark feedback resolved from running lanes.

Every verification lane must end with one parseable row for each owned item:

```text
[FEEDBACK-VERIFIED] | FB-### | CONFIRMED/PARTIAL/DISPROVED/PRE_EXISTING/NEEDS_MORE_EVIDENCE/NEEDS_USER_DECISION | evidence
```

Non-empty prose without this marker contract is not a settled verification
artifact and cannot unlock mutation.

Before the Verification step can mark any item `CONFIRMED`, `PARTIAL`,
`DISPROVED`, `PRE_EXISTING`, `NEEDS_MORE_EVIDENCE`, or `NEEDS_USER_DECISION`,
every open verification batch must be fully settled. Poll with
`collect_lane_results` (wait omitted or `false`) to process settled lanes
incrementally — clustering confirmed items and pre-reading files for settled
findings while ledger-safe work remains — then issue a final
`collect_lane_results` with `wait: true` per batch once independent work is
exhausted, to confirm every lane is settled.
Missing, stale, cancelled, or failed lanes are coverage gaps that must be closed
before marking any item CONFIRMED/PARTIAL/DISPROVED/PRE_EXISTING. Apply the
COVERAGE GATE:
retry failed lanes (max 2) as another
`swarm-pr-feedback:verification` async batch with the same immutable inventory,
exact `pr_head_sha`, agent type, prompt, scope, and isolation, or stop and
surface the lane failure to the user as BLOCKED. Under Profile A, blocking and
direct-Task fallbacks are rejected because they cannot satisfy the durable
ownership and head-provenance gate.
Do not proceed with "blocking verification and record that async advisory lanes
were unavailable" — record-and-continue is not coverage closure.

Under Profile B, partition the same immutable inventory across fresh read-only
verification subagents — every `FB-###` item owned by exactly one lane and the
union of lanes covering the entire ledger — with each prompt stating its owned
IDs and the exact `pr_head_sha`, and each lane returning one
`[FEEDBACK-VERIFIED]` row per owned item. Under Profile C, verify the ledger
in sequential category passes with the same one-row-per-item contract. On
every profile, no item may be classified until its verification lane or pass
has settled, and unclosable verification gaps are surfaced as BLOCKED.

### CI matrix cascade check (do this before fixing)

When the PR's `unit` job is a matrix across multiple OSes and downstream jobs
(`integration`, `smoke`) have `needs: unit`, an OS leg failure blocks the
entire pipeline. Before triaging, check:

1. Are `integration` or `smoke` jobs in `skipped` or `cancelled` state rather
   than `failed`? That signals a unit matrix cascade — the unit job failed
   on one OS leg, blocking the downstream jobs from running on the current
   HEAD.
2. If a unit OS leg is the blocker, classify the failure:
   - **Code issue** — the test itself fails. Reproduce locally; if the
     test passes locally, the runner is the problem.
   - **Runner performance** — the test step exceeds the configured timeout.
     Run all files in the step locally with per-file timing; if cumulative
     local runtime is <10 min and the runner can't complete in 60+ min, the
     issue is runner performance. Bump the CI timeout as a stopgap and file
     a follow-up issue for parallelization. Do not loop bumping the timeout
     past 90 min without filing the follow-up.
3. Surface cascade failures to the user explicitly. The downstream jobs'
   results don't exist; the code's coverage of the current HEAD cannot be
   confirmed by CI alone.

### PR body claim verification

The `.swarm/evidence/` paths below apply only when the reviewed repository uses
this plugin's council evidence contract. For any other repository, locate the
authoritative CI attestation, code-host review record, or repository-declared
evidence store; the universal rule is that an approval claim needs a real,
retrievable provenance artifact.

PR body text like "PHASE 2 council APPROVED (5/5, round 2)" or "Final council
APPROVED" must be backed by an evidence file under `.swarm/evidence/` — phase
councils write `.swarm/evidence/{phaseNumber}/phase-council.json`; the final
council writes the flat `.swarm/evidence/final-council.json`. Bot-generated PR
bodies commonly auto-fill these claims without real review. Before accepting
such a claim as part of triage:

1. Check whether the corresponding evidence file exists with `verdict:APPROVED`.
2. If the claim is unsupported, mark the closure ledger item as
   `NEEDS_MORE_EVIDENCE` rather than `CONFIRMED`. Do not silently drop the
   claim — it indicates the PR body was generated without a real review.

## Feedback Ledger

Normalize each item before triage:

```text
FB-001 | source | author/tool | status: UNTRIAGED | location | claim | raw link/quote | depends_on
```

Rules:

- Preserve prior `F-###`, `CI-###`, `CONFLICT-###`, `STALE-###`, and similar
  IDs from a review handoff when they already exist. Only mint fresh `FB-###`
  IDs for new feedback discovered after the handoff.
- Preserve reviewer/critic provenance from the handoff artifact so the closure
  ledger can show which items were review-validated before fix work began.
- Preserve exact reviewer wording or log summary when practical.
- Split compound comments into separate ledger items only when they require
  different evidence or fixes.
- Keep duplicate symptoms linked to one root cause rather than deleting them.
- Include conflicts, stale branch state, obsolete older-head CI,
  generated-output (`dist/`) drift, and other CI failures as first-class ledger
  items.
- Use explicit IDs for non-review feedback when useful, for example
  `CONFLICT-001` for merge/base drift and `CI-001` for check failures, so PR
  bodies can show exactly how operational blockers were closed.

### Mandatory: integrate all PR comments with feedback or findings before branch validation (Stage A)

**Before branch validation (Stage A) can begin, every PR comment that contains feedback
or findings MUST be integrated into the total feedback ledger as a
`FB-###` item.** This is a hard requirement, not a best-effort step.

What counts as "feedback or findings":
- A reviewer request for a code change ("please rename this", "add a test for
  X", "this should call `_internals.foo`")
- A reviewer claim about correctness, security, or style ("this is
  incorrect", "X will leak")
- A bot reviewer's findings table entries
- A CI failure with a specific file:line root cause
- A reviewer question that implies a code change is needed ("why is this
  static?")
- PR review summaries or aggregate comments

What does NOT count (and is therefore not required to be a ledger item):
- Pure acknowledgements ("LGTM", "looks good")
- PR-level metadata changes (title, label, milestone)
- Force-push acknowledgements

Rules:
- **No finding may be addressed outside the ledger.** If you fix something a
  reviewer mentioned, the corresponding `FB-###` item MUST be in the ledger
  before the fix. If you skip the fix, the `FB-###` item MUST be in the
  ledger with a `DISPROVED`, `PRE_EXISTING`, `NEEDS_MORE_EVIDENCE`, or
  `NEEDS_USER_DECISION` status before branch validation (Stage A) can begin.
- **Status semantics for unaddressed items:**
  - `CONFIRMED` and `PARTIAL` items must be addressed (fixed or
    disproved) before branch validation (Stage A) can begin. A `CONFIRMED` item that is
    left unaddressed is a regression against the review.
  - `DISPROVED`, `PRE_EXISTING`, `NEEDS_MORE_EVIDENCE`, and
    `NEEDS_USER_DECISION` items may remain open at branch-validation (Stage A) time, but
    each must be explicitly justified in the closure ledger.
- **The closure ledger at the end of the run must account for every `FB-###`
  item** with a final status (fixed / disproved / pre-existing / needs user
  decision / needs more evidence).
- **Comments from the latest bot round take precedence over earlier rounds**
  for the same finding; the earlier-round `FB-###` item is updated with the
  new evidence rather than a new item being created.
- **Multi-round pattern continues to apply** (see "Multi-Round Bot Reviews"
  section). A new bot round adds new `FB-###` items for findings that
  weren't in the prior round; the prior round's items are carried forward
  and updated with the new evidence.

Rationale: silently addressing a review comment without a corresponding
ledger item means the closure summary at the end of the run cannot
demonstrate that every review comment was considered. The closure summary
is the only artifact the user/maintainer reads to confirm the PR is ready
to merge. Missing items in the ledger = missing items in the closure = a
PR that ships with unreviewed feedback.

## Verification

Classify every ledger item before fixing:

| Status | Meaning |
|---|---|
| `CONFIRMED` | The issue is real, reachable or structurally proven, and introduced or exposed by the PR. |
| `PARTIAL` | The comment points at a real concern, but the framing, severity, or requested fix is incomplete. |
| `DISPROVED` | Source, tests, or execution context prove the claim is false, unreachable, or already mitigated. |
| `PRE_EXISTING` | The issue exists on the base branch and is not materially worsened by the PR. |
| `NEEDS_MORE_EVIDENCE` | The claim (e.g., "council APPROVED") is unsupported by stored evidence (e.g., a missing or failed `.swarm/evidence/` artifact); more information is required before triage. |
| `NEEDS_USER_DECISION` | The item requires a product, UX, compatibility, or scope choice that cannot be inferred. |

Verification checklist:

- Read the referenced file and surrounding code.
- Check caller context, reachability, feature flags, schema validation, guards,
  state-machine rules, and permission boundaries.
- Determine whether the issue is PR-introduced, pre-existing, or unresolved.
- Check related tests and whether a failing/proposed test would prove the item.
- Check whether multiple feedback items share one root cause.

### DI seam migration validation

When the repository uses `_internals` seam / `mock.module()` patterns, apply the validation protocol in `references/operational-gotchas.md`.

## Fix Planning

Cluster ledger items by root cause before coding. Fix in this order unless a user
instruction or dependency requires otherwise:

1. Merge conflicts, stale branch state, and base drift.
2. Deterministic CI, build, typecheck, formatting, and test failures.
3. Confirmed correctness, security, data-loss, persistence, git/write-safety, and
   permission issues.
4. Test gaps needed to prove confirmed fixes.
5. Docs, release notes, PR body, and migration guidance.
6. Reviewer communication and closure summaries.

For each cluster, record:

```text
ROOT-001 | ledger items: FB-001, FB-004 | files | fix approach | tests | docs | risk
```

Do not make scope decisions yourself. If the right fix depends on product intent
or compatibility policy, mark the item `NEEDS_USER_DECISION` and ask.

## Implementation Rules

- Patch only confirmed or partial items, plus required tests/docs.
- Do not implement speculative cleanup while feedback remains unclosed.
- Never ship unwired code. Any new command, tool, skill, config, docs surface, or
  generated artifact must be fully registered and validated.
- Never defer work or declare it out of scope without explicit user instruction.
- Keep invalid or disproved findings in the closure ledger with the evidence.
- For CI failures, verify the failing job belongs to the current PR head before
  treating it as current evidence.
- For generated output or dist failures, inspect the failing log before rebuilding
  and commit regenerated files only when the PR touches the source surface.
- When `main` has a merge queue enabled, do not rebase or force-push a PR only
  because `main` advanced. Once required checks and review are green, queue the PR
  and let the merge queue perform final current-base validation. Still resolve real
   merge conflicts and SHA-dependent review threads before queuing.

### Conditional runtime/host gotchas

For portability gotchas (plan identity, stale gate evidence, PowerShell comment posting, same-file batching), read `references/operational-gotchas.md`.

## Mandatory Gates

**Stage A and Stage B gates and the reviewer + critic closeout gate are
MANDATORY for any change made as part of the PR-feedback process.** No fix
lands, no closure ledger row is marked FIXED, and no PR is published until all
three gates pass on the current diff. This section uses the repository's
established Stage A/B meaning: Stage A = `pre_check_batch`-equivalent structural
pre-checks; Stage B = `reviewer` + `test_engineer` per-task gates (consistent
with `execute`, `plan`, `specify`, `brainstorm`, `docs/swarm-briefing.md`, and
`docs/council/README.md`).

**Mechanical controller contract (Profile A).** Prose acknowledgements, direct `Task` calls,
blocking dispatch, reused conversations, and free-form `APPROVE`/`PASS` text do
not satisfy these gates while the controller is active. The durable controller requires this exact sequence on
one content digest:

Controller authority follows the parent/child session ancestry. Coder and
nested child tool calls inherit the parent feedback gate; delegation never
grants early commit, push, remote-write, checkout, or protected-evidence
authority.

1. `run_pr_feedback_stage_a` with array-form commands for every concrete
   workspace/category/source build, typecheck, and lint/format obligation
   mechanically discovered from the repository's manifests, configs, scripts,
   or bounded `.pr-validation.json` contract, plus exact
   `["git", "diff", "--check"]`. A category with no repository-local signal is
   not invented merely to reach a fixed command count.
   Add one required proof command: use the exact failing CI/test reproduction
   when the immutable inventory includes a defect or CI/test failure; otherwise
   add a repo-appropriate targeted regression/test command that exercises the
   changed behavior. The tool executes the commands; naming a category without
   executing it is not evidence. The controller binds that reproduction receipt
   to the complete immutable feedback inventory, so no feedback item can reach
   Stage B with an unrelated or unowned Stage A receipt.
2. One `dispatch_lanes_async` lane with
   `mode: "swarm-pr-feedback:stage-b-reviewer"`,
   `workflow_lane: "stage-b-reviewer"`, every immutable
   `feedback_item_ids`, and `max_concurrent: 1`.
3. After that lane settles positively, one fresh `test_engineer` lane with
   `mode: "swarm-pr-feedback:stage-b-test"`, matching `workflow_lane`, the
   complete inventory, and `max_concurrent: 1`.
4. After Stage B settles, one separate fresh reviewer lane with
   `mode: "swarm-pr-feedback:closeout-reviewer"`, then one separate fresh
   critic lane with `mode: "swarm-pr-feedback:closeout-critic"`. Each owns the
   complete inventory and uses `max_concurrent: 1`.

Every gate lane emits exactly one fully populated row per feedback ID:

```text
[STAGE-B-REVIEW] | FB-001 | APPROVE|NEEDS_REVISION|BLOCKED | evidence
[STAGE-B-TEST] | FB-001 | PASS|FAIL|BLOCKED | evidence
[CLOSEOUT-REVIEW] | FB-001 | APPROVE|NEEDS_REVISION|BLOCKED | evidence
[CLOSEOUT-CRITIC] | FB-001 | APPROVE|NEEDS_REVISION|BLOCKED | evidence
```

Only exact positive verdict fields pass. A sentence containing “not APPROVE,” a
header without item rows, duplicate rows, missing IDs, degraded/truncated
artifacts, wrong roles, stale content digests, parallel or out-of-order phases,
and reused pre-edit approvals all fail closed. Any content change after Stage A
invalidates Stage A and every later gate; restart at step 1. See
"Re-recording Stage A on an unchanged revision" below for the one retention
exception, which applies only when the revision digest itself did not change.
Publication tools
and `git commit`/`git push` remain blocked until all four ordered lane phases
settle on the Stage-A digest. After they settle, only one standalone `git commit`
command may create the reviewed commit; push and remote publication remain
blocked until that exact commit is armed. The first completion requires a clean
index/worktree and a non-merge direct child commit whose sole parent is the
immutable intake head, so multiple commits, merge commits,
amend/non-descendant histories,
`--allow-empty`, and partially committed reviewed content fail closed. There is no speed, efficiency, token, or time exception.

**Verified no-change terminal (issue #2131 C1).** When the ENTIRE immutable
inventory is verified as a no-change outcome — every `FB-###` item classified
`DISPROVED`, `PRE_EXISTING`, `NEEDS_MORE_EVIDENCE`, or `NEEDS_USER_DECISION`
in the settled verification lanes — a correct workflow needs NO content commit.
After every ordered gate settles, call `complete_pr_workflow` with the intake
`pr_head_sha` while HEAD still equals that intake head and the tree is clean:
it returns `verified-no-change` and clears the gate terminally (nothing to
publish; an empty or `--allow-empty` commit is still forbidden). Any item
classified `CONFIRMED`/`PARTIAL` requires the ordinary exactly-one-reviewed-
commit path above.

**Base-sync/rebind (issue #2131 C2).** When base drift or merge conflicts force
a merge/rebase, the repaired history is no longer a direct child of the intake
head and the ordinary publication path can never be satisfied. Do NOT abort
ad-hoc: finish the repair, fetch the new authoritative PR head, check it out,
then call `rebind_pr_feedback_head` with the new full PR head SHA. It moves the
immutable intake head to the new head, preserves the immutable inventory, and
invalidates every ancestry-bound receipt (Stage A, verification, ordered
gates) — re-run the entire mechanical ladder on the new ancestry. It refuses a
no-op rebind, refuses while publication is armed, and refuses while lanes are
in flight.

**Without the controller (Profiles B/C).** The same gates run in the same
order with the same one-row-per-feedback-ID verdict contracts; what changes is
the executor. Stage A: run the repository's discovered build, typecheck, and
lint/format obligations, exact `git diff --check`, and one targeted
reproduction/regression command yourself, recording each command and its
output as a receipt in the ledger; track the content digest manually (for
example `git rev-parse HEAD` plus a working-tree diff hash) so stale receipts
are detectable, and re-run the whole set after any content change. Stage B:
one fresh reviewer subagent, then one fresh test-engineer-role subagent
(Profile B), or two strictly separated re-derivation passes (Profile C).
Closeout: a separate fresh reviewer, then a separate fresh critic, per the
swarm closeout contract. Emit the same `[STAGE-B-REVIEW]`, `[STAGE-B-TEST]`,
`[CLOSEOUT-REVIEW]`, and `[CLOSEOUT-CRITIC]` rows, record the verdicts in the
session task-gates artifact, and disclose Profile C's procedural independence
in the closure ledger. Any edit after a gate verdict invalidates that verdict
and every later one; restart at Stage A.

If a gate failure is suspected pre-existing, prove it on the base branch or
label it `UNVERIFIED`. Do not call the branch green while required checks are
non-green.

### Stage A — structural pre-checks (mandatory before Stage B)

Run for every changed surface. No "where relevant" — every PR-feedback change
runs these; if a surface is genuinely untouched, state that explicitly rather
than skipping silently.

- the repository's actual build validation for the changed surface — must
  succeed when that surface participates in a build,
- the repository's actual typecheck/static-analysis validation for the changed
  surface — must pass when such a check exists,
- the repository's actual lint/format validation for the changed surface — must
  pass when such a check exists,
- `git diff --check` — no whitespace or merge-marker errors.
- one proof command is mandatory on every run:
  - use the exact failing CI/test command when a ledger item is rooted in a
    defect or CI/test failure; the reproduction must fail on the pre-fix tree
    and pass after the fix.
  - otherwise run a repo-appropriate targeted regression/test command that
    exercises the changed behavior and passes on the post-fix tree.

Execute these through `run_pr_feedback_stage_a` when available. Its bounded
array-form commands are not arbitrary shell escape hatches: diff-check and a
targeted reproduction are unconditional, every mechanically discovered
workspace/category/source obligation is also required, and each command must
match its declared build/typecheck/lint/diff-check/reproduction intent. Multiple
commands in one category are mandatory when polyglot or monorepo discovery
produces multiple obligations; use the exact `working_directory` and
`obligation_id` for each. Every obligation ID gets exactly one independently
executed receipt; identical commands remain separate only when distinct
repository sources mechanically require them. The
reproduction command must name at least one exact test, package, path, or
regression selector in `targets`. Invoke recognized validators and test runners
directly. Standard contained `./gradlew` and `./mvnw` wrappers are supported. A
repository with a custom validator can declare its exact array-form command in a
   bounded `.pr-validation.json` version-1 contract that is byte-identical to
   the immutable `base_ref`/`base_sha` merge-base copy and reference the exact
   contract path/id. A contract added or changed by the PR never authorizes a
   command. When that trusted contract replaces an otherwise opaque named
package script, the controller preserves the contract identity on the discovered
obligation and receipt, requires non-empty execution evidence, and permits only
an exact inspected npm, pnpm, yarn, or Bun script selection. Unsupported
workspace-glob semantics fail closed rather than silently omitting a workspace.
Arbitrary opaque scripts and unverified package-script names remain non-proof
because a name such as `test` or `build` can hide a no-op. A
reproduction must also return non-empty machine-observable runner output.
The reproduction check also supplies one `feedback_targets` row per immutable
feedback ID, in inventory order: exact `feedback_item_id`, one executed `target`,
concrete `expected_behavior`, and a typed `proof_kind` (`defect`, `metadata`,
`source-proof`, `conflict`, `ci`, or `user-decision`). Missing, duplicate,
invented, target-less, or kind-less mappings block Stage B; the controller
persists that exact per-item mapping. This is a STRUCTURAL mapping with a typed
proof kind — it proves each item maps to a target the executed command actually
selects, not that the target is causally decisive for that item; the Stage B
reviewer lane owns that judgement (issue #2131 C4).
No-op/help/list/dry-run,
fix/update, package publication/deployment, Git mutation, remote client,
shell/eval/wrapper, and credentialed publication surfaces fail closed. The
controller snapshots the content revision plus HEAD, index, refs, upstream, and
Git config before and after every command (including failures/timeouts); any
mutation invalidates Stage A and prevents later commands from becoming proof.

The Stage A response carries per-check summaries (category, command, exit code,
duration) rather than inline stdout/stderr. On failure it also carries a bounded
tail of the failing check and a `full_output_ref` for retrieving the complete
output via `retrieve_summary`; if that persistence fails, the failing check's
full stdout/stderr is inlined instead so evidence is never lost. A successful
run persists nothing — there is no failure evidence to recover, and the
per-check summaries are the useful record.

### Re-recording Stage A on an unchanged revision

Re-recording Stage A always requires a fresh, complete receipt set on the
current revision digest — that part is unconditional. What happens to the
already-recorded Stage B and closeout gate batches depends on whether the
revision digest itself changed. If the digest is unchanged from the prior
Stage A record **and** the newly declared applicable obligations/categories
are equal to or a superset of the prior declaration, the already-approved
independent gate batches are retained: re-recording Stage A to add a
previously-missed obligation, or to re-attest the same set, does not by
itself discard Stage B and closeout work that already passed on that
revision. A narrower obligation set than the prior declaration, or any actual
digest change, still wipes every recorded gate batch and un-arms publication
exactly as before — a controller cannot narrow what it declares in order to
dodge re-verification.

### Why gate evidence is not item-scoped

Stage A, Stage B, and closeout evidence invalidate as whole gate batches, not
per feedback item, and that is a deliberate design decision, not unfinished
work:

- **No trustworthy item-to-file mapping exists to key invalidation on.** The
  file scope a caller declares for a feedback item is caller-asserted and
  only path-sanitized — it is never intersected with the actual changed-file
  set, and it carries no persisted binding back to feedback item IDs. Keying
  invalidation on that declaration would let a controller dodge
  re-verification by under-declaring scope, turning a fail-closed guarantee
  into a fail-open one (AGENTS.md invariant 9) — the same failure class that
  already ruled out keying digest invalidation on `git diff --raw` blob OIDs.
- **The four gate phases are holistic by contract.** Each recorded batch must
  own every inventory item exactly once and in declared order. Retaining
  evidence for a subset of items per gate would re-partition that
  independent-review contract itself, and would need its own
  collusion/independence analysis before it could be trusted — it is not a
  drop-in extension of the revision-level retention above.

### Stage B — reviewer + test_engineer (mandatory after Stage A passes)

Two independent agents on the Stage-A-green diff, run in order: **reviewer
first**, then **test_engineer**. The reviewer validates the fixes before the
test_engineer writes falsification probes against them; running them in parallel
risks the test_engineer pinning a not-yet-approved fix shape.

- **reviewer** — independent (fresh context, not the implementer, not a continued
  conversation). Validates each fix on the current diff against the feedback
  item it closes. Verdict per item: APPROVE / NEEDS_REVISION / BLOCKED.
- **test_engineer** — independently designs and runs the falsification probe or
  regression test that proves each fix resolves its item (tests for changed
  behavior or newly covered gaps). The structured gate lane is read-only: if a
  missing test must be authored, return `FAIL` with the exact requested probe so
  implementation can add it before the sequence restarts. Verdict per item:
  PASS / FAIL / BLOCKED.

Address every NEEDS_REVISION / BLOCKED / FAIL, then restart at Stage A on the
current diff. When implementation authors or modifies test files requested by
the test_engineer, the content-digest controller invalidates all earlier
receipts automatically. Stage A must be green over the full Stage-B-inclusive
diff before a new Stage B reviewer and test engineer run.

### Closeout gate — reviewer + critic (mandatory after Stage B)

A *separate* reviewer + critic pair on the Stage-B-approved diff. This is the
swarm closeout contract (see `../swarm/SKILL.md` "Mandatory implementation
closeout gate"); because this skill edits code, docs, release notes, or skill files it applies in full — Stage B
alone does not satisfy it.

- **independent reviewer** (fresh context, separate from the Stage B reviewer)
  → APPROVE / NEEDS_REVISION / BLOCKED per item.
- **final critic** (separate fresh context, not a continued conversation with
  the reviewer, dispatched after the reviewer returns APPROVE) → APPROVE /
  NEEDS_REVISION / BLOCKED per item. The critic challenges: is every original
  feedback item actually resolved? Any requirement drift, weak evidence, missing
  sibling-file checks, stale approvals, anything unwired or silently deferred?

Address every NEEDS_REVISION / BLOCKED item, re-review with the reviewer if the
critic surfaces correctness issues, then re-critic. **Any edit after the
reviewer's or critic's approval invalidates that approval** — re-run the
affected gate on the current diff before publishing.

Record both closeout verdicts (reviewer + critic, with HEAD/diff) in the
runtime's session task-gates artifact using the repository/runtime-specific
durable-session guidance when one exists. `.swarm/` is the plugin's runtime
state — never write task artifacts there.

### Post-publish verification (mandatory after the PR is pushed)

These checks run after the fix lands on the remote — they are NOT Stage A
pre-checks and must not be folded into Stage A.

- PR metadata checks after push: head SHA, check status,
  mergeability/conflicts, and unresolved feedback state.
- After conflict fixes, verify remote mergeability is clean (`MERGEABLE` /
  `CLEAN`), not only that local conflict markers disappeared.
- For current-head CI, prefer run-level details when PR checks look stale:
  `gh run view <run-id> --json headSha,status,conclusion,jobs,url`.

## Publishing And Communication

After every ordered local gate passes on one unchanged content digest, create
the reviewed commit with one standalone `git commit` command. Under Profile A,
then call
`complete_pr_workflow` once with `mode: "PR_FEEDBACK"` and the immutable intake
`pr_head_sha`. A `ready-to-publish` result arms publication but deliberately
keeps the durable gate active and binds that post-commit HEAD to the current
branch's exact upstream remote-tracking ref. Configure the repository's intended
PR-branch upstream before committing and arming. Push is blocked before this
transition. Arming fails unless the index/worktree are clean and the bound HEAD
is a non-merge direct child whose sole parent is the immutable intake head. Any content
mutation or amend after it is blocked; restart at Stage A if the approved
content must change.

After arming, publish with exactly one non-force, single-ref command of the
form `git push <bound-remote> <bound-commit>:refs/heads/<bound-branch>`. The
source must be the literal commit ID bound by the first completion call, not
`HEAD`; the destination must be the branch behind the bound upstream
remote-tracking ref. Force flags, mirror/all/tags/delete operations, extra
refspecs, URLs, wrappers, `git -C`, `gh` writes, aliases, and other publication
surfaces fail closed. Read-only inspection remains available. Immediately
after the exact push and read-only remote verification, call
`complete_pr_workflow` again to prove the bound remote-tracking ref points at
the bound commit. Completion also performs a bounded query of the actual remote
branch; a locally forged or fetched tracking ref is never publication proof.
The gate clears only after both observations agree, before any PR
comment/body/thread write.

Under Profiles B/C, the same publication invariants apply procedurally: one
reviewed commit on the PR branch, a single non-force push of exactly that
commit to the PR head branch through the repository's normal workflow, then
read-only verification that the actual remote head equals the pushed commit
before any PR comment/body/thread write.

Commits and pushes follow the repository's commit/PR workflow (for example
`file:.swarm/bundled-skills/commit-pr/SKILL.md` when that bundled workflow is
available) — do not push ad-hoc.

After fixes, update the PR body or comment with a closure ledger:

```text
FB-001 | fixed | commit/test evidence
FB-002 | disproved | code evidence
FB-003 | pre-existing | base-branch evidence
FB-004 | needs user decision | decision required
FB-005 | needs more evidence | .swarm/evidence/{phase}/phase-council.json missing
CONFLICT-001 | fixed | remote mergeability is MERGEABLE/CLEAN
CI-001 | fixed | current-head check/run evidence
```

Do not resolve GitHub review threads unless explicitly instructed. If instructed,
resolve only threads whose ledger item is fixed or disproved on the pushed PR
head, and record the exact evidence used.

## Final Output

Under Profile A, before emitting the user-facing final response, call
`complete_pr_workflow` a
second time with the same mode and immutable verification `pr_head_sha`. The
tool clears the durable session gate only when the content digest still equals
the independently approved digest, the exact approved commit remains current,
its bound upstream remote-tracking ref points to that exact commit, every
feedback ID has exact-provenance evidence, and no PR-workflow lanes remain
open. While the gate remains active, the runtime prepends a workflow-active
banner to architect text (the model's text is preserved below it) and normally re-wakes an
idle parent session. A user interruption pauses automatic wakes until a later
explicit user turn settles; the durable gate remains available to continue or
abort. When the terminal response reports `checkout_restore_required`, call
`prepare_pr_workflow_checkout` with `operation: "restore"` before returning to
the user. When `checkout_restore_receipts` lists multiple entries, one restore
call reapplies all receipts that share the recorded destination; an optional
listed `stash_oid` is an exact inventory assertion, not a selector that leaves
the other receipts pending. Successfully applied stashes remain in Git as
explicit safety backups and are listed in `retained_stash_oids`; the controller
never drops a mutable `stash@{n}` selector. The restore refuses
dirty, mixed-destination, missing-stash, invalid-receipt, cross-session, or
divergent state without reset/clean and preserves recovery evidence on failure.
Legacy receipts derive their original commit from the preserved stash and
select a uniquely matching local branch when available.

Under Profiles B/C, no mechanical gate exists: emit the final response only
after the closure ledger accounts for every original item and the pushed
remote head has been verified read-only.

Report:

- intake sources checked and unavailable sources,
- ledger counts by status,
- root-cause clusters fixed,
- tests and commands run,
- unresolved user decisions,
- CI/mergeability state,
- whether review-thread resolution was skipped or explicitly performed.

End with a complete ledger mapping every original item to its outcome.

## Aborting or cancelling an unrecoverable feedback workflow (Profile A)

If the verification bind is genuinely unreachable (the PR head cannot be
fetched or checked out, or a compound `git fetch … && git checkout …` keeps
being rejected — run them as TWO separate standalone commands first), call
`abort_pr_workflow` with `mode: "PR_FEEDBACK"`, `kind: "recovery"`, and a
one-line `reason` while the workflow is pre-armed. Plain recovery/force aborts
refuse once publication is armed. To terminate an armed publication without
publishing, use `kind: "cancel-publication"`, `cancel_publication: true`, and a
non-empty `reason`. This records terminal `cancelled_without_publication` with
the observed remote head, never grants push authority, and then clears the gate.
Do not substitute a plain abort. To change approved content, use
`invalidate_pr_feedback_publication`; the full Stage A and ordered independent
gates must run again. A published generation is never cleared by abort; use
`complete_pr_workflow` so the actual remote branch is re-verified. When abort
reports `checkout_restore_required`, call `prepare_pr_workflow_checkout` with
`operation: "restore"` before returning. On Profiles B/C there is no durable
gate to abort: report the blocker to the user and stop.
