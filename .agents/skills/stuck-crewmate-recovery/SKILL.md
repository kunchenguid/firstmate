---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, a worker reported as exited without reporting, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, reported as having exited without reporting, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Interrupt, stop, relaunch, and rebind a worker through `bin/fm-control.sh <task-id> interrupt|exit|relaunch|rebind`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
That plane covers workers running in this home; a remotely placed secondmate is refused by name and reconciled through `secondmate-provisioning` instead.
Load `harness-adapters` before a resume command or a harness-specific skill invocation, and whenever the adapter's own quirks matter.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Session-start reconciliation for a dead ordinary direct report

This procedure covers ordinary `kind=ship` and `kind=scout` direct reports.
Load `secondmate-provisioning` instead for `kind=secondmate` recovery.

For a REMOTE secondmate, `fm-crew-state` and `fm-peek` read the actual remote endpoint over `fm-on.sh`, and `fm-send` reports a delivered-with-pending-confirmation steer as delivered (their headers own the contracts); an `unknown-remote` read or unreachable-host failure means the remote state could not be read, never that the mate is dead or the send failed.
Recover a genuinely stuck remote mate only through `bin/fm-spawn.sh <id> --secondmate`, never raw herdr pane close/kill surgery, which strands the endpoint binding.

Treat the digest's endpoint result as a presence signal, not proof that the task's work or validation run is gone.
Read the targeted current state with `bin/fm-crew-state.sh <id>` before deciding to relaunch.
A no-mistakes run matched to the crew's branch and current code remains authoritative when the endpoint is dead: handle a terminal or parked run through the normal lifecycle, and keep supervising an active run instead of creating a duplicate worker.

When no authoritative run accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for treehouse-backed tmux, herdr, zellij, or cmux tasks, and use the recorded `orca_worktree_id=` and `terminal=` for Orca tasks.
Do not sweep another home's endpoints or infer ownership from a matching window label.

An endpoint that does not answer is not automatically an endpoint that is gone.
A recorded identifier reported as `drifted` means a live endpoint still carries this task's identity under a new identifier, and a worker reported as `suspended` is stopped rather than gone; both refuse recovery on purpose, because relaunching over either one puts a second agent on a live copy of the work.
Correct a drifted record with `bin/fm-control.sh <task-id> rebind` and then decide from its real state; resume a suspended worker in its own endpoint instead of replacing it.

A worker reported as `exited` is the third shape, and the only one of the three where the agent really is gone: its endpoint survives as a bare shell and it never wrote a terminal status line.
That verdict says the agent left, never that the work is unfinished - on 2026-08-20 the most expensive case was a complete report sitting on disk unclaimed for an hour while the record still read `working`.
So decide from the work rather than from the last status line: read the task's deliverable and worktree first, claim a finished one through its normal completion path, and relaunch only what is genuinely incomplete.
Nothing is lost either way, because the worktree, its commits, and any written deliverable all survive the exit and a relaunch in that same worktree resumes cleanly.
A worker whose record was published moments ago never reaches that verdict and reports `unknown` instead, because a harness that has not finished starting leaves the same empty endpoint as one whose agent left; that read licenses nothing in either direction, so re-read it once the window named in its detail line has passed rather than relaunching on it.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

A stale wake carries the measurement that produced it, and reading that first tells you which shape you are looking at before you spend an inspection.
`stalled` means the worker's process subtree accumulated no CPU and spawned nothing for the whole span, which is what a worker stopped by a provider session limit or a dead harness looks like - go straight to the pane and expect an empty composer, a limit banner, or a prompt that never started a turn.
`no-pid-source` means nothing could be measured on that runtime, so the wake is the older idle-timer escalation and proves only that the pane has not changed.
A wake that reports the pane as measured working is a long-cadence recheck, not a wedge; confirm the work is still the work you want rather than treating it as a stall.

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
4. If the crewmate is genuinely wedged after redirection, relaunch it with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> relaunch --note '<progress so far>'`, which stops the agent, carries the brief plus that note into a replacement in the same local copy, and restores the prior record if the replacement cannot start.
   Pass `--harness`, `--model`, or `--effort` on that same command when the worker should come back on a different runtime.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.
