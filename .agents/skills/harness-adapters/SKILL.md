---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, pi, and grok.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Harness resolution policy - the static `config/crew-harness` override, dispatch profiles, precedence, the secondmate fallback chain, and config inheritance into secondmate homes - is AGENTS.md section 4's contract; this skill owns the per-adapter operational knowledge (busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks), while the launch mechanics (launch command, autonomy flag, turn-end hook) live in `bin/fm-spawn.sh`.

Never dispatch a crewmate or secondmate on an unverified adapter (section 4's rule).
When the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, the busy signature in `fm-watch.sh` and `fm-tmux-lib.sh` defaults, any needed `FM_COMPOSER_IDLE_RE` empty-composer override, the env marker and command name in `bin/fm-harness.sh`, and the verified knowledge here.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry; `crew` and `secondmate` modes resolve the effective launch harness per AGENTS.md section 4.
On `unknown`, ask the captain instead of guessing; a captain override always beats detection.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values chosen by firstmate at intake.
The supported launch-profile flags below were verified locally on 2026-06-30 with each CLI's help and parser path.

| Harness | Model flag | Effort flag | Notes |
|---|---|---|---|
| claude | `--model <model>` | `--effort <low\|medium\|high\|xhigh\|max>` | Verified on Claude Code 2.1.196. |
| codex | `--model <model>` | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` | Verified on codex-cli 0.142.1. The installed binary schema contains `model_reasoning_effort`, the active config uses it, and the bundled model catalog advertises only low/medium/high/xhigh. `max` is omitted. |
| grok | `--model <model>` | `--reasoning-effort <low\|medium\|high\|xhigh>` | Verified on grok 0.2.73. `--effort` parses too, but firstmate's profile axis is reasoning effort. `--reasoning-effort max` is rejected, so `max` is omitted. |
| pi | `--model <model>` | `--thinking <low\|medium\|high\|xhigh>` | Verified on pi 0.80.2. `max` prints an invalid-thinking warning, so firstmate omits Pi effort when the requested effort is `max`. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness.
This preserves launch success instead of passing a known-bad value.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- grok: `/<skill>`, for example `/no-mistakes` (same form as claude); verified end to end against a real `no-mistakes axi run`. Slash-popup submit hazard and the 2026-07-03 herdr incident: see the grok section below.

## claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds.
If such a dialog is showing, accept it with `bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, and verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the pane reader in `bin/fm-tmux-lib.sh` captures only the composer line with ANSI styling, drops dim/faint SGR 2 runs, and ignores them, so only normal-intensity typed text counts as pending input.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

**Primary-session Stop hook (verified 2026-07-04, Claude Code 2.1.201).**
This is separate from the per-task crewmate turn-end hook above (that one just `touch`es a marker file in a task's own `.claude/settings.local.json`).
The firstmate PRIMARY's own `.claude/settings.json` (tracked at the repo root) registers a second, structural Stop hook, `bin/fm-turnend-guard.sh` (docs/turnend-guard.md), that can genuinely block a turn from ending: exiting the hook command with status 2 and a reason on stderr reliably forces the model to continue and act on that reason - verified live with `claude -p`, both interactively and headless.
Claude Code's stdin payload to a Stop hook carries a `stop_hook_active` boolean that is `true` exactly when the current stop attempt is itself a forced continuation from an earlier block this turn; a hook can and should use that as its own loop-guard (always allow the stop when it is already `true`) rather than tracking state itself.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root.
After those settings are loaded, hook command resolution is still cwd-sensitive because Claude Code runs commands through `/bin/sh` against the session's current cwd; keep the tracked command anchored through `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh` and see `docs/turnend-guard.md` for the verified Stop-hook details.

## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` (shown as `• Working (Xs • esc to interrupt)`) |
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; `fm-send` handles it) |
| Interrupt | single Escape |
| Skill invocation | `$<skill>` (e.g. `$no-mistakes`); `/<skill>` is claude-only and codex rejects it as "Unrecognized command" |

A `$<skill>` invocation opens a `$`-autocomplete (skill) popup, the same hazard as the `/` slash popup: submitting too fast lets the popup swallow the Enter, so the invocation never lands.
`fm-send` handles it the same way it handles `/` - it gives the popup a longer settle (1.2s) between typing and the first Enter, with the target backend's submit retry as the safety net - but the `$` settle is scoped to `harness=codex`, read from the target's `state/<id>.meta`.
That scope matters because, unlike `/`, a leading `$` commonly starts ordinary text (`$5/month`, `$HOME`), so a universal `$` rule would needlessly slow plain steers to claude/opencode/pi; only a codex target receiving a `$...` message gets the popup-settle.
An explicit `session:window` target has no meta, so its harness is unknown and treated as non-codex (the safe fast-path default).
This is why the validation trigger (`$no-mistakes`) to a codex crew now lands on the first Enter instead of biting the popup.

Directory trust dialog on first run per repo root: "Do you trust the contents of this directory?"
Accept with Enter.
The decision persists for the repo, so later worktrees of the same project skip it.

Resume after exit with `codex resume <session-id>`.
The session id is printed on quit.

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.3)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt` (dotted spinner footer; note no "to") |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch |

No trust dialog.
Opencode can auto-upgrade itself in the background and the running TUI can exit mid-task, observed live from 1.15.7 to 1.17.3.
If a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

## pi (VERIFIED 2026-06-11)

| Fact | Value |
|---|---|
| Busy-pane signature | `Working...` (braille spinner prefix; no `esc to interrupt` text) |
| Exit command | `/quit` |
| Interrupt | single Escape |

Pi has no permission system, so crewmates are always autonomous.
Keep the brief as one positional argument.
Multiple positional args become separate queued messages; `fm-spawn`'s template already does this correctly.

Project trust dialog can appear on the first pi run in any not-yet-trusted directory, observed even on clean worktrees.
Accept with Enter.
The decision persists per path in `~/.pi/agent/trust.json`, so later spawns in the same worktree slot skip it.

`fm-spawn` keeps the turn-end extension in `state/`, outside the worktree, because project-local extension files make the trust gate strictly worse and pollute the project.
The extension must listen for pi's `turn_end` event, not `agent_end`, so the watcher wakes after each completed turn instead of only when the whole agent run exits.
Pi sets `PI_CODING_AGENT=true` for its children; this is its harness-detection env marker.

## grok (VERIFIED 2026-06-29, grok 0.2.73; slash-submit behavior re-verified 2026-07-03, grok 0.2.82)

Grok Build TUI (`grok`), a Claude-Code-compatible CLI from xAI.
Launch with a positional prompt: `grok --always-approve "$(cat <brief>)"`.

| Fact | Value |
|---|---|
| Busy-pane signature | `Ctrl+c:cancel` (the mid-turn cancel hint in grok's keybind bar, shown iff a turn is running; the spinner line is a braille glyph + `<status>… N.Ns` + `[stop]`, e.g. `⠹ Thinking… 1.1s … [stop]`). Idle keybind bar shows only `Shift+Tab:mode │ Ctrl+.:shortcuts`. The ASCII `Ctrl+c:cancel` is the busy regex (avoids locale fragility of matching braille). |
| Exit command | `Ctrl+Q` double-press within 1000ms (it is a confirmed destructive action). Prints `Resume this session with: grok --resume <session-id>`. `Ctrl+D` is the quit key in VS Code family terminals. NOT `/exit` and NOT `Ctrl+C`. |
| Interrupt | single `Ctrl+C` (cancels the current turn; the footer shows `Ctrl+c:cancel` mid-turn). `Esc` only moves focus to the scrollback, it does NOT interrupt. |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`), same as claude. Opens a slash-autocomplete popup, so a too-fast Enter selects the popup entry instead of sending. For an argument-taking command that first Enter does not submit at all - it expands the selection into an argument-hint placeholder in the composer (e.g. `/compact` -> `/compact compaction instructions`, live-verified), leaving real text still sitting there unsubmitted; a genuine second Enter is required. `fm-send`'s retried Enter lands it on BOTH backends, but only because each backend's own submit-verification correctly recognizes that placeholder-filled text as still-pending - see the incident below. |
| Autonomy | `--always-approve` (footer shows `· always-approve`); auto-approves every tool execution, verified to run fully unattended. `--permission-mode bypassPermissions` is the stronger equivalent. |
| Env marker | `GROK_AGENT=1`, set for child/tool processes. grok does NOT set `CLAUDECODE` despite Claude compatibility, so the marker is unambiguous. |
| Resume | `grok --resume <session-id>` (id printed on exit) or `grok -c` / `--continue` (most recent for the cwd); `--fork-session` branches a new session id. |

