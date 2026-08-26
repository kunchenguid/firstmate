# Harness adapter verification

Audience: maintainer verification.

Stand 2026-08-26.
These are the version-scoped VERIFIED facts that used to sit inside the `harness-adapters` skill.
That skill is now a pointer; this record is the single owner of the per-adapter evidence below, and every dated claim here carries a verification debt: when a harness upgrades, re-run the live guard named in [`../verification/runtime-backends.md`](runtime-backends.md) and refresh the affected row, or strike the claim rather than let it rot into a false one.
Exact task chronology, branch names, temporary homes, and delivery transcripts remain in private reports or PR evidence.

The executable owners stay authoritative over anything below them: `bin/fm-spawn.sh` for per-task launch mechanics, `bin/fm-control-lib.sh` for interrupt, exit, relaunch, and supported task kinds, `bin/fm-busy-lib.sh` for busy verdicts and source attribution, `bin/fm-composer-lib.sh` for every composer shape and the `empty`/`pending`/`pending-unproven`/`unknown` decision, and `bin/fm-harness.sh` for detection.
A newly verified adapter is not reachable by the control plane until its rows land in those owners.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
Within the Pi family, only the exact launch-boundary marker `FM_PI_HARNESS=pi-signed` alongside `PI_CODING_AGENT=true` selects the signed identity; unmarked shared launcher ancestry remains `pi`.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness` (absent or `default` -> own).
`bin/fm-harness.sh secondmate` resolves the secondmate-launch harness through the chain `config/secondmate-harness` -> `config/crew-harness` -> own.
`bin/fm-spawn.sh` uses `crew` mode for a crewmate or scout launch and `secondmate` mode for a `--secondmate` launch, re-resolving on every spawn so the split is durable across respawns; an explicit per-spawn harness arg overrides either.
On `unknown`, ask the captain instead of guessing; a captain override always beats detection.
For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values chosen at intake; the shell scripts never parse natural-language dispatch rules.
Effort precedence is an explicit per-task captain instruction first, then any applicable standing dispatch profile or secondmate pin, then the generic fallback.
The fallback uses `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design, scaling intermediate levels with complexity, uncertainty, blast radius, and open-ended reasoning.
When a verified adapter lacks `xhigh`, cap at its highest supported non-`max` level rather than omitting the intended effort silently, and never select `max` from the fallback.

