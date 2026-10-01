---
name: fork-pr-operations
audience: swarm-plugin
description: Operational patterns for fork PRs (head repo differs from base repo). Covers GitHub workflow approval after push, force-push protocol, remote naming conventions, stale CI verification, and bot review multi-round awareness. Load when working with fork PRs, cross-repo contributions, or workflow approval issues.
---

# Fork PR Operations

Fork PRs — where the head repository differs from the base repository — have a distinct operational lifecycle. GitHub treats them with stricter security defaults that require additional steps not needed for same-repo PRs.

## When to use this skill

- You are pushing to a branch on a forked repository
- CI checks are stuck in "waiting" status after a push
- You need to rebase a fork PR branch against upstream/main
- A bot reviewer posts after every push, creating multiple review rounds

## Workflow approval after push

**Critical:** GitHub requires explicit workflow approval for fork PRs. After every push, CI jobs remain in "waiting" status until a user with write access to the base repository approves the workflow run.

### Approval command

```bash
# List pending workflow runs for the PR
gh run list --repo <upstream-owner>/<upstream-repo> --branch <branch-name> --limit 5

# Approve a specific run
gh api -X POST repos/<upstream-owner>/<upstream-repo>/actions/runs/<run-id>/approve
```

### Race condition: run not yet created

After pushing, there is a brief window (1-5 seconds) before GitHub creates the workflow run object. If you try to approve too quickly, the run won't exist yet. Retry with a short delay:

```bash
# Wait for run to appear, then approve
sleep 5
gh run list --repo <upstream-owner>/<upstream-repo> --branch <branch-name> --limit 1 --json databaseId,status --jq '.[0]'
# If status is "waiting", approve:
gh api -X POST repos/<upstream-owner>/<upstream-repo>/actions/runs/<databaseId>/approve
```

### Permission requirements

The `gh api -X POST .../approve` call requires `actions: write` permission on the **base** (upstream) repository. This typically means your GitHub token needs the `repo` or `public_repo` scope, and you must have write access to the upstream repo. Fork owners without upstream write access cannot approve workflow runs — only upstream maintainers can.

```bash
gh auth status
# Verify you have repo/public_repo scope and write access to the upstream repo
```

## Remote naming conventions

Standard remote setup for fork-based contributions:

```bash
# origin = your fork
git remote add origin https://github.com/<your-username>/<repo>.git

# upstream = canonical repository
git remote add upstream https://github.com/<canonical-owner>/<repo>.git

# Additional forks by owner name (if collaborating across forks)
git remote add <collaborator> https://github.com/<collaborator>/<repo>.git
```

## Force-push protocol

Always use `--force-with-lease`, never bare `--force`:

```bash
# Safe: verifies remote tracking branch matches expected SHA
git push --force-with-lease origin <branch-name>

# DANGEROUS: overwrites any remote changes, including work by collaborators
git push --force origin <branch-name>  # NEVER DO THIS
```

`--force-with-lease` checks that the remote tracking branch matches your local expectation. If someone else pushed between your last fetch and your force-push, the lease check fails safely instead of destroying their work.

## Rebase workflow

To sync a fork PR branch with upstream/main:

```bash
# Fetch latest from upstream
git fetch upstream

# Rebase your branch onto upstream/main
git rebase upstream/main

# Resolve conflicts if any, then continue
git rebase --continue

# Force-push the rebased branch to your fork
git push --force-with-lease origin <branch-name>
```

After rebase + force-push, the PR head SHA changes. All CI checks re-trigger (subject to workflow approval for fork PRs).

## Stale CI verification

After a rebase or force-push, verify CI check data belongs to the current PR head:

```bash
# Get current PR head SHA
gh pr view <number> --repo <upstream-owner>/<upstream-repo> --json headRefOid --jq '.headRefOid'

# Check if CI checks match this SHA
gh pr checks <number> --repo <upstream-owner>/<upstream-repo> --json name,state,startedAt,completedAt
```

If check data references an older SHA, the checks are stale. Cancel obsolete runs only after confirming they are not the current head:

```bash
# Cancel a specific run (only if it's NOT the current head)
gh run cancel <run-id> --repo <upstream-owner>/<upstream-repo>
```

## Bot review multi-round awareness

Automated bot reviewers (e.g., hermes-pr-review) post a new review after **every push**. If you push N times, you get N bot reviews. This is expected behavior, not a bug.

### Strategy

1. **Ignore APPROVE rounds** from bots. A bot APPROVE after a trivial push adds no signal.
2. **Scan for new findings only.** Compare the latest bot review against prior rounds to identify newly raised issues.
3. **Focus on human reviewer findings.** Bot findings are advisory; human reviewer findings are binding.
4. **Do not attempt to silence the bot.** The multi-round pattern is by design.

## Cross-references

- `.claude/skills/commit-pr/SKILL.md` — PR publication protocol, including `--force-with-lease` guidance and remote check verification
- `.opencode/skills/swarm-pr-feedback/SKILL.md` — Feedback closure workflow for addressing review findings
- `.agents/skills/subprocess-safety/SKILL.md` — Subprocess safety for `gh` CLI calls
