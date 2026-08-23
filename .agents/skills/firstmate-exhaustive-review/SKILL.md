---
name: firstmate-exhaustive-review
description: >-
  Agent-only procedure for a captain-requested exhaustive review, review
  convergence, canonical fix wave, or exact-SHA post-fix review.
  Load before accepting or dispatching that work.
user-invocable: false
metadata:
  internal: true
---

# firstmate-exhaustive-review

Use this procedure only when the captain asks for an exhaustive review, review convergence, a canonical fix wave, or an exact-SHA post-fix review.
This skill is the single owner of that conditional procedure.
It does not turn an ordinary ship task or selected delivery mode into an additional review gate.

## Ownership and dispatch

The ownership chain is Primary Firstmate -> configured Firstmate worker and backend -> GSD review workflow in that worker -> workflow-owned specialist reviewers in that worker.
The primary remains the captain-facing supervisor, and the worker remains the sole owner of project code, project git state, review artifacts, fixes, tests, commits, pushes, and PR updates.

1. Resolve the project, delivery mode, `yolo` posture, and any fitting secondmate route under `AGENTS.md` section 7.
   A routed secondmate is the Firstmate layer that launches and supervises its own configured worker.
2. Before dispatch, load `harness-adapters` and apply the captain override, dispatch-profile, quota-array, effort, and spawn-capable backend rules in `AGENTS.md` section 4.
   When `config/crew-dispatch.json` exists, read its matching rule or default before writing the brief; a harness-only spawn does not satisfy a selected profile.
   Resolve every selected profile axis before launching: pass its concrete harness, model, and effort to `fm-spawn`, and preserve the selected backend through the supported backend selection path.
   When a configured profile supplies model or effort, never omit either axis or replace it with a generic fallback.
   For a profile array, retain the quota and candidate-accounting evidence that selected those concrete axes.
   Do not hard-code a harness, model, effort, or backend for this workflow.
3. Create one task-specific brief and launch the project worker only through `bin/fm-spawn.sh` on the resolved backend.
   The brief must name this skill, require the immutable-SHA and canonical-ledger gates below, and preserve the selected delivery mode.
4. The primary must not invoke `$gsd-code-review`, another generic GSD adapter, a top-level `spawn_agent` path, or any project reviewer/fixer directly.
   A Codex GSD adapter's `Task` to `spawn_agent` translation is permitted only after the Firstmate worker has started in its isolated project worktree.
5. The worker invokes `$gsd-code-review` or the appropriate GSD review command from its own project worktree.
   Any reviewer or fixer that GSD owns stays under that worker, never under the primary.
6. If the selected worker cannot run an appropriate GSD review command without violating its configured runtime or task authority, it reports a blocker.
   The primary does not replace that worker layer with a generic direct review path.

Never begin this procedure while a no-mistakes run already owns the branch.
The worker first follows the active gate's custody rules, and the exhaustive review becomes input to the one selected delivery path rather than a competing pipeline.

## Freeze the initial review

1. In the worker worktree, resolve and record one full immutable commit SHA before discovery begins.
   The reviewed source tree remains read-only until the complete finding set is frozen.
2. Run discovery-first review against that SHA.
   Do not edit source, apply a formatter, stage changes, commit, or begin GSD fix mode during this phase.
3. Give every independent reviewer the same immutable SHA and an explicit source scope.
   Keep one ledger per reviewer with stable finding identifiers, severity, location, evidence, impact, and proposed disposition.
4. Wait for all planned reviewer outputs to finish before reporting review results or changing code.
   A partial reviewer result is neither a final finding set nor authorization for an early fix.
5. Reconcile the independent ledgers into one tracked, PR-visible canonical review document on the task branch.
   It must name the reviewed full SHA, scope, reviewers, every unique finding, duplicate or conflict reconciliation, disposition, and the unresolved blocker count.
6. Treat a GSD-generated `REVIEW.md` as an input ledger unless it is itself the tracked canonical document.
   Do not rely on an ignored, local-only, or transient workflow artifact as the canonical record.
7. Capture every completed review artifact on the task branch.
   Commit it when the project keeps it, or carry its full ledger into the committed canonical document before reporting the review outcome.
   No completed reviewer output may remain only as an unpushed local file.
8. Push each review-artifact commit without force and verify that the remote branch SHA equals the local commit SHA.

## Canonical fix wave

Fix only from the frozen canonical ledger.
Canonical fix work begins only when that ledger is complete, committed, and bound to its immutable reviewed SHA.
If no such ledger exists, return to "Freeze the initial review" rather than inferring scope or creating an ad hoc ledger.
Group findings into coherent dependency groups, rather than running a reviewer after each individual correction.

For every group:

1. State the ledger finding IDs and the expected behavioral change before editing.
2. Establish red evidence with a failing regression test or a reproducible behavioral proof whenever the finding describes a defect.
3. Implement the complete dependency group, then establish green evidence with the relevant behavioral test or proof.
4. Make one coherent atomic fix checkpoint that contains only the reviewed group, its regression coverage, and necessary documentation.
5. Before each checkpoint commit and push, inspect the worktree and stage only reviewed files.
   Never stage, commit, or push unreviewed dirty state, credentials, runtime artifacts, recovery sentinels, or private fleet paths.
6. Push each green atomic checkpoint without force and verify its exact remote branch SHA before proceeding.
   A divergence, rejected non-fast-forward update, or remote-SHA mismatch is a stop-and-reconcile condition, not authority to force-push.

Do not use GSD `--fix --auto` or another one-finding retry loop to evade this grouping rule.
If a correction exposes a materially new issue, record it for the next complete ledger rather than silently adding an eleventh serial review pass.

## Exact-SHA final review and certification boundary

After the final green fix checkpoint, resolve its full SHA and run a fresh independent GSD review invocation against that exact SHA by a reviewer who did not implement the fixes.
The final reviewer must not inherit the initial ledgers as proof or treat prior clean claims or the implementer's self-review as proof.
Record the final reviewer, scope, reviewed SHA, and every disposition in the tracked canonical review document, then commit, non-force-push, and remote-SHA-verify that artifact.

Only a final review whose zero-blocker result names the exact final code SHA may advance to certification or merge consideration.
If a code-bearing commit advances the branch after that review, the exact-SHA result is stale and a new independent final review is required.
An artifact-only review-record commit may accompany the certified code SHA only when it declares that SHA and changes no reviewed project behavior.
Any final blocker starts a new full frozen-ledger wave with coherent dependency groups, not a one-comment-at-a-time loop.

## Delivery boundaries

The selected delivery mode still owns validation, PR creation, CI, and its normal approval gates.
This procedure grants no merge, force-push, tag, release, credential exposure, main-branch write, or broader project authority.
Existing captain approval, ask-user, security-sensitive, destructive-action, and no-mistakes boundaries remain unchanged.