| Harness | Model flag | Effort flag | Notes |
|---|---|---|---|
| claude | `--model <model>` | `--effort <low\|medium\|high\|xhigh\|max>` | Verified on Claude Code 2.1.196. |
| codex | `--model <model>` | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` | Verified on codex-cli 0.142.1. The installed binary schema contains `model_reasoning_effort`, the active config uses it, and the bundled model catalog advertises only low/medium/high/xhigh. `max` is omitted. |
| grok | `--model <model>` | `--reasoning-effort <low\|medium\|high>` | Verified on grok 0.2.99 (2026-07-13). `--effort` is an alias, but firstmate's profile axis is reasoning effort. As of 0.2.99 the ceiling is `high`; both `xhigh` and `max` are rejected with `use one of: high, medium, low`, so firstmate omits them. |
| pi / pi-signed | `--model <model>` | `--thinking <low\|medium\|high\|xhigh\|max>` | Verified 2026-07-27 on Pi and pi-signed 0.82.0. Both expose the same accepted thinking levels and completed the same model-qualified max-thinking smoke. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |
| kimi | `--model <model>` | none | Verified 2026-07-25 on Kimi Code CLI 0.29.1. |
| cursor | `--model <model>` | none | Verified 2026-08-11 on Cursor Agent CLI 2026.08.11-e8db854. No effort flag exists, so firstmate records the requested effort in task metadata and omits it from the launch. Validate ids against `cursor-agent --list-models` rather than assuming a low/medium/high family: the live catalog carries only `-high` Grok ids. |
| muse | `--model <model>` | `--reasoning-effort <low\|medium\|high\|xhigh>`, and `ultra` only for an explicit `max` | Verified 2026-08-05 on Muse Code 0.1.0-R708.1. The flag accepts `none\|minimal\|low\|medium\|high\|xhigh\|ultra` and defaults to `high`. `ultra` is muse's max-class level, so it is reachable only through an explicit captain `max`, never from the generic fallback; `none` and `minimal` sit below the shared vocabulary and stay unreachable. |

The concrete `harness` field owns adapter identity independently of the model provider: `harness=pi` with `model=xai/grok-*` is Pi using xAI, not `harness=grok`, and does not require Grok CLI login.
Likewise `harness=cursor` with `model=cursor-grok-4.5-*` is Cursor Agent CLI routing a Grok model, not the xAI Grok Build `grok` harness.
No script resolves that split for you: establish which credential store a tuple reads from the discovery surfaces below plus `quota-axi auth --json`'s per-provider sources, and show that reasoning rather than inferring it from a name.

### Model support discovery

Treat model and provider knowledge as current source-of-truth discovery, not as a permanent namespace or provider mapping.

| Harness | Authoritative discovery surface |
|---|---|
| claude | Open the current interactive session's `/model` picker; `claude --help` documents the accepted alias or full-model-name input shape. |
| codex | Open the current interactive session's `/model` picker. |
| opencode | Run `opencode models [provider]`, which lists available provider/model identifiers. |
| pi / pi-signed | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |
| grok | Run `grok models`, which lists the models available to the current Grok installation and account. |
| kimi | Run `kimi provider list --json`, which lists the current provider and model configuration. |
| cursor | Run `cursor-agent --list-models` (or the legacy `agent --list-models`), which lists the ids available to the current Cursor account. `cursor` is not the CLI name. |

A listing that reaches the account and does not contain the model is concrete evidence the model is unsupported: block that candidate and quote the result.
A discovery surface you could not reach establishes nothing; report that as uncertainty rather than turning it into a verdict.
When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag, preserving launch success instead of passing a known-bad value.

## Skill invocation forms

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode, pi, pi-signed: no separate verified skill invocation beyond normal command behavior; use natural language if uncertain.
- grok: `/<skill>`, same form as claude, verified end to end (grok discovers the user-level `no-mistakes` skill and drives a real `no-mistakes axi run`).
- kimi: `/<skill>`.
- cursor: `/<skill>`; Cursor discovers firstmate's user-level skills.

Slash and `$` popups swallow the first Enter on grok, codex, and cursor, and for an argument-taking command that first Enter only expands the selection into an argument-hint placeholder rather than submitting.
`fm_tmux_submit_core`'s retried Enter handles it through the shared structural composer classifier; the herdr backend needed a dedicated fix (`fm_backend_herdr_composer_state`) because its prior delta-based verification false-positived on that same popup-close content change.

### Submission acknowledgement hazards

A send or key action reporting success is not proof that the intended action happened.
OpenCode can accept and queue an Enter while leaving text visible, Grok can consume Enter in its slash popup without submitting, and Kimi can silently drop a message sent before readiness even though the send returns success.
The shared symptom is a healthy-looking pane with no work in progress, so each adapter must verify the observable postcondition specific to its TUI.

## Primary-session integrations

**Turn-end guard.**
The primary integrations for `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, and `cursor` have empirically validated hook paths for the "no turn ends blind" guard.
`claude` and `codex` block directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`opencode`, `pi`, and `pi-signed` expose passive lifecycle callbacks and force one bounded follow-up when the shared predicate blocks.
Grok selects native blocking or its pre-native bounded resume fallback from the exact running Stop payload.
Kimi is outside the primary turn-end guard scope, while `docs/turnend-guard.md` owns its separate guarded global hook for crew wake signals.
muse is CREWMATE and SCOUT ONLY and has no primary integration at all: its plugin engine is disabled in the default build, and its Claude-compatible hook dialect names `asyncRewake` and model reawakening as explicitly unsupported, so `bin/fm-spawn.sh` refuses a `--secondmate` launch on muse.
cursor HAS a full hooks system - 20 lifecycle events at project scope in `.cursor/hooks.json`, plus a Claude-Code compatibility name map that also loads `<project>/.claude/settings.json` - but its `stop` step cannot block (exit 2 there is a silent no-op), so `bin/fm-turnend-guard-cursor.sh` parks the turn boundary on the watcher and returns one bounded `followup_message`.
Because Cursor loads the tracked Claude settings too, every Claude-shaped entrypoint whose event Cursor covers stands down on a Cursor-delivered payload.
`docs/turnend-guard.md` owns the exact hook files, commands, scoping rules, and fail-open tradeoffs; `docs/verification/supervision.md` "Turn-end guard" owns active validation evidence.

**Pre-arm (PreToolUse) seatbelt.**
The same seven primaries have wired PreToolUse-equivalent hooks that deny a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs.
`claude` and `codex` block directly; `grok` blocks the same way but requires every `$VAR` reference in its hook `command` string to carry an inline `:-default` or it fails to launch the hook entirely.
`opencode`, `pi`, and `pi-signed` block by throwing from `tool.execute.before` or returning `{block: true}` from `tool_call`.
`docs/arm-pretool-check.md` owns the hook files, commands, output-shaping quirks (Claude Code only honors the deny when stdout is empty), and validation transcripts.

**Delegation-shape guard.**
Claude exposes built-in delegation, scheduling, and worktree tools that a primary session can use to create work with no `state/<id>.meta`, which makes the whole guard stack inert because every guard counts that metadata.
The shipped mechanism is `bin/fm-subagent-pretool-check.sh`, a primary-home PreToolUse guard that denies a delegation-SHAPED tool name.
Claude primaries should also use an untracked per-home local `permissions.deny` list, because it removes those tools from the model's schema so they are never offered; that list must not ship in tracked `.claude/settings.json`, which is harness-agnostic and propagates into linked worktrees where it would disarm legitimate crewmates.
Two verified facts: the subagent tool presents to the model as `Agent`, and on Claude Code 2.1.217 both `Agent` and `Task` work as `permissions.deny` keys, verified by an A/B with a nonsense-name control; `permissions.allow` is a pre-approval list rather than an availability list, so there is no fail-closed positive allowlist.
`docs/subagent-guard.md` owns the full contract, the `FM_ALLOW_SUBAGENT=1` escape hatch, and the per-harness applicability review.

