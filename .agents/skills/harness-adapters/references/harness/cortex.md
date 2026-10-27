# Cortex Code

Verified on 2026-10-12 with Cortex Code 1.1.104 (`cortex`, build 1.1.104+041358.66de1c44636f) on Linux, through tmux and a named Herdr 0.8.2 lab session.
The live worker guard also passed on 1.2.14 the same day; the Herdr lab checks ran on 1.1.104 only.
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/cortex.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Native `UserPromptSubmit` opens, `Stop` closes normal completion and an Escape interrupt alike, and `SessionEnd` closes shutdown, through the generation-bound writer; `../../../../../bin/fm-busy-lib.sh` owns trust. |
| Hook channel | A per-task plugin directory passed with `--plugin-dir`; `--config <settings.json>` replaces the user settings file but never supplies hooks, and no flag switches the user or project hook files off. |
| Exit command | `/quit`, with the shared slash-command settle before Enter; prints a summary carrying `cortex --resume <session-id>`. |
| Interrupt | One Esc cancels a running turn and prints `Interrupted`; Esc, single or doubled, on an idle composer does nothing, and repeating it never exits. Ctrl+C also cancels a running turn and is not used. |
| Skill invocation | `/<skill>` from the composer; the slash popup lists user skills from `~/.claude/skills` beside Cortex's own commands, but an end-to-end skill invocation through `fm-send` was not exercised. |
| Resume | `cortex --resume <session-id>` restores the conversation and fires `SessionStart` with `source: resume`; `--continue` and `cortex resume --last` are in `--help` and were not exercised. `--session-id` is ignored for an interactive session, so the id is read from the exit summary or a hook payload, never chosen. |
| Model flag | `--model <id>` with the ids an unavailable-model error lists, such as `claude-sonnet-5-5` and `claude-haiku-5-5`, or `auto`. |
| Effort flag | `--effort minimal\|low\|medium\|high\|max`; `xhigh` has no native level and is omitted. |
| Model discovery | `/model` in the composer, or the error a bad `--model` produces on its first prompt; there is no listing subcommand. |
| Marker | None; anchored native `cortex` ancestry identifies the adapter and outranks foreign inherited markers. |
| Trust dialogs | `--dangerously-allow-all-tool-calls` (alias `--bypass`) also skips the `Do you trust this project?` dialog and writes nothing to `~/.snowflake/cortex/cortex.json`; project hooks and settings still load. |
| Imported config | Cortex loads Claude-compatible `~/.claude/settings.json` and project `.claude/settings.json` and `settings.local.json` hooks as well as its own `.cortex/` files, so a worker in a project with Claude hooks runs them; there is no switch to disable the import. |
| Commit attribution | The model, not a client setting, writes a `Generated with Snowflake CoCo` line and a `Co-authored-by: Snowflake CoCo <noreply@snowflake.com>` trailer; the spawn-owned commit-msg strip (`../../../../../bin/fm-git-strip-ai-trailers.sh`) removes both unless the home sets `config/keep-ai-trailers`. |

## Worker lifecycle limits

Claude project hooks also run inside a Cortex worker and cannot be switched off, so weigh that before choosing this adapter for a project whose `.claude/` hooks assume Claude Code.
The plugin's `SessionStart` hook fires at startup, before the first prompt, and Firstmate uses it only to register the pane on Herdr; busy state comes from `UserPromptSubmit`, `Stop`, and `SessionEnd`.
A turn that ends in a model error (such as an unavailable model) leaves the composer idle; whether `Stop` fires for it was not observed, so a worker sitting on a rendered error with a busy record is a case for the stale-worker playbook, not a hook fault.
`--sql-read-only` and the `guard:` cell of the mode line are the SQL write guard, not a tool-permission setting; the launch does not pass the flag, so SQL write policy stays the captain's own Cortex configuration, and `CORTEX_CLIENT_READ_ONLY=1` set in the launch environment applies natively.
Herdr 0.8.2 has no Cortex entry in its detection manifest (herdrdev/herdr discussion 783), so a hook-less Cortex pane reads `agent_not_found`, which the liveness probe classifies `dead` and which makes the steering doorbell skip the endpoint.
The per-task plugin's hooks therefore report the pane to Herdr as a `cortex` agent from source `firstmate:cortex` when `HERDR_ENV=1`.
Herdr's own claude integration hook claims a pane as a `claude` session whenever `CLAUDECODE=1` is set, because Cortex loads `~/.claude/settings.json`; that claim survives the Cortex exit and silently drops every later report on the pane, so the launch always clears `CLAUDECODE`.
With the claim in place `agent get` still answers `agent_not_found` after exit and a relaunch cannot register, which leaves only the semantic busy record as state truth.

`../../../../../bin/fm-spawn.sh` owns autonomy, trust, typed brief delivery, the environment clearing, and the omission of the Claude permission-mode mapping.
`../../../../../bin/fm-cortex-plugin.sh` owns the private plugin directory and its lifecycle hooks; the user and project configs remain vendor-owned and untouched.

## Composer and steering

`../../../../../bin/fm-composer-lib.sh` owns the verified bordered `›` composer, whose rounded top rule carries the session title and whose idle placeholder is `Type your message...` (`Type to queue message...` while a turn runs), drawn as a reverse-video cursor cell then dim text. The classifier accepts that titled top rule only when the caller proves the pane's foreground process is Cortex (the `cortex=1` capability: tmux's exact process name, Herdr's native agent probe), so a titled box on any other pane stays ambiguous.
The `>> bypass safeguards  |  teams: off  |  plan: off ...` mode line under the box is furniture, and its wording follows the terminal width.
Cortex parks the terminal cursor in the first column of the blank row under its footer, so on tmux the cursor-anchored read cannot find the composer and `../../../../../bin/fm-tmux-lib.sh` reads the pane cursorlessly for a foreground process named exactly `cortex`; Herdr's read is cursorless already.
`../../../../../bin/fm-spawn.sh` refuses a cortex launch on zellij, cmux, orca, paseo, rex, and t3code, which supply no Cortex pane identity to prove the titled composer empty.
Text typed while a turn runs is queued and listed under `Queued (↑ to edit, Enter to send next):`, and an Escape interrupt lets the queued message start as the next turn.
A dim follow-up suggestion after a turn (`push it`) is ghost text, not a draft.
The `../../../../../bin/fm-task-inbox-lib.sh` doorbell was read and acknowledged through real `fm-send` on tmux, and exit and relaunch were driven through real `fm-control` on a Herdr lab pane.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract was verified for Cortex.
Do not launch a primary or secondmate with this adapter.
ACP, Cortex's own worktree and teams modes, and quota-provider integration remain separate follow-ups.
