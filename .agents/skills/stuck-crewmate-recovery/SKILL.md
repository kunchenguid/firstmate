---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck firstmate direct reports.
  Use after a stale wake, permission-prompt or system-dialog suspicion, no-mistakes reattach socket read timeout, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Routes permission grants and home-scoped validation recovery before the ordinary peek, steer, interrupt, relaunch, and failed-status ladder.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, permission-blocked, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Load `harness-adapters` before handling a permission prompt or sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

## No-mistakes reattach timeout branch

Handle an error shaped as `drive run: reconcile run ...: read response: ... socket: i/o timeout` before the ordinary ladder.
That signature means an established daemon connection missed the bounded run-snapshot response deadline; it is not evidence that the daemon stopped.

1. Run `FM_HOME=<this-firstmate-home> bin/fm-no-mistakes-reattach.sh <id>` from the active firstmate repository unless `FM_HOME` already names the active home.
2. Let the helper own retry timing and task identity checks.
   It retries only the observed transient signature and requires the daemon to report running before every attempt. This read-only preflight narrows risk but cannot guarantee no start because ordinary `axi run` calls `EnsureDaemon` after the check; strict protection requires an upstream attach-only operation.
3. Treat a returned gate or outcome as the current run result and continue the ordinary validation decision or completion workflow.
4. If the helper exhausts its retries, preserve its exact final error and escalate the lane as blocked without changing daemon lifecycle state.
5. Do not use this branch for another daemon error.
   Diagnose that error through the ordinary ladder and retain the shared-daemon prohibition.

## Permission-blocked branch

Handle permission evidence before the ordinary recovery ladder because approving, denying, interrupting, or relaunching can change the security decision or hide the only useful evidence.

1. Peek the pane and read the requested command, tool, directory, or capability.
2. If the wake says `permission-prompt detected`, or the pane matches the target's mid-run permission shape in `harness-adapters`, do not press an approval or denial key and do not interrupt or relaunch the agent.
3. Tell the captain what action is waiting and ask them to approve or deny it in the visible prompt.
   Keep the message product-facing, such as `Work is blocked waiting for permission to <action>; please approve or deny that request in the visible dialog.`
   Do not name the harness, pane, task id, watcher, or other fleet machinery.
4. If the wake says `permission/system-dialog suspected`, remember that it is a timeout heuristic rather than a directly observed macOS dialog.
   Inspect the pane for the foreground action and any clear evidence of ordinary progress.
   If ordinary progress is visible, resume supervision and treat the wake as a conservative false positive.
   Otherwise tell the captain `A macOS permission dialog may be blocking <action>; please grant or deny it in the visible dialog or in Privacy & Security in System Settings.`
5. Never try to grant a macOS TCC permission with keystrokes, AppleScript, Accessibility APIs, `tccutil`, or a settings-database edit.
   macOS owns that decision and the captain must make it.
6. After the captain clears the dialog, verify that the pane changes or `bin/fm-crew-state.sh <id>` reports resumed work before returning to supervision.
   If the permission was denied and the task still cannot proceed, use the ordinary ladder below with that denial as evidence.

For a non-permission stall, escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Escape`.
4. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain with evidence.