**Watcher supervision.**
At session start, `bin/fm-session-start.sh` prints exactly one watcher supervision block for the detected primary harness; never substitute another harness's wait shape.
Claude's Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns tokenless re-arm around `bin/fm-watch-arm.sh`, and Grok uses tracked background-notify cycles around the same script.
Codex uses bounded foreground checkpoints through `bin/fm-watch-checkpoint.sh` because Codex cannot reason while a foreground tool call is running.
OpenCode uses `.opencode/plugins/fm-primary-watch-arm.js`, which coordinates with the turn-end guard plugin and wakes the TUI with `client.session.promptAsync`.
Pi and pi-signed use the tracked `.pi/extensions/fm-primary-turnend-guard.ts` plus `.pi/extensions/fm-primary-pi-watch.ts`, both project-local extensions the Pi engine auto-discovers once trusted.
`docs/sessionstart-nudge.md` owns session-open tier assignment, per-surface transports, source routing, the runtime bound, and fail-open behavior.

## claude (VERIFIED; busy-state hooks live-verified 2026-07-28 on Claude Code 2.1.220)

| Fact | Value |
|---|---|
| Busy state | Owned lifecycle hooks: `UserPromptSubmit` opens a turn, while `Stop`, `StopFailure`, and `SessionEnd` close it; because Claude fires no hook for a manual interrupt, `bin/fm-control.sh interrupt` reports only delivered keys and the verified endpoint or live agent, publishes no idle event, makes no cancellation claim, and leaves adapter-observed state unchanged, so a mid-turn worker typically remains busy via `claude-hook`. That busy verdict is overridden only when Claude Code's blocking auto-continue usage-limit widget renders in the pane's composer region - to paused for a widget that resolves itself, to blocked for its give-up rendering, which never resumes without a human; a bare limit notice alone leaves the worker working and merely annotates the detail - `fm_busy_claude_limit_banner` owns the wordings, the anchoring, and that deliberate limitation. |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, peek the pane within about 20 seconds and accept the dialog with `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> --key Enter`, then verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim/faint text inside an otherwise-empty composer after a turn completes, and a plain `tmux capture-pane` cannot tell that ghost text apart from typed text.
Firstmate launches every claude crewmate and secondmate with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped through `bin/fm-spawn.sh` so it never touches the captain's global config; the CLI's `--prompt-suggestions` flag is print/SDK-mode only and does not suppress the interactive ghost text, verified empirically on v2.1.186.
As defense in depth for any pane that flag cannot reach, `fm_composer_strip_ghost` removes dim/faint SGR 2 ghost runs before pending-input classification on every styled reader; that styled capture is internal to the boolean detector only, and `fm-peek` stays plain `tmux capture-pane`.

**Primary-session guard fact (verified 2026-07-04, Claude Code 2.1.201; preserved 2026-07-08, 2.1.204; Stop-owned auto-arm revalidated 2026-07-24, 2.1.219).**
The firstmate PRIMARY's own `.claude/settings.json` registers two Stop hooks: `bin/fm-turnend-guard.sh --claude` and the Stop-owned auto-arm `bin/fm-claude-stop-autoarm.sh` (`asyncRewake: true`, `timeout: 28800`), and exiting the guard with status 2 plus stderr reliably forces the model to continue.
Claude Code's stdin payload carries a `stop_hook_active` boolean that is `true` when the current stop attempt follows ANY stop-hook-driven continuation, including `asyncRewake` rewakes; the primary guard therefore ignores it in `--claude` mode and uses the cooperative claim/epoch check plus a bounded re-block budget instead, while codex-mode still treats it as a one-block loop guard.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory - so firstmate launches the primary from the repo root, and hook command resolution stays cwd-sensitive, so tracked commands are anchored through `"$CLAUDE_PROJECT_DIR"/bin/...`.

### claude-ox (VERIFIED as a control-plane adapter value, 2026-08-23)

`claude-ox` is a distinct verified adapter value for the claude family's Ox Alpha launch profile, the same family-variant pattern already used for `pi-signed` alongside `pi`.
Everything under `claude` above applies unchanged, because `fm_control_harness_family` folds `claude-ox` to `claude` by the same `claude*` prefix rule that already folds a raw launch command's basename such as `claude1`.
The distinct value exists only so a task's recorded `harness=` can name the Ox launch profile precisely instead of falling back to the un-reconstructable basename.

| Fact | Value |
|---|---|
| Launch | The `claude` launch shape with the `claude1 --ox` Ox Alpha wrapper in place of the bare `claude` binary. `claude1` is the Ox Alpha wrapper binary; `--ox` selects stealth/ox-alpha via OpenRouter. |
| Model flag | Never emitted. `claude-ox` is deliberately absent from `model_flag_for_harness`'s case table, because the wrapper pins stealth/ox-alpha and a `--model` flag would be billed on OpenRouter instead of routed free. A requested model is still recorded in task metadata but never reaches the launch command. |
| Effort flag | `--effort <low\|medium\|high\|xhigh\|max>`, same as `claude`. |
| Secondmate use | Technically capable, but the captain's dispatch policy keeps secondmates on account harnesses; that is a dispatch-profile choice, not a control-plane restriction. |

