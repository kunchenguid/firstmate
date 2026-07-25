# harness-adapters: grok

Load this reference only when a Grok Build runtime is being selected, spawned, recovered, interrupted, exited, resumed, or verified.
The core [harness-adapters](SKILL.md) reference owns universal selection, dispatch, backend, and verification invariants.
Worker operation facts below were verified 2026-06-29 on grok 0.2.73 unless a narrower fact gives its own evidence.
Slash-submit was re-verified 2026-07-03 on grok 0.2.82.
The reasoning-effort ceiling was re-verified 2026-07-13 on grok 0.2.99.
Exit paths were re-verified 2026-07-19 on grok 0.2.103.

## Launch profile and model discovery

| Axis | Verified support |
|---|---|
| Model flag | `--model <model>` |
| Effort flag | `--reasoning-effort <low\|medium\|high>` |
| Evidence | Verified on grok 0.2.99 on 2026-07-13. |

`--effort` is an alias, but firstmate's profile axis is reasoning effort.
As of grok 0.2.99 the ceiling is `high`.
Both `xhigh` and `max` are rejected with `use one of: high, medium, low`, so firstmate omits them.
Run `grok models` to list the models available to the current Grok installation and account.
If the current authenticated environment does not establish the requested model or provider relationship, fail loudly and report the unresolved candidate.

## Worker operation facts

Grok Build TUI is launched with the `grok` command and is a Claude-Code-compatible CLI from xAI.
Launch with a positional prompt: `grok --always-approve "$(cat <brief>)"`.

| Fact | Value |
|---|---|
| Busy-pane signature | `Ctrl+c:cancel`, the mid-turn cancel hint in grok's keybind bar, shown iff a turn is running. |
| Spinner detail | The spinner line is a braille glyph plus `<status>… N.Ns` plus `[stop]`, such as `⠹ Thinking… 1.1s … [stop]`. |
| Idle keybind bar | Idle shows only `Shift+Tab:mode │ Ctrl+.:shortcuts`. |
| Busy regex rationale | The ASCII `Ctrl+c:cancel` avoids locale fragility of matching braille. |
| Exit command | `/exit` typed into the composer exits the TUI cleanly and prints `Resume this session with: grok --resume <session-id>`. |
| Exit fallbacks | `Ctrl+Q` double-press within 1000ms remains a fallback; `Ctrl+D` is the quit key in VS Code family terminals; `Ctrl+C` is the interrupt, not the exit. |
| Interrupt | single `Ctrl+C`, which cancels the current turn while the footer shows `Ctrl+c:cancel` mid-turn. |
| Esc behavior | `Esc` only moves focus to the scrollback and does not interrupt. |
| Skill invocation | `/<skill>`, same as claude. |
| Slash popup | Argument-taking commands open a hint popup whose first Enter may fill rather than submit; `fm-send`'s verified retry lands the required second Enter. |
| Autonomy | `--always-approve`, with footer `· always-approve`; auto-approves every tool execution, verified to run fully unattended. |
| Stronger autonomy equivalent | `--permission-mode bypassPermissions`. |
| Env marker | `GROK_AGENT=1`, set for child or tool processes. |
| Claude marker boundary | grok does not set `CLAUDECODE` despite Claude compatibility, so the marker is unambiguous. |
| Resume | `grok --resume <session-id>`, with id printed on exit, or `grok -c` / `--continue` for the most recent session for the cwd. |
| Forking | `--fork-session` branches a new session id. |

**Incident, 2026-07-03, herdr backend only, grok 0.2.82.**
Two grok/herdr crewmates were sent an argument-taking slash command via `fm-send`.
Both left it fully typed but unsubmitted in the composer for minutes, with footer still `Enter:send`, and `fm-send` exited 0 with no error.
Reproduced live: the herdr adapter's submit-verification at the time treated any pane-content change after Enter as submitted, and the popup-close-with-placeholder-fill described above is a visible content change even though nothing was actually sent.
The tmux backend was never affected.
`fm_tmux_composer_state` reads the actual cursor row, correctly sees the placeholder text as still pending, and its retry loop already sends the needed second Enter.
The Herdr adapter was fixed in `fm_backend_herdr_composer_state` in `bin/backends/herdr.sh` by classifying the composer's own row structurally instead of diffing raw content.
See [`docs/herdr-backend.md`](../../../docs/herdr-backend.md) "Composer and injection safety" for the current boundary and `tests/fm-backend-herdr.test.sh` for regression coverage.

Startup dialog: the "Run Grok Build in a project directory?" project picker appears only when grok is launched from a non-project directory such as home, Desktop, Downloads, or `/tmp`.
`fm-spawn` launches inside the treehouse worktree, which is a git repo root, so the picker never appears and grok treats the worktree as a trusted project automatically.
No post-launch keystroke is needed.
Pin `[hints] project_picker_disabled = true` in `~/.grok/config.toml` if a non-project launch ever needs to skip it.

