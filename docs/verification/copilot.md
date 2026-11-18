# GitHub Copilot CLI worker verification

Verified on 2026-11-04 on Linux with `GitHub Copilot CLI 1.0.105.` through a real pty.
The [adapter reference](../../.agents/skills/harness-adapters/references/harness/copilot.md) owns operating limits; the [spawn header](../../bin/fm-spawn.sh) owns launch mechanics.
Every backend other than tmux and Herdr is refused; a Copilot persistent secondmate is verified on both under Secondmate below, and a hand-opened primary under Copilot as this home's primary.
Vendor observations marked as a pty were made through a private pty; the Herdr trial section records what a real pane showed.

## Unanswerable questions

On 2026-11-07, two real tmux 3.7c panes ran Copilot 1.0.105 with the same prompt, which told the model to use its `ask_user` tool and then append a line to a status file with a shell command.
Without `--no-ask-user` the pane showed `Asking user`, a `Copilot needs information` picker with `red`, `blue`, and `Other (type your answer)`, and waited with no status line written.
With `--no-ask-user` the model reported that no question tool was available, decided alone, appended its status line, and finished with no picker.
`copilot --help` lists the flag as `--no-ask-user` (disable the `ask_user` tool; the agent works autonomously without asking questions).
The shipped launch passes it, and the ordinary shell tool and status-line appends are unaffected.

## Subagent turns

On 2026-11-07, in a real tmux 3.7c pane with Copilot 1.0.105, a worker was told to use its `task` tool to have a subagent run `sleep 20; echo hi`.
The hooks fired in this order: the parent's `userPromptSubmitted`, `preToolUse` for `task`, `subagentStart`, then a second `userPromptSubmitted` and later a second `agentStop` for the subagent, then `subagentStop`, `postToolUse` for `task`, and finally the parent's own `agentStop`.
Subagent payloads carry `agentId`, `agentType`, and `parentAgentId`, and their `sessionId` is the subagent's own; the parent's payloads carry none of those three keys.
The subagent's `agentStop` arrived about 1.5 s before the parent's, so before the fix it closed the parent's busy record and raised the turn-end notification while the parent was still working (the record's sequence counter reached 5 for one parent turn, against 3 after the fix).
The plugin hooks now skip `userPromptSubmitted` and `agentStop` payloads that contain `"parentAgentId":"`, and a repeat run of the same task kept the record `busy copilot-hook` until the parent's `agentStop`, with the turn-end notification raised once at the end.
`subagentStart`, `subagentStop`, and `sessionEnd` are not wired; `sessionEnd` was seen only at exit.

## Real Herdr pane trial

On 2026-11-05 a supervised Copilot 1.0.105 ship worker ran in a real Herdr pane: the `fm-spawn.sh` launch, brief pickup, status reports, and the busy and idle hook records all worked.
Steer delivery through `fm-send` started a busy turn on that pane.

- A real pane draws the composer as a block-glyph box (`╻▄▄▄…` above, `┃`-led input rows, `╹▀▀▀…` below), with no `❯`. An empty composer is a bare `┃` and a draft is `┃ text`. The plain pty shape (`❯` between `─` rules) is read as well, and both are pinned by the real captures in `tests/captures/copilot-1.0.105-herdr`.
- The armed footer `esc again to interrupt` stays visible for about 0.5 s after the first Escape (measured by polling the pane), so the control plane sends the second Escape 0.05 s after the first. The armed proof keeps an idle agent out of the rewind picker, which renders `again to rewind`.
- `fm-control interrupt` on a busy turn delivered both presses and the pane printed `Operation cancelled by user` (claim `cancel=unconfirmed`, as for every adapter without a recorded cancel signal).
- `fm-control exit` stopped the agent, and the pane returned to its shell and printed `Resume copilot --resume=<session-id>`.

## Real tmux pane trial

On 2026-11-05 Copilot CLI 1.0.105 ran as a real scout on tmux 3.7c (Linux) through `fm-spawn.sh --scout --harness copilot --backend tmux`, in a scratch Firstmate home with a private tmux socket and a local-origin project, so no real fleet state or Herdr was touched.
Every step below used the real control plane against the live pane and found no defect in the adapter:

- **Launch:** the worker started in a never-trusted worktree with no trust dialog, picked up its brief, ran a foreground `sleep 240` shell tool, wrote its report, and appended `done`. `#{pane_current_command}` read `copilot`.
- **Busy record:** `userPromptSubmitted` opened a `copilot-hook` busy record, and `agentStop` closed it after the finished turn.
- **Interrupt:** `fm-control interrupt` on the busy turn returned `interrupt-delivered … verified=agent-alive cancel=unconfirmed`, and the pane printed `Operation cancelled by user` with the composer back to a bare `❯`. As the reference records, `agentStop` does not fire after a cancel, so the busy record stayed open until the next prompt.
- **Exit:** `fm-control exit` returned `stopped`; the pane fell back to its login shell and printed `Resume copilot --resume=<session-id>`.
- **Relaunch:** `fm-control relaunch` (a scout requires `--note`) started a replacement agent in the same window and worktree; it re-armed the busy record, picked up the note, wrote its report, and the record closed at `agentStop`.
- **Teardown:** `fm-teardown.sh` on a finished scout returned the worktree and closed the backlog item. It reported the pane's own login shell as a leaked worktree process and removed it; no `copilot` process survived `/exit` (checked by scanning process working directories before and after).
- **Draft safety:** with `zzdraft words` typed and not submitted, `fm-control exit` refused because the composer holds pending text, and the agent kept running.

On tmux a pane draws the plain rule-bounded `❯` composer with a status row above the top rule, not the Herdr block-glyph box, and both shapes classify correctly.
The real screens are in `tests/captures/copilot-1.0.105-tmux` and pinned by `tests/fm-copilot-harness.test.sh`.

## Full-suite and live-guard run

On 2026-11-05 and 2026-11-06, with Copilot CLI 1.0.105 and tmux 3.7c on Linux, the signed-in live guard and the Copilot harness test were run from this branch.

- `FM_COPILOT_SIGNALS_LIVE=1 bash bin/fm-test-run.sh tests/fm-copilot-signals-live-e2e.test.sh` passed without a gate skip (comm `MainThread`, argv[0] `copilot`, real prompt to `busy copilot-hook`, turn end, clean `/exit`).
- `tests/fm-copilot-harness.test.sh` passed.


## Folder trust options

On 2026-11-06 each route below was run in a real tmux 3.7c pane against a scratch git project that carried a project hook (`.github/hooks`), a project skill, and a project MCP server (`.mcp.json`), with a prompt of `reply with the word ok` and the plugin hook from this adapter.
Each cell is what the pane and the hook logs showed.

| Route | Starts unattended | Plugin hooks deliver | Project hooks and MCP load | Real `~/.copilot` untouched |
|---|---|---|---|---|
| `COPILOT_ALLOW_ALL=true` (previous launch) | yes | yes | yes | no (login state, sessions, logs) |
| `COPILOT_ALLOW_ALL=1` plus answering `1. Yes` | no (dialog until answered) | yes | yes | no |
| `COPILOT_ALLOW_ALL=1` plus declining (`Esc`) | no | the agent exits with a blank pane | not applicable | not applicable |
| per-task `COPILOT_HOME` with `trustedFolders` seeded (shipped) | yes | yes | yes | yes |
| per-task `COPILOT_HOME` plus `{"disableAllHooks":true}` in its `settings.json` | yes | yes | yes | yes |

