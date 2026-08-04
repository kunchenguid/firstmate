---
name: pr-shepherd
description: >-
  Thoroughly review one or more GitHub PRs and shepherd them to merge when gates
  pass: inventory reviewer findings, verify each is fixed or intentionally deferred
  with evidence, drive CI to green, fix real failures, report a gate-style outcome,
  and merge by default. Use when the captain asks to babysit/shepherd a PR, ensure
  reviewer comments are addressed, get CI green and land a PR, "make sure comments
  are fixed", "drive to merge", or invokes /pr-shepherd.
user-invocable: true
argument-hint: "<pr-number-or-url> [pr...] [--no-merge]"
metadata:
  internal: true
---

# pr-shepherd

`pr-shepherd` is a gated PR landing pipeline for existing open pull requests.
It is the counterpart of `no-mistakes` (which gates your uncommitted work before and through open): you drive a fixed sequence of phases until the PR is honestly merge-ready, then **merge by default** when all hard gates pass.

You are the pipeline driver: every phase produces evidence; skip nothing; never claim "comments addressed" without a per-finding disposition table.

## When to load

- Captain: `/pr-shepherd`, "shepherd this PR", "get comments fixed and CI green", "drive PR N to merge", "are reviewer comments addressed?"
- Firstmate: before reporting a ship PR ready, before autonomous merge under `yolo`, and any time a bot or human left formal or informal review feedback.

## Modes

| Invocation | Behavior |
|---|---|
| `/pr-shepherd <n>` or URL | Full pipeline; **default terminal is merge** after all hard gates pass. |
| `/pr-shepherd <n> --no-merge` | Same pipeline through report only; stop at **merge-ready** without merging. |
| Multiple PRs | Process **bottom-up** if stacked; otherwise one at a time. Stack desync is a hard gate. |

Invoking `/pr-shepherd` (without `--no-merge`) is merge authority for that PR once gates pass.
Standing firstmate `yolo` is not required for a captain-invoked `/pr-shepherd`, but red CI and incomplete comment dispositions still block merge.
Translate "report only" / "don't merge yet" into `--no-merge`.

## Hard rules

1. **Never invent "addressed."** Every unresolved thread, formal CHANGES_REQUESTED body, and consensus BLOCKER/WARN from bot review gets a disposition row.
2. **Never merge red CI.** Optional/non-blocking checks (for example long-running advisory review jobs you have evidence are non-required) may remain pending only when explicitly classified - see CI.
3. **Default terminal is merge.** When gates 3–5 pass on the current head, merge unless `--no-merge` was requested.
4. **Never force-push without `--force-with-lease`.** Prefer rebase + lease after base advances.
5. **Never discard unlanded work** to clear a path.
6. **Dead-code / wrong-surface findings are blockers.** If a review says the change is on an unused component, **verify importers with `git grep` / search** before disposing as NIT.
7. **Do not equate "I approved it" with "reviews addressed."** Your approval does not clear bot BLOCKERs or open threads.

## Pipeline overview

```
intake → inventory → thorough-review → comments → ci → base/stack → report → merge
```

Each phase ends with a **gate**.
Missing evidence means not ready.
Merge is the default final step when gates pass; only `--no-merge` stops after the report.

---

## Phase 0 - Intake

1. Resolve owner/repo (default: `gh-axi repo view --json nameWithOwner`, or `gh` when outside a firstmate home).
2. For each PR number/URL:

```bash
gh-axi pr view <n> --repo <owner/repo> --json number,title,state,isDraft,url,baseRefName,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,author,commits,files
```

3. Refuse CLOSED/MERGED (report only).
   Undraft if the captain wants land and the only draft reason was a temporary hold you placed - otherwise ask.
4. Detect stack: walk open PRs where `baseRefName` is another PR's `headRefName`.
   If stacked, process bottom-up; if desynced (independent rebases of the same stack), stop and fix topology before comment/CI work (rebase onto base PR or main, thin the upper PR to unique delta).

**Gate 0:** Open PR identity, base/head SHAs, stack map recorded.

---

## Phase 1 - Inventory (read-only evidence pack)

Collect **all** of the following before editing anything:

### 1a. Human + formal reviews

```bash
gh-axi api repos/<o>/<r>/pulls/<n>/reviews --jq '.[] | {user: .user.login, state: .state, submitted_at, body}'
```

Note DISMISSED vs active CHANGES_REQUESTED / APPROVED.

### 1b. Unresolved review threads (paginate)