**TRUECOLOR placeholder styling, covered by task afk-herdr-false-pending on 2026-07-10.**
A freshly dismissed, never typed into grok composer shows a placeholder, `Type a message...`, styled with a dark 24-bit TRUECOLOR foreground, not the SGR-2 dim or faint attribute the ghost stripper originally detected.
The shared ANSI-aware owner `fm_composer_strip_ghost` in `bin/fm-composer-lib.sh` now drops a dark or muted truecolor foreground, per perceived luminance below `FM_COMPOSER_GHOST_LUMA_MAX` default 128, as well as dim or faint.
The placeholder is stripped and the row reads empty on both ANSI-capable backends, because tmux and herdr route through the same owner.
Verified live against grok 0.2.93: real input is the bright `38;2;224;222;244` with luminance about 225, which is kept.
Grok's borders and placeholder/hint text are dark truecolor, `38;2;50;47;70` through `38;2;110;106;134`, with luminance about 51 through 110, which is dropped.
This assumes a dark terminal theme, the fleet reality.
The SGR-2 signal stays theme-independent.
Regression coverage: `tests/fm-composer-ghost.test.sh` includes `test_strip_ghost_drops_dark_truecolor_ghost` and `test_dark_truecolor_ghost_only_composer_is_not_pending`.
Regression coverage: `tests/fm-backend-herdr.test.sh` includes `test_composer_state_grok_dark_truecolor_placeholder_is_empty` and `test_composer_state_grok_bright_truecolor_real_text_is_pending`.

**Residual gap, tmux-only and unfixed.**
In that same pristine placeholder-only state, tmux's own `#{cursor_y}` points at the composer box's bottom border row, one row below the actual text row.
The box appears to render one row lower before any real typing starts.
Once real text is typed the cursor correctly aligns with the text row again.
This is a row-selection quirk, orthogonal to the styling fix above, and affects only the tmux path.
Herdr uses a structural composer-row scan, not `cursor_y`, so it is unaffected.
A correct fix needs a row-window read near `cursor_y` rather than the single `cursor_y` row.
In practice `fm-spawn` launches grok with the brief as its initial prompt, so a live task's composer is never observed in this pristine pre-typing state.
This is unverified for every path, such as a steer sent before grok's first real turn settles, and needs dedicated investigation before relying on it.

Turn-end hook: grok fires a `Stop` hook at every turn boundary, giving firstmate a precise per-turn wake instead of only stale-pane detection.
grok loads project hooks from `<worktree>/.grok/hooks/` and `<worktree>/.claude/settings.local.json` only after the folder is granted hook-trust in `~/.grok/trusted_folders.toml`.
That trust is not automatic, and firstmate will not establish it by editing grok's own managed trust store.
Global hooks in `~/.grok/hooks/` are always trusted and load on first launch.
So `fm-spawn` installs one firstmate-owned global hook, `~/.grok/hooks/fm-turn-end.json`, plus the companion `~/.grok/hooks/fm-turn-end.sh`, guarded as a no-op for every non-firstmate grok session.
Its `Stop` command fires only when the current workspace holds a `.fm-grok-turnend` token pointer that matches the firstmate-owned hook registry under `~/.grok/hooks/fm-turn-end.d/`.
`fm-spawn` writes that per-task pointer, `<worktree>/.fm-grok-turnend`, gitignored via git info/exclude like the other harnesses' worktree hook files.
`fm-spawn` also writes a matching registry entry naming this task's `state/<id>.turn-ended`.
The hook reads `$GROK_WORKSPACE_ROOT`, which is always set for hooks and equals the worktree.
This keeps the hook outside the worktree, needs no trust grant, and writes only firstmate-owned files.
`fm-teardown` removes the worktree pointer before returning a pooled worktree.
Secondmate spawns skip the pointer because idle panes are healthy and there is no stale-pane detection for them.

## Primary integration facts

`grok` exposes passive lifecycle callbacks for the primary turn-end guard, so its tracked primary adapter forces one bounded follow-up when the shared predicate blocks.
`grok` blocks watcher-arm anti-patterns directly through PreToolUse hooks.
Every `$VAR` reference in a grok hook `command` string must carry an inline `:-default` or Grok fails to launch the hook entirely.
Grok uses tracked background-notify cycles around `bin/fm-watch-arm.sh`.
Grok's primary watcher protocol is Claude-shaped background-notify around `bin/fm-watch-arm.sh`; the passive Stop hook is only a backstop for blind turn ends.

`bin/fm-sessionstart-nudge.sh` has a verified project `SessionStart` event on grok 0.2.103 with `source=new`, but stdout does not reach model context.
The tracked project hook remains fail-open, and a global token-guarded fallback requires a captain decision.

**Primary-session guard fact, verified 2026-07-08 on Grok 0.2.91.**
The firstmate primary's own `.grok/hooks/fm-primary-turnend-guard.json` invokes `bin/fm-turnend-guard-grok.sh`.
Grok Stop hooks are passive for this purpose: exit 2 does not make the model continue.
The adapter therefore runs the shared predicate and, when it returns 2, forces one same-session follow-up with `grok --resume <sessionId> -p <guard-reason>` while setting `GROK_TURNEND_GUARD_ACTIVE=1` so the nested Stop hook does not recurse.
It does not pass `--permission-mode`, so the passive hook cannot escalate the primary session's tool permissions.
Project-local Grok hooks require folder trust, verified with launch-time `--trust`.
If the primary firstmate checkout is not trusted for Grok hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.