Verification evidence: `tests/fm-control-relaunch.test.sh`'s `test_relaunch_moves_a_task_onto_ox_and_back_to_an_account` exercises both directions end to end against the fake session provider, and `tests/fm-spawn-dispatch-profile.test.sh`'s `test_claude_ox_threads_effort_but_never_model` pins the launch-command shape.

## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a firstmate-launched worker. |
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; the shared submit path handles it) |
| Interrupt | single Escape |
| Skill invocation | `$<skill>`; `/<skill>` is rejected as "Unrecognized command" |

A `$<skill>` invocation opens a `$`-autocomplete popup with the same swallow hazard as `/`.
`fm-send` gives the popup a longer settle (1.2s) between typing and the first Enter, with the backend's submit retry as the safety net, but that settle is scoped to `harness=codex` read from the target metadata, because a leading `$` commonly starts ordinary text (`$5/month`, `$HOME`) and a universal rule would needlessly slow plain steers.
An explicit `session:window` target has no meta, so its harness is unknown and treated as non-codex.

Directory trust dialog on first run per repo root: "Do you trust the contents of this directory?", accepted with Enter; the decision persists for the repo, so later worktrees skip it.
Resume after exit with `codex resume <session-id>`; the session id is printed on quit.

**Primary-session guard fact (verified 2026-07-08, codex-cli 0.142.1).**
The primary's own `.codex/hooks.json` registers a Stop hook that pipes Codex's Stop payload to `bin/fm-turnend-guard.sh`; Codex Stop hooks block on exit 2 and expose `stop_hook_active`.
Codex runs the Stop hook command with process PWD set to the hook-loaded project root, and sets no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` variable, so the tracked hook anchors to `pwd -P`, verifies that root is firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.
Codex's primary watcher protocol is `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, deliberately foreground and bounded so Codex regains control regularly.

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.6; 1.18.4 busy-queue re-verified 2026-07-20)

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's semantic `session.status`: `busy` and `retry` are active, `idle` is inactive, latched to the worker's own session. |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so use `bin/fm-control.sh <task-id> relaunch` for a wedged pane |

No trust dialog.
Opencode can auto-upgrade itself in the background and the running TUI can exit mid-task, observed live from 1.15.7 to 1.17.3; if a pane shows the exit banner, relaunch with `--continue`, and note that `--prompt` does not auto-submit alongside `--continue`.

