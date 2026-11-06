# Gemini CLI

Google's `gemini` TUI, verified end to end on 2026-09-04 with gemini-cli 0.58.0 on Linux.
Launch shape: `GEMINI_CLI_TRUST_WORKSPACE=true gemini -y "$(cat <brief>)"`.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no gemini wake protocol.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Semantic `gemini-hook`: `BeforeAgent` opens a turn, `AfterAgent` and `SessionEnd` close it. `AfterAgent` also fires on a manual interrupt, so a cancelled turn closes its own record. |
| Rendered tail | Not a state source, but the running turn's status row is the one ASCII busy token: `(esc to cancel, <n>s)`, absent when idle. The phase text beside it is model-generated and varies per turn, and the spinner is braille; neither is ever a signal. |
| Turn end | `AfterAgent` fires once per turn after the final response, carrying `cwd`, `session_id`, `prompt`, `prompt_response`, `stop_hook_active`, and `transcript_path`. On a cancelled turn `prompt_response` is `[no response text]`. |
| Exit | `/quit` (alias `/exit`), one Enter, exit status 0; prints `To resume this session: gemini --resume <session-id>`. `Ctrl+C` cancels or quits on empty input and `Ctrl+D` exits on an empty buffer. |
| Interrupt | Single `Escape`, which prints `ℹ Request cancelled.` and leaves the agent running. The composer does not repollute; it returns to its `Type your message or @path/to/file` placeholder. |
| Skill | `/<skill>`, for example `/no-mistakes`; ONE Enter submits, with no popup swallow, and the turn opens with an `Activate Skill` tool call. |
| Autonomy | `-y` / `--yolo`, footer ` YOLO Ctrl+Y`, verified unattended on a real file write with no approval gate; `--approval-mode yolo` is the equivalent long form. |
| Marker | `GEMINI_CLI=1` on child and tool processes. `AI_AGENT` is NOT a Gemini identity - see Detection below. |
| Resume | `gemini --resume <session-id>` restores full history; `--resume latest` and an index are also accepted, and `--list-sessions` enumerates them per project. |
| Model | `-m` / `--model <model>`; discover through the interactive `/model` dialog. There is no `gemini models` subcommand, and the session's exit usage table also names the models actually used. |
| Effort | None. `gemini --help` on 0.58.0 exposes no effort, reasoning, or thinking flag, so `references/common/model-and-effort.md`'s record-and-omit contract applies. `thinkingLevel` and `thinkingBudget` exist only as generation settings inside `settings.json` and are NOT a verified interactive axis. |

## Trust, and why the two documented options are not equivalent

Every task worktree is a path Gemini has never seen, so an unhandled launch refuses outright:
`Gemini CLI is not running in a trusted directory. To proceed, either use --skip-trust, set the GEMINI_CLI_TRUST_WORKSPACE=true environment variable, or trust this directory in interactive mode.`
Headless, that refusal exits 55.

The CLI presents those two options as equivalents and they are not.
A controlled A/B on one worktree - same config home, same prompt, only the trust mechanism changed - showed `--skip-trust` runs the turn while leaving PROJECT configuration unloaded, so the project's own hooks never fire and its `.agents/skills` are never discovered, while `GEMINI_CLI_TRUST_WORKSPACE=true` loads both.
A firstmate-repo task needs exactly those workspace skills, so the spawn uses the environment variable and `--skip-trust` must not be substituted for it.
Firstmate's OWN busy hooks do not depend on this, because they ride the system settings layer described below.
Trusting the workspace loads that project's `.gemini/settings.json`, hooks, MCP servers, and skills, which is the same posture the other adapters already run under in a task worktree.

