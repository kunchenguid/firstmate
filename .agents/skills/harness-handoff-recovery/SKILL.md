---
name: harness-handoff-recovery
description: >-
  Agent-only procedure for recovering Firstmate supervision and in-flight workers when an active Claude or Codex usage window ends and work must continue on the other harness.
  Reconstructs from durable home and no-mistakes records, preserves landed and unlanded work, proves preserved pipeline heads in the matching gate repository, and bounds relaunch to existing lifecycle controls.
user-invocable: false
metadata:
  internal: true
---

# harness-handoff-recovery

Load this procedure when a Claude or Codex usage window has ended and Firstmate supervision or an ordinary in-flight worker must continue on the other harness.
This procedure transfers reasoning custody between verified harnesses without transferring repository custody, changing runtime backends, or inventing a second recovery policy.
Load `harness-adapters` before every worker relaunch or other harness-specific action.
Load `stuck-crewmate-recovery` for an ordinary direct report whose endpoint must be reconciled, and load `secondmate-provisioning` instead for a secondmate.

## Boundary

Use this procedure only after the predecessor can no longer continue because its usage window ended or the successor session was explicitly chosen for that reason.
Low remaining quota, an approaching reset, a quiet pane, or a context compaction is not proof that a usage window ended.
Do not stop or restart a primary Firstmate process from this procedure.
The surrounding harness starts the successor Firstmate, and the ordinary session-start lock decides whether that successor has mutation authority.
Do not change the recorded runtime backend, allocate a new worktree, create a replacement task id, or redesign supervision while recovering the handoff.

## Establish successor authority

Run the normal session-start procedure exactly once in the successor Firstmate session and read its complete digest once.
Proceed only when that session acquired and verified the home lock.
A lock refusal leaves the successor read-only and forbids relaunch, steer, state repair, no-mistakes custody recovery, or any other fleet mutation.
If the predecessor is still live, let the lock refusal preserve its authority rather than trying to evict it.

Reconstruct the handoff from the session-start digest and these durable sources only:

- `state/<id>.meta` for task identity, kind, recorded harness, backend target, worktree, branch, model, effort, and delivery contract.
- `data/<id>/brief.md` for accepted scope and worker instructions.
- `state/<id>.status` for wake events and durable keyed decisions, interpreted through the current-state tools rather than as current-state truth.
- The backlog record for task disposition and dependencies.
- The recorded worktree's Git objects, branch, HEAD, index, and working-tree state for landed and unlanded code.
- `no-mistakes axi status`, `no-mistakes runs`, and the matching no-mistakes gate worktree for validation custody.

Do not reconstruct authority or accepted requirements from conversation memory, pane scrollback, a harness transcript, a window title, or a task's last status sentence.
Those surfaces may explain a symptom, but they do not replace the durable records above.
Never read the no-mistakes database directly.

## Account for every in-flight record

For each direct report printed by the digest, run `bin/fm-crew-state.sh <id>` and reconcile that result with its exact metadata and recorded worktree.
Do not sweep another home's endpoint namespace or infer ownership from a matching label.
Record the worktree's current branch, full HEAD, and ordinary Git status before any relaunch so committed, staged, unstaged, and untracked work remain visible.
Do not stash, clean, reset, rebase, switch branches, delete refs, force a checkout, tear down the task, or move commits between worktrees during reconstruction.

Classify each task once:

1. A confirmed landed or terminal task stays terminal and follows the ordinary PR, local landing, decision-hold, or teardown lifecycle.
2. A live worker that remains healthy stays on its recorded harness even when the primary Firstmate moved to the other harness.
3. A dead or exhausted ordinary worker with no authoritative no-mistakes run may be relaunched only after `stuck-crewmate-recovery` proves that no live agent owns its recorded endpoint and that its recorded worktree remains available.
4. A no-mistakes run whose branch and head match the task under the existing run-attribution contract remains authoritative whether or not the worker endpoint is live.
5. An irreconcilable worktree, duplicate owner, unsupported relaunch backend, or unprovable gate head stays intact and becomes a concrete blocker.

An active no-mistakes run is not a fleet worker and is never relaunched through Firstmate.
Keep supervising an active run, route a parked gate to a successor worker in the same task worktree, and handle a terminal run only through the structured action reported by no-mistakes.

## Prove a preserved no-mistakes head

When structured no-mistakes status reports that a terminal run left unpublished pipeline commits preserved in its local gate, do not trust the reported abbreviated head by itself.
Run `no-mistakes doctor` and use its reported data directory rather than assuming the default location.
Use the exact run id from `no-mistakes axi status --run <run-id>` to locate exactly one gate worktree at `<data-directory>/worktrees/<repo-id>/<run-id>`.
Refuse ambiguity, a missing gate worktree, or a repository id that differs between the worktree path and its resolved Git common directory.

Run `bin/fm-preserved-head-check.sh <data-directory> <repo-id> <run-id> <status-head>` and require it to print the resolved full commit id.
This proves that the preserved head is a real commit in the matching gate repository and is still the exact run worktree head, rather than a stale status string or an object found in an unrelated repository.

All of these checks are read-only.
Do not copy objects, create preservation refs, move the task branch, or repair the gate repository by hand.
On any mismatch, preserve both repositories unchanged and report the run id, expected head, resolved paths, and failed equality as a blocker.

After that proof, follow only `branch_sync.next_action` from fresh structured axi status.
Run the supported guarded `no-mistakes axi sync --recover` path only when its code is `recover_custody`, and use only the choices and protections described by that command's current help.
No-mistakes owns anchoring preserved pipeline commits and the pre-recovery local head.
The successor must not reproduce those ref or branch mutations itself.

## Relaunch an ordinary worker

Switch a worker from Claude to Codex or Codex to Claude only through `FM_HOME=<active-home> bin/fm-control.sh <task-id> relaunch --harness <successor> --note '<durable progress>'`.
The control plane must reuse the existing task id, recorded backend endpoint, and recorded worktree, positively prove the endpoint agent-free, and restore the prior record if the replacement cannot start.
Do not call a fresh generic spawn for the same task.
Do not fall back to another runtime backend when the recorded backend cannot prove safe relaunch.

Choose only a verified successor adapter and apply the existing dispatch, model, effort, quota, and authentication rules rather than adding handoff-specific selection policy.
The progress note must be rebuilt from the brief, resolved decision records, Git state, and current no-mistakes status.
Include the accepted objective, current branch and full HEAD, whether the worktree is dirty, the authoritative run id and full proven gate head when present, the current gate or next action, and the first concrete continuation step.
Do not paste transcript prose or infer unfinished work from the predecessor's last message.

After relaunch, re-read `bin/fm-crew-state.sh <id>` and require the successor to continue the existing delivery lifecycle.
If validation owns the branch, the successor drives the existing axi run through its gates and does not hand-edit or start another run.
If custody recovery is required, the successor performs the supported recovery before any local follow-up commit.

## Completion gate

The handoff is reconciled only when every durable in-flight task is accounted for as unchanged and healthy, safely relaunched in its original worktree, governed by its authoritative no-mistakes run, terminal under the ordinary lifecycle, or blocked with all work preserved.
Do not claim recovery from shell liveness, a successful launch message, or a status append alone.
Do not tear down any task as part of this procedure.