**Incident (2026-07-03, herdr backend only, grok 0.2.82):** two grok/herdr crewmates were sent `/no-mistakes` via `fm-send`; both left it fully typed but unsubmitted in the composer for minutes (footer still `Enter:send`), and `fm-send` exited 0 with no error.
Reproduced live: the herdr adapter's submit-verification at the time treated ANY pane-content change after Enter as "submitted", and the popup-close-with-placeholder-fill described above IS a visible content change even though nothing was actually sent.
The tmux backend was never affected - `fm_tmux_composer_state` reads the actual cursor row, correctly sees the placeholder text as still-pending, and its retry loop already sends the needed second Enter.
Fixed in the herdr adapter (`fm_backend_herdr_composer_state`, `bin/backends/herdr.sh`) by classifying the composer's own row structurally instead of diffing raw content; see `docs/herdr-backend.md`'s "Incident (2026-07-03)" section for the full account and `tests/fm-backend-herdr.test.sh` for the regression coverage.

Startup dialog: the "Run Grok Build in a project directory?" project picker appears ONLY when grok is launched from a non-project directory (home, Desktop, Downloads, `/tmp`).
`fm-spawn` launches inside the treehouse worktree (a git repo root), so the picker never appears and grok treats the worktree as a trusted project automatically - no post-launch keystroke is needed.
Pin `[hints] project_picker_disabled = true` in `~/.grok/config.toml` if a non-project launch ever needs to skip it.

