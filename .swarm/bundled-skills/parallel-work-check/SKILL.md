---
name: parallel-work-check
audience: swarm-plugin
description: >
  Apply before starting work on an existing branch. Checks for parallel work by
  other agents or developers that may supersede or conflict with your planned
  changes. Prevents wasted effort on stale branches.
effort: small
generated_from_knowledge: []
source_knowledge_ids: ['f07c1f4d-9bb0-4219-9804-26aa8efe8146']
generated_at: 2026-06-14T16:50:00Z
confidence: 0.8
status: active
version: 4
skill_origin: generated
provenance_note: >
  Re-linked to current knowledge entries (version 4). The original source ID
  b8fee776... is no longer present in the active knowledge store. The skill
  body and behavior are unchanged; only source_knowledge_ids metadata was
  updated to point to the current lesson about verifying pre-existing state
  on parent commit, which is directly relevant to the parallel-work-check
  protocol.
---

# Parallel Work Check Protocol

Run this check before starting ANY work on an existing branch (not a fresh branch
you just created). This applies to PR branches, feature branches, and any branch
that may have concurrent contributors.

## Step 1 — Check current branch state

1. Determine the current branch name.
2. Determine the remote tracking branch (usually `origin/<branch-name>`).

## Step 2 — Fetch remote state

Fetch the latest state from the remote for the current branch. Do NOT skip this
step because "the branch looks recent" or "I just checked."

## Step 3 — Compare local vs remote

Compare the local HEAD commit hash with the remote HEAD commit hash:

- **Identical**: Remote has not diverged. Proceed with your work.
- **Remote ahead**: The remote branch has commits you don't have locally.
  - Read the new commit messages with `git log local..remote`.
  - Check if any of those commits touch files you plan to modify.
  - If yes: evaluate whether the parallel work supersedes your planned changes.
  - If the parallel work is superior: reset your local branch to match remote
    and abandon your planned approach. Document the decision.
  - If the parallel work is complementary: integrate it first, then proceed.
- **Local ahead**: You have local commits not on remote. This is normal if you
  already started work. Proceed, but be aware that pushing may conflict with
  subsequent remote changes.
- **Diverged**: Both local and remote have unique commits. This requires
  integration. Merge or rebase as appropriate for the team's workflow.

## Step 4 — Check for parallel swarm/agent work

If the remote has new commits:

1. Check the commit authors. If commits are from a different swarm/agent
   (different author name/email pattern), treat this as parallel swarm work.
2. Parallel swarm work is often superior because:
   - It may have access to different context or tools
   - It may have started earlier or had more iterations
   - It may have taken a fundamentally better approach
3. Default stance: **prefer the parallel swarm's work** unless you can clearly
   articulate why your approach is better.

## Step 5 — Decision and documentation

Before proceeding, document your decision:

```
PARALLEL WORK CHECK:
- Branch: <name>
- Local HEAD: <hash> <message>
- Remote HEAD: <hash> <message>
- Diverged: yes/no
- New commits on remote: <count>
- Parallel swarm work detected: yes/no
- Decision: [proceed / integrate-then-proceed / abandon-use-remote / needs-review]
- Rationale: <one sentence>
```

## Anti-patterns — do NOT do these

- Skip the fetch because "I'm sure nothing changed."
- Ignore remote commits because "my approach is probably better."
- Start fixing code without checking if the remote already fixed it.
- Blindly overwrite remote work with local changes without evaluating first.

## Example: parallel swarm superseded local work

```
PARALLEL WORK CHECK:
- Branch: codex/issue-956-plan-completion-gate
- Local HEAD: 5aa34f88 fix(delegation-gate): block next task until completion is persisted
- Remote HEAD: 2b4e9266 fix: correct contradictory test title/comments
- Diverged: yes (remote is 8 commits ahead)
- New commits on remote: 8
- Parallel swarm work detected: yes (different commit author)
- Decision: abandon-use-remote
- Rationale: Parallel swarm restored file from main and re-integrated cleanly,
  producing 486 passing tests vs our incremental patching which left 38 failures.
```

## Integration with swarm workflow

This check should run:
- At session start (MODE: RESUME or MODE: EXECUTE)
- Before creating a new plan for an existing branch
- Before dispatching the first coder task
- After any significant pause where parallel work could have occurred

## Integration with other skills

The parallel-work-check skill is referenced by other skills that start work on an existing branch:

| Skill | Usage |
|-------|-------|
| `file:.swarm/bundled-skills/swarm-pr-feedback/SKILL.md` | Checks before starting PR feedback fixes — ensures no parallel work has already addressed the same findings |
| Legacy pr-review-fix alias | Compatibility entry that delegates to the bundled `swarm-pr-feedback` protocol |
| `file:.swarm/bundled-skills/swarm-implement/SKILL.md` | Checks before implementation Phase 1 — ensures the branch is up-to-date before planning |
| Any skill that starts work on an existing branch | Run the parallel-work-check protocol before beginning fixes or implementation |

When a skill references parallel-work-check, the checking agent must:
1. Fetch and compare remote vs local state
2. Read any new commits from parallel work
3. Evaluate whether the parallel work supersedes, complements, or does not affect the planned work
4. Document the decision using the PARALLEL WORK CHECK template