- `COPILOT_ALLOW_ALL` accepts several truthy spellings, but only exactly `true` trusts the directory (`copilot help environment`); `1` with `--allow-all` showed the dialog `Do you trust the files in this folder?` with `1. Yes`, `2. Yes, and remember this folder for future sessions`, and `3. No (Esc)`.
- `1. Yes` is session-only and did not write the real `config.json`, but trusting the folder is what loads project hooks and MCP servers, so it gives no isolation over the previous launch.
- Declining closed the agent, so the dialog cannot be used to keep project configuration out.
- `--trust-folder` is documented for one new prompt-mode session only and was not tried with `-i`.
- The setting `disableAllHooks` read back as `true` from the task home, yet the project hook and the plugin hook both still fired in a `-p` run and an interactive run, so it does not suppress them in 1.0.105.
- A relocated `COPILOT_HOME` is a fresh directory (`config.json` only, then logs, sessions and `installed-plugins` as the run creates them), so the user's own user-level hooks, plugins, and skills stay out of the worker.
- Login worked in a relocated, empty home for `-p` and for the interactive pane: the credential is a `keyring:<host>:<account>@copilot-cli` entry in the OS keyring, not a file under `~/.copilot`.
- A host without an OS keyring keeps the token in `config.json` under `authTokens` on 1.0.109 (the older `copilotTokens` shape is also copied; a plain-text login needs `storeTokenPlaintext`), which a fresh task home lacks.
  `bin/fm-copilot-plugin.sh` therefore copies only `authTokens`, `copilotTokens`, `loggedInUsers`, and `lastLoggedInUser` from the real `config.json` into the task one (mode 600, replaced on every seed so a source without a login clears an earlier copy), pinned by `tests/fm-copilot-harness.test.sh` with fake values; a live config.json-token host was not exercised.
- A failing project MCP server holds the first prompt for about a minute (`Loading … still waiting`), which the previous launch also did.
- No route avoids loading the worktree's own hooks, skills, and MCP servers once the worktree is trusted; the per-task home narrows trust to that worktree and keeps the user home out, which is the only improvement found.

## Native slash skills

On 2026-11-06, in a real tmux pane with a per-task `COPILOT_HOME`, the slash popup listed a project skill from `.github/skills` as `/projskill` and a skill from a `--plugin-dir` plugin as `/<plugin>:<skill>`.
Submitting either rendered `skill(<name>)` and the skill's reply.
`bin/fm-send.sh <task> '/labskill'` against a spawned scout whose worktree carried `.agents/skills/labskill` took the typed plane, submitted without a stuck popup, and produced `skill(labskill)` and the expected reply.
Project skills are discovered from `.agents/skills`, `.github/skills`, and `.claude/skills` (`copilot skill --help`).
Firstmate's own skills are read by path from the brief, so a worker does not depend on the inherited list.

## Hook decision facts

On 2026-11-06, with a plugin hook file and a relocated `COPILOT_HOME` in a real tmux pane, these hook results were observed.
They bear on a Copilot primary, whose hooks are verified under Native primary hooks and Typed wake.

- `preToolUse` printing `{"permissionDecision":"deny","permissionDecisionReason":"..."}` stopped a shell command from running under `--allow-all`, and the pane showed `Denied by preToolUse hook: <reason>`.
- `preToolUse` exiting 2 also denied, with the generic reason `hook exited with code 2`; its stderr was not shown.
- `agentStop` printing `{"decision":"block","reason":"..."}` queued the reason as a follow-up message and ran another turn, whose own stop carried `stop_hook_active: true`; exiting 2 with stderr only printed a warning line.
- An always-blocking `agentStop` produced 8 continuations and then let the turn end.
- Copilot waited synchronously for an `agentStop` hook: a 75 s sleep with `timeoutSec: 200` held the stop and its block decision was honoured, and a `.claude/settings.json` Stop hook marked `asyncRewake` was awaited the same way.
- `sessionStart` printing `{"additionalContext":"..."}` put that text in front of the model before its first reply.
- Copilot also loads a trusted project's `.claude/settings.json` hooks and delivers Claude-shaped payloads (`tool_name` `Bash`, `tool_input.command`, `hook_event_name`) with `CLAUDE_PROJECT_DIR`, `COPILOT_CLI`, and `COPILOT_PROJECT_DIR` set for the hook.

## Claude-shaped payloads

On 2026-11-08, Copilot 1.0.105 in a `-p` run with a relocated `COPILOT_HOME` that trusted only a scratch project ran a recording hook from that project's `.claude/settings.json` for `SessionStart`, `PreToolUse`, `UserPromptSubmit`, and `Stop`.
Claude Code 2.x in a `claude -p` run with the same recording hooks gave the Claude side of the comparison.
Copilot payload keys, per event (all four carry `hook_event_name`, `session_id`, `timestamp`, and `cwd`):

```text
SessionStart      source, initial_prompt
PreToolUse        tool_name, tool_input
UserPromptSubmit  prompt
Stop              transcript_path, stop_reason, stop_hook_active
```

Claude payload keys on the same events:

```text
SessionStart      session_id, transcript_path, cwd, hook_event_name, source
PreToolUse        session_id, transcript_path, cwd, prompt_id, permission_mode, effort, hook_event_name, tool_name, tool_input, tool_use_id
UserPromptSubmit  session_id, transcript_path, cwd, prompt_id, permission_mode, hook_event_name, prompt
Stop              session_id, transcript_path, cwd, prompt_id, permission_mode, effort, hook_event_name, stop_hook_active, last_assistant_message, background_tasks, session_crons
```

- `timestamp` (ISO-8601 with a `Z` suffix, such as `2026-01-01T00:00:00.000Z`) is present on every Copilot payload and absent from every Claude payload above, so it separates the two for all four events.
- `stop_reason` is not a usable signal alone because it is present only on `Stop`.
- `bin/fm-hook-host-lib.sh` requires the `timestamp` string and the absence of `permission_mode`, `prompt_id`, and `tool_use_id`, none of which Copilot sends, so a Claude release that adds `timestamp` does not stand Claude down.
- The same predicate also returns true when `COPILOT_HOOK_DEPTH` is a positive integer (set for hooks from 1.0.106, absent from tool shells) or the hook's parent process is `copilot`, so a changed or missing `timestamp` cannot re-enable the Claude auto-arm Stop hook, which Copilot would wait on for its declared 28800 s `timeout`.
- The shared checks stand down on that predicate, so `bin/fm-pretool-copilot.sh` and `bin/fm-turnend-guard-copilot.sh` run them with `COPILOT_HOOK_DEPTH` removed from their environment; with the variable left in, the checks denied nothing on a Copilot primary (1.0.106 and later).
- `tests/fm-copilot-primary.test.sh` sets `COPILOT_HOOK_DEPTH=1` in every registered-command run, and its denial and block assertions fail without that removal.
- Live check, 2026-11-17, copilot 1.0.113 (outside the verified range, which only adds a launch warning) in a `-p` run: a scratch clone of the branch as a plain primary checkout, a lab `FM_HOME` from `bin/fm-lab-home.sh`, a relocated `COPILOT_HOME` holding only the login and trusting only the clone, `--allow-all`, model `claude-haiku-4.5`.
  Command: `env -i HOME="$HOME" PATH="$PATH" FM_HOME=<lab> COPILOT_HOME=<task home> copilot -p "Run exactly this shell command with your bash tool and report its output or any error verbatim: cd projects/foo && pwd" --allow-all --model claude-haiku-4.5 --no-auto-update`, run from the clone.
  Output: `✗ Shell  Denied by preToolUse hook: [persistent-cd] a persistent top-level directory change in the primary firstmate checkout is blocked; it would move the shell out of the home so a later firstmate-owned command runs inside a project clone. Reach the target without moving the shell - use git -C <dir> or an absolute path on the command itself - or scope the cd to a subshell like (cd <dir> && ...).`
  The model then ran the subshell form `(cd projects/foo && pwd)`, which passed.
