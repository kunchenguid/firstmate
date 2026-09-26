# Polytoken

Verified on 2026-09-26 with Polytoken 0.8.14.
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/polytoken.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Launch | `polytoken new --prompt <typed launch envelope>` spawns a daemon session, attaches the TUI, and submits the multi-line brief once attached. |
| Autonomy | `default_permission_matcher: bypass` in the worker overlay below; Polytoken has no per-launch permission flag. |
| Busy state | `pre_user_prompt` opens and `stop` closes a turn through the generation-bound writer; a queued follow-up fires another `pre_user_prompt` inside the same turn. `../../../bin/fm-busy-lib.sh` owns trust. |
| Exit command | `/quit`; the slash palette accepts it on the first Enter, the TUI exits at once, and the daemon finishes shutting down about five seconds later. It prints no resume hint. |
| Interrupt | One Escape cancels the running turn, tool included, flashes `Cancelling turn`, and leaves an empty composer; a turn cancelled during a tool call renders `Canceled after <n>s`, one cancelled before any output leaves no turn row. No hook fires, so control invalidates a busy record to unknown. |
| Rewind hazard | On an idle agent one Escape only flashes `Press Esc again to rewind to a prompt.`; a second Escape inside that flash opens the `Rewind` picker, where Enter drops the conversation after the chosen point. One Escape closes it. |
| Skill invocation | `@skill:<name>` in a prompt; its References popup takes the first Enter. Skills load from `~/.agents/skills`, the global config's `skills/`, and the project's `.agents/skills` and `.polytoken/skills`. |
| Resume | `polytoken continue <session-id>` restores the conversation, facet, and model and re-runs the project hooks; `polytoken sessions --format json` lists live sessions with `session_id`, `pid`, and `project_path`. |
| Model flag | `--model <provider>/<model>` or a listed `<provider>/<model>(<variant>)`; unqualified names and unlisted variants fail inside the pane, so spawn validates first. |
| Effort flag | None; a requested level becomes the model's `(<level>)` variant only when `polytoken models --format json` lists it among that model's reasoning levels, and is otherwise recorded but omitted. |
| Model discovery | `polytoken models --format json`, which also names `default_model`; `polytoken auth provider status` reports managed provider logins. |
| Marker | None reaches tool shells; `POLYTOKEN_*` variables are set for hook processes only. Anchored `polytoken` ancestry identifies the adapter. |
| Trust dialogs | None for a fresh worktree. A data directory without recorded license acceptance opens a `License Agreement` gate that Firstmate never answers. |
| Update prompt | The launch-time update check can prompt before the session; `POLYTOKEN_SKIP_UPDATE_CHECK=1` on the launch skips it. |

## Worker overlay

Polytoken reads hooks only from `hooks.json` in the global config directory and in the project's `.polytoken/` directory, and `--config-dir` starts an isolated daemon that loads neither the global layer nor project hooks.
`../../../bin/fm-polytoken-lib.sh` therefore writes a Firstmate-owned `.polytoken/hooks.json` and `.polytoken/config.yaml` into the task worktree, hidden through `info/exclude`, while the captain's global config, auth, and hooks load unchanged ahead of it.
A project that tracks either file, already holds a different one, or holds another `.polytoken/config.*` file refuses the spawn rather than being edited.
Relaunch retires the overlay through `../../../bin/fm-control-lib.sh`, and cleanup removes only files still carrying the overlay's marker.

## Detached daemon

The daemon double-forks away from the pane (parent pid 1, its own process group, cwd = the worktree), and its tool shells descend from it rather than from the TUI.
A TUI that stops without `/quit` leaves the daemon running any turn in flight, so an agent-free pane does not prove an agent-free worktree.
Spawn and relaunch refuse while a live session is anchored at the worktree, naming `polytoken attach <id>` and `polytoken reap <id>`.
Cleanup's worktree process reaper stops a leftover daemon with SIGTERM, which it honors in about five seconds.

## Composer and steering

The composer is the separated shape: one or more rows between two full-width rules above the status row, with no glyph or placeholder.
`../../../bin/fm-composer-lib.sh` proves it empty only with a live `polytoken` identity, which the tmux probe reads from the pane's foreground process and its `Running for <n>` turn row; Herdr's native identity does not name Polytoken, so there it stays unknown and `exit` refuses.
Text submitted while a turn runs is queued (`Queued for the next agent pause`) and folded into that turn, so a steer typed into a busy pane is delivered rather than lost.
Alt+Enter inserts a newline and Ctrl+U clears only the current row.

## Primary integration

No primary stop guard, watcher protocol, pre-tool protection, or session-start contract was verified for Polytoken.
Do not launch a primary or secondmate with this adapter.
