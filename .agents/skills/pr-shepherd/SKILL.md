---
name: pr-shepherd
description: >-
  Thoroughly gate one or more open GitHub PRs to an honestly landable state:
  inventory reviewer findings, verify each is fixed or intentionally deferred
  with evidence, drive critical CI green, then merge when captain merge
  authority exists and otherwise stop at a merge-ready report.
  Use when the user asks to babysit/shepherd a PR, ensure reviewer comments are
  addressed, get CI green and land a PR, "make sure comments are fixed",
  "drive to merge", or invokes /pr-shepherd.
user-invocable: true
argument-hint: "<pr-number-or-url> [pr...] [--no-merge]"
metadata:
  internal: true
---

# pr-shepherd

`pr-shepherd` is a gated PR landing pipeline for existing open pull requests.
It is the counterpart of `no-mistakes`, which gates your own uncommitted work before and through open, while this skill gates a PR that already exists.
You drive a fixed sequence of phases until the PR is honestly landable, then either merge it under real authority or stop at a merge-ready report.

Terminal success is a landed PR when merge authority exists, and a merge-ready report when it does not.
You are the AXI driver: every phase produces evidence, skip nothing, and never claim "comments addressed" without a per-finding disposition table.

## Merge authority

Merge authority is an input to this skill, not something the skill grants itself.
`AGENTS.md` section 1 hard rule 2 is the owner: never merge a PR without the captain's word.

Phase 7 may merge only when at least one of these authority paths holds for the PR in front of you:

- (a) A standing shepherd or merge posture recorded in this home's `data/captain.md`, or in an inherited `data/captain-shared.md` when secondmate inheritance applies, in the scoped, captain-marked bullet form `docs/configuration.md` owns.
- (b) The project's captain-approved `yolo` posture, for routine green merges within its scope.
- (c) A current explicit captain word to merge that PR.

Path (a) is satisfied only by reading such a bullet in one of those two files and confirming both its captain-provenance marker and a scope that names this PR's project.
Read the file rather than inferring the posture: a missing bullet, a missing marker, or a scope that does not name this project makes path (a) false, and merge then needs path (b) or path (c).
Never write, mark, or widen such a bullet to create the authority this skill is about to rely on.
Invoking `/pr-shepherd` is not by itself authority path (a).
Paths (a) and (b) cover a routine green merge only, so an admin or branch-protection-bypass merge always needs path (c) naming that bypass, per Phase 7.
A PR that changes any surface the merge-authority contract rests on needs path (c) for that PR, because paths (a) and (b) never cover a change to the rules that grant them; hard rule 2 owns that list, and it includes the recorded-posture form in `docs/configuration.md` and this section.
When none of (a), (b), or (c) holds, finish the pipeline and stop at the merge-ready report, exactly as if `--no-merge` had been passed.
`--no-merge` forces report-only even when authority exists.
Merging is never the default for an environment that has granted none of these paths.

## When to load

- Captain or user: `/pr-shepherd`, "shepherd this PR", "get comments fixed and CI green", "drive PR N to merge", "are reviewer comments addressed?".
- Firstmate: before reporting a ship PR ready, before an autonomous merge under `yolo`, and any time a bot or human left formal or informal review feedback.

## Modes

| Invocation | Behavior |
|---|---|
| `/pr-shepherd <n>` or URL | Full pipeline; merge when gates 3-5 pass and an authority path holds, otherwise report merge-ready. |
| `/pr-shepherd <n> --no-merge` | Same pipeline; always stop at merge-ready and report only. |
| Multiple PRs | Process bottom-up if stacked, otherwise one at a time; stack desync is a hard gate; land each as it clears gates and authority. |

Plain language "shepherd", "drive to land", or "get it merged" selects the full pipeline, but it still resolves merge through the authority paths above rather than assuming permission.

## Hard rules

