---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer. Escalates from peek, to one-line steer, to harness-specific interrupt, to relaunch with progress, to failed status.
user-invocable: false
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

Escalate in order:

1. Peek the pane.
2. If the crewmate is waiting on a question its brief already answers, answer in one line via `bin/fm-send.sh`.
3. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `bin/fm-send.sh <window> --key Escape`.
4. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
   Relaunch through the pane's shell, not through `bin/fm-send.sh` - see "Relaunching into a pane that holds no agent" below.
5. If a second relaunch fails too, write `failed` to the backlog and tell the captain with evidence.

## Relaunching into a pane that holds no agent

Once the agent has exited, the pane holds a bare shell, and `bin/fm-send.sh` will not touch it.
That refusal is deliberate, not a bug: the only way to put text into a shell pane is to run it, so forwarding a steer there would EXECUTE it, and a corrective line like `git reset --hard origin/main` would run in the crewmate's worktree.
`fm-send` therefore refuses a pane with no detected agent and reports that nothing was delivered and nothing was executed.
Do not look for a way around it.

Use herdr's own verb instead, which is exactly what `bin/fm-spawn.sh` uses to start an agent in a fresh pane:

```sh
herdr pane run <pane-id> '<launch command>'
```

The pane id is the `window=` value in `state/<id>.meta` (post-cutover panes, the ones marked `mux=herdr`).
Build the launch command from the adapter's entry in `harness-adapters`, and carry the same `FM_HOME=` / `HERDR_SESSION=` / `FM_*_OVERRIDE=` env prefix `fm-spawn` puts on its own launch string, or the relaunched agent loses the pins that tell it which firstmate home it belongs to.
For a pane that predates the cutover, `window=` is a tmux session:window and the old path still applies: `bin/fm-send.sh` types into that shell as it always did.

There is no firstmate wrapper for this today.
`fm_herdr_run` in `bin/fm-herdr.sh` is library-level only and `bin/fm-herdr.sh`'s CLI exposes just `--name` and the workspace reconcile, so the binary's verb is the supported route.

## Reading a steer's outcome

Delivery to a herdr pane is acknowledged rather than inferred, so `bin/fm-send.sh` names which failure you hit instead of leaving you to guess.

- **Refused at an approval dialog** - the crewmate is blocked and was not typed over.
  Clear the dialog first with `bin/fm-send.sh <window> --key <choice>`, then send the corrective line.
- **Refused because the pane holds no agent** - nothing was delivered, and deliberately nothing was executed, since a pane holding a shell would have run the steer as a command.
  Peek it: the agent has exited or is still starting, which is step 4 territory, not another steer.
  If it has exited, relaunch with `herdr pane run` as described above; `fm-send` is never the tool for that.
- **Delivered but unconfirmed** - a warning, not an error.
  Treat it as delivered and do not re-send it; re-sending a steer the crewmate already holds is the worse of the two errors.
- For a pane that predates the herdr cutover the old rule still holds: only a positively confirmed swallow, with the text left in the composer, is a failure.
