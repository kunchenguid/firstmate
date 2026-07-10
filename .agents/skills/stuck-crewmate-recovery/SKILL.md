---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, a permission-confirmation dialog, or a failed steer. Escalates from peek, to one-line steer, to harness-specific interrupt, to relaunch with progress, to failed status.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, parked at an interactive permission-confirmation dialog, unresponsive, or when a steer failed to land.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

1. Peek the pane.
2. **Permission-confirmation dialog first, ahead of the escalation ladder below** (task crew-rmrf-fix-q3): if the pane shows an interactive Claude Code permission prompt ("Do you want to proceed?" with numbered options - `bin/fm-crew-state.sh` reports this as `state: blocked · source: pane`, and a stale wake reason carries a `permission-dialog:` tag when this is why), this is a distinct case from "confused or looping" (step 4) and does not want an interrupt or relaunch - either would just recreate the same wedge on the next similarly-risky command, and interrupting mid-dialog can leave the harness in an inconsistent state.
   Read exactly what it is asking permission for (the shown command and its stated purpose).
   Decide whether the request is safe and matches the crewmate's brief and task scope, then respond immediately with the option number as literal text (not `--key`, which only supports Escape/Enter/C-c): `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> "1"` to approve, `"2"` to decline, from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
   If the request looks unsafe, unexpected, or out of scope, decline it and steer with a one-line correction (per step 3) instead of approving on autopilot.
   Known quirk: `fm-send.sh`'s composer-clear verification can report a false `pending`/failure right after a dialog closes, because the larger visual re-render (the whole dialog box clearing, the next message rendering) can take longer than its bounded retry window even though the keypress landed correctly - peek to confirm the actual pane state before assuming the response did not land and retrying.
   A blind retry that DOES land a second time can select the wrong option against a NEW dialog that appeared in between, so confirm, don't just resend.
3. If the crewmate is waiting on a question its brief already answers, answer in one line via `FM_HOME=<this-firstmate-home> bin/fm-send.sh` from an active firstmate session unless `FM_HOME` is already set to the active firstmate home.
4. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Escape`.
5. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
6. If a second relaunch fails too, write `failed` to the backlog and tell the captain with evidence.