1. Never invent "addressed": every unresolved thread, formal CHANGES_REQUESTED body, and consensus BLOCKER or WARN from bot review gets a disposition row.
2. Never merge red CI; optional or non-blocking checks may remain pending only when explicitly classified as advisory in Phase 4.
3. Never merge without one of the authority paths in the merge-authority section, and never merge red or with an open BLOCKER even when authority exists.
4. Never force-push without `--force-with-lease`, and prefer rebase plus lease after the base advances.
5. Never discard unlanded work to clear a path.
6. Dead-code and wrong-surface findings are blockers: if a review says the change is on an unused component, verify importers with `git grep` or search before disposing as NIT.
7. Do not equate "I approved it" with "reviews addressed", because your approval does not clear bot BLOCKERs or open threads.
8. Under firstmate, never run a state-changing command under `projects/` or in any project worktree yourself, including edit, commit, checkout-for-edit, rebase, branch update, and any push; `AGENTS.md` hard rule 1 reserves those for crewmates, and the project-write boundary section below is this skill's single owner of how that applies here.

## Pipeline overview

```
intake -> inventory -> thorough-review -> comments -> ci -> base/stack -> report -> merge
```

Each phase ends with a gate.
Fail closed: missing evidence means not ready.

## GitHub command surface

Under firstmate, use `gh-axi` for GitHub operations per `AGENTS.md`, and consult `gh-axi --help` and each subcommand's help rather than memorizing flags.
For a task-owned PR merge, use `bin/fm-pr-merge.sh <task-id> <url>` so `pr=` and `pr_head=` are recorded for the teardown landed-work test; never call a lower-level merge command around that guard.
`gh-axi api` takes REST paths, so the Phase 1b GraphQL `reviewThreads` pagination is the one call that stays on raw `gh api graphql`; re-check `gh-axi api --help` first in case it has gained a GraphQL form.
Outside firstmate, raw `gh` and `gh api` are fine and the standalone examples below apply directly.

## Project-write boundary

This section is this skill's single owner of who performs project writes, and every phase below defers to it.

Under firstmate, every project-mutating git action is crewmate-only work in an isolated task worktree: editing, committing, checking out a project branch to change it, fetching or otherwise mutating a project clone, rebasing, updating a branch against its base, and any push including `--force-with-lease`.
Firstmate dispatches or steers a crewmate for those actions, then reads the result through `gh-axi` and read-only git to verify it.
That includes `git fetch`, which takes ref locks in the shared object store and can fail a live crewmate's rebase or push, so firstmate never fetches a project clone or task worktree at all.
There is no idle-worktree exception: when inventory needs refs that are not already local, ask the crewmate that owns the worktree to fetch, and otherwise read the head through `gh-axi` instead.
Outside firstmate, perform those actions yourself on an isolated checkout of the PR branch.

---

## Phase 0 - Intake

1. Resolve owner/repo.
2. Read each PR's identity, state, draft status, base and head refs, head SHA, mergeability, merge state, review decision, author, commits, and files.
   ```bash
   # firstmate
   gh-axi pr view <n> --repo <owner/repo>
   # standalone
   gh pr view <n> --repo <owner/repo> --json number,title,state,isDraft,url,baseRefName,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,author,commits,files
   ```
3. Refuse CLOSED and MERGED PRs with a report only.
4. Undraft only when the user wants landing and the sole draft reason was a temporary hold you placed, otherwise ask.
5. Detect a stack by walking open PRs whose `baseRefName` is another PR's `headRefName`.
6. If stacked, process bottom-up; if desynced through independent rebases of the same stack, stop and fix topology before comment or CI work.

**Gate 0:** Open PR identity, base and head SHAs, and the stack map are recorded.

---

## Phase 1 - Inventory (read-only evidence pack)

Collect all of the following before anything is edited.

### 1a. Human and formal reviews

```bash
# firstmate
gh-axi pr view <n> --reviews
# standalone
gh api repos/<o>/<r>/pulls/<n>/reviews --paginate --jq '.[] | {user: .user.login, state: .state, submitted_at, body}'
```

Note DISMISSED versus active CHANGES_REQUESTED or APPROVED.

### 1b. Unresolved review threads (paginate)

