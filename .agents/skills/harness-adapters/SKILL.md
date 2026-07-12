---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, pi, grok, cursor, and agy.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
Optional dispatch profiles in `config/crew-dispatch.json` can override that static default for one crewmate or scout dispatch by selecting concrete harness, model, and effort axes at intake.
The captain may override that file at session start or later; a per-task instruction such as "run this one on codex" overrides it for that dispatch only.
`default` means mirror firstmate's own harness.

Secondmates have their own harness knob, so a secondmate can run on a different adapter than crewmates.
`config/secondmate-harness` is the harness the primary uses to launch SECONDMATE agents, resolved through the fallback chain `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own.
An absent or `default` `config/secondmate-harness` therefore behaves exactly as the crew harness did before this knob existed (secondmates launched on the crew harness); setting it splits the two.
`config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend` are inherited by secondmate homes.
This skill owns only the harness-relevant consequence: a secondmate's own crewmates use the primary's dispatch profiles and static harness value, while `config/secondmate-harness` is the primary's own setting and is never inherited - secondmates do not spawn secondmates.
Inheritance copies the literal `config/crew-harness` file, so for a secondmate's own crewmates to run on the primary's crewmate harness the captain must set `config/crew-harness` to a concrete adapter name, such as `codex`.
If `config/crew-harness` is unset or `default`, there is no concrete value to inherit, so the secondmate's own crewmates fall back to the secondmate's own/detected harness rather than the primary's effective crewmate harness.
Inheritance also copies the literal `config/crew-dispatch.json` file, so secondmates apply the same best-fit profile rules for their own crewmates.

Each adapter splits into mechanics and knowledge.
The per-task mechanics, including launch command, autonomy flag, and crewmate turn-end hook, live in `bin/fm-spawn.sh`.
The primary-session "no turn ends blind" guard contract and harness hook installation paths live in `docs/turnend-guard.md`.
The primary-session watcher wake protocols are rendered from `docs/supervision-protocols/` by `bin/fm-supervision-instructions.sh`.
The supervision knowledge lives here: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, tell the captain and fall back to firstmate's own harness until that adapter is verified.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, the busy signature in `fm-watch.sh` and `fm-tmux-lib.sh` defaults, any needed `FM_COMPOSER_IDLE_RE` empty-composer override plus any novel bare agent prompt glyph in `bin/fm-composer-lib.sh`'s shared composer classifier (the one fleet-wide owner of the empty/dead-shell/pending decision, so a new harness's own idle composer is not misread as a dead shell), the tmux agent-process liveness classification in `bin/backends/tmux.sh` when the harness can launch a secondmate, and the verified knowledge here.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness` (absent or `default` -> own).
`bin/fm-harness.sh secondmate` resolves the secondmate-launch harness through the chain `config/secondmate-harness` -> `config/crew-harness` -> own, so an unset `config/secondmate-harness` matches the crew harness.
`bin/fm-spawn.sh` uses `crew` mode for a crewmate/scout launch and `secondmate` mode for a `--secondmate` launch, re-resolving on every spawn so the split is durable across respawns; an explicit per-spawn harness arg overrides either.
On `unknown`, ask the captain instead of guessing.
A captain override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## Primary turn-end guard

Every verified primary harness has an empirically validated hook path for the "no turn ends blind" guard.
`claude` and `codex` block directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`opencode`, `pi`, and `grok` expose passive lifecycle callbacks for this purpose, so their tracked primary adapters force one bounded follow-up or resume when the shared predicate blocks.
The exact hook files, commands, validation transcripts, scoping rules, and fail-open tradeoffs are owned by `docs/turnend-guard.md`.
When changing any primary turn-end hook, validate the real harness behavior in a scratch project or throwaway home before trusting it, then update that doc and the relevant concise fact below.

## Primary pre-arm (PreToolUse) seatbelt

Every verified primary harness also has a wired PreToolUse-equivalent hook that denies a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs.
`claude` and `codex` block directly through PreToolUse hooks; `grok` blocks the same way but requires every `$VAR` reference in its hook `command` string to carry an inline `:-default` or it fails to launch the hook entirely.
`opencode` and `pi` block by throwing from `tool.execute.before` / returning `{block: true}` from `tool_call`.
The exact hook files, commands, output-shaping quirks (Claude Code only honors the deny when stdout is empty), and validation transcripts are owned by `docs/arm-pretool-check.md`.
When changing any primary PreToolUse hook, validate the real harness behavior in a scratch project before trusting it, then update that doc.

