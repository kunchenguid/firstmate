---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer, or before changing a live crewmate's runtime mid-task.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, when a steer failed to land, or before changing a live direct report's runtime mid-task.

Interrupt, stop, and relaunch a worker through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
That plane covers workers running in this home; a remotely placed secondmate is refused by name and reconciled through `secondmate-provisioning` instead.
Load `harness-adapters` before a resume command or a harness-specific skill invocation, and whenever the adapter's own quirks matter.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

For a supported in-place relaunch - same task id, same worktree and lease, same brief, different or same harness - use `bin/fm-runtime-handoff.sh` (it drives `fm-spawn.sh --reuse-worktree`).
That path owns clean exit of the old harness, meta rewrite of `harness=`/`model=`/`effort=` and the new endpoint fields while preserving other meta such as `pr=`, and the progress-note handoff prompt that tells the replacement agent to re-attach any live no-mistakes run rather than starting a second one.
Do not hand-edit meta or kill a live endpoint around it.
That path covers treehouse-backed tasks only; it refuses `backend=orca` because Orca owns its own worktree lifecycle, so an Orca task keeps the reconciliation above rather than an in-place relaunch.
Quota exhaustion mid-task is a handoff case, not a teardown case: teardown correctly refuses unlanded work.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
4. If the crewmate is genuinely wedged after redirection, relaunch it with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> relaunch --note '<progress so far>'`, which stops the agent, carries the brief plus that note into a replacement in the same local copy, and restores the prior record if the replacement cannot start.
   Pass `--harness`, `--model`, or `--effort` on that same command when the worker should come back on a different runtime.
   Runtime-capacity handoff is also available through `bin/fm-runtime-handoff.sh` when the old endpoint can be proven dead and a launch-only handoff prompt is useful.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   Read that capacity claim with `bin/fm-statusline-quota.sh <id>`, which reports `ok`, `low`, `unknown`, or `exhausted`, and treat an `unknown` statusline quota reading as unknown capacity, never as exhaustion.
   When you pick the target harness, a Claude target can draw on the same Claude budget as the supervising firstmate session, so surface that tradeoff to the captain instead of assuming it is fresh capacity.
   The worktree and commits persist; handoff is the cheap safe path.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.