Query GraphQL `reviewThreads` for `isResolved`, `isOutdated`, full comment bodies, paths, and authors.
Page until `hasNextPage` is false.
This is the deliberate raw `gh api graphql` exception described in the command-surface section above.

### 1c. Issue-level comments, bot and human

```bash
# firstmate
gh-axi api /repos/<o>/<r>/issues/<n>/comments --paginate --jq '.[] | {user: .user.login, body}'
# standalone
gh api repos/<o>/<r>/issues/<n>/comments --paginate --jq '.[] | {user: .user.login, body}'
```

Collect every top-level comment first and classify by author afterwards, because a reviewer who leaves feedback as a plain comment rather than a formal review is invisible to 1a and 1b.
For a bot body, parse BLOCKER, WARN, NIT, CONSENSUS, and CHANGES_REQUESTED out of the text, including `<!-- claude-pr-review -->` style markers.
A human comment carries no severity label, so read it and assign one yourself: "this drops the migration, do not land" is a BLOCKER even though nothing marks it as one, and it earns a disposition row exactly like a formal finding.
The PR author's own comments are context rather than findings, except where one leaves an open question for someone else.

### 1d. Checks

```bash
# firstmate
gh-axi pr checks <n>
# standalone
gh pr checks <n> --repo <o>/<r>
gh pr view <n> --json statusCheckRollup
```

### 1e. Diff reality

```bash
# firstmate
gh-axi pr diff <n>
# standalone
gh pr diff <n> --name-only
gh pr diff <n>
```

For any finding that claims "unused", "dead component", or "zero importers", check importers against the real head.

Under firstmate this inventory stays read-only against the remote head: `gh-axi pr diff <n>` and the forge's file listing answer most importer questions without touching a clone.
When a tree-wide search genuinely needs a local tree, delegate it to the crewmate that owns the worktree, per the project-write boundary, and never fetch to make the search possible.
A `git grep` against refs that are already local stays read-only and is fine either way.

Standalone, or as the crewmate in its own worktree:

```bash
git fetch origin <headRefName>
git grep -n '<SymbolOrFilename>' origin/<headRefName> -- '*.ts' '*.tsx' '*.js'
```

**Gate 1:** A written inventory exists in chat or a scratch note, and no phase 2 or later work starts without it.

---

## Phase 2 - Thorough review (independent read)

Before trusting prior approvals, do a fresh pass on the current head.

1. Read the PR body for claimed scope and verification.
2. Walk the diff for correctness, security, product mismatch, and tests.
3. Cross-check bot and human findings against the code, confirming or refuting each with file evidence.
4. Flag new issues you find that nobody mentioned.

Optionally run a cross-vendor PR review skill when one is available, and still validate every cited path against the real diff because hallucinated paths do not count.

**Gate 2:** A short shepherd-review note exists that is either approve-with-findings or a list of new blockers; an empty "LGTM" without inventory is invalid.

---

## Phase 3 - Comments gate (hard)

Build a disposition table for every item from Phase 1.

| ID | Source | Severity | Summary | Disposition | Evidence |
|----|--------|----------|---------|-------------|----------|
| t1 | thread | … | … | fixed \| reply \| defer \| wontfix \| outdated | commit SHA / reply URL / reason |
| b1 | bot BLOCKER | … | … | … | … |
| h1 | human comment | severity you assigned | … | … | … |

### Disposition rules

| Severity | Allowed dispositions |
|----------|----------------------|
| BLOCKER or formal CHANGES_REQUESTED consensus | **fixed** with code pushed, replied to after push with the SHA. |
| WARN, consensus or product-correctness | **fixed** preferred; **defer** only with captain or user OK plus a backlog note; **wontfix** only with a written technical rebuttal posted on the thread. |
| NIT | fixed when cheap, otherwise a reply with rationale. |
| Outdated or already on main | **outdated** with SHA proof. |
| Question or clarification | **reply** with a substantive technical answer, never "will fix" or "ack". |

### Who makes the code fix