**Busy-queued Enter (opencode 1.18.4).**
Mid-turn, the composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane `fm-send` to a busy opencode pane exits non-zero on a false "Enter swallowed", and every daemon escalation landing mid-turn is treated as wedged.
Both tmux and herdr delegate this exception to `fm_composer_queued_enter_verdict`; regression coverage is `tests/fm-tmux-submit-busy.test.sh`, `tests/fm-composer-lib.test.sh`, and `tests/fm-backend-herdr.test.sh`, with the live Herdr Claude guard at `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

**Primary-session guard fact (verified 2026-07-08, OpenCode 1.17.6).**
`.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`; throwing there does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when the guard returns 2.
The follow-up was verified in the interactive TUI; `opencode run` can exit before displaying a queued follow-up, so the adapter is fail-open in headless mode.

## pi and pi-signed (VERIFIED 2026-07-27)

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned extension's `agent_start` (busy) and `agent_settled` confirmed by `ctx.isIdle()` (idle), which covers retries, compaction, tool loops, and queued continuations. |
| Exit command | `/quit` |
| Interrupt | single Escape |

Pi has no permission system, so crewmates are always autonomous.
Pi's settings documentation names `regular` as the `tuiMode` default and `fullscreen` as experimental; fullscreen can bury steers by rewriting scrollback, so Firstmate avoids it when the installed CLI supports the override.
`pi-signed` is the signed wrapper identity verified on 0.82.0 with the same CLI and TUI behavior; Firstmate records it without normalization and refuses rather than falling back to `pi` when the wrapper is unavailable.
The observed signed process tree is an exact `pi-signed` wrapper parent with the Pi application as its child, while tmux reports the foreground command as `pi-launcher` for both executables, and the installed plain `pi` command also execs that signed launcher - so `FM_PI_HARNESS=pi-signed` is the authoritative selection marker.
Keep the brief as one positional argument; multiple positional args become separate queued messages.

Project trust dialog can appear on the first pi run in any not-yet-trusted directory, observed even on clean worktrees; accept with Enter, and the decision persists per path in `~/.pi/agent/trust.json`.
`fm-spawn` keeps the turn-end extension in `state/`, outside the worktree, because project-local extension files make the trust gate strictly worse; the extension must listen for pi's `turn_end` event, not `agent_end`.
Pi sets `PI_CODING_AGENT=true` for its children; this is its harness-detection env marker.

**Primary-session guard fact (verified 2026-07-09, Pi 0.80.5).**
`.pi/extensions/fm-primary-turnend-guard.ts` listens for logical-run `agent_settled`, not per-tool-loop `turn_end`, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when the guard returns 2; without `deliverAs: "followUp"`, Pi rejects the send while the agent is still processing.
Pi's primary watcher protocol also requires the tracked `.pi/extensions/fm-primary-pi-watch.ts`, same trust-once discovery; the model arms through `fm_watch_arm_pi`, never a foreground bash arm.
`bin/fm-session-start.sh` reports when a live Pi-family session has not loaded both extensions, and points at the selected executable after project trust as the fix, with `-e` as a trust-free fallback.

## grok (VERIFIED 2026-06-29, grok 0.2.73; slash-submit re-verified 2026-07-03 on 0.2.82; reasoning-effort ceiling re-verified 2026-07-13 on 0.2.99; exit paths re-verified 2026-07-19 on 0.2.103)

Grok Build TUI (`grok`), a Claude-Code-compatible CLI from xAI, launched with a positional prompt: `grok --always-approve "$(cat <brief>)"`.

| Fact | Value |
|---|---|
| Busy state | The one remaining rendered-tail fallback, isolated to Grok until its structured lifecycle is live-verified: `Ctrl+c:cancel`, the mid-turn cancel hint shown in grok's keybind bar iff a turn is running. The idle bar shows only `Shift+Tab:mode │ Ctrl+.:shortcuts`. ASCII is matched rather than the braille spinner to avoid locale fragility. |
| Exit command | `/exit` typed into the composer exits cleanly and prints `Resume this session with: grok --resume <session-id>`; `Ctrl+Q` double-press within 1000ms remains a fallback; `Ctrl+D` is the quit key in VS Code family terminals; `Ctrl+C` is the interrupt, not the exit. |
| Interrupt | single `Ctrl+C`. `Esc` only moves focus to the scrollback, it does NOT interrupt. |
| Skill invocation | `/<skill>`, same as claude, with the popup hazard described above. |
| Autonomy | `--always-approve` (footer shows `· always-approve`); `--permission-mode bypassPermissions` is the stronger equivalent. |
| Env marker | `GROK_AGENT=1`, set for child/tool processes on grok 0.2.73. grok does NOT set `CLAUDECODE`, so the marker is unambiguous WHEN PRESENT, but not guaranteed present: a grok 1.0.0 hook process carries `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, and `GROK_WORKSPACE_ROOT` with no `GROK_AGENT`. Treat it as a fast path only; `bin/fm-harness.sh`'s ancestry walk is what guarantees identification. |
| Resume | `grok --resume <session-id>` (id printed on exit) or `grok -c` / `--continue`; `--fork-session` branches a new session id. |

**Incident (2026-07-03, herdr backend only, grok 0.2.82):** two grok/herdr crewmates were sent `/no-mistakes` via `fm-send`; both left it fully typed but unsubmitted for minutes (footer still `Enter:send`), and `fm-send` exited 0 with no error.
Reproduced live: the herdr adapter's submit-verification treated ANY pane-content change after Enter as "submitted", and the popup-close-with-placeholder-fill IS a visible content change even though nothing was sent.
The current tmux and Herdr adapters pass their captures and capability descriptors to `bin/fm-composer-lib.sh`, whose shared structural classifier sees placeholder-filled text on any proven content row as still pending, so the retry loop sends the needed second Enter.

Startup dialog: the "Run Grok Build in a project directory?" picker appears ONLY when grok launches from a non-project directory, and `fm-spawn` launches inside the treehouse worktree, so it never appears.
Pin `[hints] project_picker_disabled = true` in `~/.grok/config.toml` if a non-project launch ever needs to skip it.

**TRUECOLOR placeholder styling: covered (task afk-herdr-false-pending, 2026-07-10).**
A freshly-dismissed, never-typed-into grok composer shows a placeholder styled with a dark 24-bit TRUECOLOR foreground, not the SGR-2 dim/faint attribute the ghost stripper originally detected.
`fm_composer_strip_ghost` now drops a dark/muted truecolor foreground (perceived luminance below `FM_COMPOSER_GHOST_LUMA_MAX`, default 128) as well as dim/faint.
Verified live against grok 0.2.93: real input is the bright `38;2;224;222;244` (luminance ~225, kept), while borders and placeholder text are dark truecolor (`38;2;50;47;70` .. `38;2;110;106;134`, luminance ~51..110, dropped).
This assumes a dark terminal theme, the fleet reality; the SGR-2 signal stays theme-independent.
Regression coverage: `tests/fm-composer-ghost.test.sh` and `tests/fm-backend-herdr.test.sh`.

