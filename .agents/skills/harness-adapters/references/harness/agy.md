# Google Antigravity CLI (agy)

Verified 2026-09-11 on agy 1.2.1 for crewmate and scout work only.
agy is not verified or supported as a primary or secondmate harness.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `bin/fm-spawn.sh` resolves an executable named `agy` from `PATH`, then `$HOME/.local/bin/agy`, and refuses when neither is executable. |
| Launch | The canonical interactive launch is `agy --model <model> --dangerously-skip-permissions -i "<brief>"`, with the brief encoded by Firstmate's operational-input helper. |
| One-shot mode | `-p` is headless one-shot mode and exits immediately, so it is never the worker launch path. |
| Models | `--model <model>` is passed when a model is selected, while agy's installed catalog remains the authority because it is narrow and spans Gemini, Claude, and GPT-OSS variants. |
| Effort | `--effort low|medium|high` is passed when requested, while `xhigh`, `max`, and unsupported values remain in task metadata and are omitted from the launch. |
| Busy state | The workspace-local `PreInvocation` hook records `busy` and the `Stop` hook records `idle` through `bin/fm-busy-event.sh` using source `agy-hook`. |
| Turn end | The workspace-local `Stop` hook also touches `state/<id>.turn-ended` for the watcher's notification path. |
| Hook location | agy discovers `.agents/hooks.json` by walking from its cwd to the enclosing git repository, so `bin/fm-spawn.sh` writes this one file inside the task's isolated worktree and `bin/fm-teardown.sh` removes it. |
| Hook scope | The workspace-local hook is the only approved agy worktree write, and Firstmate never edits the shared `~/.gemini/config/hooks.json`. |
| Interactive limitation | `PreInvocation` and populated `workspacePaths` were verified in interactive mode, while headless `PreInvocation` and task-identifying `workspacePaths` were not established and are irrelevant because the worker launch is interactive. |
| Interrupt | One `Ctrl+C` cancels the active turn and leaves the session alive for the next prompt. |
| Exit | `Ctrl+D` exits cleanly, and double `Ctrl+C` is also supported by agy; the control plane uses `Ctrl+D` as the deterministic exit key. |
| Resume | agy accepts `--continue`/`-c` and `--conversation <id>`, and prints a conversation id in its exit resume hint. |
| Trust | No separate trust-dialog path was observed, and `--dangerously-skip-permissions` is required for unattended tool work. |
| Detection | No agy-specific environment marker was established, so Firstmate detects the exact `agy` process name in ancestry and liveness classification. |

## Launch and lifecycle wiring

The launch template keeps agy interactive and supplies the initial brief with `-i`.
The hook file uses agy's direct command-hook schema with `PreInvocation` and `Stop` arrays.
Each generated command is bound to the task id, state directory, and minted busy generation.
An existing `.agents/hooks.json` is preserved and causes the canonical agy spawn to refuse rather than overwrite an unknown workspace hook.
The generated file is excluded through the worktree's git info exclude and is removed before a pooled worktree is returned.

## Known gaps

The full supervised brief, steer, and teardown dispatch was not run during adapter verification and remains the follow-up live test.
The minimum safe delay for slash or skill submission was not characterized beyond successful generous two-to-three-second delays.
The default five-minute print timeout and long multi-tool-call behavior were not tested.
Headless `PreInvocation` behavior is not supported by this adapter contract because headless mode is not used for worker launches.
