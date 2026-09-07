# Kimi Code

Verified on 2026-07-25 with Kimi Code CLI 0.29.1.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute executable resolved from `PATH`, then executable `$HOME/.kimi-code/bin/kimi`; spawning refuses if neither exists. |
| Launch | Bare interactive TUI with `--auto`, followed by readiness-gated pointer delivery; positional prompts are rejected. |
| Models | Observed default `kimi-code/kimi-for-coding`, `kimi-code/kimi-for-coding-highspeed`, `kimi-code/k3`, and `kimi-code/k3-256k`; use `kimi provider list --json` for current configuration. |
| Busy state | Standalone Kimi is unknown pending a live-verified semantic source, preferring Wire's `prompt` lifetime then documented hooks including `Interrupt`; Kimi behind Pi uses Pi lifecycle, and the moon-phase spinner is never a state source. |
| Exit command | `/exit`. |
| Interrupt | Single Escape, which prints `Interrupted by user`. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; Firstmate skills are discovered. |
| Autonomy | `--auto`; `-y` and `--yolo` are weaker and are not used. |
| Trust dialog | None observed on a clean first launch in a fresh pooled worktree. |
| Slash submission | One Enter submits, with no popup swallow or settle hazard. |
| Environment marker | None; detection uses process ancestry command name `kimi`. |
| Composer | Bordered box with a bare `>` prompt glyph and no observed ghost or placeholder text. |
| Effort | No verified reasoning-effort flag; `references/common/model-and-effort.md` owns unsupported-value handling. |

## Readiness-gated start

`../../../bin/fm-spawn.sh` launches Kimi bare, waits for the composer box or `Welcome to Kimi Code!`, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires a cleared composer plus either the echoed `✨` submission or nonzero context before accepting delivery.
This launch-then-send shape is mandatory because Kimi rejects positional instructions as an unknown command.
The path must be absolute because the instructions live outside the task worktree and Kimi reads them there without `--add-dir`.

Sending before readiness was reproduced as a silent drop with zero exit status, an empty composer, `context: 0%`, no echoed user message, and a healthy-looking idle pane.
The startup input-readiness window is the established cause; the banner is not.
An early Enter can expand the composer to multiple content rows, leaving pointer text on the first row and the cursor on an empty later row.
The shared tmux reader therefore locates the complete bordered composer and treats real text on any content row as positive evidence that submission remains pending.
No rendering signal proves Kimi will accept input during this window, so delivery retries Enter through the shared submit core and retains the postcondition verification rather than relaxing readiness.

Observed spinner captures had optional leading whitespace, a moon-phase glyph, whitespace around `·`, and rotating tip text, including during tool execution.
The delivery-only matcher requires the observed whitespace, deliberately excludes the unobserved zero-whitespace form, and does not require trailing tip text.
Kimi's footer tip can show `ctrl+c: cancel` while idle, and its idle bar can contain lowercase `thinking` as an effort label.
Neither is a busy-state source.
The delivery-only spinner match covers the full moon-phase glyph set but remains locale- and emoji-font-sensitive because Kimi exposes no stable ASCII busy token.

## Crew turn-end hook and primary limit

Kimi is outside the primary turn-end guard scope.
`../../../docs/turnend-guard.md` owns its separate global hook surface and captain-approved crew wake integration.

`../../../bin/fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one silent always-zero hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`.
Each Kimi worker worktree receives a gitignored `.fm-kimi-turnend` pointer.
The global hook touches `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding it did not fire.
The guarded turn-end signal remains a wake notification.
Standalone Kimi has no busy-state source until one is live-verified.