## Primary watcher supervision

At session start, `bin/fm-session-start.sh` prints exactly one watcher supervision block for the detected primary harness.
Do not substitute another harness's wait shape when resuming supervision.
Claude and Grok use tracked background-notify cycles around `bin/fm-watch-arm.sh`.
Codex uses bounded foreground checkpoints through `bin/fm-watch-checkpoint.sh` because Codex cannot reason while a foreground tool call is running.
OpenCode uses `.opencode/plugins/fm-primary-watch-arm.js`, which coordinates with the turn-end guard plugin and wakes the TUI with `client.session.promptAsync`.
Pi uses the tracked `.pi/extensions/fm-primary-turnend-guard.ts` plus the tracked `.pi/extensions/fm-primary-pi-watch.ts`, both project-local extensions Pi auto-discovers once trusted.
When changing any primary watcher adapter, update `docs/supervision-protocols/`, `docs/turnend-guard.md` if a shared idle or turn-end hook changed, and the relevant concise fact below.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values chosen by firstmate at intake.
Do not make the shell scripts parse or match natural-language dispatch rules.
The supported launch-profile flags below were verified locally on 2026-06-30 with each CLI's help and parser path.

| Harness | Model flag | Effort flag | Notes |
|---|---|---|---|
| claude | `--model <model>` | `--effort <low\|medium\|high\|xhigh\|max>` | Verified on Claude Code 2.1.196. |
| codex | `--model <model>` | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` | Verified on codex-cli 0.142.1. The installed binary schema contains `model_reasoning_effort`, the active config uses it, and the bundled model catalog advertises only low/medium/high/xhigh. `max` is omitted. |
| grok | `--model <model>` | `--reasoning-effort <low\|medium\|high\|xhigh>` | Verified on grok 0.2.73. `--effort` parses too, but firstmate's profile axis is reasoning effort. `--reasoning-effort max` is rejected, so `max` is omitted. |
| pi | `--model <model>` | `--thinking <low\|medium\|high\|xhigh>` | Verified on pi 0.80.2. `max` prints an invalid-thinking warning, so firstmate omits Pi effort when the requested effort is `max`. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |
| cursor | `--model <id>` | none (effort is a suffix in the id) | Verified on cursor-agent 2026.07.09. The id carries the effort, e.g. `gpt-5.6-sol-medium` (suffixes `-none\|-low\|-medium\|-high\|-xhigh\|-max`). The documented `<model>[effort=<level>]` bracket form is rejected by the installed CLI, so firstmate passes the full suffixed id and emits no effort flag. |
| agy | `--model <name>` | none (effort is baked into the name) | Verified on agy 1.1.1. `--model` takes a display name from `agy models`, e.g. `'Gemini 3.1 Pro (High)'` or `'Claude Opus 4.6 (Thinking)'`, whose effort is part of the name. No separate effort flag. |

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness.
This preserves launch success instead of passing a known-bad value.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- cursor: no separate verified skill invocation for `no-mistakes`; use natural language. cursor has its own `/`-style slash commands and a distinct skills store, but its discovery of the user-level `no-mistakes` skill is unverified.
- agy: no separate verified skill invocation for `no-mistakes`; use natural language.
- grok: `/<skill>`, for example `/no-mistakes` (same form as claude). Verified end to end: grok discovers the user-level `no-mistakes` skill, `/no-mistakes` invokes it, and grok drives a real `no-mistakes axi run`. Like codex's `$`/`/` popups, typing `/<skill>` opens grok's slash-autocomplete, so a too-fast Enter selects the popup entry instead of sending, and for an argument-taking command (like `/no-mistakes`'s optional task-first argument) that first Enter only expands the popup selection into an argument-hint placeholder rather than submitting - a genuine second Enter is required (see the grok section below for the 2026-07-03 incident and fix). `fm_tmux_submit_core`'s retried Enter (used by `fm-send` on the tmux backend) already handles this correctly by reading the cursor row; the herdr backend needed a dedicated fix (`fm_backend_herdr_composer_state`, docs/herdr-backend.md) because its prior delta-based verification false-positived on that same popup-close content change.

## claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`) |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds.
If such a dialog is showing, accept it from an active firstmate session using `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Enter`, or the choice the dialog requires, unless `FM_HOME` is already set to the active firstmate home; verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes.
A plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents through `bin/fm-spawn.sh`, so it never touches the captain's global config.
The CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive composer ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the shared `fm_composer_strip_ghost` extractor in `bin/fm-composer-lib.sh` removes dim/faint SGR 2 ghost runs before pending-input classification on both ANSI-capable readers (tmux and herdr).
Its broader dark-TRUECOLOR placeholder handling and dark-theme tradeoff are documented in `docs/herdr-backend.md`'s 2026-07-10 incident record.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

