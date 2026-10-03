# Factory Droid CLI

Droid is a verified crewmate and scout harness on the tmux and Orca TUI paths; it has no Firstmate primary supervision protocol and cannot run a secondmate.
`../../../bin/fm-spawn.sh` owns its launch and runtime settings file, while `../../../bin/fm-control-lib.sh` owns interrupt, exit, and relaunch mechanics.

## Operating facts

| Fact | Value |
| --- | --- |
| Start | `droid --settings <task-settings> --auto high "<launch-brief>"` starts an interactive TUI and submits the positional prompt. |
| Model | Interactive `droid --help` offers no `--model` flag, so Firstmate validates a requested ID with `droid exec --model <id> --list-tools` and selects it through per-task settings using IDs listed by `droid exec --help`. |
| Effort | Interactive `droid --help` offers no reasoning flag, so the runtime settings key `reasoningEffort` carries a shared effort only with an explicit `--model` whose Factory catalog entry lists support for it. |
| Autonomy | `--auto high` plus `sessionDefaultSettings.autonomyLevel=high` in the per-task settings file keeps the interactive TUI at Auto (High), with commands allowed. |
| Status line | The per-task settings replace any user `statusLine` with the command `printf firstmate` so the composer parser can prove an empty pane beneath Droid's tmux or Orca footer. |
| Turn state | `UserPromptSubmit` opens a busy record; `Stop`, `Notification` with `idle_prompt`, and `SessionEnd` close it; `Stop` also touches the task's turn-ended marker. |
| Trust | Spawn confirms that `Trust this folder` is selected in the live viewport before sending Enter, then waits for the prompt hook to prove brief receipt. |
| Interrupt | One Escape cancels a running turn; Ctrl+U clears a prompt Droid restores from its steering queue. |
| Exit | `/exit` terminates the interactive TUI. |
| Resume | `droid --resume <sessionId>` resumes a native session, while Firstmate's deterministic `relaunch` starts from the brief and progress note. |
| Identity | The live process name is exactly `droid`, with no verified child environment marker; process ancestry identifies it. |
| Skill invocation | Use the TUI's slash command, such as `/no-mistakes`, when that skill is installed. |

The settings file lives under this task's Firstmate `state/` and is removed on relaunch or teardown.
No project `.factory/` file or user Factory hook configuration is changed.
Folder trust is an interactive Droid decision on the isolated worktree; the spawn does not write Factory's trust store.
Only tmux and Orca can launch Droid because their viewport capture, composer, and lifecycle controls are verified; Herdr and Zellij require live verification before dispatch.
A history capture could replay a stale trust dialog and send Enter to a live composer.
The per-task settings leave the operator's `hooksDisabled` policy intact, and spawn refuses when hooks cannot acknowledge the launch brief.
Requested effort stays in task metadata but is omitted from Droid settings when no explicit `--model` is given, since the operator's own default model then runs, or when that model's CLI catalog does not establish support for it.

The CLI and hook contracts come from `droid --help`, `droid exec --help`, and Factory's [CLI reference](https://docs.factory.com/droid-cli/cli-reference.md), [settings reference](https://docs.factory.com/droid-cli/settings.md), and [hooks reference](https://docs.factory.com/harness/hooks.md).
[`docs/verification/runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#factory-droid-cli) records the current live evidence.
