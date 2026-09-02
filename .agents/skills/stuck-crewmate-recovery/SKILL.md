---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing ordinary Firstmate direct reports.
  Use when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Interrupt, stop, and relaunch a worker through `bin/fm-control.sh <task-id> interrupt|exit|relaunch`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything ([`docs/agent-control.md`](../../../docs/agent-control.md)).
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

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
`bin/fm-control.sh relaunch` and its `bin/fm-spawn.sh --relaunch` delegate enforce the shared ownership proof in `bin/fm-worktree-ownership-lib.sh`; a worktree whose `.fm-task-owner` marker names another task or another spawn generation, a conflicting task claim, a contradicting provider binding, a foreign task branch, or a mismatched secondmate home marker each refuse before either path acts on the recorded worktree.
A record with no `worktree=` line has already had that claim retired, so relaunching it refuses rather than adopting a path the provider may have taken back.
Only an interrupted retirement can leave a recoverable copy of the claim, and the refusal prints one manual-recovery drill naming that copy together with the slot's retired `.fm-task-owner` copy whenever that half was stashed too; put both halves back together or neither, and only after confirming with the provider that the path was never released, because a released slot may already belong to another task and a claim restored without its marker can never prove ownership again.
A slot whose `.fm-task-owner` the record cannot prove is its own - one naming another task or another spawn generation, an unreadable or incomplete one, or an entry that is not a regular file - refuses before any retirement begins: the record keeps its `worktree=` line, no claim or marker copy is written, no drill is printed, and the entry is left byte-for-byte as it is.
Nothing is parked there, so attribute that entry by the rules below and rerun once it is resolved, instead of looking for a preserved copy that was never made.
Every retirement that has already begun and then stops short of a confirmed provider release parks that way instead: nothing is recorded as final on its own, no runtime path restores either half, and the drill stops rather than creating or overwriting another owner's marker.
Until an operator works through that drill, the parked record keeps refusing its own teardown and relaunch, so reconcile it deliberately instead of expecting a rerun to finish the remaining cleanup.
A pool slot refused because its `.fm-task-owner` marker names a task with no record was taken by a spawn that was killed before it published one; the refusal reports whether that spawn's ownership record still stands beside the task records in `state/` and names both files, and clearing them by hand after confirming the slot is idle is the only recovery, because no teardown exists for a task that was never recorded.
A fresh spawn of that same task id refuses while any such record still names a slot that carries that marker, or that the spawn cannot read well enough to tell, naming each unresolved spawn generation and the worktree it took, so resolve the stranded slot first and then spawn the id again.
A record whose recorded worktree no longer carries that marker strands nothing: the spawn reports it as leftover paperwork that is safe to delete and proceeds, so it never wedges the id for good.
The same removal is the recovery when the refusal reports that the marked task's own record has moved on to another generation and another worktree, because that task's teardown retires its marker elsewhere and will never clear this slot.
When the refusal instead reports that the marked task's record does not say clearly enough who owns the slot, ownership is unknown: remove nothing, repair that record or establish with the crew which task is working there first.
A relaunch interrupted between restamping the worktree's marker and advancing its record leaves the marker one generation ahead; that is recorded as a generation handoff and needs no repair, so relaunch or tear the task down normally rather than editing either half by hand.
Preserve its uncommitted changes and commits, keep the same task identity, and resume or relaunch the recorded harness in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

Escalate in order:

1. Peek the pane, and check the task's steering inbox (`state/<id>.inbox/`) for unhandled `*.msg` records - a stale wake naming an unread firstmate instruction means the worker never acknowledged a durable steer, and the record itself shows exactly what was intended.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
4. If the crewmate is genuinely wedged after redirection, relaunch it with `FM_HOME=<this-firstmate-home> bin/fm-control.sh <task-id> relaunch --note '<progress so far>'`, which stops the agent, carries the brief plus that note into a replacement in the same local copy, and restores the prior record if the replacement cannot start.
   Pass `--harness`, `--model`, or `--effort` on that same command when the worker should come back on a different runtime.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.