**Primary-session guard fact (verified 2026-07-04, Claude Code 2.1.201; preserved 2026-07-08, Claude Code 2.1.204).**
This is separate from the per-task crewmate turn-end hook above (that one just `touch`es a marker file in a task's own `.claude/settings.local.json`).
The firstmate PRIMARY's own `.claude/settings.json` registers `bin/fm-turnend-guard.sh` as a Stop hook, and exiting with status 2 plus stderr reliably forces the model to continue.
Claude Code's stdin payload to a Stop hook carries a `stop_hook_active` boolean that is `true` exactly when the current stop attempt is itself a forced continuation from an earlier block this turn; a hook can and should use that as its own loop-guard (always allow the stop when it is already `true`) rather than tracking state itself.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root.
After those settings are loaded, hook command resolution is still cwd-sensitive because Claude Code runs commands through `/bin/sh` against the session's current cwd; keep the tracked command anchored through `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh` and see `docs/turnend-guard.md` for the verified Stop-hook details.
Claude Code's primary watcher protocol is the lowest-friction path: run `bin/fm-watch-arm.sh` as its own Claude Code background task and treat background-task completion as the wake.

## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` (shown as `• Working (Xs • esc to interrupt)`) |
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; `fm-send` handles it) |
| Interrupt | single Escape |
| Skill invocation | `$<skill>` (e.g. `$no-mistakes`); `/<skill>` is claude-only and codex rejects it as "Unrecognized command" |

A `$<skill>` invocation opens a `$`-autocomplete (skill) popup, the same hazard as the `/` slash popup: submitting too fast lets the popup swallow the Enter, so the invocation never lands.
`fm-send` handles it the same way it handles `/` - it gives the popup a longer settle (1.2s) between typing and the first Enter, with the target backend's submit retry as the safety net - but the `$` settle is scoped to `harness=codex`, read from the target metadata for exact task ids or legacy `fm-<id>` labels.
That scope matters because, unlike `/`, a leading `$` commonly starts ordinary text (`$5/month`, `$HOME`), so a universal `$` rule would needlessly slow plain steers to claude/opencode/pi; only a codex target receiving a `$...` message gets the popup-settle.
An explicit `session:window` target has no meta, so its harness is unknown and treated as non-codex (the safe fast-path default).
This is why the validation trigger (`$no-mistakes`) to a codex crew now lands on the first Enter instead of biting the popup.

Directory trust dialog on first run per repo root: "Do you trust the contents of this directory?"
Accept with Enter.
The decision persists for the repo, so later worktrees of the same project skip it.

Resume after exit with `codex resume <session-id>`.
The session id is printed on quit.