Code fixes follow the project-write boundary above: under firstmate a crewmate makes and pushes them in its own isolated task worktree while firstmate steers, reviews dispositions, and verifies the pushed result.

### Required code verification for "fixed"

1. Confirm the change is on the PR head rather than only in a local dirty tree.
2. Re-read the resolved path at the new head after the push lands, through `gh-axi pr diff` or the forge under firstmate, and on `origin/<head>` standalone.
3. For dead-surface claims, re-run the importer search after the fix.

### Cap and re-run

- Prefer fixing all WARNs that touch correctness in the same PR.
- After pushes, re-fetch reviews, threads, and bot comments, because old DISMISSED reviews do not prove the new head is clean.
- Wait for re-review when a formal bot CHANGES_REQUESTED was active.

**Gate 3 (comments-addressed):** Zero open BLOCKER dispositions other than `fixed` with evidence, zero unresolved threads that still need code, and every WARN either fixed or deferred with explicit authority.
Any incomplete row means not ready.

---

## Phase 4 - CI gate (hard)

1. Classify every check.
   - Critical: anything required for merge, plus CI, test, lint, typecheck, quality, build, and guardrail jobs that normally block.
   - Advisory: clearly non-blocking review bots, only when you have evidence they never block merge.
   - Default unknown checks to critical.
2. On failure, pull the logs, get the fix made, and re-wait.
   - Read failures with `gh-axi run view <id>` under firstmate or `gh run view <id> --log-failed` standalone, or open the job URL.
   - Make the branch fix through the project-write boundary above.
3. Do not claim green while critical checks are pending or failing.
4. Allow one re-run for a single suspected flake, then fix the root cause.

**Gate 4 (ci-green):** All critical checks pass, and no critical check is failed, cancelled, or timed out without resolution.

---

## Phase 5 - Base, stack, and mergeability

1. Resolve a CONFLICTING `mergeable` or `mergeStateStatus` by rebasing onto the current base, bottom of the stack first.
2. When behind main but clean, prefer an update or rebase so CI matches the landing base.
3. For a stack, the upper PR's diff against main must not re-introduce lower PR content after the lower one merges.

Steps 1 and 2 are project writes, so they follow the project-write boundary above: under firstmate, dispatch or steer a crewmate to rebase or update the branch and push, and read the resulting mergeability back through `gh-axi` rather than rebasing the project branch yourself.

**Gate 5:** The PR is MERGEABLE, or a known platform lag is recorded with a recheck, and the stack is consistent.

---

## Phase 6 - Report (always, before any merge)

Emit a captain-facing or user-facing summary in outcomes rather than mechanics.

```markdown
## PR shepherd: <title>
URL: https://github.com/.../pull/N

### Status: merge-ready | merging | blocked | merged

### Comments
| Finding | Disposition | Evidence |
| ... | ... | ... |

### CI
Critical: green | red (list failures)

### Shepherd review
1-5 bullets of independent findings, or "none beyond inventory"

### Next
- merge-ready, awaiting captain word / merging now / merged <url> / blocked on <decision>
```

Under firstmate, translate internal terms per `AGENTS.md` section 9.

**Gate 6:** The report is prepared, and Phase 7 runs only when gates 3-5 passed, `--no-merge` was not passed, and an authority path holds.

---

## Phase 7 - Merge (only under authority)

Merge when all of the following hold.

1. Gates 3-5 passed on the current head SHA, meaning comments addressed, critical CI green, and mergeable with a consistent stack.
2. One of the merge-authority paths (a), (b), or (c) holds for this PR.
3. The user did not pass `--no-merge`.
4. No higher-priority hard boundary blocks the merge, such as red CI, an open BLOCKER, or a destructive or irreversible step beyond a normal merge; soft bot WARNs disposed as fixed, wontfix, or defer-with-reason do not block.

When any of those fail, stop at the merge-ready report and say exactly what is missing, including which authority is absent.

Use the project's merge path:

- Firstmate, task-owned PR: `bin/fm-pr-merge.sh <task-id> <url>`.
- Firstmate, otherwise: `gh-axi pr merge <n> --squash` or the repo default method.
- Standalone: `gh pr merge <n> --squash` or the repo default method.