The interactive trust dialog is `Do you trust the files in this folder?` with three choices.
Unlike Claude's, its default selection is the SAFE one: `● 1. Trust folder (<name>)`, with `2. Trust parent folder (<parent>)` and `3. Don't trust` unselected.
Accepting persists to `~/.gemini/trustedFolders.json`, so the spawn's environment variable is preferred: it is per-session and leaves no growing global record of disposable worktree paths.

## Credential precondition, and the wedge it causes

A Gemini worker needs a credential it can use without a dialog, and firstmate does not manage one.
Export `GEMINI_API_KEY` into the environment BEFORE the session-provider daemon starts, or complete `gemini`'s own sign-in.
The daemon matters: a long-lived tmux or Herdr server hands panes the environment it was started with, so a key exported after that server came up never reaches a worker.
The headless probe `gemini --skip-trust -p '<prompt>'` exits 41 with `you must specify the GEMINI_API_KEY environment variable` when no credential is resolvable, which is the cheapest pre-dispatch confirmation.
A first run also shows an auth-method picker (`How would you like to authenticate for this project?`, default `● 2. Use Gemini API Key`); answering it once writes `security.auth.selectedType` to the user `settings.json` and it does not return.

With no credential the pane wedges on an `Enter Gemini API Key` dialog, and that dialog is dangerous in two distinct ways.
It RENDERS THE KEY IN PLAINTEXT in the pane once a value is present, where any capture or debug log would retain it, and the launch brief fails behind it with `API Error: Content generator not initialized`.
Worse, it is a credential field that accepts whatever is typed next: sending the ordinary exit command to a wedged pane submits `/quit` INTO it and persists it as a stored credential in `~/.gemini/gemini-credentials.json`.
That poisons the machine for every later run - a credential-less run then stops failing cleanly with exit 41 and instead reaches the API and fails per request with `API key not valid` - and it is repairable only by clearing that stored credential.
So never drive lifecycle text into a gemini pane that is showing this dialog.
Treat it as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

Do NOT give a worker an isolated `GEMINI_CLI_HOME`.
It hides `~/.agents/skills`, so `/no-mistakes` and every other user skill silently disappear from that worker.

## Detection

`GEMINI_CLI=1` is load-bearing rather than a fast path, so `../../../../../bin/fm-harness.sh` checks it BEFORE `CLAUDECODE`.
Gemini does not clear an inherited `CLAUDECODE`, so a gemini worker under a claude primary carries both markers and whichever is tested first wins; the spawn additionally clears the foreign markers at the launch boundary.

Ancestry cannot cover the gap.
The shipped CLI is a node bundle (`~/.local/bin/gemini` -> `@google/gemini-cli/bundle/gemini.js`) and modern Node on Linux reports `comm` as `MainThread` rather than `node` (measured on Node v24.20.0), so neither the command-name arm nor the interpreter arm matches a live gemini process.
Do not close that by matching `MainThread`: it would make every node process's arguments searchable and let an unrelated command claim an identity.
`../../../../../tests/fm-gemini-harness.test.sh` pins both the marker precedence and this ancestry boundary.

`AI_AGENT` must never be promoted to a marker.
The same verified tool process carried the CLAUDE primary's value (`claude-code_2-1-260_agent`), so it identifies the launcher, not the running harness.

Pane liveness has the same problem and needs its own answer, because the marker is not visible to a process scan.
A live gemini pane's foreground group reads `comm=MainThread` and `argv0=<node path>`, so neither of `bin/backends/tmux.sh`'s existing name sources can see it, and `bin/fm-control.sh` refused every lifecycle verb with `endpoint reads 'ambiguous'` until this was closed.
`../../../../../bin/fm-gemini-lib.sh` owns the narrow structural rule that fixes it: identity comes from argv[1], the script argument, accepted only when it is named `gemini` or lives under `@google/gemini-cli/`.
It is structural and runs no subprocess, for the same reason cursor's rule does not: probing a stranger's binary during a liveness poll is the hazard being avoided.
A bare interpreter, an unrelated node script, and a gemini name appearing later on a command line are all rejected, so a stranger's node pane is never reported as a live agent.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` writes a firstmate-owned per-task settings file at `state/<id>.gemini-settings.json` with three hooks bound to the minted busy generation, and the launch reaches it through `GEMINI_CLI_SYSTEM_SETTINGS_PATH`.
This wiring belongs only to the canonical exact `gemini` adapter template, which receives busy-state wiring, the turn-end hook, and trusted busy state together.
A raw Gemini-shaped launch is an unverified escape hatch: it receives no busy-state wiring or turn-end hook and therefore has no trusted busy state.
It is deliberately NOT the worktree's `.gemini/settings.json`: unlike Claude's `settings.local.json`, that path is the PROJECT's own committed settings file, so writing it would clobber a project's configuration and retiring it would delete a tracked file.
Hook arrays MERGE across Gemini's settings layers rather than overriding, so a project's own hooks still run alongside firstmate's; both were observed firing for one turn.
`../../../../../bin/fm-teardown.sh` removes the file, so nothing survives into a pooled worktree.
`BeforeAgent` records busy, `AfterAgent` records idle and keeps the `state/<id>.turn-ended` touch as the watcher NOTIFICATION, and `SessionEnd` records idle so an abnormal end cannot strand a busy record.
Each hook command prints the empty JSON object Gemini's hook contract requires and tolerates a refused event, so a stale-generation writer can never break Gemini's own lifecycle.

Two quirks are wired for deliberately.
`SessionEnd` was observed firing TWICE for one `/quit`; the repeated idle event is idempotent and is not de-duplicated.
`AfterAgent` fires on a manual Escape interrupt as well as on normal completion, which is better than Claude, whose interrupt emits no hook and usually leaves `claude-hook` busy.

The system settings layer also makes the busy contract independent of the trust decision: its hooks were verified firing under `--skip-trust` in an untrusted folder, and they need no entry in Gemini's per-workspace `~/.gemini/trusted_hooks.json`, which only records PROJECT hooks.
Workspace trust therefore buys skills, not state.
A guarded user-level hook in `~/.gemini/settings.json` was also proven to work, gated grok-style by a worktree pointer and a private token registry, and was rejected because it mutates the captain's own global settings for every session on the machine.

While a hook runs, the status row shows `Executing Hook: <name>` and the `(esc to cancel,` token is already gone, so that brief window reads idle; the turn itself is genuinely over by then.

## Skills

Gemini discovers user skills from `~/.gemini/skills/` or `~/.agents/skills/` and workspace skills from `.gemini/skills/` or `.agents/skills/`.
`~/.agents/skills/no-mistakes` is therefore discovered as a user skill and loads even in an untrusted folder, which is what keeps firstmate's delivery path available.
Workspace skills need the workspace trust the launch already grants, which is what makes a firstmate-repo task's own `.agents/skills` reachable.
Gemini does NOT read `.claude/skills`.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no gemini protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
Gemini's `BeforeAgent`/`AfterAgent` pair and its `gemini hooks migrate` command make a future primary integration plausible, but it remains unbuilt work, not a fact to rely on.
