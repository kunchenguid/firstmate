# Antigravity CLI

Verified with Antigravity CLI 1.2.0 on Linux on 2026-09-10.
Crewmate and scout only; primary and secondmate supervision are unsupported.

| Fact | Observed behavior |
|---|---|
| Launch | `agy --dangerously-skip-permissions --prompt-interactive '<prompt>'` submits the initial prompt and keeps an interactive session. |
| Detection | Tool subprocesses carry `ANTIGRAVITY_AGENT=1`; the native executable reports process name `agy`. |
| Trust | A fresh folder prompts `Do you trust the contents of this project?` despite the autonomy flag. The default `Yes, I trust this folder` accepts with Enter; inspect afterward to prove the initial prompt ran. |
| Autonomy | A Bash command ran without a permission prompt after folder trust was accepted. |
| Model | `--model <id>`; `agy models` lists account-available identifiers. `gemini-3.8-flash-low` completed the live probe. |
| Effort | CLI help advertises `--effort low\|medium\|high`; low and medium launches displayed the selected effort. |
| Composer | `>` between solid horizontal rules, followed by a mode/model footer. Empty input shows `? for shortcuts`; typed input hides that hint. A fresh composer before its first submitted prompt shows a mode placeholder (`Accept-edits mode: ...`) in a palette-dim color the shared ghost stripper keeps, so that transient window classifies `pending`; the settled post-turn composer classifies `empty`, and a turn under way classifies `unknown`. Native identity is required to distinguish this shell-like glyph safely. |
| Interrupt | One Escape interrupted the turn and left an empty composer. A running `sleep 30` remained listed as a background task after interruption; interruption does not prove child-command termination. |
| Exit | `/exit` followed by one Enter returned to the shell and printed a conversation resume command. |
| Resume | `agy --conversation <id>` restored the observed conversation history. CLI help also advertises `--continue` / `-c`; that alternative was not exercised. |
| Skills | Unknown; use natural-language instructions until native skill invocation is verified. |
| Busy state | Unknown. The rendered `esc to cancel` footer persisted after interruption while a shell task remained; it is not semantic turn-state evidence. |
| Turn end | No per-task hook configuration is verified. CLI help exposes no settings-file or hook flag. No hook is installed and no turn-end event is fabricated. |

`bin/fm-spawn.sh` owns launch, effort omission, and the secondmate refusal.
It does not install configuration in the user's `~/.gemini` or the project's configuration.
The CLI itself reported its project configuration under `~/.gemini/config/projects/` during `/help`; do not confuse its own persistence with a verified per-task settings override.
`bin/fm-busy-lib.sh` returns `unknown agy-unverified`, including on Herdr, until a semantic source is verified.
`bin/fm-composer-lib.sh` requires the observed separated input layout and idle native agy identity; backends without that identity remain unknown.

Primary startup, pre-tool protection, and watcher supervision have no verified agy integration.
Do not borrow Gemini's configuration variables or hooks merely because both tools use `~/.gemini`.
The live refresh command and dated results belong to `docs/verification/runtime-backends.md`.