**Primary-session guard fact (verified 2026-07-08, codex-cli 0.142.1).**
The firstmate PRIMARY's own `.codex/hooks.json` registers a Stop hook that pipes Codex's Stop payload to `bin/fm-turnend-guard.sh`.
Codex Stop hooks block on exit 2 and expose `stop_hook_active` for the same one-block loop safety Claude uses.
Codex's Stop payload includes `cwd`, but the tracked primary hook does not use it to choose the guard executable.
Verified on 2026-07-08: Codex runs the Stop hook command with process PWD set to the hook-loaded project root, and no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is firstmate-shaped and hook-bearing, and then invokes `bin/fm-turnend-guard.sh` with the original payload.
Codex's primary watcher protocol is `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `bin/fm-watch-arm.sh`.
The checkpoint is deliberately foreground and bounded so Codex regains control regularly to process user messages and queued wakes.

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.6)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt` (dotted spinner footer; note no "to") |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch |

No trust dialog.
Opencode can auto-upgrade itself in the background and the running TUI can exit mid-task, observed live from 1.15.7 to 1.17.3.
If a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

**Primary-session guard fact (verified 2026-07-08, OpenCode 1.17.6).**
The firstmate PRIMARY's own `.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `bin/fm-turnend-guard.sh` returns 2.
The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher wake supervision and coordinates with the guard plugin before the guard tries a blind-turn follow-up.
The follow-up was verified in the interactive TUI; `opencode run` can exit before displaying a queued follow-up, so the adapter is fail-open in headless mode.

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

**Primary-session guard fact (verified 2026-07-09, Pi 0.80.5).**
The firstmate PRIMARY's own `.pi/extensions/fm-primary-turnend-guard.ts` listens for logical-run `agent_settled`, not per-tool-loop `turn_end`, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when `bin/fm-turnend-guard.sh` returns 2.
Without `deliverAs: "followUp"`, Pi rejects the send while the agent is still processing.
Pi's primary watcher protocol also requires the tracked `.pi/extensions/fm-primary-pi-watch.ts` extension, same trust-once discovery as the turn-end guard.
The model arms through `fm_watch_arm_pi`, never a foreground bash arm; the watcher tool result and clean-exit fallback are owned by `docs/supervision-protocols/pi.md`.
`bin/fm-session-start.sh` reports when the live Pi session has not loaded both the turn-end guard and watcher extensions, and points at plain `pi` after project trust as the fix, with `-e` as a trust-free fallback.
When a secondmate is launched on Pi, `fm-spawn.sh --secondmate` launches Pi with both `-e .pi/extensions/fm-primary-turnend-guard.ts` and `-e .pi/extensions/fm-primary-pi-watch.ts`, both already present in the secondmate home's git worktree.

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

**TRUECOLOR placeholder styling: covered (task afk-herdr-false-pending, 2026-07-10).**
A freshly-dismissed, never-typed-into grok composer shows a placeholder ("Type a message...") styled with a dark 24-bit TRUECOLOR foreground, not the SGR-2 dim/faint attribute the ghost stripper originally detected.
The shared ANSI-aware owner `fm_composer_strip_ghost` (`bin/fm-composer-lib.sh`) now drops a dark/muted truecolor foreground (perceived luminance below `FM_COMPOSER_GHOST_LUMA_MAX`, default 128) as well as dim/faint, so the placeholder is stripped and the row reads empty on both ANSI-capable backends (tmux and herdr route through the same owner).
Verified live against grok 0.2.93: real input is the bright `38;2;224;222;244` (luminance ~225, kept), while grok's borders and placeholder/hint text are dark truecolor (`38;2;50;47;70` .. `38;2;110;106;134`, luminance ~51..110, dropped).
This assumes a dark terminal theme, the fleet reality; the SGR-2 signal stays theme-independent.
Regression coverage: `tests/fm-composer-ghost.test.sh` (`test_strip_ghost_drops_dark_truecolor_ghost`, `test_dark_truecolor_ghost_only_composer_is_not_pending`) and `tests/fm-backend-herdr.test.sh` (`test_composer_state_grok_dark_truecolor_placeholder_is_empty`, `test_composer_state_grok_bright_truecolor_real_text_is_pending`).

**Residual gap, tmux-only (unfixed):**
in that same pristine placeholder-only state, tmux's own `#{cursor_y}` points at the composer box's BOTTOM BORDER row, one row below the actual text row (the box appears to render one row lower before any real typing starts); once real text is typed the cursor correctly aligns with the text row again.
This is a row-SELECTION quirk, orthogonal to the styling fix above, and affects only the tmux path (herdr uses a structural composer-row scan, not `cursor_y`, so it is unaffected).
A correct fix needs a row-window read near `cursor_y` rather than the single `cursor_y` row.
In practice `fm-spawn` launches grok with the brief as its initial prompt, so a live task's composer is never observed in this pristine pre-typing state - but this is unverified for every path (e.g. a steer sent before grok's first real turn settles) and needs dedicated investigation before relying on it.

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