- A payload that is not an object, has no `timestamp`, or cannot be parsed runs the entry.
- `bash tests/fm-copilot-claude-standdown.test.sh` pins the sanitized shapes against each affected entrypoint.

## Native primary hooks

On 2026-11-08, Copilot 1.0.105 ran in real tmux 3.7c panes and `-p` runs with a relocated `COPILOT_HOME` that trusted only a scratch project, to verify the tracked registration `.github/hooks/firstmate-primary.json`.
The registration holds one `sessionStart` entry running `bin/fm-sessionstart-copilot.sh` and one `preToolUse` entry running `bin/fm-pretool-copilot.sh`, both anchored through `$COPILOT_PROJECT_DIR`.

### Hook sources and environment

- A project hook file in `.github/hooks/*.json` loaded once the folder was trusted, with `{"version":1,"hooks":{"<event>":[{"type":"command","bash":"...","timeoutSec":N}]}}`.
- Run with the shell in a subdirectory of the project, the hook still ran with its working directory and `COPILOT_PROJECT_DIR` both set to the project root.
- A worker's trusted worktree loads the same project hooks, so a launch built like `fm-spawn.sh`'s (per-task `COPILOT_HOME`, `--plugin-dir` worker plugin, linked worktree carrying the registration) invoked both adapters; they stood down by primary scope, the digest was absent from the model's context, `cd projects/foo` ran, and the `task` tool ran a subagent.
- That worker launch reproduced `fm-spawn.sh`'s launch template and `bin/fm-copilot-plugin.sh` by hand in a scratch directory; it was not started by `fm-spawn.sh` itself.
- The plugin `bin/fm-copilot-plugin.sh` writes registers only `userPromptSubmitted`, `agentStop`, and `sessionEnd`, so a worker plugin never carries either primary hook.
- A project registration is therefore the only tracked channel that reaches a hand-opened session in a checkout, and it also reaches a worker on a Firstmate worktree, which is why both adapters stand down outside a primary home.

### sessionStart

