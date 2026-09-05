# GitHub Copilot CLI

Verified initially for crew and secondmate dispatch on Linux with Copilot CLI 1.0.73 in the work behind PRs #827 and #1009.
The current hook and launch contract was refreshed against Copilot CLI 1.0.83-3 and the GitHub Copilot hooks reference on 2026-09-02.

## Operating facts

| Fact | Value |
|---|---|
| Launch | `copilot --allow-all --no-ask-user -i "<instructions>"`, with optional `--model` and `--effort`; `-i` starts an interactive session and executes the initial prompt. |
| Busy state | Repository `userPromptSubmitted`, `agentStop`, and `sessionEnd` hooks write the `copilot-hook` semantic source; the completed-turn hook also touches the task turn-end marker. |
| Exit | `/exit`. |
| Interrupt | Single Escape. |
| Skill | Name the skill with a leading slash in the prompt, for example `Use the /no-mistakes skill`; `/skills` manages discovery and enablement. |
| Resume | `copilot --resume=<session-id>` or `copilot --continue`; deterministic Firstmate recovery still uses relaunch from durable instructions. |
| Autonomy | `--allow-all` grants tool, path, and URL permissions; `--no-ask-user` removes the interactive question tool from unattended workers. |
| Marker | `COPILOT_CLI=1` reaches child and hook processes; Firstmate clears it when launching another adapter so a markerless child cannot inherit Copilot identity. |
| Model | `--model <model>`; discover current availability through `/model`. |
| Effort | `--effort <low\|medium\|high\|xhigh\|max>`; Copilot also exposes lower `none` and `minimal` values outside Firstmate's shared vocabulary. |
| Composer | Complete half-box using a `╻` plus `▄` top rule, `┃`-prefixed content, and a width-matched `╹` plus `▀` bottom rule. |

The CLI may show a repository trust prompt before hooks and project instructions load.
Accept the remembered trust choice only for a repository the captain intends to trust, then verify the initial instructions begin processing.

## Detection and liveness

`../../../bin/fm-harness.sh` prefers the nearest real Copilot process in ancestry and falls back to `COPILOT_CLI=1` only when ancestry cannot prove the host.
It also recognizes the Linux process shapes observed across releases: command name `copilot`, argv zero ending in `/copilot`, or the bundled executable's `MainThread` command with Copilot argv zero.
The anchored argv-zero rule deliberately does not match editor extensions, plugin paths, or an unrelated command whose later arguments merely mention Copilot.

Tmux normally reports `copilot` through `#{pane_current_command}` even when the kernel command is `MainThread`.
`../../../bin/backends/tmux.sh` also applies the shared executable-path identity to the foreground process group, so either independent signal can prove the agent alive.

## Worker hooks

`../../../bin/fm-spawn.sh` writes `.github/hooks/fm-busy-state-<task-id>.json` into a crew or scout worktree and excludes it from git.
That install refuses symlinked or non-directory `.github` path components and any pre-existing destination, so a repository cannot redirect or reuse Firstmate's generated worker hook.
The hook uses absolute Firstmate-owned commands and incarnation tokens, so a stale worker cannot settle a replacement worker's busy record.
`../../../bin/fm-teardown.sh` and the control-plane relaunch path remove the hook before a worktree is reused.

Secondmates skip the worker hook because an idle secondmate is healthy.
Their own primary behavior comes from the tracked repository hook below.

## Primary integration

Tracked `.github/hooks/fm-primary.json` owns Copilot's primary integration.
Every entry routes through `../../../bin/fm-copilot-hook.sh`, which exits unless the actual host process ancestry is Copilot so non-Copilot runtimes and Copilot cloud-agent jobs remain inert.
Its native `sessionStart` hook runs the full session-start adapter and returns the digest as `additionalContext`.
Its `preToolUse` hooks apply the watcher-arm, persistent-directory-change, and built-in-delegation protections through the shared policy scripts.
Its `agentStop` hook translates the shared turn-end guard's exit-2 refusal into Copilot's native `decision: "block"` continuation.

Copilot also reads `.claude/settings.json`.
Those tracked Claude compatibility entries resolve the helper root from `CLAUDE_PROJECT_DIR` when present or from the physical hook cwd otherwise, verify that root before executing any helper, and stand down whenever the actual hook host is Copilot.
Every non-Copilot Firstmate launch still clears inherited Copilot markers so a genuine child adapter retains its own hooks.

Primary watcher supervision uses Copilot's attached asynchronous shell task around `../../../bin/fm-watch-arm.sh`.
The CLI notifies the model when that task completes, and the `agentStop` hook prevents a blind turn end when supervision is required but no healthy cycle exists.
`../../../docs/supervision-protocols/copilot.md` owns the exact operating loop.
