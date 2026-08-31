---
name: validation-run-changes
description: >-
  Agent-only contract for changing a task while its no-mistakes validation run is active.
  Load before expanding a task under an active run, and before acting on a captain instruction that invalidates work being validated.
  Owns the in-scope boundary during validation and the abort-settle-replace-revalidate sequence that is the only supported way to supersede a run.
user-invocable: false
metadata:
  internal: true
---

# validation-run-changes

Load this once a no-mistakes validation run is active and something wants to change the work under it.
`AGENTS.md` section 7 owns the always-loaded facts: the worker that starts a run drives it, firstmate never calls `no-mistakes axi respond` for a crew-owned run, and nothing outside this skill authorizes hand-editing, committing, aborting, or restarting while a run owns the branch.
`ask-user-authority` owns gate findings; this skill covers requirement changes arriving from outside the pipeline.

## In-scope boundary during validation

Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated.
The following stay within the current task even when they touch files not named at intake:

- The smallest downstream changes needed to keep already accepted product or engineering behavior correct.
- Behavioral tests added where an executable contract exists.
- Documentation kept accurate for the accepted behavior.

Corrections required to satisfy already accepted intent are not new requirements.

## Superseding a run

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
When that happens, the worker follows this sequence exactly and in order.

1. **Abort.**
   Cancel the active run through no-mistakes axi's supported abort command, and confirm through axi status that the run has stopped before changing any code.
   That single supported abort is the only permitted intervention: do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
2. **Settle ownership.**
   Follow `branch_sync.next_action` from structured axi status.
   Use axi sync's supported guarded recovery only when its code is `recover_custody`.
   Otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
3. **Replace, do not build on.**
   Custody recovery settles branch ownership, not content.
   Replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
4. **Revalidate once.**
   Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

A worker that hand-edits, commits, aborts, or restarts outside this exact sequence while a run still owns the branch has duplicated pipeline ownership; `AGENTS.md` section 7 owns the steer-back-to-gate-flow response.