- The native payload is `sessionId`, `timestamp` (epoch milliseconds, an integer), `cwd`, `source`, and `initialPrompt`.
- The hook fires when the first prompt is submitted, not when the pane opens.
- `source` was `new` for a fresh launch, `new` again after `/clear`, and `resume` (with the earlier session's id) for `copilot --continue`.
- `/clear` first fires `sessionEnd` with `reason: user_exit` for the old session, then a `sessionStart` with a new session id at the next prompt.
- The SDK type also lists `startup`; no real run sent it.
- `copilot --resume <id>` sent `source: resume` with the same session id (see "Resume" under the primary run below).
- `/compact` fired `preCompact` (`trigger: manual`, `customInstructions`, `transcriptPath`) and no `sessionStart` afterwards.
- `preCompact` output never reaches the model, so compaction is delivered through the two-step transport in [Compaction re-emit](#compaction-re-emit).
- In a hand-opened session in a scratch primary checkout, a 12790-character digest returned as `additionalContext` reached the model: it quoted the digest's first and last lines.
- Subagent sessions raised no `sessionStart`.

### preToolUse

- A `preToolUse` for the subagent tool carries `toolName` `task` and `toolArgs` of `description`, `prompt`, `agent_type`, `name`, and `mode`, and precedes the `subagentStart` hook.
- That is the subagent-spawn point, so the subagent guard needs no separate native hook.
- The hook configuration schema in the SDK types has no matcher field, and a matcher was not tried, so `bin/fm-pretool-copilot.sh` receives every tool call and filters on its own.
- A subagent's own tool calls raise `preToolUse` too, with `agentId`, `agentType`, and `parentAgentId` in the payload.
- The model's tool names in one session were `bash`, `read_bash`, `stop_bash`, `list_bash`, `view`, `web_fetch`, `skill`, `sql`, `read_agent`, `list_agents`, `write_agent`, `rg`, `glob`, `task`, `apply_patch`, `search_code_subagent`, `run_dynamic_workflow`, and `dynamic_workflows_manage`, plus the connected MCP server's `github-mcp-server-*` tools.
- With every GitHub MCP tool enabled, Copilot CLI 1.0.113 listed about 110 `github-mcp-server-*` tools, and the only one whose name carried one of the stems in use then is `get_copilot_task_status`, a status getter whose definition the CLI would not print, which is on the guard's observe-only list.
  The `withcopilot` and `assigncopilot` stems were added afterwards so tools that hand work to GitHub's Copilot coding agent are denied; `docs/subagent-guard.md` owns the stem list.
- The guard has no prefix exemption for these tools, so a tool added later with a stem in its name is denied until it is verified and listed.
- `search_code_subagent`, `run_dynamic_workflow`, `dynamic_workflows_manage`, and `write_agent` match the subagent guard's delegation stems and are denied in a primary; `read_agent` and `list_agents` are on its observe-only list.
- In a hand-opened session in a scratch primary checkout, `cd projects/foo` and the `task` tool were both denied through `{"permissionDecision":"deny","permissionDecisionReason":"..."}` with exit 0, and the pane showed `Denied by preToolUse hook:` followed by the full reason, which the model then quoted back exactly.

### Reusable guard

```bash
bash bin/fm-test-run.sh tests/fm-copilot-primary.test.sh
FM_COPILOT_PRIMARY_LIVE=1 bash bin/fm-test-run.sh tests/fm-copilot-primary-live-e2e.test.sh
```

The live guard needs a signed-in `copilot` and spends one small prompt.
The portable suite pins sanitized payloads, the registration's own command strings, the worker worktree stand-down, and the worker plugin's missing primary hooks, with no Copilot install.

## Parked hooks

On 2026-11-08, Copilot 1.0.105 in a real tmux 3.7c pane with a relocated `COPILOT_HOME` ran an `agentStop` hook that waited for an event file.
A prompt typed during the wait showed `[pending · ↑ recall]`, and `userPromptSubmitted` did not fire until the hook returned.
Double Escape did nothing, Ctrl-C left the status on `Cancelling`, and `/exit` queued until the hook returned.
The runtime ended a run after 8 consecutive `decision: block` results, and the ninth reason was dropped with only a log line.
The next typed prompt reset that count.
A hook that outran `timeoutSec` was sent SIGTERM and the turn ended idle.
The pane reads `Working` for the whole wait, so firstmate does not park a Copilot turn boundary.

## Typed wake

On 2026-11-08, Copilot 1.0.105 (model `claude-haiku-4.5`) ran in a real tmux 3.7c pane on a private socket, in a plain clone of this repository carrying the tracked registration, with a relocated `COPILOT_HOME` that trusted only that clone.
The first prompt asked the model to run `bin/fm-copilot-wake.sh start`, and scripted status lines drove a real `bin/fm-watch.sh`.

| Scenario | Observed |
| --- | --- |
| Idle pane, new status line | Queue row in 4 s, doorbell typed 2 s later, the model read the record and ran `bin/fm-wake-drain.sh` and its `--ack-through`, queue empty 5 s after the ring |
| `zzdraft words` left in the composer | No ring for 15 s with a row queued, draft unchanged, doorbell typed 2 s after the draft was cleared, then acknowledged |
| Running turn (`sleep 40`) | No ring for 12 s with a row queued and the turn busy, doorbell typed 2 s after `agentStop`, then acknowledged |
| Double Escape on a running turn | The record stayed `state=busy`, the footer no longer showed `Working`, and the doorbell was typed once the record passed the 25 s grace configured for the run, then acknowledged |
| Wake process and watcher stopped, then a prompt | `agentStop` returned one block, the reason arrived as a `FIRSTMATE_OP: v1 turn-end-guard:` message, the model ran `bin/fm-copilot-wake.sh start`, and the following stop carried `stop_hook_active: true` and ended the turn |
| `/exit` with the pane kept open by a shell | The wake process logged `stopped: the pane agent is gone` within 7 s |

- A busy pane draws `Working · <n> B esc esc interrupt` in its footer row, and an idle or interrupted pane does not.
- A process started from a model `bash` tool call in its own process group outlived the call and the turn.
- `$TMUX_PANE` reached that process, so `bin/fm-supervisor-target-lib.sh` named the session's own pane.
- A tmux pane's foreground list carried argv[0] `copilot` during turns and shell tools, so a list without it means the agent exited.
- A plain clone's `bin/fm-lock.sh` recorded the Copilot pid in `state/.lock` once `copilot` joined the session-lock vocabulary; without it the digest reported a read-only session.
- A real session-start digest printed `primary harness: copilot`, `Lock: held by this session`, and the `Mode: GitHub Copilot CLI typed wake` protocol, after `bin/fm-sessionstart-copilot.sh` named the harness; without that the digest's process chain passed the eight levels `bin/fm-harness.sh` climbs and it reported `unknown`.
- The doorbell is the ASCII record-backed form from `bin/fm-operational-input.sh`, so whether Copilot keeps U+2063 in a typed prompt was not measured.
- The keystroke window between the composer check and the typed line is recorded in "Keystroke window" below.
- The wake on a Herdr pane is recorded in the next section.

```bash
bash bin/fm-test-run.sh tests/fm-copilot-wake.test.sh tests/fm-copilot-primary.test.sh
```

The portable suites pin the wait, re-ring, draft, picker, swallowed-Enter, interrupted-turn, and stand-down paths with a real tmux pane and no Copilot install.

## Typed wake on a Herdr pane

On 2026-11-09, Copilot 1.0.105 (model `claude-haiku-4.5`) ran in a real pane of Herdr 0.9.5, in a named lab session driven only through the guarded lab helper, in a plain clone of this repository with a relocated `COPILOT_HOME` that trusted only that clone.
The first prompt asked the model to run `bin/fm-copilot-wake.sh start`, and scripted status lines drove a real `bin/fm-watch.sh`.
The wake used the same grace settings as the tmux run (2 s poll, 8 s first re-ring, 25 s interrupted-turn grace).

| Scenario | Observed |
| --- | --- |
| Idle pane, new status line | Doorbell typed with verdict `empty` 5 s after the status line, the model drained and acknowledged, queue empty 13 s after the ring |
| `zzdraft words` left in the composer | No ring for 20 s with a row queued, draft unchanged, doorbell typed 3 s after `Ctrl+U` cleared it, then acknowledged |
| Running turn (`sleep 40`) | No ring for 14 s with a row queued and the turn busy, doorbell typed 1 s after `agentStop`, then acknowledged |
| `/exit` with the pane kept open by its shell | The wake process logged `stopped: the pane agent is gone` 6 s later and exited |

- A Herdr pane exports `HERDR_ENV`, `HERDR_PANE_ID` and `HERDR_SESSION` to a process started from a model `bash` tool call, so `bin/fm-supervisor-target-lib.sh` named `<lab session>:<pane id>` and not the default session.
- `herdr pane process-info` listed the Copilot process in the pane's foreground with argv[0] `copilot` and kernel name `MainThread` while idle and during a shell tool, so a foreground list without `copilot` means the agent exited. The sanitized body is `tests/captures/copilot-1.0.105-herdr/process-info.json`.
- The doorbell went through the ordinary typed-input path (`pane send-text`, then Enter) and the composer read stayed `empty` before each ring, `pending` with the draft, and `empty` after.
- Herdr's own agent state is not read by the wake; the busy record and composer verdict decide, as on tmux.
- The Herdr keystroke window is recorded in "Keystroke window" below.
- Interrupted-turn grace (double Escape) was not re-run on Herdr; its logic is backend-independent and pinned on tmux.

```bash
bash bin/fm-test-run.sh tests/fm-copilot-wake-herdr.test.sh
```

That suite runs a stand-in Copilot pane in a throwaway named Herdr session and pins start, deferral, re-ring, the draft, a picker, stand-down, and a refused missing pane.

## Teardown of a live worker

On 2026-11-06, in a scratch Firstmate home on a private tmux socket with a local-origin project, a Copilot scout was spawned with the per-task home, replied through a steer, and was torn down with `fm-teardown.sh` while its agent was still running.
Teardown first refused until the scout's captain-call inventory was recorded, which is the ordinary scout gate.
It then reaped the two worktree processes (the agent and its launcher), returned the worktree to the pool, and closed the window.
A listing of the lab home before and after showed that only these records changed: the task's `busy-gen`, `busy-state`, `copilot-home` (with its sessions, logs, and `config.json`), `copilot-plugin`, `git-hooks`, `meta`, and `turn-ended` were removed, and the home's `terminal-outcomes` record was added.
The task's `data/` directory, the project clone, and the other tmux window were untouched, no worker process survived, and no file under the user's real `~/.copilot` was modified.
A second scout was exited, relaunched with `fm-control relaunch --note`, and found with its per-task home preserved (a marker file inside it survived), the worktree still listed under `trustedFolders`, and no trust dialog; it was then torn down the same way.

## Herdr relaunch and teardown

On 2026-11-07, in a named isolated Herdr lab session (guarded helper for every lifecycle action, default session untouched and still running afterwards) and a scratch Firstmate home with a local-origin project, a Copilot scout was spawned with `fm-spawn.sh --scout --harness copilot --backend herdr`.
- **Launch:** no trust dialog appeared, the worker answered, wrote its report, and appended `done`; the busy record went from `busy fm-spawn` to `busy copilot-hook` and closed at `agentStop` with the turn-end notification raised once.
- **Exit and relaunch:** `fm-control exit` returned `stopped` and the pane fell back to its shell with `Resume copilot --resume=<session-id>`.
  `fm-control relaunch --note` started a replacement agent in the same pane and worktree under a new busy generation, which picked up the note, answered, appended `done`, and closed its record at `agentStop`.
- **Per-task home:** a marker file placed in the task's Copilot home before the exit survived the relaunch, `trustedFolders` still listed exactly the worktree, and the pane showed no trust dialog.
- **Teardown:** `fm-teardown.sh` on the live agent returned the worktree, closed the pane, and left no `copilot` process.
  A before and after listing of the lab home to two levels showed only the task's own records removed (`busy-gen`, `busy-state`, `control-relaunch` with its `brief-prior`, `meta-prior` and `note` records, `copilot-home`, `copilot-plugin`, `git-hooks`, `meta`, `status`, `turn-ended`) and `terminal-outcomes` plus the watcher-stale banner marker added; the project clone, `data/`, and the rest of the home were unchanged, and no file under the user's real `~/.copilot` changed.
- The lab helper's teardown stopped and deleted the lab session, and the default session was still running.

## Copilot as this home's primary

On 2026-11-11, Copilot 1.0.109 (model `claude-haiku-4.5`, `--allow-all`) was opened by hand as the primary in a scratch clone of this repository outside the firstmate home, with a lab `FM_HOME` from `bin/fm-lab-home.sh` and a relocated `COPILOT_HOME` whose `trustedFolders` named only that clone.
It ran once on tmux 3.7c (private socket) and once on Herdr 0.9.5 (named lab session through `bin/fm-herdr-lab.sh`; the default session stayed running).

| Step | tmux | Herdr |
| --- | --- | --- |
| Session-start digest | `primary harness: copilot` and `Lock: held by this session` in the `sessionStart` `additionalContext`; the model quoted both | the same two lines; the wake process targeted `<lab session>:w1:p1` |
| Pre-tool guards | `cd projects` denied by `persistent-cd`; the `task` tool denied by `subagent-dispatch` | the same two denials |
| Turn-end guard | with a task record, no watcher, and a trivial prompt: one `turn-end-guard` block, the model reran `bin/fm-copilot-wake.sh start`, the next stop ended the turn | the same |
| Typed wake from a real status line | status line at +0 s, queue row at +46 s (the watcher's own poll), doorbell typed (`verdict=empty`) at +47 s, queue empty after the model's `--ack-through` | queue row at +32 s, doorbell typed at +34 s, queue empty by +75 s |
| Double Escape on a running `sleep` | `Operation cancelled by user`; the turn record stayed `busy`; a status line queued afterwards rang once the record was 120 s old (`FM_COPILOT_WAKE_INTERRUPT_GRACE` default) | `Operation cancelled by user`; the record stayed `busy`; the clean rerun with nothing in the background is below |
| `/compact` | `session.compaction_complete`, no new `sessionStart`; asked, the model held no digest | the same |
| `/exit` | the wake process logged `stopped: the pane agent is gone` and no firstmate process survived | the same; the pane returned to its shell with `Resume copilot --resume=<id>` |

- An unacknowledged row was typed again after the 60 s re-ring grace on Herdr (rows at 11:59:58Z and 12:00:58Z), and the doorbell was never typed into a draft or a running turn.
- After `/compact` the digest is gone.
  Asked what its project instructions say to do at session start, the model on tmux reran `bin/fm-session-start.sh`, but unprompted none of 4 scout trials did, so `bin/fm-copilot-compact.sh` re-emits it ([Compaction re-emit](#compaction-re-emit)).
- Copilot 1.0.109 draws `Working · <n> B ctrl+c interrupt` while a turn runs.
  The wake read it correctly: no doorbell was typed into a running turn.
- A hand-opened primary needs its own multiplexer's variables only: with the parent's Herdr variables inherited, `fm-copilot-wake.sh start` resolved a pane of the default Herdr session and stood down within 8 s, typing nothing.
  The run used a scrubbed environment and a real `tmux` binary first on `PATH`.

### Away mode on a Copilot primary

The supervision host has no Copilot arm owner (a parked `agentStop` leaves the pane deaf, see Parked hooks), and the typed-wake process stands down once `state/.afk` exists, so `/afk` and `/quiet` use the away daemon, as they do for every primary the host does not run on.
On tmux the model ran `bin/fm-afk-launch.sh enter` and `start`; the daemon launched in a detached tmux session supervising the pane.
A `needs-decision` status line was escalated 1 s after the watcher signal, and a `FIRSTMATE_OP: v1 away-supervisor` prompt was typed into the pane and reached `userPromptSubmitted` with the U+2063 marker intact (bytes `e2 81 a3`), so Copilot keeps the invisible envelope and the daemon needs no record-backed doorbell.
`bin/fm-afk-launch.sh stop` cleared the record and the daemon.
On a Herdr pane the daemon's generic composer read classified the captured idle Copilot screen as `unknown` (the tmux capture read `empty`), which would have deferred every injection.
The daemon now reads its supervisor pane's composer as Copilot when the primary is Copilot, and the same capture reads `empty`.
On a Herdr pane (Copilot 1.0.109, Herdr 0.9.5, named lab session) the full daemon run worked.
`bin/fm-afk-launch.sh enter --words ...` and `start` launched the daemon in a second workspace of the lab session, supervising the primary's pane.
A `needs-decision` status line was signalled by the watcher 40 s after it was written (the watcher's poll), the daemon logged `escalate` 4 s later, and the `FIRSTMATE_OP: v1 away-supervisor` prompt reached the model about 90 s after that (the daemon's 90 s escalation batch window), with the U+2063 marker intact (bytes `e2 81 a3` at the start of the `user.message`) and no other text typed into the composer.
`bin/fm-afk-launch.sh stop` cleared the record, archived the contract and closed the daemon workspace; it printed `terminal close command failed, but exact absence was confirmed`, and the lab session held only the primary's workspace afterwards.

### Interrupted turn on Herdr

With nothing running in the background, a foreground `sleep 280` was started at 13:37:22Z.
A double Escape sent as one `herdr pane send-keys <pane> esc esc` printed `Operation cancelled by user` at 13:38:22Z; two separate `send-keys esc` calls a second apart cancelled nothing.
A `needs-decision` status line written at 13:38:03Z queued a row at 13:38:42Z (the watcher's poll).
The wake process logged `ring: typed the doorbell (verdict=empty, head=3)` at 13:39:25Z, which is 122 s after the turn began and 63 s after the cancel, matching `FM_COPILOT_WAKE_INTERRUPT_GRACE` (120 s) counted from the busy record.
The typed doorbell started a turn (`userPromptSubmitted` at 13:39:24.9Z) and the model drained the queue.
No ring was typed between the cancel and the grace expiry.

### Resume

`copilot --resume=<id>` (printed by `/exit` as `Resume copilot --resume=<id>`) was run in the same pane after `/exit` on Herdr and on tmux 3.7c, with the primary run's lab home.
The wake process had logged `stopped: the pane agent is gone` and the lock file named a dead pid.
The `sessionStart` payload was `{"source":"resume","initialPrompt":...,"sessionId":<the earlier id>,...}`, and it fired at the first prompt after the resume, not when the pane opened.
`bin/fm-sessionstart-copilot.sh` takes the helm with the full digest on `resume`; the run wrapper's nudge for `resume` is only a one-line instruction, which a resumed model can ignore in favour of its restored conversation.
On both backends the `sessionStart` output was the whole digest (11117 characters on Herdr) with `lock acquired: harness pid <the new copilot pid>` and `Lock: held by this session`, and `bin/fm-copilot-wake.sh start` (run when the model was asked to) logged a new `started: target=<pane>` with a fresh watcher.
The resumed model's replies kept the earlier conversation, so a resumed primary has both the old context and the new digest.

## Second Firstmate home in the default Herdr session

On 2026-11-16, Copilot CLI 1.0.109 (model `gpt-6-luna`, effort medium) ran as the primary of a second Firstmate home inside the default Herdr 0.9.5 session on Linux.
The second home was a plain clone with no remote and one local-only scratch project, with `config/backend` set to `herdr` and Claude as the default worker.

- Isolation: the second home's lock named its own Copilot pid, different from the other home's Claude pid, and the other home's backlog, project list and state counts were identical before, during and after.
- Launch: `bin/fm-copilot-primary.sh --allow-all` in a Herdr pane started Copilot with the folder-trust dialog answered once.
  The `sessionStart` hook returned a digest of 29538 bytes, then 32634 bytes after the resume, and no hook failed (243 `hook.start`, 243 `hook.end`).
- Workers: a Claude scout and a Copilot scout (`harness=copilot` in its record) were dispatched from the primary and both reported.
  In both cases the wake process typed the doorbell into the idle composer and the primary drained and acknowledged by itself.
- Wake restart: killing the wake process while the pane was idle logged `restarting: the wake process was gone while the pane was idle` and a new process attached.
  Killing it again and then typing a prompt logged `restarting: the wake process was gone at a prompt`.
- Cancel: Esc, Esc during a 150 second shell command showed `Operation cancelled by user` and left 1 `abort` event in the session's `events.jsonl`.
  A doorbell rang afterwards and the primary handled the queued note.
- Exit and resume: `/exit` logged `stopped: the pane agent is gone` and the lock read stale.
  `--resume=<id>` through the launcher took a new lock pid and logged a new `started: target=` line, the primary restarted the wake when asked, and a queued note rang and was acknowledged.
- Teardown: both scouts torn down through the primary left no task records.
- A shell in the default Herdr session exports `HERDR_ENV` and `HERDR_PANE_ID` but no `HERDR_SESSION`.
- The `lock acquired` and `Lock: held by this session` digest lines were not visible on the Copilot screen, because the primary answered in plain outcome words, so the lock pid was the proof.

## Copilot 1.0.109 output reads

On 2026-11-11, Copilot 1.0.109 (model `claude-haiku-4.5`, `--allow-all`) ran in a real tmux 3.7c pane (150 columns, private socket) with a relocated `COPILOT_HOME` that trusted only a scratch directory, to check the output firstmate scrapes against the 1.0.105 evidence above.
The pane tails are pinned in `tests/captures/copilot-1.0.109-tmux` and asserted by `tests/fm-copilot-harness.test.sh`.

| Read | 1.0.105 | 1.0.109 | Matching |
| --- | --- | --- | --- |
| Busy footer | `Working esc esc interrupt` | `Working · <n> B ctrl+c interrupt` | `FM_DELIVERY_COPILOT_BUSY_REGEX_DEFAULT` carries both alternatives, so no change |
| Footer after one Escape on a running turn | `esc again to interrupt` | `Working · <n> B esc again to interrupt` | `again to interrupt` (`fm_control_interrupt_arm_signal`), so no change |
| Footer after the second Escape | `Operation cancelled by user` | `Operation cancelled by user`, the tool row `Operation aborted by user`, composer a bare `❯` | nothing in `bin/` matches this line |
| Idle composer, empty and with a draft | `❯` between `─` rules, `❯ text` | the same shapes | no change |
| Idle double Escape | `Rewind to a previous point` picker | the same picker with `↑↓ Navigate · Enter Select · Esc Cancel`, read `unknown` | no change |
| `/exit` | usage summary and `Resume copilot --resume=<id>` after a session with turns | the pane returned to its shell; a session with no turn printed no Resume line | nothing in `bin/` matches the Resume line |

- The first-Escape footer was captured 0.1 s after the key, the same gap as `fm_control_interrupt_press_gap`.
- Only the 1.0.109 busy and armed footers differ from 1.0.105 in anything matched; both versions are pinned by tests.
- `fm-spawn.sh` prints `warning: copilot version <v> is outside the verified range 1.0.105-1.0.109` to stderr for any other `copilot --version` and still launches (`fm_copilot_version_verified` in `bin/fm-busy-lib.sh`), following the Pi stream-version warning.
  A primary opened by hand gets the same warning from `bin/fm-sessionstart-copilot.sh` with the same bound.

On the same date the Copilot, daemon, harness-precedence, afk-launch and secondmate-liveness suites passed under `bin/fm-test-run.sh` with the tmux binary first on `PATH`; `tests/fm-copilot-signals-live-e2e.test.sh` capability-skipped without its opt-in.

## Keystroke window

Copilot CLI 1.0.109, tmux 3.7c, Herdr 0.9.5, 2026-11-11, `bin/fm-copilot-wake.sh` `ring_once`.
Terminal input has no compare-and-type, so a key typed between the composer read and the doorbell is submitted to the model together with it.
- Before the narrowing the window was the typed doorbell's 0.5 s settle plus a second composer read and a busy-baseline read: about 0.65 to 0.8 s on both backends.
  A key injected inside it was submitted merged with the doorbell on 7 of 7 trials.
- Copilot swallows the Enter of an unbracketed fast burst, so one `send-keys -l ... Enter` call leaves the doorbell unsent.
  A bracketed paste followed by Enter in one tmux command list is submitted (5 of 5).
  Herdr's `pane run` submits an unbracketed line (2 of 2).
- Now the ring reads the cursor before the composer read on tmux and re-tests it inside the tmux server in the same command list as the paste and the Enter (`fm_backend_tmux_paste_submit_if_cursor`).
  On Herdr it re-reads the composer immediately before one `pane run`.
  A key that lands before the guard makes the ring refuse and leaves the draft alone; the portable tests inject one and assert that.
- Measured remaining window: about 5 to 10 ms on tmux and 10 to 30 ms on Herdr (scout sweeps with 2 to 5 trials per cell; keys injected at +0 ms merged in 1 of 2 tmux trials, keys from +2 ms on landed after the Enter as a new draft).
- Live re-check after the change, on a private tmux socket and a lab Herdr session with Copilot 1.0.109 trusting only a scratch clone: an idle pane received the doorbell and started a turn on both backends, and a pane holding the draft `half written` was left untouched with no doorbell typed.
  The tmux guard call took 11 to 12 ms; on Herdr the whole guard (readiness check, re-read, `pane run`) took 59 ms through the lab helper, of which only the gap between the re-read and the `pane run` is exposed.
- The limit that remains is Copilot's own echo time (22 to 35 ms on tmux): a key already written to the pane but not yet drawn cannot be seen by any screen or cursor read, so it can still merge with the doorbell.
  The merged line is submitted as one prompt, the wake queue still holds the row, and the user's text reaches the model early.
- Not built on purpose: removing only the typed doorbell from the composer after a merge takes about 2 s and races with further typing.
- If Copilot stops enabling bracketed paste, the Enter is swallowed and the doorbell stays unsent; the existing pending path then sends Enter only.

## Compaction re-emit

`bin/fm-copilot-compact.sh` (`mark` on `preCompact`, `deliver` on `userPromptSubmitted` and `postToolUse`) restores the digest after a compaction ([owner](../sessionstart-nudge.md#copilot-compaction)).
Measured on copilot 1.0.109 on tmux:

- `preCompact` output is discarded: six canary fields printed at once (`additionalContext`, `systemMessage`, `message`, `reason`, `hookSpecificOutput.additionalContext`, `customInstructions`) reached neither the summarizer nor the model, and the CLI's event log records no `output` for that hook.
- `additionalContext` from `userPromptSubmitted` and from `postToolUse` reaches the model as a `<system_reminder>` appended to the prompt or tool result, and stays in history until the next compaction.
- `preCompact` fires for manual (`trigger: manual`) and automatic (`trigger: auto`) compaction and carries `sessionId`; both delivery events carry the same `sessionId`.
- A re-emit of about 8 KB was delivered; 200 KB was delivered intact; the hook layer drops an aggregate between 4 MiB and 16 MiB, far above the digest.
- With two `userPromptSubmitted` entries returning `additionalContext`, only the last non-empty one reaches the model, so the delivery entry is registered last.
- Unprompted after `/compact`, 0 of 4 scout trials reran session start; with the transport the model drained the right home and restarted supervision.

Portable regression: `tests/fm-copilot-primary.test.sh`.
Live check, 2026-11-11, copilot 1.0.109 on tmux (private socket, scratch clone of the branch, lab `FM_HOME`, relocated `COPILOT_HOME` trusting only the clone, scrubbed environment, Claude Haiku 4.5): a first prompt received the startup digest through `sessionStart`; `/compact` ran; the next prompt carried the re-emit once (`userPromptSubmitted` hook output of 8455 bytes, and the model quoted its first line, "This session already took the helm at its own startup and has only lost its context."); the prompt after that carried none (hook output 4 bytes, `transformedContent` without the re-emit).

## Combined branch run

On 2026-11-11 the primary support, Herdr resume and lab, 1.0.109 pins and version warning, keystroke narrowing, and compaction re-emit changes were run together with Copilot 1.0.109 and tmux 3.7c on Linux.

- `bin/fm-test-run.sh` passed every `tests/fm-copilot-*.test.sh` (`tests/fm-copilot-signals-live-e2e.test.sh` capability-skipped without its opt-in), `tests/fm-daemon.test.sh`, `tests/fm-harness-precedence.test.sh`, `tests/fm-afk-launch.test.sh`, `tests/fm-secondmate-liveness.test.sh` and `tests/fm-documentation-audiences.test.sh`; `bin/fm-lint.sh` passed with shellcheck 0.11.0 and actionlint 1.7.12.
- The tests need a real `tmux` binary first on `PATH`, because a version-manager shim of `tmux` makes the shim of `tests/fm-copilot-wake.test.sh` re-invoke itself.
- Live smoke on a private tmux socket, a scratch clone of the merged branch, a lab `FM_HOME`, a relocated `COPILOT_HOME` trusting only that clone, a scrubbed environment and Claude Haiku 4.5, opened by hand as the primary in one session:
  - the first prompt received the digest through `sessionStart` (11256 bytes); the model quoted `primary harness: copilot` and the lock line;
  - a status line was typed back as one doorbell, and the model drained and acknowledged the queue (`--ack-through`);
  - `/compact` completed; the next prompt carried one `userPromptSubmitted` output of 8681 bytes (the other three returned 4 bytes), and the model quoted the re-emit's first line;
  - `/exit` returned the pane to its shell with the `Resume copilot --resume=<id>` line, and the wake log recorded `stopped: the pane agent is gone`.
- Not exercised in the combined run: Herdr, which the sections above and the Herdr wake suite cover.

## Interrupt transcript, launch prompt and update restart

Live checks, 2026-11-11, copilot 1.0.109 on tmux (private socket, scratch clone, lab `FM_HOME`, relocated `COPILOT_HOME`, scrubbed environment, Claude Haiku 4.5):

- **Abort event:** no hook fired on a cancel, but the session transcript `<COPILOT_HOME>/session-state/<sessionId>/events.jsonl` gained `{"type":"abort","data":{"reason":"user_abort"}}` (Escape twice) or `"reason":"user_initiated"` (Ctrl-C) 4-123 ms after the key.
  Five cancels wrote five lines; none appeared for 12 finished turns, for a double Escape on an idle session, or for a Ctrl-C with nothing running.
  `bin/fm-copilot-wake.sh` rings on it (3.3 s after the cancel, against about 92 s at the 120 s grace), ignores an abort that a later `user.message` follows, and falls back to the grace when the file is unreadable.
  `bin/fm-control.sh` reads a new one in the task's own `COPILOT_HOME` as the cancel acknowledgement; the portable pins are `tests/fm-copilot-wake.test.sh` and `tests/fm-control.test.sh`.
  Not run: the `fm-control` change on a live Copilot task, an interrupt during a subagent or a permission prompt, and Herdr.
  On 2026-11-12 `FM_COPILOT_SIGNALS_LIVE=1 bash bin/fm-test-run.sh tests/fm-copilot-signals-live-e2e.test.sh` passed on copilot 1.0.109 (tmux 3.7c, Linux) in the default `~/.copilot`.
  It starts a long second turn, sends a double Escape through a private pty, and asserts the transcript gained a line starting with `{"type":"abort"`.
  The matcher is `fm_copilot_abort_count` in `bin/fm-busy-lib.sh`, shared by the wake and `fm-control`, and the guard fails with `copilot <version>` in its message when a release stops writing that event.
- **Launch prompt:** a plain launch fired no hook in 25 s; `-i '<prompt>'` fired `userPromptSubmitted` at +2.5 s and `sessionStart` (`source:new`) at +6.4 s with a 7902-character digest, and `--resume=<id> -i` fired `sessionStart` with `source:resume`.
  With an untrusted folder the `-i` prompt waited for the trust dialog and was submitted 0.29 s after `Yes`; `No` ended the session.
- **Update restart:** `bin/fm-update.sh` then `bin/fm-secondmate-restart.sh` relaunched a live Copilot secondmate fresh (no `--resume`) with one new digest and a new lock.
  The primary's running wake loop kept the pre-update script (it held the replaced file open), which is why the loop now re-executes itself.
  Copilot's `view` refused the 50.4 KB `AGENTS.md` in one call.
- **Natural compaction:** two automatic compactions (one in the background, one turn-blocking) each re-sent the digest once through `postToolUse`.

## Still not exercised

- A live host that keeps the Copilot token in `config.json` rather than the OS keyring (the copy is only pinned with fake values).
- A real attached client's typing, IME input, and a slash or `@` popup opening in the keystroke window; keys were injected through the multiplexer.
- An in-process `/resume` to another session, whose `source` was not recorded.
- Any Copilot version other than 1.0.105 and 1.0.109 (see "Copilot 1.0.109 output reads"), and a ship worker or secondmate run on 1.0.109 (a Copilot scout ran on 1.0.109 in the [second-home run](#second-firstmate-home-in-the-default-herdr-session)).
- macOS and native Windows, which no run has covered (every run was on Linux).
- Whether Copilot asked to sign in in the second-home run.

## Reusable guards

```bash
FM_COPILOT_SIGNALS_LIVE=1 bash bin/fm-test-run.sh tests/fm-copilot-signals-live-e2e.test.sh
FM_COPILOT_PRIMARY_LIVE=1 bash bin/fm-test-run.sh tests/fm-copilot-primary-live-e2e.test.sh
bash bin/fm-test-run.sh tests/fm-copilot-harness.test.sh
```

The live guard needs a signed-in `copilot`, `python3`, and `jq`, creates its own pty and temporary directory, and spends one small prompt.
An unavailable required tool is reported by the shared `fm_live_gate`; explicit opt-in refuses missing capabilities.
It launches in an untrusted temporary directory, asserts that a real prompt produces `busy copilot-hook`, then the idle transition and turn-end notification, and that `/exit` ends the process with status 0.
The primary guard needs a signed-in `copilot`, `jq`, `tar`, and `git`, and spends one small prompt.
It runs `copilot -p` in a scratch plain checkout of the working tree with a relocated `COPILOT_HOME` that trusts only that checkout, and asserts the `Denied by preToolUse hook: [persistent-cd]` text, which exercises session scope, the hook environment, and the deny object together.
Run it after every Copilot upgrade: a release that changed the hook environment once made the shared stand-down predicate skip every primary check without any portable test noticing.

## Process identity

A live interactive process reported `comm` `MainThread` (the thread name) and `/proc/<pid>/exe` `~/.local/bin/copilot`, with argv `copilot --no-auto-update`.
No `COPILOT_*` identity variable reached the process environment.
Only argv[0] therefore names the harness, and both the tool-side detector and the liveness classifier match its exact basename `copilot`.

## Hooks

A plugin directory passed with `--plugin-dir` (`plugin.json` plus `hooks/hooks.json`, `{"version":1,"hooks":{...}}` with `{"type":"command","bash":"...","timeoutSec":N}` entries) loaded in both `-p` and interactive runs, once the directory is trusted.
Events observed in an interactive run, in order, each receiving a JSON object on stdin that carries `sessionId`, `timestamp`, and `cwd`:

```text
userPromptSubmitted  {"prompt":"..."}
sessionStart         {"source":"new","initialPrompt":"..."}            (fires after the first prompt, not at launch)
preToolUse           {"toolName":"bash","toolArgs":{...}}
agentStop            {"transcriptPath":"...","stopReason":"end_turn","stop_hook_active":false}
sessionEnd           {"reason":"complete"}   (non-interactive)  /  {"reason":"user_exit"}   (interactive /exit)
```

`agentStop` did not fire when a double Escape cancelled a running shell tool, and `sessionEnd` fired only at exit, so an interrupted turn leaves the busy record open until the next prompt.
The turn-end notification is raised by the generation-bound apply, which the portable regression pins against a stale generation.

## Composer and lifecycle

Screens below are the plain rendering of the captured byte stream; the idle and working composers have the same shape.

```text
────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
 ← open sidebar · Interactive · Allow All · / commands · ? help      GPT-6 Luna · Medium · (18%)

 ○ Working · 90 B esc esc interrupt                                  GPT-6 Luna · Medium · (18%)
```

A typed draft rendered as `❯ half typed draft` between the same rules, and the idle footer became `Interactive · Allow All · @ files · # issues`.
Text typed while a turn ran was queued (`Queued (1)`).
The first Escape on a running tool rendered `esc again to interrupt`, the second printed `Operation cancelled by user`, and the composer returned to a bare `❯`.
On an idle agent with history the first Escape rendered `esc again to rewind` and the second opened `Rewind to a previous point` with `↑↓ Navigate · Enter Select · Esc Cancel`; with no history it printed `Nothing to rewind yet. Start a conversation first.`
`/exit` printed a usage summary and `Resume copilot --resume=<session-id>` and fired `sessionEnd` with `user_exit`.

## Launch

`copilot --allow-all --no-auto-update -i "<prompt>"` in a never-trusted temporary directory stopped at `Do you trust the files in this folder?` with the prompt unsent, so `--allow-all` alone is not enough.
With `COPILOT_ALLOW_ALL=true` in the environment the same launch showed no dialog, auto-submitted the prompt, and delivered the plugin's hooks (`busy copilot-hook` at 4.0 s, `idle copilot-hook` at 9.5 s).
The shipped launch uses a per-task `COPILOT_HOME` instead; see Folder trust options.
An earlier observation of "no dialog" came from a directory already in Copilot's trusted-folder list and is withdrawn.
`--model bogus-model` exited at launch with `Error: Model "bogus-model" from --model flag is not available.`
`--reasoning-effort xhigh` on `gpt-6-luna` and `--reasoning-effort max` on `claude-sonnet-5.5` were accepted.
No catalog listing command was found, so the spawn does not pre-validate the model.

## Secondmate

On 2026-11-10, Copilot CLI 1.0.105 ran as a persistent secondmate through `bin/fm-spawn.sh <id> <home> copilot --secondmate` in a scratch lab primary home, once on tmux 3.7c (private socket) and once on Herdr (a named `fm-lab-` session created and torn down by `bin/fm-herdr-lab.sh`).
Each lab home was marked with `bin/fm-lab-home.sh`, and each mate home was a `git clone` of this branch seeded by `bin/fm-home-seed.sh <id> <home> --no-projects`, so it carried `.github/hooks/firstmate-primary.json`.
The real `~/.copilot`, the real fleet, and every real Herdr workspace were untouched; the existing login was reused through the per-task `COPILOT_HOME`.
Both backends behaved the same on every step:

- **Launch:** the spawn recorded `kind=secondmate harness=copilot`, wrote `state/<id>.copilot-home` (trusting only the mate home) and `state/<id>.copilot-plugin` in the parent's state, and exported `FM_HOME=<mate home>` on the launch.
- **Digest:** the session's `events.jsonl` held a successful `sessionStart` hook whose `additionalContext` began `SESSION START - <mate home>`, reported `lock acquired`, and carried the Copilot typed-wake operating instructions; the digest ran inside the mate home, so `state/.session-start-complete` appeared there and not in the parent.
- **Seatbelts and guard:** `preToolUse` and `agentStop` hooks succeeded on every call and turn.
- **Busy state:** the per-task plugin's `userPromptSubmitted` and `agentStop` moved the parent's `state/<id>.busy-state` between `busy` and `idle` (source `copilot-hook`).
- **Steer:** `fm-send <id> <text>` wrote an inbox record and typed the doorbell; the mate moved the record to `handled/` and appended a `done [corr=...]` line to the parent's status, which `fm-crew-state` read as `done`.
- **Typed wake:** the mate ran `bin/fm-copilot-wake.sh start`; `bin/fm-inbox.sh note` into the mate home then produced `ring: typed the doorbell (verdict=empty, head=1)`, and the mate drained the queue and acknowledged it (queue empty).
- **Interrupt:** `fm-control interrupt` during a foreground `sleep 150` returned `interrupt-delivered ... verified=agent-alive cancel=unconfirmed` and the pane printed `Operation cancelled by user`.
- **Exit:** `fm-control exit` returned `stopped`, the pane printed `Resume copilot --resume=<session-id>`, and the wake process logged `stopped: the pane agent is gone`.
- **Relaunch:** `fm-control relaunch` started a new Copilot session in the same pane with its own `sessionStart` digest and a fresh `lock acquired`.

Not exercised: an `/updatefirstmate` style restart (`bin/fm-secondmate-restart.sh`) of a live Copilot mate, a treehouse-leased linked-worktree mate home (the lab homes were clones, and the shared cd guard stays inert in a linked-worktree home by its own scope), a mate with real crewmates of its own, a remote secondmate, and a live host whose Copilot token is not in the OS keyring.
`tests/fm-copilot-harness.test.sh`, `tests/fm-copilot-primary.test.sh`, and `tests/fm-secondmate-liveness.test.sh` pin the portable parts: the spawn launch shape and trust scope, the three adapters running in a marked secondmate home, the separate busy records, and the liveness sweep's relaunch of a dead Copilot mate.