Turn-end hook: grok fires a `Stop` hook at every turn boundary.
grok loads PROJECT hooks only after the folder is granted hook-trust in `~/.grok/trusted_folders.toml`, which firstmate will not establish by editing grok's managed trust store, while GLOBAL hooks in `~/.grok/hooks/` are always trusted.
So `fm-spawn` installs ONE firstmate-owned global hook, `~/.grok/hooks/fm-turn-end.json` plus `fm-turn-end.sh`, guarded as a no-op for every non-firstmate grok session; its `Stop` command fires only when the current workspace holds a `.fm-grok-turnend` token pointer matching the registry under `~/.grok/hooks/fm-turn-end.d/`.
The hook reads `$GROK_WORKSPACE_ROOT`, always set for hooks and equal to the worktree, so it stays outside the worktree, needs no trust grant, and writes only firstmate-owned files.
`fm-teardown` removes the worktree pointer before returning a pooled worktree; secondmate spawns skip the pointer.

**Primary-session guard fact (verified 2026-07-28, Grok 0.2.112 and 0.2.73).**
`.grok/hooks/fm-primary-turnend-guard.json` invokes `bin/fm-turnend-guard-grok.sh`.
Grok 0.2.112 exposes native same-process Stop continuation in its running payload, while the genuine pre-native 0.2.73 payload omits that capability and still needs one guarded `grok --resume`.
The tracked Claude hook entries whose event Grok already covers skip themselves under `GROK_AGENT` or `GROK_HOOK_EVENT`, because Grok also loads Claude-compatible project settings and would otherwise create a second blocking path.
Project-local Grok hooks require folder trust, verified with launch-time `--trust`; without it the primary guard fails open and `fm-guard.sh` remains the next-command alarm.

## cursor (VERIFIED CREWMATE/SCOUT 2026-08-11 on tmux and 2026-08-12 on Herdr, SECONDMATE/PRIMARY 2026-08-13, Cursor Agent CLI 2026.08.11-e8db854)

| Fact | Value |
|---|---|
| Binary | Resolved through `fm_cursor_resolve_binary`. `cursor` is NOT the CLI: the installed names are `cursor-agent` and the legacy alias `agent`, both symlinked into `~/.local/share/cursor-agent/versions/<version>/cursor-agent`. The STABLE launcher is used, never the versioned target, which the CLI replaces on auto-update. |
| Launch | A positional prompt with `--trust`, `--yolo`, `--model <model>` when selected, and `--workspace <absolute-task-worktree>`, behind `env -u` of the foreign primary markers. |
| Models | Validate against `cursor-agent --list-models` for the current account rather than a fixed list; that list has already drifted once. The live catalog contains only `-high` Grok ids (`cursor-grok-4.5-high`, `cursor-grok-4.5-high-fast`) and several `xhigh` ids. |
| Busy state | Its own per-conversation transcript, folded on demand by `bin/fm-busy-lib.sh` (source `cursor-transcript`). Each turn is bracketed by a `role:user` open and a typed `turn_ended` close covering `success` and `aborted`, so unlike Claude's `Stop` hook this source covers manual interruption. Backend-agnostic, confirmed identical on tmux and Herdr. |
| Exit command | `/exit` |
| Interrupt | Single Escape. The composer returns to its placeholder rather than the cancelled prompt, so NO clear key is needed (unlike muse). `bin/fm-control-lib.sh` claims no cancellation acknowledgement: the aborted transcript close appeared within seconds in some runs and not within twenty in others. |
| Skill invocation | `/<skill>`; Cursor discovers firstmate's user-level skills. |
| Slash submission | The popup is REAL and swallows the first Enter; a SECOND submits, the same hazard as grok. |
| Autonomy | `--yolo`, the documented alias for `--force`, whose TUI footer reads `Run Everything`. |
| Trust dialog | `--trust` suppresses it. `--yolo` does NOT, and every task gets a fresh worktree path. |
| Environment marker | `CURSOR_INVOKED_AS=cursor-agent` on the agent process and its children, plus `CURSOR_AGENT=1` on child/tool processes. Other `CURSOR_*` variables are not identity markers. |
| Effort | No effort flag exists; the requested axis is recorded in task metadata only. |
| Composer | A BARE row whose prompt glyph is `→` (U+2192); no border. Idle placeholders are `Plan, search, build anything` fresh and `Add a follow-up` after a turn, drawn de-emphasised. |
| Primary hooks | Tracked project-scope `.cursor/hooks.json` registers `stop`, `sessionStart`, and two `preToolUse` seatbelts, anchored through `$CURSOR_PROJECT_DIR`. Cursor ALSO loads `<project>/.claude/settings.json`. |
| Primary limits | `stop` does not fire in headless `cursor-agent -p`. `preCompact` is deliberately unregistered because it cannot inject context, so a Cursor primary does not re-emit its digest after a compaction. Project hooks need `--trust`. |

**Detection ordering is load-bearing.**
Cursor does NOT clear an inherited `CLAUDECODE`, so a cursor worker under a claude primary carries both markers and whichever is tested first wins.
`bin/fm-harness.sh` tests the cursor markers BEFORE the `CLAUDECODE` check, and the launch additionally clears the foreign markers; both are kept, because launch sanitization only covers sessions fm-spawn started.

**The `node` process-name caveat.**
Cursor runs as a bundled node script, so tmux reports `#{pane_current_command}` as a bare `node` while `ps -o comm=` carries the cursor-agent install path.
`node` matches no harness name pattern, so identity comes from Cursor's own name or install tree in the path or argv[0]; an unrelated `node` or `agent` is deliberately left `other`, which liveness callers fold into `ambiguous` rather than `dead`.

