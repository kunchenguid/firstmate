# Verification: the agy (Google Antigravity CLI) crewmate adapter

Active empirical evidence for firstmate's agy adapter.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `agy 1.1.12` (`agy --version`) |
| Verified | 2026-08-11 |
| Binary | `~/.local/bin/agy`, Mach-O 64-bit arm64, also first on `PATH` |
| Platform | macOS arm64 (Darwin 24.6.0) |
| App data | `~/.gemini/antigravity-cli/` (settings.json, conversations, brain, logs) |

Every run below used throwaway git workspaces driven through tmux the way firstmate drives a crewmate pane, on an operator account already authenticated to Antigravity.
The temporary lab hook files, trust entries, and scratch workspaces were removed after the runs.

## Verified facts

### Launch, autonomy, and flags

`agy --dangerously-skip-permissions -i "<prompt>"` starts the interactive TUI, submits the prompt, and keeps the session open; the tool turns below ran fully unattended under that flag.
Without the flag, a `run_command` tool call raised a numbered permission dialog ("Requesting permission for: ... Do you want to proceed?" with `> 1. Yes` preselected, Enter accepting, `esc to cancel` in the footer).

Model and effort flags were probed in print mode; every invalid combination refuses at launch with a loud error rather than degrading:

```
$ agy -p "Say only the token FLAG_PROBE_OK" --model gemini-3.6-flash-low --effort low
FLAG_PROBE_OK
$ agy -p "Say OK" --effort xhigh
Error: invalid model selection (--model "" --effort "xhigh"): invalid --effort "xhigh" (valid: low, medium, high)
$ agy -p "Say only OK1" --model claude-sonnet-4-6 --effort low
Error: invalid model selection (--model "claude-sonnet-4-6" --effort "low"): --effort is not supported for model "claude-sonnet-4-6"
$ agy -p "Say only OK4" --model gemini-3.6-flash
Error: invalid model selection (--model "gemini-3.6-flash" --effort ""): --model gemini-3.6-flash requires --effort (available: low, medium, high)
```