GraphQL `reviewThreads` with `isResolved`, `isOutdated`, full comment bodies, paths, authors.
**Page until `hasNextPage` is false.**

### 1c. Bot / issue review comments

```bash
gh-axi api repos/<o>/<r>/issues/<n>/comments --jq '.[] | select(.user.login|test("bot|github-actions|gemini|claude|copilot|coderabbit";"i")) | {user: .user.login, body}'
```

Parse **BLOCKER**, **WARN**, **NIT**, **CONSENSUS**, **CHANGES_REQUESTED** from bodies (including `<!-- claude-pr-review -->` style).

### 1d. Checks

```bash
gh-axi pr checks <n> --repo <o>/<r>
# and/or
gh-axi pr view <n> --json statusCheckRollup
```

### 1e. Diff reality

```bash
gh-axi pr diff <n> --name-only
gh-axi pr diff <n>   # or compare main...head for content questions
```

For any finding that claims "unused" / "dead component" / "zero importers":

```bash
git fetch origin <headRefName>
git grep -n '<SymbolOrFilename>' origin/<headRefName> -- '*.ts' '*.tsx' '*.js' ...
```

**Gate 1:** Written inventory exists (in chat or a scratch note).
No phase 2+ without it.

---

## Phase 2 - Thorough review (independent read)

Before trusting prior approvals, do a **fresh** pass on the current head:

1. Read the PR body for claimed scope and verification.
2. Walk the diff for correctness, security, product mismatch, and tests.
3. Cross-check bot/human findings against the code (confirm or refute with file evidence).
4. Flag new issues you find that nobody mentioned.

Optional: run a cross-vendor PR review skill if available; still validate every cited path against the real diff (hallucinated paths do not count).

**Gate 2:** Short "shepherd review" note: approve-with-findings, or list new blockers.
Empty "LGTM" without inventory is invalid.

---

## Phase 3 - Comments gate (hard)

Build a disposition table for **every** item from Phase 1:

| ID | Source | Severity | Summary | Disposition | Evidence |
|----|--------|----------|---------|-------------|----------|
| t1 | thread | … | … | fixed \| reply \| defer \| wontfix \| outdated | commit SHA / reply URL / reason |
| b1 | bot BLOCKER | … | … | … | … |

### Disposition rules

| Severity | Allowed dispositions |
|----------|----------------------|
| **BLOCKER** / formal CHANGES_REQUESTED consensus | **fixed** (code + push) only. Reply after push with SHA. |
| **WARN** (consensus or product-correctness) | **fixed** preferred; **defer** only with captain OK and backlog note; **wontfix** only with written technical rebuttal posted on the thread. |
| **NIT** | fixed if cheap; else reply with rationale. |
| Outdated / already on main | **outdated** with SHA proof. |
| Question / clarification | **reply** with substantive technical answer (never "will fix" / "ack"). |

### Required code verification for "fixed"

1. Confirm the change is on the **PR head** (not only local dirty tree).
2. Re-read the resolved path on `origin/<head>` after push.
3. For dead-surface claims: re-run importer search post-fix.

### Cap and re-run

- Prefer fixing all WARNs that touch correctness in the same PR.
- After pushes, **re-fetch** reviews/threads/bot comments - old DISMISSED reviews do not prove the new head is clean; wait for re-review when a formal bot CHANGES_REQUESTED was active.

**Gate 3 (comments-addressed):** Zero open **BLOCKER** dispositions other than `fixed` with evidence; zero unresolved threads that still need code; every WARN either fixed or deferred with explicit authority.
If any row is incomplete, the PR is **not ready**.

---

## Phase 4 - CI gate (hard)

1. Classify checks:
   - **Critical:** anything that is required for merge, all `CI` / test / lint / typecheck / quality / build / guardrail jobs that normally block, and any check the repo treats as required.
   - **Advisory:** clearly non-blocking review bots (only if you have evidence they never block merge, for example optional check runs).
     Default: treat unknown as **critical**.
2. On failure:
   - Pull logs (`gh-axi run view <id> --log-failed` or job URL).
   - Fix on the PR branch in an isolated worktree when under firstmate; push.
   - Re-wait.
3. Do **not** claim green while critical checks are `pending` or `fail`.
4. Flaky single flakes: one re-run max, then fix root cause.

**Gate 4 (ci-green):** All critical checks `pass` (or `success`); no critical `fail`/`cancelled`/`timed_out` without resolution.

---

## Phase 5 - Base / stack / mergeability