**Cursor parks its terminal cursor outside its composer.**
`#{cursor_y}` pointed below the footer both when idle and with real text typed, and `#{cursor_flag}` was 0, so tmux's cursor row is not a composer locator for a Cursor pane.
`bin/fm-tmux-lib.sh` therefore reclassifies a pane it can prove is Cursor the way every cursorless backend already is, letting the bottom-most shape win, so `fm_tmux_composer_state` reports a real `empty` or `pending` (verified 2026-08-13).
That gate is Cursor's own structural process identity, never the verdict alone, so the strict blank-cursor-row posture stays in force elsewhere and a dead shell still never reads `empty`.
Submission is additionally acknowledged from the idle-to-busy transition, which is why cursor's `ctrl+c to stop` token is part of the delivery busy union; match that TOKEN and never the spinner verb, because the same version rendered `Working` in one turn and `Running` in the next.

**Delivery confirmation is verified on tmux and Herdr only.**
Herdr reports a Cursor pane `blocked` in EVERY state, so its native idle-baseline submit path is unreachable and the composer branch runs instead; `bin/backends/herdr.sh` confirms a Cursor submit from a rendered-footer idle-to-busy transition, taking the baseline before the first Enter so an already-busy pane never confirms.
Zellij, cmux, and Orca share a submit core that never consults that footer, so a typed-plane Cursor send there LANDS but `bin/fm-send.sh` reports delivery unconfirmed and exits non-zero; treat that as a known limitation of those three backends rather than a lost message.

Firstmate acquires and enters the treehouse worktree before launching Cursor, then passes that same absolute path through `--workspace`.
NEVER pass Cursor's own `-w/--worktree`: it allocates a SECOND worktree under `~/.cursor/worktrees` and would break firstmate's worktree-isolation contract.
The drift guard that refreshes the dated captures in `runtime-backends.md` "Cursor Agent CLI" is:

```bash
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

## kimi (VERIFIED 2026-07-25, kimi 0.29.1)

| Fact | Value |
|---|---|
| Binary | Executable `kimi` from `PATH`, then executable `$HOME/.kimi-code/bin/kimi`; spawning refuses if neither exists. |
| Launch | Bare interactive TUI with `--auto`, followed by readiness-gated pointer delivery; positional prompts are rejected. |
| Models | `kimi-code/kimi-for-coding` (default), `kimi-code/kimi-for-coding-highspeed`, `kimi-code/k3`, and `kimi-code/k3-256k`. |
| Busy state | Standalone Kimi is unknown until a semantic source is live-verified; prefer Wire's `prompt` request lifetime, then documented hooks including `Interrupt`. Kimi behind Pi uses Pi's lifecycle. Its moon-phase spinner is not a state source. |
| Exit command | `/exit` |
| Interrupt | Single Escape, which prints `Interrupted by user`. |
| Skill invocation | `/<skill>`; firstmate skills are discovered. |
| Autonomy | `--auto`; `-y` and `--yolo` are weaker and are not used. |
| Trust dialog | None on a clean first launch in a fresh pooled worktree. |
| Slash submission | One Enter submits, with no popup swallow or settle hazard. |
| Environment marker | None; detection relies on process ancestry command name `kimi`. |
| Composer | Bordered box with a bare `>` prompt glyph and no observed ghost or placeholder text. |
| Effort | No reasoning-effort flag exists. |

`fm-spawn.sh` launches Kimi bare, waits for the composer box or `Welcome to Kimi Code!`, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires a cleared composer plus either the echoed `✨` submission or nonzero context before accepting delivery.
This launch-then-send shape is mandatory because Kimi rejects a positional brief as an unknown command, and sending before readiness was reproduced as a silent drop with a zero exit status, an empty composer, `context: 0%`, and a healthy-looking idle pane.
The brief path must be absolute because the brief lives outside the task worktree, and Kimi reads it there without `--add-dir`.

Observed live spinner captures included optional leading whitespace, a moon-phase glyph, whitespace around `·`, and rotating tip text; the matcher requires that whitespace and does not require trailing tip text.
An early Enter can expand Kimi's composer to multiple content rows, the same single-cursor-row reading defect Grok's bottom-border quirk exposed, so the shared tmux reader locates the complete bordered composer and treats real text on any content row as pending.
Kimi's footer tip rotates independently and can display `ctrl+c: cancel` while completely idle, and the idle status bar can contain lowercase `thinking` as the model's effort label - which is why no Kimi rendered signature is a state source.
`fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one silent always-zero hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`; each crew worktree receives a gitignored `.fm-kimi-turnend` pointer, and the global hook touches `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding it did not fire.

## muse (VERIFIED 2026-08-05, Muse Code 0.1.0-R708.1, build sha 427a430436)

Muse Code is a CREWMATE and SCOUT adapter only; `bin/fm-spawn.sh` refuses `--secondmate` on muse, and a firstmate primary detected as muse falls back to the `unknown` supervision protocol.

