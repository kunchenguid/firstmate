---
name: validation-lifecycle
description: Load before starting, supervising, superseding, or answering a finding in a no-mistakes validation run.
user-invocable: false
metadata:
  internal: true
---

# Validation lifecycle

For a no-mistakes ship, trigger validation on the same worker after its implementation commit, using the harness invocation owned by `harness-adapters`.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated.
The smallest downstream changes needed to keep accepted behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's guarded recovery only for `recover_custody`; otherwise proceed only when structured status confirms branch ownership is already returned.
Custody recovery settles ownership, not content: replace obsolete work from the correct pre-invalidation base, excluding the obsolete run's pipeline-fix commits.
Apart from that supported abort, do not hand-edit, commit, restart, or start another validation run while the obsolete run owns the branch.
Once ownership is settled, validate exactly once against the final head.

An ask-user finding returns as `needs-decision`; firstmate decides only when configured authority permits, otherwise escalate to the captain.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the current-code-matched run step through `bin/fm-crew-state.sh`, not by shell liveness or the last status event.
Running, fixing, or CI states remain working; parked approval or fix-review states require the worker to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed.
A worker hand-editing, committing, aborting, or restarting during an active run duplicates pipeline ownership outside the supersession sequence; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.
