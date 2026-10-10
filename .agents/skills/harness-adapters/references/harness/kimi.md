# Kimi Code

Verified on 2026-09-17 with Kimi Code CLI 2.0.0.

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
| Autonomy | `--auto` is the `Never Ask` tier; `-y` and `--yolo` now select the distinct, weaker `Ask When Needed` tier and are not used. |
| Trust dialog | A fresh worktree shows `Trust this folder?` with `Trust this folder` pre-selected; spawn reads the visible pane, recognizes the complete dialog (its title, both navigation-hint tokens `↑↓ navigate` and `Enter select` - matched separately so a hint wrapped in a narrow pane still counts - the selected `❯ Trust this folder`, and `Don't trust`), sends Enter on every poll the complete dialog is still there, verifies that a later visible-pane capture no longer contains it, and then continues the ordinary readiness gate. Trust is never pre-registered in `config.toml`; the dialog is answered live. |
| Slash submission | One Enter submits, with no popup swallow or settle hazard. |
| Environment marker | None; identity comes from process ancestry command name `kimi`, which `../../../bin/fm-harness.sh` keeps a retained foreign marker from overriding. |
| Composer | Bordered box with a bare `>` prompt glyph and no observed ghost or placeholder text. |
| Effort | `kimi provider list --json` exposes per-model `supportEfforts` values `low`, `high`, and `max` plus a `defaultEffort`; the launch flag and mapping remain unverified, so spawn records and omits requested effort per `references/common/model-and-effort.md`. |

## Readiness-gated start

`../../../bin/fm-spawn.sh` launches Kimi bare, handles the complete 2.0.0 trust dialog when it appears, waits for the composer box or `Welcome to Kimi Code!`, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires a cleared composer plus either the echoed `✨` submission or nonzero context before accepting delivery.
Every trust predicate reads `fm_backend_visible_capture`, the viewport without scrollback, because a history read could replay a cleared dialog and send Enter to a live composer.
The verified viewport implementations for Kimi are tmux, Herdr, and Zellij, as recorded in `bin/fm-backend.sh` and `docs/verification/runtime-backends.md`.
Orca's screen read is limited to recorded Droid tasks, and cmux lacks a verified viewport.
Spawn refuses Kimi on Orca and cmux through the shared missing-viewport check before creating a worktree or pane.
A failed viewport read ends readiness with the backend named, and a blank successful read restarts the two-capture ready count without claiming a cleared dialog.
Kimi's trust answer can be retried only while the complete dialog remains on the live viewport, since the CLI can swallow an Enter during startup.
Trust is accepted only after a later viewport capture proves that the dialog cleared; a stuck dialog reports the observed signals and answer count.
Any single marker of the dialog on that visible pane - `Trust this folder` or the negative `Don't trust` option - withholds the ready verdict, because a capture caught mid-redraw and a capture that has painted only the box title both miss the complete dialog while the banner above it would otherwise read as ready. The banner also prints before the dialog paints at all, which no single capture can distinguish from a ready pane, so the verdict additionally requires two consecutive captures that are each ready and free of dialog text; a capture that is not ready, and a blank one, restarts that count, which is what keeps the pre-banner boot captures and redraw frames from spending it.
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
