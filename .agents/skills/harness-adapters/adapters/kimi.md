## kimi (VERIFIED 2026-07-25, kimi 0.29.1)

Kimi Code CLI launches from the absolute path resolved from `PATH`, falling back to the executable `$HOME/.kimi-code/bin/kimi`.

| Fact | Value |
|---|---|
| Binary | Executable `kimi` from `PATH`, then executable `$HOME/.kimi-code/bin/kimi`; spawning refuses if neither exists. |
| Launch | Bare interactive TUI with `--auto`, followed by readiness-gated pointer delivery; positional prompts are rejected. |
| Models | `kimi-code/kimi-for-coding` (default), `kimi-code/kimi-for-coding-highspeed`, `kimi-code/k3`, and `kimi-code/k3-256k`. |
| Busy state | Standalone Kimi is unknown until a semantic source is live-verified; prefer Wire's `prompt` request lifetime, then documented hooks including `Interrupt`. Kimi behind Pi uses Pi's lifecycle. Its moon-phase spinner is not a state source. |
| Exit command | `/exit` |
| Interrupt | Single Escape, which prints `Interrupted by user`. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; firstmate skills are discovered. |
| Autonomy | `--auto`; `-y` and `--yolo` are weaker and are not used. |
| Trust dialog | None on a clean first launch in a fresh pooled worktree. |
| Slash submission | One Enter submits, with no popup swallow or settle hazard. |
| Environment marker | None; detection relies on process ancestry command name `kimi`. |
| Composer | Bordered box with a bare `>` prompt glyph and no observed ghost or placeholder text. |
| Effort | No reasoning-effort flag exists, so requested effort is recorded in task metadata but omitted from launch. |

`fm-spawn.sh` launches Kimi bare, waits for the composer box or `Welcome to Kimi Code!`, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires a cleared composer plus either the echoed `✨` submission or nonzero context before accepting delivery.
This launch-then-send shape is mandatory because Kimi rejects a positional brief as an unknown command.
Sending before readiness was reproduced as a silent drop with a zero exit status, an empty composer, `context: 0%`, no echoed user message, and a healthy-looking idle pane.
The brief path must be absolute because the brief lives outside the task worktree, and Kimi reads it there without `--add-dir`.

Observed live spinner captures included optional leading whitespace, a moon-phase glyph, whitespace around `·`, and rotating tip text, with the same shape observed during tool execution.
Because every captured spinner row had whitespace on both sides of `·`, the matcher requires that whitespace, deliberately does not match the never-observed zero-whitespace form, and does not require trailing tip text.
The startup input-readiness window is the established cause of Kimi's first-Enter delivery defect, while the banner is not the cause.
An early Enter can expand Kimi's composer to multiple content rows, leaving the pointer text on the first row and the cursor on an empty later row, which is the same single-cursor-row reading defect exposed by Grok's bottom-border cursor quirk.
The shared tmux reader now locates the complete bordered composer and treats real text on any content row as positive evidence that submission is still pending.
No rendering signal is trustworthy for proving that Kimi will accept input during this window, so delivery retries Enter through the shared submit core and retains the existing postcondition verification rather than relaxing readiness or delivery checks.
Kimi's footer tip rotates independently and can display `ctrl+c: cancel` while completely idle, which is one reason no Kimi rendered signature is a state source.
The idle status bar can contain lowercase `thinking`, which is the model's effort label rather than a busy signal.
The delivery-only spinner match covers the full moon-phase glyph set rather than one frame, but it remains locale- and emoji-font-sensitive because Kimi exposes no stable ASCII busy token.

[`docs/turnend-guard.md`](../../../../docs/turnend-guard.md) owns Kimi's verified global hook surface and captain-approved crew wake integration.
`fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one silent always-zero hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`.
Each Kimi crew worktree receives a gitignored `.fm-kimi-turnend` token pointer, and the global hook touches that task's `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding that the hook did not fire.
The guarded turn-end signal remains a wake notification; standalone Kimi has no busy-state source until one is live-verified.
