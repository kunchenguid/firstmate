# Claude exit-dialog screen captures

These files are the visible-screen inputs for the exit-dialog cases in `../../fm-control.test.sh`.
They pin `fm_control_exit_confirm_key` in `../../../bin/fm-control-lib.sh`, which lets `bin/fm-control.sh <id> exit` confirm Claude's background-work dialog with one Enter.

| File | Source | Screen |
| --- | --- | --- |
| `background-work-v2.1.280.screen` | Claude Code 2.1.280, captured 2026-09-22 with `tmux capture-pane -p -S -0` | `/exit` submitted while one `run_in_background` shell ran; three options with `1. Exit and stop tasks` selected |
| `background-work-two-option.screen` | Transcribed from the 2026-09-21 diagnosis lab capture of an earlier Claude Code build; the recorded shell commands were already elided there | The same dialog with two options, `1. Exit and stop tasks` selected and `2. Stay` |
| `workspace-trust-v2.1.280.screen` | Claude Code 2.1.280, captured 2026-09-22 the same way | The workspace-trust dialog, which shares the footer and must never receive the confirming Enter |

The only edits are the working-directory path, replaced with `/tmp/fm-task-worktree`, and the shell prompt above the trust dialog, removed.
On 2.1.280, an Enter on the first capture's screen stopped the background `sleep 900` and exited the agent, leaving only the pane shell.