**Primary-session guard fact (verified 2026-07-08, Grok 0.2.91).**
The firstmate PRIMARY's own `.grok/hooks/fm-primary-turnend-guard.json` invokes `bin/fm-turnend-guard-grok.sh`.
Grok Stop hooks are passive for this purpose: exit 2 does not make the model continue.
The adapter therefore runs the shared predicate and, when it returns 2, forces one same-session follow-up with `grok --resume <sessionId> -p <guard-reason>` while setting `GROK_TURNEND_GUARD_ACTIVE=1` so the nested Stop hook does not recurse.
It does not pass `--permission-mode`, so the passive hook cannot escalate the primary session's tool permissions.
Project-local Grok hooks require folder trust, verified with launch-time `--trust`; if the primary firstmate checkout is not trusted for Grok hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.
Grok's primary watcher protocol is Claude-shaped background-notify around `bin/fm-watch-arm.sh`; the passive Stop hook is only a backstop for blind turn ends.

## cursor (VERIFIED 2026-07-12, cursor-agent 2026.07.09-a3815c0)

Cursor Agent CLI (`cursor-agent`), verified as a CREW and secondmate adapter, not as the firstmate primary.
Launch with a positional prompt: `cursor-agent --force --model <id> "$(cat <brief>)"`.
The `cursor-agent` binary is a bash launcher that execs Node with `exec -a "$0"`, so the pane command and process name stay `cursor-agent` (not a bare `node`).

| Fact | Value |
|---|---|
| Busy-pane signature | `ctrl+c to stop` (footer stop hint shown iff a turn is running; the spinner line reads `⠘⠣ Working`). Idle footer shows only the placeholder `→ Add a follow-up`. The ASCII `ctrl+c to stop` is the busy regex (avoids the braille spinner glyph). |
| Exit command | double `Ctrl+C` within ~1s (`Press Ctrl+C again to exit`). Prints `To resume this session: agent --resume=<conversationId>`. |
| Interrupt | single `Ctrl+C` (cancels the current turn; footer shows `ctrl+c to stop` mid-turn). |
| Skill invocation | no separate verified `no-mistakes` invocation; use natural language (cursor has its own slash commands and skills store). |
| Autonomy | `--force` (alias `--yolo`); auto-approves every tool execution, footer shows `Run Everything`. Verified to run fully unattended. |
| Env marker | `CURSOR_AGENT=1`, set for child/tool processes (also `CURSOR_INVOKED_AS=cursor-agent`). It does NOT set `CLAUDECODE`. |
| Resume | `cursor-agent --resume=<conversationId>` (id printed on exit and exported as `CURSOR_CONVERSATION_ID`), `--continue` (most recent for the cwd), or bare `--resume` (session picker). |

Model and effort: `--model <id>` where the id carries the effort as a suffix, e.g. `gpt-5.6-sol-medium` (`-none`/`-low`/`-medium`/`-high`/`-xhigh`/`-max`).
The documented `<model>[effort=<level>]` bracket-override form is rejected by this CLI (`Cannot use this model`), and the rejection prints the full accepted id set.
So firstmate folds the requested effort into the model id and passes no separate effort flag.

Trust dialog on first launch in a not-yet-trusted directory: `⚠ Workspace Trust Required ... ▶ [a] Trust this workspace / [q] Quit`.
Accept from an active firstmate session with `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Enter` (Enter selects the highlighted Trust option; `a` also works).
The `--trust` flag is print/headless-mode only, so it cannot pre-trust the interactive crew launch; accept the dialog after spawn instead.
The decision persists per directory, so later launches in the same worktree skip it.

Composer: an idle cursor composer shows the placeholder `→ Add a follow-up` rendered dim (SGR 2), which the shared `fm_composer_strip_ghost` strips, so `fm_tmux_composer_state` reads it as `empty` (verified live). No `FM_COMPOSER_IDLE_RE` override is needed.

