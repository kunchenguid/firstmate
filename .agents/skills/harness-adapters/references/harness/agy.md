# Google Antigravity CLI (agy)

Verified 2026-09-11 on agy 1.2.1 for crewmate and scout work only.
The launch, workspace-binding, trust, and exit rows below were re-verified live against a real authenticated agy 1.2.1 in a tmux pane.
agy is not verified or supported as a primary or secondmate harness.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `bin/fm-spawn.sh` resolves the Antigravity CLI only at `$HOME/.local/bin/agy` and refuses when it is not executable. `PATH` is never consulted: the Antigravity IDE cask installs a wrapper under the same `agy` name (`/opt/homebrew/bin/agy` execs the IDE binary), so a PATH lookup launches the wrong program - and a stale cask makes the pane die instantly while the spawn reports success. |
| Launch | The canonical interactive launch is `agy --add-dir <worktree> --model <model> --dangerously-skip-permissions -i "<brief>"`, with the brief encoded by Firstmate's operational-input helper. |
| One-shot mode | `-p` is headless one-shot mode and exits immediately, so it is never the worker launch path. |
| Models | `--model <model>` is passed when a model is selected, while agy's installed catalog remains the authority because it is narrow and spans Gemini, Claude, and GPT-OSS variants. |
| Effort | No effort flag is ever passed. agy encodes effort in the model id (`gemini-3.8-flash-low`, `-medium`, `-high`, `gemini-3.1-pro-low`, `-high`, and fixed-effort Claude and GPT-OSS entries) and defines no `--effort` flag: verified on agy 1.2.2, `--model gemini-3.8-flash-low --effort high -p` exits 1 with `--model gemini-3.8-flash-low conflicts with --effort=high`, a bare `--effort` or a mismatched pair is rejected as an undefined flag, and in the `-i` mode Firstmate launches agy silently discards BOTH flags and runs the host's persisted default model. Every requested effort therefore stays in task metadata only, per the record-and-omit contract, and reaches agy through the model id. `config/crew-dispatch.json` rejects an agy profile that carries an `effort`, as it does for cursor. |
| Busy state | The workspace-local `PreInvocation` hook records `busy` and the `Stop` hook records `idle` through `bin/fm-busy-event.sh` using source `agy-hook`. |
| Turn end | The workspace-local `Stop` hook also touches `state/<id>.turn-ended` for the watcher's notification path. |
| Hook location | agy discovers `.agents/hooks.json` by walking from its cwd to the enclosing git repository, so `bin/fm-spawn.sh` writes this one file inside the task's isolated worktree and `bin/fm-teardown.sh` removes it. |
| Hook scope | The workspace-local hook is the only approved agy worktree write, and Firstmate never edits the shared `~/.gemini/config/hooks.json`. |
| Interactive limitation | `PreInvocation` and populated `workspacePaths` were verified in interactive mode, while headless `PreInvocation` and task-identifying `workspacePaths` were not established and are irrelevant because the worker launch is interactive. |
| Interrupt | One `Ctrl+C` cancels the active turn and leaves the session alive for the next prompt, and it is what `fm_control_interrupt_key` returns; Escape was not observed to cancel a turn and is not used. |
| Exit | `/quit` is an alias of `/exit` and ends the session on one submitted Enter, which is what `fm_control_exit_command` returns. `Ctrl+D` is NOT usable as a single-key exit: the first press only prints `press ctrl+d again to exit` and the process stays alive until a second confirming press. |
| Resume | agy accepts `--continue`/`-c` and `--conversation <id>`, and prints a conversation id in its exit resume hint. |
| Workspace binding | `--add-dir <worktree>` is required and is not redundant with the pane's cwd. Launched on cwd alone, agy renders the worktree as the accessed workspace but runs every tool in `~/.gemini/antigravity-cli/scratch`, so the task worktree receives no work and its `.agents/hooks.json` never fires. With `--add-dir`, tools run in the worktree and both hooks fire. |
| Trust | A fresh folder is gated behind an interactive `Do you trust the contents of this project?` dialog, which would wedge an unattended spawn; answering it appends the folder to the machine-global `trustedWorkspaces` list in `~/.gemini/antigravity-cli/settings.json`. `GEMINI_CLI_TRUST_WORKSPACE=true` is NOT honoured. Passing the worktree with `--add-dir` admits it with no dialog and no global write, which is why Firstmate relies on that flag rather than a trust store. `--dangerously-skip-permissions` remains required for unattended tool work. |
| Detection | The installed `agy` is a native Mach-O arm64 executable rather than a node bundle, so its process `comm` is the literal `agy`, and no agy-specific environment marker was established. agy does not export `GEMINI_CLI`, which it carries only as a surface enum value alongside `ANTIGRAVITY`, so gemini's marker never precedes agy's ancestry match. Firstmate therefore detects the exact `agy` process name in ancestry and liveness classification. |

## Launch and lifecycle wiring

The launch template keeps agy interactive, binds the task worktree with `--add-dir`, and supplies the initial brief with `-i`.
The hook file uses agy's direct command-hook schema with `PreInvocation` and `Stop` arrays.
Each generated command is bound to the task id, state directory, and minted busy generation.
An existing `.agents/hooks.json` is preserved and causes the canonical agy spawn to refuse rather than overwrite an unknown workspace hook.
The generated file is left untracked rather than added to the shared repository's git info exclude, which every worktree including the primary checkout would see, and it is removed at teardown - only for a task whose recorded harness is agy - before a pooled worktree is returned.
A fresh spawn that aborts before publishing its task record removes the file itself, because no record yet names it and a leftover untracked path would refuse the next spawn of ANY harness into that pooled worktree; once the record is published the removal belongs to teardown.
Because the file is untracked and git-visible, every reading that means unlanded crew work exempts exactly that one path for an agy task - teardown's worktree safety check and the relaunch checkpoint's `worktree_dirty` flag - so an agy task is never reported dirty over firstmate's own wiring.

## Known gaps

The full supervised brief, steer, and teardown dispatch was not run during adapter verification and remains the follow-up live test.
The minimum safe delay for slash or skill submission was not characterized beyond successful generous two-to-three-second delays.
The default five-minute print timeout and long multi-tool-call behavior were not tested.
Headless `PreInvocation` behavior is not supported by this adapter contract because headless mode is not used for worker launches.