Prefer the normal merge path and do not reach for `--admin`.
`--admin` bypasses branch protection the forge is actively enforcing, so it is allowed only when gates 3-5 already pass and the captain gives a current explicit instruction naming the admin merge, or an equivalent protection bypass, for that PR.
Authority paths (a) and (b) never authorize it, no matter how the recorded posture or `yolo` scope is worded.
An agent's own judgement that a required review is stale is never sufficient.

After merge, confirm `state=MERGED`, report the full URL, and give a one-line outcome.
Under firstmate, `AGENTS.md` section 7 owns landing, fleet sync, and teardown from that point.

**Done criteria for the skill:** either `outcome: merged` with the URL, or `outcome: merge-ready` with the missing gate or authority named.

---

## Firstmate integration

| Concern | Rule |
|---------|------|
| Project writes | Every project-mutating git action, including rebase and any push, is crewmate-only per the project-write boundary section (hard rule 1). |
| PR open from ship | After a worker reports green, still run Phases 1-3 before considering a merge. |
| Bot formal CHANGES_REQUESTED | Block merge until a re-run clears it or code fixes land. |
| Worker status lines | `AGENTS.md` section 7 owns the ready signal; a ship worker still reports `done: PR <url> checks green` when CI goes green, and `done: PR <url> merged` follows only once this skill has actually landed it. |
| Status line `done: PR … checks green` | Treat as a worker claim and re-verify gates 3-4 yourself before merging. |
| Shepherd terminal | Merge only under an authority path; otherwise stop at merge-ready. |
| `--no-merge` | Report-only, regardless of available authority. |

The sequence is checks green first, then merge when authorized, then merged; never withhold the checks-green ready signal while waiting on merge.

Suggested captain invocation: `/pr-shepherd 4125` or `/pr-shepherd https://github.com/org/repo/pull/4125`.

---

## Relationship to other tools

| Tool | Role |
|------|------|
| `no-mistakes` | Pre-merge validation of your own branch and pipeline work. |
| **pr-shepherd** | Thorough single or stacked land gate for an existing PR, ending in a merged PR under authority or a merge-ready report. |

Prefer `pr-shepherd` when the honesty of "comments addressed, CI green, landed" matters.
Use `--no-merge` when you want the full gate without any merge.

---

## Anti-patterns (learned the hard way)

- Approving and merging while a bot BLOCKER is still a formal CHANGES_REQUESTED.
- Merging on the assumption that running this skill is itself permission to merge.
- Wiring UI to a component with zero importers because the PR body said so.
- Treating a quality or knip flake as "whole tree debt" without running the ratchet.
- Claiming CI green when only title or body lint ran and full CI never triggered.
- Merging the stack top while it still contains the bottom's files after both rebased independently.
- Leaving collapsed a11y WARNs unfixed on the PR that introduced them.

---

## Minimal command cheatsheet

Firstmate path:

```bash
gh-axi pr view N
gh-axi pr view N --reviews
gh-axi pr checks N
gh-axi pr diff N
gh-axi api /repos/O/R/issues/N/comments --paginate
gh-axi pr comment N --body "..."
bin/fm-pr-merge.sh <task-id> <pr-url>   # task-owned PR, only under authority
```

Standalone path:

```bash
gh pr view N --json url,state,headRefOid,reviewDecision,mergeable,statusCheckRollup
gh pr checks N
gh api repos/O/R/pulls/N/reviews --paginate
gh api repos/O/R/issues/N/comments --paginate
gh pr diff N --name-only
gh pr comment N --body "..."
gh pr merge N --squash                  # only under authority and green gates
```

Read-only, either path, against refs that are already local:

```bash
git grep -n Symbol origin/branch -- '*.ts' '*.tsx'
```

Project writes, standalone or crewmate only per the project-write boundary:

```bash
git fetch origin <headRefName>
git rebase origin/<base>
git push --force-with-lease             # only if a rebase rewrote history
```
