---
name: ci-failure-batching
audience: swarm-plugin
description: Batch collection and fix protocol for CI failures. Triggered when any CI check fails on a PR. Prevents serial diagnose-fix-push cycles by collecting all failures before fixing.
---

# CI Failure Batching

## Trigger
When the PR monitor surfaces `pr.ci.failed`. The event is batched after the
check set is complete and includes all known failed checks in `failedChecks`.

## Protocol
1. **DO NOT immediately fix the first failure.** Check if other jobs are still running:
   ```
   gh pr checks <PR> --repo <repo>
   ```
2. **If jobs are still running:** Note the failure, WAIT for the run to complete
3. **Once the run completes, collect ALL failures:**
   - Identify every check with `fail` status
   - For each: `gh run view <run-id> --log-failed`
   - Build a complete failure ledger
4. **Fix ALL failures in one changeset:** Cluster by root cause, fix each cluster, verify locally
5. **Publish through `commit-pr`.** This skill owns diagnosis and fix-planning
   ONLY (issue #2131 criterion E): before any commit or push, compose the
   `commit-pr` skill for the commit message, PR body/invariant-audit/test-plan
   discipline, and the push protocol. The batching goal is ONE push cycle
   (collect all → fix all → push once), not literally one commit — a single new
   commit containing all batched fixes satisfies the goal. Guardrail facts (verified in the
   tool-before push guardrail): bare `git push --force`
   and `-f` are deny-pattern-blocked; `--force-with-lease` is EXEMPT because it
   refuses to overwrite remote work gained since your last fetch — commit-pr
   mandates it for fork/rebase flows. Even so, prefer a normal new fix commit
   over amending an already-pushed commit.
6. **Only re-push if NEW failures surface** that were not in the original batch.

## Why this matters
Without batching, N failures produce N push cycles. With batching, N failures produce 1 push cycle.

Example from session #1685:
- Without batching: 6 pushes (format → stale-assertion-1 → stale-assertion-2 → integration → merge-group → clean)
- With batching: 2 pushes (collect all → fix all → push once → clean)

## Pr-monitor expectation
The pr-monitor should fire one `pr.ci.failed` event for the completed failing
check set, not one event per check. Still verify with `gh pr checks` before
fixing, because GitHub can append late merge-group or matrix jobs.