`--effort medium` with no model, `--model gemini-3.6-flash --effort high`, `--model gemini-3.6-flash-low` alone, and `--model claude-sonnet-4-6` alone all succeeded.
`agy models` is the discovery surface; it listed effort-variant Gemini ids (`gemini-3.6-flash-{low,medium,high}`, ...), `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, and `gpt-oss-120b-medium`.

### Trust is per exact workspace path and is not bypassed by the autonomy flag

A first launch in a fresh workspace shows "Do you trust the contents of this project?" with `> Yes, I trust this folder` preselected and Enter accepting, even under `--dangerously-skip-permissions` (observed in `/tmp/fm-agy-lab/repo2` and again in a fresh repo under `$HOME` while `/Users/niels` itself was already trusted, disproving prefix trust).
Accepting appends the exact workspace path to `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json`, which on this machine contained only that array.
Pre-adding the exact worktree path to that array before launch suppressed the dialog entirely (verified in `/tmp/fm-agy-lab/repo5`), which is the basis of `bin/fm-spawn.sh`'s jq pre-trust preflight.

### Hooks: surfaces, trust timing, and event lifecycle

agy documents its hook surface in the bundled `agy-customizations` skill (`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`): a `hooks.json` in a customization root, events `PreToolUse`, `PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`, commands run via `sh -c` with JSON payloads on stdin and JSON expected on stdout.
All of the following was confirmed live with a logging hook:

- Workspace hooks fire from both the plural `.agents/hooks.json` and the singular `.agent/hooks.json` discovery roots, and MERGE with a global `~/.gemini/config/hooks.json` (workspace handlers ran first in every capture).
- Workspace hooks load ONLY when the workspace was already trusted at launch: in the session where trust was granted through the dialog, the workspace hook log stayed empty, and a relaunch in the now-trusted workspace fired them.
  A global hook fired even in the dialog session, but a global hook cannot carry per-task state without payload parsing, so fm-spawn pre-trusts and uses the per-task workspace file instead.
- A clean no-tool turn logged `PreInvocation` then `Stop` with `"terminationReason":"NO_TOOL_CALL","fullyIdle":true`; a tool turn logged `PreInvocation`, tool events, further `PreInvocation`s, and one final `Stop`.
- During a turn whose command became a background task, `Stop` fired MID-TURN with `"fullyIdle":false`, the composer returned with a `N task(s) · /tasks` footer, and the loop auto-resumed with a fresh `PreInvocation` about 2 seconds later before the final `Stop` with `"fullyIdle":true`.
  This is why the adapter's Stop handler records idle unconditionally: gating idle on `fullyIdle` could latch a permanent busy under a long-lived background process, while the interactive-composer window is honestly idle and busy re-opens within seconds.
- A user interrupt (single Escape mid-generation) fired NO hook at all: the log ended at the last `PreInvocation` and no `Stop` arrived.
  This is the same gap Claude's hook set has, and it is why an interrupted agy worker typically reads busy until its next turn's Stop.
- A `PreToolUse` hook whose stdout was `{}` DENIED the tool call ("⚠ Tool call denied by pre-tool hook"), looping the model on denials.
  Firstmate therefore registers only the flat no-decision events (`PreInvocation`, `Stop`), and each hook command ends with `printf '{}'` so stdout is always a parseable JSON object.

### Interrupt, exit, resume

Single Escape mid-turn cancels the turn: the transcript shows `⎿  Interrupted · What should Antigravity CLI do instead?`, the composer is left EMPTY (no muse-style prompt restore), and the footer returns to `? for shortcuts`.
Typing `/quit` opened the slash popup showing `> /exit (quit)  Exit the CLI`; ONE Enter selected and executed it (no grok-style second-Enter requirement), and the pane printed:

```
Resume with -c (or command below):
agy --conversation=f77c8c82-43dc-422b-b0db-c3b4b15126bb
```

`agy -c --dangerously-skip-permissions -i "<prompt>"` resumed the prior conversation with memory intact (it answered a token from an earlier turn).
An unknown slash command is NOT sent to the model: typing `/no-mistakes` showed `No matches` in the popup, and Enter produced the inline composer error `Unknown command: /no-mistakes`, cleared by Ctrl+U.
agy does not discover claude user-level skills (`~/.claude/skills/no-mistakes` existed during the probe), so skill invocation for agy crews is natural language pointing at the skill file.

### Composer shape and rendered signals

The idle composer is a bright-blue `ESC[94m>` prompt row between two full-width dark-gray (`ESC[90m`) `─` rules - structurally the classifier's separated (pi) pair with a shell-glyph prompt row:

```
────────────────────────────────────────
>
────────────────────────────────────────
? for shortcuts                    Gemini 3.6 Flash · high
```

Typed text renders in the default foreground after the glyph (`ESC[94m>ESC[39m hello composer probe text`); no idle placeholder or ghost text was observed in any capture; Ctrl+U clears typed text.
Mid-model-call the pane adds a braille spinner row with a rotating label (`⣷  Loading...`, `⡿  Working...`, `⣷  Generating...`) and the footer's left slot swaps `? for shortcuts` for `esc to cancel`.
`esc to cancel` also shows while a slash or permission popup is open, and the footer reverts to the idle shape while the loop is suspended on a background task, so the footer is a delivery-guard signal only, never a state source (`FM_TMUX_AGY_BUSY_REGEX_DEFAULT`).
A dead pane keeps the stale pair in scrollback with a shell prompt below it, which is why the composer verdict requires a live `agy` foreground process (the tmux identity probe) before the pair proves anything.
A spontaneous vendor feedback survey ("How's the CLI experience so far? [1] Good [2] Fine [3] Bad [0] Skip") appeared once mid-session and consumed the next keypress; `0` dismissed it.

### Environment markers and process identity

A tool child's environment carried `ANTIGRAVITY_AGENT=1` plus `ANTIGRAVITY_CONVERSATION_ID`, `ANTIGRAVITY_PROJECT_ID`, `ANTIGRAVITY_LS_ADDRESS`, `ANTIGRAVITY_AGENTAPI_EXE`, `ANTIGRAVITY_TRAJECTORY_ID`, and `ANTIGRAVITY_SOURCE_METADATA` (the full tool-call JSON).
The same dump also showed a `CLAUDECODE=1` inherited from the launching session's environment, demonstrating the foreign-marker precedence hazard; the launch template clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` for that reason.
The live TUI process's command name is exactly `agy`, which is what `bin/fm-harness.sh`'s ancestry walk and `bin/backends/tmux.sh`'s liveness classifier anchor on.

### Worktree hygiene

`git status --short` in the lab workspaces stayed clean across tool turns; conversations, transcripts, and artifacts live under `~/.gemini/antigravity-cli/` (`brain/<conversation-id>/`), not in the workspace.
The only workspace file firstmate adds is its own `.agent/hooks.json`, excluded via git info/exclude and removed by relaunch retirement and teardown.

## Still unproven

- Herdr, Zellij, cmux, and Orca backends have not run an agy worker; only tmux is verified.
  Herdr's native `agent get` identity for an agy pane is unknown, so the separated-shape verdict there stays `unknown` until probed.
- No secondmate/primary integration exists: no turn-end guard hook path, no watcher supervision block, no session-start tier.
  `bin/fm-spawn.sh` refuses `--secondmate agy` for that reason.
- The `Stop` payload's `terminationReason` vocabulary beyond `NO_TOOL_CALL` (for example the model-stop and error values) was not enumerated; the adapter does not branch on it.
- Long multi-row composer wrap was not exercised; the shared classifier's pair-interior row rules cover it structurally but no live capture pinned it.

## Refresh procedure

`FM_AGY_SIGNALS_LIVE=1 tests/fm-agy-signals-live-e2e.test.sh` is the command that refreshes the harness-dependent half: it launches the real installed agy against a pre-trusted scratch workspace and fails naming the agy version when hook delivery, trust gating, the identity probe, or the composer verdict drifts (passed 2026-08-11 on agy 1.1.12).
After an agy upgrade, run that guard, then re-run the flag matrix above, one Escape interrupt (expect no Stop event and an empty composer), one `/exit` (expect the `--conversation` resume line), and one fresh-workspace launch WITHOUT pre-trust (expect the trust dialog), then update the version and date here.
`tests/fm-agy-harness.test.sh` pins the harness-independent logic in CI.
