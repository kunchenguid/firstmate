# Google Antigravity CLI

Google's `agy` TUI, verified end to end on 2026-09-04 with Antigravity CLI 1.1.26 on macOS.
This is a distinct adapter from Google's separate `gemini` CLI.
It is verified for crewmates, scouts, second mates, and interactive primary sessions.

## Operating facts

| Fact | Value |
|---|---|
| Launch | `agy --dangerously-skip-permissions --add-dir <exact-worktree> --add-dir <firstmate-hook-overlay> --model <id> --effort <low|medium|high> --prompt-interactive "<brief>"`. Second mates omit the task overlay because their own tracked `.agents/hooks.json` supplies primary hooks. |
| Workspace | The first `--add-dir` selects the exact isolated project and makes its `AGENTS.md` and `.agents/skills/` available. Without it, terminal tools start in `~/.gemini/antigravity-cli`, not the launching shell's directory. |
| Autonomy | `--dangerously-skip-permissions` is the documented always-proceed mode and runs terminal tools unattended. `--mode accept-edits` alone does not grant command execution in headless mode; the command is automatically denied. |
| Marker | Tool subprocesses carry `ANTIGRAVITY_AGENT=1`. Inherited `AI_AGENT` and Pi markers are not Antigravity identity and are cleared by the canonical launch. |
| Model | `--model <id>`; `agy models` is the authoritative current catalog. The Firstmate adapter is Gemini-only: it validates an explicit `gemini-*` id or chooses a live Gemini catalog entry, preferring the requested effort suffix. |
| Effort | `--effort low|medium|high`; xhigh and max are unsupported and deliberately omitted. |
| Busy state | Semantic `antigravity-hook`: task `PreInvocation` opens activity and `Stop` settles it. Herdr's native `agent get` also reports `agy` with working/idle status, and the rendered delivery token is `esc to cancel`. |
| Turn end | The Firstmate-owned task overlay's `Stop` hook settles activity and touches `state/<id>.turn-ended`. |
| Interrupt | One `Escape`; the active turn cancels and the TUI remains open. |
| Exit | `/quit`, then one Enter. |
| Skills | Antigravity automatically discovers skills under `.agents/skills/` from the added workspace. |
| Primary | One foreground `bin/fm-watch.sh` terminal call; see `../../../../../docs/supervision-protocols/antigravity.md`. |

## Version and sign-in

Require `agy --version` 1.1.26 or newer.
That release advertises the fix for repeated subagent approvals in always-proceed mode; use the vendor's `agy update` command when the installed version is older.
Complete Antigravity's own sign-in once before dispatch.
Firstmate never copies or embeds the account credential in a launch command.

## Detection and liveness

`../../../../../bin/fm-harness.sh` checks `ANTIGRAVITY_AGENT=1` before inherited Pi or other generic markers and recognizes exact `agy` process ancestry.
Never use `AI_AGENT` as identity: a verified Antigravity tool process retained its Pi launcher's value.
The exact executable name `agy` is also registered with the shared session-lock and tmux foreground-process classifiers.
Herdr 0.8.0 natively reports `agent=agy` and working/idle state for the same process.
A bare command or path merely containing the substring `agy` is not accepted as identity.

## Workspace, instructions, and hooks

Antigravity discovers `.agents/hooks.json`, `AGENTS.md`, and `.agents/skills/` from a directory passed with `--add-dir`.
Hook discovery is independent of the argument's position in the repeated `--add-dir` list.
Hook commands run with the directory containing `hooks.json` as their working directory.
The tracked root hook injects the normal startup reminder with `PreInvocation` and gates terminal/delegation tools with `PreToolUse`.
For workers, `fm-spawn.sh` writes `state/<id>.antigravity-hooks/.agents/hooks.json` and adds that isolated overlay after the project path, so it never writes or replaces the project's own `.agents/hooks.json`.
`fm-control.sh relaunch` retires the old hook file before arming a replacement generation, and cleanup removes the overlay directory.
A raw launch command receives none of this task wiring and has no trusted semantic activity state.

## Composer, steering, and lifecycle

Antigravity draws a `>` input row between two solid separator rows.
The shared composer classifier accepts that shell-like glyph only inside the verified separated shape and only when the live identity probe says Antigravity; a bare `>` remains a dead shell and can never prove an empty composer.
This preserves the ordinary durable-inbox steering path and Enter-only retry rule on tmux and Herdr.
Lifecycle operations go only through `../../../../../bin/fm-control.sh`.
The executable table in `../../../../../bin/fm-control-lib.sh` owns the one-Escape interrupt, `/quit` exit, task-kind support, and hook-overlay cleanup path.

## Primary safety and supervision

Antigravity's `PreToolUse` input is `.toolCall.name` plus `.toolCall.args.CommandLine`, and deny output is `{"decision":"deny","reason":"..."}`.
The tracked primary hooks adapt that native contract to Firstmate's watcher-arm, persistent-directory-change, and built-in delegation guards.
Those guards are primary-scoped and remain inert in isolated worker copies where delegation is legitimate.
A live Gemini turn on 1.1.26 identified the built-in delegation tools as `invoke_subagent` and `send_message`; both are denied by the guard's existing delegation-shape classification in a Firstmate primary.
Antigravity hooks are synchronous and expose no verified asynchronous background-task-to-model wake.
The primary therefore uses the named foreground supervision protocol rather than borrowing another harness's background mechanics.
Headless `--print` is not a primary host because it has no persistent conversation for later fleet notifications.

## Verification boundary

The live checks used a named disposable Herdr lab and explicit Gemini models only.
They proved model and effort display, exact workspace tool execution, `AGENTS.md` and skill discovery, autonomous terminal execution, marker precedence, native Herdr identity, hook discovery, one-Escape interrupt, and `/quit` exit.
No Claude-family model was selected.
See `../../../../../docs/verification/antigravity.md` for the dated commands, counterfactuals, and remaining limitations.