Turn-end hook: cursor fires a `stop` hook at every turn boundary once the workspace is trusted, the clean equivalent of claude's Stop hook.
`fm-spawn` installs a per-worktree `.cursor/hooks.json` (`{"version":1,"hooks":{"stop":[{"command":"touch <turnend>"}]}}`) that touches the task's `state/<id>.turn-ended`; it is gitignore-excluded via git info/exclude and removed by `fm-teardown`, exactly like the other harnesses' worktree hook files.
Verified live: the inline single-file form touches the marker when the agent completes a turn.

## agy (VERIFIED 2026-07-12, agy 1.1.1)

Antigravity CLI (`agy`), a native binary, verified as a CREW and secondmate adapter, not as the firstmate primary.
Launch with an initial interactive prompt: `agy --dangerously-skip-permissions --model <name> -i "$(cat <brief>)"` (`-i` is `--prompt-interactive`; the non-interactive `-p`/`--print`/`--prompt` is NOT for a crew pane).

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to cancel` (footer cancel hint shown iff a turn is running; the verb line reads `Working...` or `Generating...`). Idle footer shows `? for shortcuts`. `esc to cancel` is the busy regex because it is stable across agy's changing verb lines. |
| Exit command | double `Ctrl+C` within ~1s (`press ctrl+c again to exit`). Prints `Resume with -c (or command below): agy --conversation=<id>`. |
| Interrupt | single `Escape` (`⎿ Interrupted · What should Antigravity CLI do instead?`). `Ctrl+C` is the exit key, not the interrupt. |
| Skill invocation | no separate verified `no-mistakes` invocation; use natural language. |
| Autonomy | `--dangerously-skip-permissions`; auto-approves every tool request. Verified to run fully unattended. |
| Env marker | `ANTIGRAVITY_AGENT=1`, set for child/tool processes (also `ANTIGRAVITY_CONVERSATION_ID`). |
| Resume | `agy -c` / `--continue` (most recent) or `agy --conversation=<id>` (id printed on exit and exported as `ANTIGRAVITY_CONVERSATION_ID`). |

Model and effort: `--model <name>` where `<name>` is a display string from `agy models`, e.g. `'Gemini 3.1 Pro (High)'` or `'Claude Opus 4.6 (Thinking)'`.
The effort is baked into the name (`(High)`/`(Medium)`/`(Low)`/`(Thinking)`), so there is no separate effort flag; firstmate quotes the whole name into `--model`.

Trust dialog on first launch in a not-yet-trusted project: `Do you trust the contents of this project? ... > Yes, I trust this folder / No, exit. ↑/↓ Navigate · enter Confirm`.
Accept with Enter (the highlighted option is Trust).

Composer: an idle agy composer is a lone `> ` prompt glyph (a 256-colour, not dim, foreground) drawn inside a box whose top and bottom are horizontal `───` rule rows, with no side border on the input row.
A single-row read of that bare `>` would classify as a dead-shell `unknown`, so the tmux composer reader (`fm_tmux_composer_state`) treats a lone shell-prompt glyph flanked by pure horizontal-rule rows as a genuine composer box and reads it as `empty` (`fm_tmux_row_is_rule` in `bin/fm-tmux-lib.sh`).
A real dead-shell prompt is not flanked by rule rows, so its unsafe-to-inject `unknown` verdict is preserved.
Residual gap (unfixed, low-impact): if agy ever renders the cursor on a border row instead of the `>` row (a pristine pre-typing quirk seen on other harnesses), the content row would be a rule and read `pending`; a live crew launched with the brief is past that state.

Turn-end hook: agy exposes no verified trust-free per-turn turn-end hook.
Its `hooks.json` / `mcp_config.json` system surfaces only internal framework hooks (`captureUserRequests`, `generateContextSummary`, `PreInvocation`, `OnShellCommandFinished`), no confirmed trust-free per-turn `stop` event, and writing into `~/.gemini` is high blast radius.
So `fm-spawn` installs no hook for agy and the watcher relies on stale-pane detection driven by the `esc to cancel` busy signature disappearing at turn end.
This is coarser than a precise per-turn hook but is the same busy-signature mechanism the watcher already uses fleet-wide.