| Fact | Value |
|---|---|
| Binary | Executable `muse` from `PATH`, resolved absolute; spawning refuses if absent. The installed launcher `~/.local/bin/muse` `exec`s `~/.local/bin/muse-bin-<version>`, so the LIVE process name carries the version and changes on every auto-update. |
| Launch | Positional prompt, the Grok/Pi shape. |
| Models | `--model <model>`; the only provider is `meta`. |
| Busy state | Its own durable session event log, folded on demand by `bin/fm-busy-lib.sh`. There is no hook or plugin writer, so nothing is armed and no busy record is ever seeded. |
| Exit command | `/exit`; one Enter submits it, and the pane prints `To continue this session, run muse resume <session-uuid>`. |
| Interrupt | Single Escape, which closes the run with `terminal: cancelled` AND restores the interrupted prompt into the composer as real bright text, so `fm-control` follows Escape with `C-u` to clear it. |
| Skill invocation | `/<skill>`. |
| Autonomy | `--yolo`, which disables approval, disables the sandbox, and trusts the workspace for the run. |
| Trust dialog | `Do you trust this workspace?` with `1 Trust and continue` preselected. `--yolo` suppresses it entirely, which is what firstmate relies on. |
| Environment marker | None. Detection is process ancestry on the anchored prefix `muse-bin-*`. `MUSE_CURRENT_SESSION_LOG` is a path rather than an identity. |
| Composer | Bordered box whose prompt glyph is `⟩` (U+27E9) in truecolor `38;2;90;160;255`, luminance ~149.9 - the narrowest margin over the 128 ghost threshold in the fleet. Typed text is `38;2;204;211;219` (~209.8). |
| Effort | `--reasoning-effort`, default `high`. |
| Resume | `muse resume --last` or `muse resume <session-uuid>`; bare `muse resume` opens a picker. |

**Credentials are a spawn preflight, not a screen check.**
muse reads `META_API_KEY` (which always wins) or a stored credential at `${XDG_CONFIG_HOME:-$HOME/.config}/muse/auth.json`.
`bin/fm-spawn.sh` accepts `META_API_KEY` only when it can prove the backend worker already has it, because a command-scoped caller variable does not cross a long-lived backend daemon and the secret must never enter launch argv.
It refuses the launch when neither worker-reachable path is present, because an unauthenticated pane does NOT exit: it sits on the device-code sign-in page indefinitely, which supervision would read as a wedged worker rather than a missing credential.
Escalate that refusal to the captain as a needed credential.

**Foreign personal context is a real privacy boundary.**
muse loads the OPERATOR's foreign personal rules from `~/.claude` into every run and ships them to Meta-hosted inference, printing a first-launch notice only once per config, so a silent later launch is still loading them.
An isolated `XDG_CONFIG_HOME` does NOT prevent this, and `--no-foreign-personal-context` is `muse exec` ONLY.
The control that reaches a pane worker is `MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on`, which `fm-spawn` sets on every muse launch; it was verified to drop the foreign `rules_file` block while KEEPING a project's own `AGENTS.md` rules.

**Session event log and the busy fold.**
Sessions persist to `${XDG_DATA_HOME:-$HOME/.local/share}/muse/sessions/YYYY/MM/DD/<session-uuid>/session.jsonl`, and `fm-spawn` writes `state/<id>.muse-session` pinning that root, the task worktree, its binding incarnation, and every pre-existing matching main log so the classifier binds a pane to its one new log.
Each submitted turn is bracketed by `{"payload":{"kind":"run","run_id":"<uuid>","event":{"kind":"started"` and a matching `"event":{"kind":"terminal"`, whose value was observed as `completed` and `cancelled`, so this source covers interruption.
Two traps the fold already handles: muse also emits nested `"record":{"kind":"terminal"}` cleanup payloads that are NOT run terminals, so the match is anchored on the full structural prefix; and muse's native sub-agents write independent run lifecycles one directory deeper, so the resolver is depth-bounded and folds only the main log.
Never use `--no-session-log` for a crewmate: it disables the only busy source muse has.
[`muse.md`](muse.md) owns the credentialed evidence for trusting idle and the post-upgrade refresh procedure.

**Native sub-agents and worktrees.**
muse fans out to its own sub-agents, but worktree isolation is per-child and opt-in, and no nested git worktree appeared in any verified lab run.
Firstmate deliberately does NOT exclude any muse path from `fm-teardown.sh`'s uncommitted-work check: it writes `.claude/settings.local.json` itself, which is why that path is excluded for claude, but it does not write muse's, so a nested muse worktree or leftover scratch is the agent's own work product and MUST be able to refuse teardown.

**Maturity caveats.**
muse is a day-0 `0.1.0` beta whose launcher polls a release channel hourly and can replace the running binary underneath the fleet, changing the process name with it.
The captain accepted that risk, so firstmate does NOT set `MUSE_NO_AUTO_UPDATE=1`.
Its plugin/hook engine reports `plugins are not available in this build` unless `MUSE_EXPERIMENTAL_PLUGINS=on`, which is why the busy source reads the session log instead of installing a hook.