1. `mergeable` / `mergeStateStatus`: resolve CONFLICTING with rebase onto current base (stack-aware: bottom first).
2. If behind main but clean, prefer update/rebase so CI matches landing base.
3. Stack: upper PR diff vs main should **not** re-introduce lower PR content after lower merges.

**Gate 5:** `MERGEABLE` (or known-platform lag with recheck); stack consistent.

---

## Phase 6 - Report (always)

Emit a captain-facing summary **in outcomes, not mechanics** (AGENTS.md section 9):

```markdown
## PR shepherd: <title>
URL: https://github.com/.../pull/N

### Status: merged | merge-ready | blocked

### Comments
| Finding | Disposition | Evidence |
| ... | ... | ... |

### CI
Critical: green | red (list failures)

### Shepherd review
1–5 bullets of independent findings (or "none beyond inventory")

### Next
- merged at <SHA> / merge-ready (--no-merge) / blocked on <decision>
```

**Gate 6:** Report delivered.
Proceed to Phase 7 unless `--no-merge` or a hard gate failed.

---

## Phase 7 - Merge (default terminal)

Merge when all of the following hold:

1. Gates 3–5 passed on the **current** head SHA.
2. `--no-merge` was **not** requested.
3. Merge authority is satisfied by one of:
   - Captain invoked `/pr-shepherd` (or equivalent land intent) for this PR, or
   - Explicit captain instruction to merge **this** PR, or
   - Firstmate standing `yolo` for that project **and** PR is green and within original task scope.
4. Prefer the project's merge path:
   - Firstmate: `bin/fm-pr-merge.sh <task-id> <url>` when a task owns the PR.
   - Else: `gh-axi pr merge <n> --squash` (or repo default); use `--admin` only when the captain authorized bypass of non-code gates **and** code/CI gates passed.

Still never merge red CI or incomplete BLOCKER dispositions.
After merge: confirm `state=MERGED`, full URL, one-line outcome.
Firstmate: fleet-sync clone; cleanup only when unlanded-work checks pass.

---

## Firstmate integration

When running as firstmate:

| Concern | Rule |
|---------|------|
| Project edits | Worker / isolated copy only (hard rule 1). |
| PR open from ship | After worker reports green, **still run Phase 1–3** before telling captain "ready" or merging under yolo / default shepherd merge. |
| Bot formal CHANGES_REQUESTED | Block merge until re-run clears or code fixes land. |
| Status line `done: PR … checks green` | Treat as worker claim; **re-verify** gates 3–4 yourself. |
| Default merge | Captain `/pr-shepherd` (or ship yolo path) is land authority once gates pass; use `--no-merge` to stop at report. |

Suggested captain invocation: `/pr-shepherd 4125` or `/pr-shepherd https://github.com/org/repo/pull/4125`.
Use `/pr-shepherd 4125 --no-merge` when the captain wants a merge-ready report only.

---

## Relationship to other tools

| Tool | Role |
|------|------|
| `no-mistakes` | Pre-merge validation of **your** branch/pipeline work. |
| `pr-babysit` | Multi-PR loop with auto-fix; **never merges**; use for watch lists. |
| **pr-shepherd** | **Thorough single/stack land gate** with mandatory comment disposition; **merges by default** when hard gates pass. |

Prefer `pr-shepherd` when honesty of "comments addressed + CI green" and landing matter more than polling many PRs.
Use `pr-babysit` for ongoing multi-PR watch.

---

## Anti-patterns (learned the hard way)

- Approving and merging while a bot **BLOCKER** is still formal CHANGES_REQUESTED.
- Wiring UI to a component with **zero importers** because the PR body said so.
- Treating quality/knip flake as "whole tree debt" without running the ratchet.
- Claiming CI green when only title/body lint ran (full CI never triggered).
- Merging the stack top while it still contains the bottom's files after both rebased independently.
- Leaving collapsed a11y WARNs unfixed on the PR that introduced them.

---

## Minimal command cheatsheet

```bash
# Identity + checks
gh-axi pr view N --json url,state,headRefOid,reviewDecision,mergeable,statusCheckRollup
gh-axi pr checks N

# Reviews + threads (see Phase 1 for full GraphQL pagination)
gh-axi api repos/O/R/pulls/N/reviews
gh-axi api repos/O/R/issues/N/comments

# Diff + importers
gh-axi pr diff N --name-only
git grep -n Symbol origin/branch -- '*.ts' '*.tsx'

# After fix
git push --force-with-lease   # only if rebase rewrote
gh-axi pr comment N --body "..."

# Merge (default terminal when gates green; skip if --no-merge)
gh-axi pr merge N --squash
```