**Known gap, unfixed (found 2026-07-03, not yet in scope of any fix):** a freshly-dismissed, never-typed-into grok composer shows a placeholder ("Type a message...") styled with a dark 24-bit TRUECOLOR foreground, not the SGR-2 dim/faint attribute `fm_tmux_strip_ghost` detects, so it is NOT stripped and reads as real pending text - `FM_COMPOSER_IDLE_RE` is NOT already set to cover it. Worse, live-verified: in that exact pristine placeholder-only state, tmux's own `#{cursor_y}` points at the composer box's BOTTOM BORDER row, one row below the actual text row (the box appears to render one row lower before any real typing starts); once real text is typed the cursor correctly aligns with the text row again. A correct fix needs a row-window read near `cursor_y` (or a structural scan like the herdr adapter's composer-row finder, `bin/backends/herdr.sh`), not just a wider idle regex. In practice `fm-spawn` launches grok with the brief as its initial prompt, so a live task's composer is never observed in this pristine pre-typing state - but this is unverified for every path (e.g. a steer sent before grok's first real turn settles) and needs dedicated investigation before relying on it.

Turn-end hook: grok fires a `Stop` hook at every turn boundary, giving firstmate a precise per-turn wake instead of only stale-pane detection.
grok loads PROJECT hooks (`<worktree>/.grok/hooks/`, `<worktree>/.claude/settings.local.json`) only after the folder is granted hook-trust in `~/.grok/trusted_folders.toml`, which is not automatic and which firstmate will not establish by editing grok's own managed trust store.
GLOBAL hooks in `~/.grok/hooks/` are always trusted and load on first launch.
So `fm-spawn` installs ONE firstmate-owned global hook, `~/.grok/hooks/fm-turn-end.json`, plus the companion `~/.grok/hooks/fm-turn-end.sh`, guarded as a no-op for every non-firstmate grok session.
Its `Stop` command fires only when the current workspace holds a `.fm-grok-turnend` token pointer that matches the firstmate-owned hook registry under `~/.grok/hooks/fm-turn-end.d/`.
`fm-spawn` writes that per-task pointer (`<worktree>/.fm-grok-turnend`, gitignored via git info/exclude like the other harnesses' worktree hook files) and a matching registry entry naming this task's `state/<id>.turn-ended`.
The hook reads `$GROK_WORKSPACE_ROOT`, which is always set for hooks and equals the worktree.
This keeps the hook outside the worktree, needs no trust grant, and writes only firstmate-owned files.
`fm-teardown` removes the worktree pointer before returning a pooled worktree.
Secondmate spawns skip the pointer (idle panes are healthy, no stale-pane detection for them).
