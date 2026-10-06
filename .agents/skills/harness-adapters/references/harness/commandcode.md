# Command Code

Verified on 2026-10-05 with Command Code 1.74.1 on Linux, model `deepseek/deepseek-v4.1-flash`.
The adapter name is `commandcode`, the executable Firstmate resolves; `cmd` is also installed but is too generic to name an adapter.
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/commandcode.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The tracked `../../../bin/fm-commandcode-mod.ts`, loaded per process with `--mod`: `run_start` opens, `run_end` closes (an Escape interrupt included, as stop reason `interrupted`), and session end closes; `../../../bin/fm-busy-lib.sh` owns trust. |
| Exit command | `/quit` (`/exit` is an alias); prints `cmd --resume <session-id>`. |
| Interrupt | One Esc cancels a running turn and prints `Interrupted · What should Command Code do instead?` with an empty composer. Two Escs within about half a second on an idle agent open the Rewind checkpoint picker, where Enter restores a checkpoint, so the control plane sends one press and closes a picker with one more Esc. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; Command Code discovers user skills from `~/.agents/skills` and `~/.commandcode/skills`, and its slash popup lists them as `[skill]`. |
| Resume | `commandcode --resume <session-id>` (also `--session <id-prefix>`) reopens the conversation but ignores a message passed beside it, so the next prompt is typed after the composer reads empty; `--model` applies to the resumed session. |
| Model flag | `--model <model-id>`; `commandcode --list-models` is the authoritative listing, and an unlisted id exits the launch. |
| Effort flag | `--effort <level>`, model-scoped; both DeepSeek V4.1 Flash models accept `off`, `low`, `high`, and `max`, and an unaccepted value exits the launch, so `../../../bin/fm-spawn.sh` passes only verified pairs. |
| Model discovery | `commandcode --list-models`; authentication preflight is `commandcode status`. |
| Marker | None; the process title is the anchored name `command-code`, which identifies the adapter and outranks foreign inherited markers. |
| Trust dialogs | `--trust` skips the fresh-worktree folder-trust prompt and `--yolo` bypasses permission prompts. |
| Commit attribution | Command Code adds `Co-authored-by: CommandCodeBot <noreply@commandcode.ai>` by default and only its settings files can turn that off, so the fleet commit-msg strip removes it unless the home sets `config/keep-ai-trailers` (`../../../docs/configuration.md` "Commit attribution"). |

## Per-process wiring limits

`--config key=value` is not per process: it persists the setting into `~/.commandcode/config.json`, so Firstmate never passes it.
Hooks in `settings.json` are file-scoped and gain no `UserPromptSubmit`, so the mod, not a hook, carries busy state; user and project hooks keep running beside it.
Taste learning has no per-process switch and seeds `.commandcode/taste/` in the project on every start, which the spawn adds to the worktree's git exclude.

## Composer and steering

Command Code draws a bare `❯` composer between two rules, parks the terminal cursor below its footer, and draws its own reverse-video cursor cell.
Its `Ask your question...` placeholder is truecolor bright enough to survive the fleet ghost ceiling, so `../../../bin/fm-composer-lib.sh` reads a screen with a Command Code identity at a higher ceiling; typed text is the default foreground and stays pending.
The launch clears `NO_COLOR` and pins `COLORTERM=truecolor`, because a 256-colour terminal renders the placeholder in an untested palette colour.
`../../../bin/fm-tmux-lib.sh` supplies the `commandcode` identity on tmux, while Herdr's native detection reports `cmd`.
The delivery busy signals are `esc to interrupt` and the bullet-framed elapsed cell on the status row.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract was verified for Command Code.
Do not launch a primary or secondmate with this adapter.
Quota-provider mapping and typed dispatch resolution remain separate follow-ups.
