---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, pi, pi-signed, grok, kimi, cline, cursor-agent, copilot, and agy.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
Optional dispatch profiles in `config/crew-dispatch.json` can override that static default for one crewmate or scout dispatch by selecting concrete harness, provider, model, and effort axes at intake.
When a matched rule or default is a profile array, load `quota-array-dispatch` for the subscription-aware candidate choice after this skill establishes harness and model/provider facts.
The captain may override that file at session start or later; a per-task instruction such as "run this one on codex" overrides it for that dispatch only.
`default` means mirror firstmate's own harness.

Secondmates have their own harness knob, so a secondmate can run on a different adapter than crewmates.
`config/secondmate-harness` is the harness the primary uses to launch SECONDMATE agents, resolved through the fallback chain `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own.
An absent or `default` `config/secondmate-harness` therefore behaves exactly as the crew harness did before this knob existed (secondmates launched on the crew harness); setting it splits the two.
The [`secondmate-provisioning` skill](../secondmate-provisioning/SKILL.md) owns the complete inherited-local-material allowlist and propagation contract.
This skill owns only the harness-relevant consequence: a secondmate's own crewmates use the primary's inherited dispatch profiles and static harness value, while `config/secondmate-harness` is the primary's own setting and is never inherited - secondmates do not spawn secondmates.
Inheritance copies the literal `config/crew-harness` file, so for a secondmate's own crewmates to run on the primary's crewmate harness the captain must set `config/crew-harness` to a concrete adapter name, such as `codex`.
If `config/crew-harness` is unset or `default`, there is no concrete value to inherit, so the secondmate's own crewmates fall back to the secondmate's own/detected harness rather than the primary's effective crewmate harness.
Inheritance also copies the literal `config/crew-dispatch.json` file, so secondmates apply the same best-fit profile rules for their own crewmates.

Each adapter splits into mechanics and knowledge.
The per-task mechanics, including launch command, autonomy flag, and any enabled crewmate turn-end hook, live in `bin/fm-spawn.sh`.
The primary-session "no turn ends blind" guard contract and harness hook installation paths live in `docs/turnend-guard.md`.
The primary-session watcher wake protocols are rendered from `docs/supervision-protocols/` by `bin/fm-supervision-instructions.sh`.
The supervision knowledge lives here: busy state, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.
Each adapter's `Busy state` row names only which semantic source that harness uses; `bin/fm-busy-lib.sh` owns the contract itself, including verdicts, source attribution, and the verification gates that keep an unverified harness at unknown.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, tell the captain under `AGENTS.md` section 9 that the requested worker runtime is not verified yet, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime before future use.
Do not pause current work for that future-verification choice, and never launch an unverified adapter.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, its semantic busy source and trust gate in `bin/fm-busy-lib.sh`, any needed `FM_COMPOSER_IDLE_RE` empty-composer override plus any novel bare agent prompt glyph in `bin/fm-composer-lib.sh`'s shared composer classifier (the one fleet-wide owner of the empty/dead-shell/pending decision, so a new harness's own idle composer is not misread as a dead shell), the tmux agent-process liveness classification in `bin/backends/tmux.sh` when the harness can launch a secondmate, and the verified knowledge here.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
Within the Pi family, only the exact launch-boundary marker `FM_PI_HARNESS=pi-signed` alongside `PI_CODING_AGENT=true` selects the signed identity; unmarked shared launcher ancestry remains `pi`.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness` (absent or `default` -> own).
`bin/fm-harness.sh secondmate` resolves the secondmate-launch harness through the chain `config/secondmate-harness` -> `config/crew-harness` -> own, so an unset `config/secondmate-harness` matches the crew harness.
`bin/fm-spawn.sh` uses `crew` mode for a crewmate/scout launch and `secondmate` mode for a `--secondmate` launch, re-resolving on every spawn so the split is durable across respawns; an explicit per-spawn harness arg overrides either.
On `unknown`, ask the captain instead of guessing.
A captain override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts.

## Primary turn-end guard

The primary integrations for `claude`, `codex`, `opencode`, `pi`, `pi-signed`, and `grok` have empirically validated hook paths for the "no turn ends blind" guard.
`claude` and `codex` block directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`opencode`, `pi`, and `pi-signed` expose passive lifecycle callbacks and force one bounded follow-up when the shared predicate blocks.
Grok selects native blocking or its pre-native bounded resume fallback from the exact running Stop payload; [`docs/turnend-guard.md`](../../../docs/turnend-guard.md) owns that contract.
Kimi is outside the primary turn-end guard scope, while `docs/turnend-guard.md` owns its separate guarded global hook for crew wake signals.
The exact hook files, commands, scoping rules, and fail-open tradeoffs are owned by `docs/turnend-guard.md`.
`docs/verification/supervision.md` "Turn-end guard" owns active validation evidence.
When changing any primary turn-end hook, validate the real harness behavior in a scratch project or throwaway home before trusting it, then update that doc and the relevant concise fact below.

## Primary pre-arm (PreToolUse) seatbelt

The primary integrations for `claude`, `codex`, `opencode`, `pi`, `pi-signed`, and `grok` also have wired PreToolUse-equivalent hooks that deny a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs.
`claude` and `codex` block directly through PreToolUse hooks; `grok` blocks the same way but requires every `$VAR` reference in its hook `command` string to carry an inline `:-default` or it fails to launch the hook entirely.
`opencode`, `pi`, and `pi-signed` block by throwing from `tool.execute.before` / returning `{block: true}` from `tool_call`.
The exact hook files, commands, output-shaping quirks (Claude Code only honors the deny when stdout is empty), and validation transcripts are owned by `docs/arm-pretool-check.md`.
When changing any watcher-arm PreToolUse hook, validate the real harness behavior in a scratch project before trusting it, then update that doc.
## Primary delegation-shape guard

Claude exposes built-in delegation, scheduling, and worktree tools that a primary session can use to create work with no `state/<id>.meta`, which makes the whole guard stack inert because every guard counts that metadata.
The shipped mechanism is `bin/fm-subagent-pretool-check.sh`, a primary-home PreToolUse guard that denies a delegation-SHAPED tool name.
Claude primaries should also use an untracked per-home local `permissions.deny` list as hardening for known Claude delegation tools, because it removes them from the model's schema so they are never offered.
That deny list must not ship in tracked `.claude/settings.json` because it is Claude-only rather than harness-agnostic, and because tracked project settings propagate into linked worktrees where they disarm legitimate crewmates.
`docs/subagent-guard.md` owns the full contract, the local deny-list recommendation, the `FM_ALLOW_SUBAGENT=1` escape hatch, and the per-harness applicability review.

Two verified facts worth pinning here.
The subagent tool presents to the model as `Agent`, and on Claude Code 2.1.217 both `Agent` and `Task` work as `permissions.deny` keys, verified by an A/B with a nonsense-name control.
`permissions.allow` is a pre-approval list rather than an availability list, so there is no fail-closed positive allowlist.

## Primary session-start nudge

AGENTS.md section 3 remains the behavioral owner for session start, while tracked native adapters invoke `bin/fm-sessionstart-nudge.sh` as an idempotent enforcement layer.
The wrapper prints one canonically typed `session-start` instruction to run `bin/fm-session-start.sh`; it never runs the digest, wake drain, bootstrap sweeps, lock, or supervision arm itself.
Full mechanics, scoping, and fail-open behavior live in `docs/sessionstart-nudge.md`.
`docs/verification/supervision.md` "Native session-start delivery" owns active dated commands, payloads, and evidence.

- `claude`: verified native `SessionStart` stdout injection; `.claude/settings.json` matches `startup`, `resume`, and `clear`, but not `compact`.
- `codex`: verified on 0.144.4; `.codex/hooks.json` receives `source=startup`, and wrapper stdout reaches model context.
- `opencode`: verified on 1.17.18; `session.created` plus `client.session.promptAsync` starts the nudge turn in the TUI, while `opencode run` remains fail-open headless.
- `pi` and `pi-signed`: verified native `session_start`; the existing primary extension handles `startup`, `new`, and `resume` and uses `pi.sendMessage` to inject context without racing a positional launch prompt.
- `grok`: the 0.2.103 project `SessionStart` event fires with `source=new`, but stdout does not reach model context; the tracked project hook remains fail-open, and a global token-guarded fallback requires a captain decision.

## Primary watcher supervision

At session start, `bin/fm-session-start.sh` prints exactly one watcher supervision block for the detected primary harness.
Do not substitute another harness's wait shape when resuming supervision.
Claude's Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns tokenless re-arm around `bin/fm-watch-arm.sh`, and Grok uses tracked background-notify cycles around `bin/fm-watch-arm.sh`.
Codex uses bounded foreground checkpoints through `bin/fm-watch-checkpoint.sh` because Codex cannot reason while a foreground tool call is running.
OpenCode uses `.opencode/plugins/fm-primary-watch-arm.js`, which coordinates with the turn-end guard plugin and wakes the TUI with `client.session.promptAsync`.
Pi and pi-signed use the tracked `.pi/extensions/fm-primary-turnend-guard.ts` plus the tracked `.pi/extensions/fm-primary-pi-watch.ts`, both project-local extensions the Pi engine auto-discovers once trusted.
When changing any primary watcher adapter, update `docs/supervision-protocols/`, `docs/turnend-guard.md` if a shared idle or turn-end hook changed, and the relevant concise fact below.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--harness`, `--provider`, `--model`, and `--effort` values chosen by firstmate at intake.
Do not make the shell scripts parse or match natural-language dispatch rules.

Effort precedence is an explicit per-task captain instruction first, then any applicable standing dispatch profile or secondmate pin, then the generic fallback below.
Never replace an effort value supplied by either higher-precedence source.
Use the fallback only when neither the captain nor applicable standing configuration specifies effort.
Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design.
Choose intermediate levels proportionally as complexity, uncertainty, blast radius, or open-ended reasoning increases.
When a verified adapter lacks `xhigh`, cap the choice at its highest supported non-`max` level rather than omitting the intended effort silently.
Never select `max` from this fallback; use it only when the captain has explicitly expressed that per-task or standing preference.

The supported launch-profile flags below are verified locally; each row records its evidence.

| Harness | Model flag | Effort flag | Notes |
|---|---|---|---|
| claude | `--model <model>` | `--effort <low\|medium\|high\|xhigh\|max>` | Verified on Claude Code 2.1.196. |
| codex | `--model <model>` | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` | Verified on codex-cli 0.142.1. The installed binary schema contains `model_reasoning_effort`, the active config uses it, and the bundled model catalog advertises only low/medium/high/xhigh. `max` is omitted. |
| grok | `--model <model>` | `--reasoning-effort <low\|medium\|high>` | Verified on grok 0.2.99 (2026-07-13). `--effort` is an alias, but firstmate's profile axis is reasoning effort. As of 0.2.99 the ceiling is `high`; both `xhigh` and `max` are rejected with `use one of: high, medium, low`, so firstmate omits them. |
| pi / pi-signed | `--model <model>` | `--thinking <low\|medium\|high\|xhigh\|max>` | Verified 2026-07-27 on Pi and pi-signed 0.82.0. Both expose the same accepted thinking levels and completed the same model-qualified max-thinking smoke. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |
| kimi | `--model <model>` | none | Verified 2026-07-25 on Kimi Code CLI 0.29.1. |
| cline | `--model <id>` | `--thinking <low\|medium\|high\|xhigh>` | Verified 2026-07-27 on Cline CLI 3.0.46. `max` is omitted. |
| cursor-agent | `--model <id>` | none | Verified 2026-07-27 on Cursor CLI 2026.07; effort is not a firstmate launch flag for this adapter. |
| copilot | `--model <id>` | `--reasoning-effort <low\|medium\|high\|xhigh\|max>` | Verified 2026-07-28 on GitHub Copilot CLI 1.0.75; firstmate's shared effort vocabulary is a supported subset. |
| agy | `--model <id>` | `--effort <low\|medium\|high>` | Verified 2026-08-01 on Antigravity CLI 1.1.9. Base model ids require `--effort`; effort-baked model ids (`…-low`/`…-medium`/`…-high`) work alone; matching baked+effort works; conflict fails closed. Cap at `high`; omit `xhigh`/`max`. Preferred form: base model + `--effort`. |

The concrete `harness` field owns adapter identity independently of the model provider: `harness=pi` with `model=xai/grok-*` is Pi using xAI, not `harness=grok`, and does not require Grok CLI login; `harness=grok` remains the standalone Grok Build CLI adapter.
No script resolves that split for you: establish which credential store a tuple reads from the discovery surfaces below plus `quota-axi auth --json`'s per-provider sources, and show that reasoning rather than inferring it from a harness, model, or source name.

### Model support discovery

Treat model and provider knowledge as current source-of-truth discovery, not as a permanent namespace or provider mapping.
Use the discovery surface in the current authenticated environment because supported and available models can change by version, account, and configuration.

| Harness | Authoritative discovery surface |
|---|---|
| claude | Open the current interactive session's `/model` picker; `claude --help` documents the accepted alias or full-model-name input shape. |
| codex | Open the current interactive session's `/model` picker. |
| opencode | Run `opencode models [provider]`, which lists available provider/model identifiers. |
| pi / pi-signed | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |
| grok | Run `grok models`, which lists the models available to the current Grok installation and account. |
| kimi | Run `kimi provider list --json`, which lists the current provider and model configuration. |
| agy | Run `agy models`, which lists model ids available to the current Antigravity CLI install and account (includes effort-baked slugs). |

For an unfamiliar harness or model namespace, establish support and provider identity from that harness's authoritative CLI help, model listing, or current documentation rather than guessing from a name or prefix.
A listing that reaches the account and does not contain the model is concrete evidence the model is unsupported: block that candidate and quote the result.
A discovery surface you could not reach establishes nothing; report that as uncertainty rather than turning it into a supported or unsupported verdict.

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness.
This preserves launch success instead of passing a known-bad value.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi and pi-signed: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- grok: `/<skill>`, for example `/no-mistakes` (same form as claude). Verified end to end: grok discovers the user-level `no-mistakes` skill, `/no-mistakes` invokes it, and grok drives a real `no-mistakes axi run`. Like codex's `$`/`/` popups, typing `/<skill>` opens grok's slash-autocomplete, so a too-fast Enter selects the popup entry instead of sending, and for an argument-taking command (like `/no-mistakes`'s optional task-first argument) that first Enter only expands the popup selection into an argument-hint placeholder rather than submitting - a genuine second Enter is required (see the grok section below for the 2026-07-03 incident and fix). `fm_tmux_submit_core`'s retried Enter (used by `fm-send` on the tmux backend) handles this through the structural composer reader; the herdr backend needed a dedicated fix (`fm_backend_herdr_composer_state`, docs/herdr-backend.md) because its prior delta-based verification false-positived on that same popup-close content change.
- kimi: `/<skill>`, for example `/no-mistakes`.

## Submission acknowledgement hazards

A send or key action reporting success is not proof that the intended action happened.
OpenCode can accept and queue an Enter while leaving text visible, Grok can consume Enter in its slash popup without submitting, and Kimi can silently drop a message sent before readiness even though the send returns success.
The shared symptom is a healthy-looking pane with no work in progress, so each adapter must verify the observable postcondition that is specific to its TUI.

## claude (VERIFIED; busy-state hooks live-verified 2026-07-28 on Claude Code 2.1.220)

| Fact | Value |
|---|---|
| Busy state | Owned lifecycle hooks: `UserPromptSubmit` opens a turn, `Stop`, `StopFailure`, and `SessionEnd` close it. Claude fires no hook for a manual interrupt, so a firstmate-initiated interrupt must record the clear itself. |
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
Its broader dark-TRUECOLOR placeholder handling and dark-theme tradeoff are documented in `docs/herdr-backend.md` "Composer and injection safety", with active captures in `docs/verification/runtime-backends.md`.
That styled capture is internal to the boolean detector only.
`fm-peek` and every other human or LLM-facing capture path stays plain `tmux capture-pane` with no escape codes.

**Primary-session guard fact (verified 2026-07-04, Claude Code 2.1.201; preserved 2026-07-08, Claude Code 2.1.204; Stop-owned auto-arm revalidated 2026-07-24, Claude Code 2.1.219).**
This is separate from the per-task crewmate turn-end hook above (that one just `touch`es a marker file in a task's own `.claude/settings.local.json`).
The firstmate PRIMARY's own `.claude/settings.json` registers two Stop hooks: `bin/fm-turnend-guard.sh --claude` and the Stop-owned auto-arm `bin/fm-claude-stop-autoarm.sh` (`asyncRewake: true`, `timeout: 28800`), and exiting the guard with status 2 plus stderr reliably forces the model to continue.
Claude Code's stdin payload to a Stop hook carries a `stop_hook_active` boolean that is `true` when the current stop attempt follows ANY stop-hook-driven continuation, including `asyncRewake` rewakes; the primary guard therefore ignores it in `--claude` mode and uses the cooperative claim/epoch check plus a bounded re-block budget instead, while the codex-mode default still treats it as a one-block loop guard.
A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory looking for one, so firstmate launches the primary from the repo root.
After those settings are loaded, hook command resolution is still cwd-sensitive because Claude Code runs commands through `/bin/sh` against the session's current cwd; keep the tracked commands anchored through `"$CLAUDE_PROJECT_DIR"/bin/...` and see `docs/turnend-guard.md` for the verified Stop-hook details.
Claude Code's primary watcher protocol is Stop-owned: the auto-arm hook fires on every Stop and foregrounds `bin/fm-watch-arm.sh` when the home is eligible and still needs supervision, and its exit-2 `asyncRewake` rewake is the wake; the model drains and handles wakes but never runs a routine re-arm command.

## codex (VERIFIED 2026-06-11, codex-cli 0.139.0)

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a firstmate-launched worker. |
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

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.6; 1.18.4 busy-queue re-verified 2026-07-20)

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's semantic `session.status`: `busy` and `retry` are active, `idle` is inactive, latched to the worker's own session. |
| Exit command | `/exit` |
| Interrupt | double Escape; known flaky while a long shell command runs, so a wedged pane may need `/exit` and relaunch |

No trust dialog.
Opencode can auto-upgrade itself in the background and the running TUI can exit mid-task, observed live from 1.15.7 to 1.17.3.
If a pane shows the exit banner, relaunch with `--continue` to resume the session.
`--prompt` does not auto-submit alongside `--continue`, so send the next instruction via `fm-send` once the TUI is up.

**Busy-queued Enter (opencode 1.18.4, tmux backend fix, herdr known gap).**
While opencode is mid-turn, the composer accepts Enter as a "send when the turn
ends" keystroke but does not clear the typed text from the composer until the
turn actually finishes.
Without a fix, every `fm-send` to a busy opencode pane exits non-zero on a
false "Enter swallowed", and every daemon escalation that lands while the
primary is mid-turn is treated as wedged.
The shared `fm_tmux_submit_enter_core` (`bin/fm-tmux-lib.sh`) now falls back
to `fm_pane_is_busy` once the Enter-retry budget is spent: a busy pane means
the Enter was accepted and queued (reported as `empty` so the caller does not
re-send), while an idle pane keeps `pending` as a genuine swallow. The herdr
adapter observes the same opencode behavior but needs a separate fix; it is
recorded as a known gap in `docs/herdr-backend.md` rather than patched here,
so the tmux adapter does not paper over a herdr-specific shape.
Regression coverage: `tests/fm-tmux-submit-busy.test.sh` covers the four
scenarios (busy + pending -> `empty`, idle + pending -> `pending`, busy +
cleared -> `empty`, idle + cleared -> `empty`).

**Primary-session guard fact (verified 2026-07-08, OpenCode 1.17.6).**
The firstmate PRIMARY's own `.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `bin/fm-turnend-guard.sh` returns 2.
The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher wake supervision and coordinates with the guard plugin before the guard tries a blind-turn follow-up.
The follow-up was verified in the interactive TUI; `opencode run` can exit before displaying a queued follow-up, so the adapter is fail-open in headless mode.

## pi and pi-signed (VERIFIED 2026-07-27)

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned extension's `agent_start` (busy) and `agent_settled` confirmed by `ctx.isIdle()` (idle), which covers retries, compaction, tool loops, and queued continuations. |
| Exit command | `/quit` |
| Interrupt | single Escape |

Pi has no permission system, so crewmates are always autonomous.
`pi-signed` is the signed wrapper identity verified on version 0.82.0 and exposes the same CLI and TUI behavior as Pi.
Firstmate launches the selected executable name from `PATH`, records `pi-signed` without normalization, and refuses rather than falling back to `pi` when that wrapper is unavailable.
The observed signed process tree is an exact `pi-signed` wrapper parent with the Pi application as its child, while tmux reports the foreground command as the exact `pi-launcher` name for both selected executables.
The installed plain `pi` command also execs that signed launcher, so `FM_PI_HARNESS=pi-signed` is the authoritative selection marker and shared unmarked ancestry remains `pi`.
Firstmate sets `FM_PI_HARNESS` explicitly for both worker launch identities, and a signed primary uses the README launch command to establish the same boundary.
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
`bin/fm-session-start.sh` reports when the live Pi-family session has not loaded both the turn-end guard and watcher extensions, and points at the selected executable after project trust as the fix, with `-e` as a trust-free fallback.
When a secondmate is launched on Pi or pi-signed, `fm-spawn.sh --secondmate` launches the selected executable with both `-e .pi/extensions/fm-primary-turnend-guard.ts` and `-e .pi/extensions/fm-primary-pi-watch.ts`, both already present in the secondmate home's git worktree.

## grok (VERIFIED 2026-06-29, grok 0.2.73; slash-submit re-verified 2026-07-03 on 0.2.82; reasoning-effort ceiling re-verified 2026-07-13 on 0.2.99; exit paths re-verified 2026-07-19 on grok 0.2.103)

Grok Build TUI (`grok`), a Claude-Code-compatible CLI from xAI.
Launch with a positional prompt: `grok --always-approve "$(cat <brief>)"`.
For Grok's supported reasoning-effort values and omission behavior, see the [launch-profile-axes table](#launch-profile-axes).

| Fact | Value |
|---|---|
| Busy state | The one remaining rendered-tail fallback, isolated to Grok until its structured lifecycle is live-verified: `Ctrl+c:cancel`, the mid-turn cancel hint shown in grok's keybind bar iff a turn is running. The idle bar shows only `Shift+Tab:mode │ Ctrl+.:shortcuts`. ASCII is matched rather than the braille spinner to avoid locale fragility. |
| Exit command | `/exit` typed into the composer exits the TUI cleanly and prints `Resume this session with: grok --resume <session-id>`; `Ctrl+Q` double-press within 1000ms remains a fallback; `Ctrl+D` is the quit key in VS Code family terminals; `Ctrl+C` is the interrupt, not the exit. |
| Interrupt | single `Ctrl+C` (cancels the current turn; the footer shows `Ctrl+c:cancel` mid-turn). `Esc` only moves focus to the scrollback, it does NOT interrupt. |
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`), same as claude. Opens a slash-autocomplete popup, so a too-fast Enter selects the popup entry instead of sending. For an argument-taking command that first Enter does not submit at all - it expands the selection into an argument-hint placeholder in the composer (e.g. `/compact` -> `/compact compaction instructions`, live-verified), leaving real text still sitting there unsubmitted; a genuine second Enter is required. `fm-send`'s retried Enter lands it on BOTH backends, but only because each backend's own submit-verification correctly recognizes that placeholder-filled text as still-pending - see the incident below. |
| Autonomy | `--always-approve` (footer shows `· always-approve`); auto-approves every tool execution, verified to run fully unattended. `--permission-mode bypassPermissions` is the stronger equivalent. |
| Env marker | `GROK_AGENT=1`, set for child/tool processes. grok does NOT set `CLAUDECODE` despite Claude compatibility, so the marker is unambiguous. |
| Resume | `grok --resume <session-id>` (id printed on exit) or `grok -c` / `--continue` (most recent for the cwd); `--fork-session` branches a new session id. |

**Incident (2026-07-03, herdr backend only, grok 0.2.82):** two grok/herdr crewmates were sent `/no-mistakes` via `fm-send`; both left it fully typed but unsubmitted in the composer for minutes (footer still `Enter:send`), and `fm-send` exited 0 with no error.
Reproduced live: the herdr adapter's submit-verification at the time treated ANY pane-content change after Enter as "submitted", and the popup-close-with-placeholder-fill described above IS a visible content change even though nothing was actually sent.
The tmux backend's structural `fm_tmux_composer_state` read sees placeholder-filled text on any content row as still pending, so its retry loop sends the needed second Enter.
The Herdr adapter (`fm_backend_herdr_composer_state`, `bin/backends/herdr.sh`) classifies the composer's own row structurally instead of diffing raw content; see `docs/herdr-backend.md` "Composer and injection safety" for the current boundary and `tests/fm-backend-herdr.test.sh` for regression coverage.

Startup dialog: the "Run Grok Build in a project directory?" project picker appears ONLY when grok is launched from a non-project directory (home, Desktop, Downloads, `/tmp`).
`fm-spawn` launches inside the treehouse worktree (a git repo root), so the picker never appears and grok treats the worktree as a trusted project automatically - no post-launch keystroke is needed.
Pin `[hints] project_picker_disabled = true` in `~/.grok/config.toml` if a non-project launch ever needs to skip it.

**TRUECOLOR placeholder styling: covered (task afk-herdr-false-pending, 2026-07-10).**
A freshly-dismissed, never-typed-into grok composer shows a placeholder ("Type a message...") styled with a dark 24-bit TRUECOLOR foreground, not the SGR-2 dim/faint attribute the ghost stripper originally detected.
The shared ANSI-aware owner `fm_composer_strip_ghost` (`bin/fm-composer-lib.sh`) now drops a dark/muted truecolor foreground (perceived luminance below `FM_COMPOSER_GHOST_LUMA_MAX`, default 128) as well as dim/faint, so the placeholder is stripped and the row reads empty on both ANSI-capable backends (tmux and herdr route through the same owner).
Verified live against grok 0.2.93: real input is the bright `38;2;224;222;244` (luminance ~225, kept), while grok's borders and placeholder/hint text are dark truecolor (`38;2;50;47;70` .. `38;2;110;106;134`, luminance ~51..110, dropped).
This assumes a dark terminal theme, the fleet reality; the SGR-2 signal stays theme-independent.
Regression coverage: `tests/fm-composer-ghost.test.sh` (`test_strip_ghost_drops_dark_truecolor_ghost`, `test_dark_truecolor_ghost_only_composer_is_not_pending`) and `tests/fm-backend-herdr.test.sh` (`test_composer_state_grok_dark_truecolor_placeholder_is_empty`, `test_composer_state_grok_bright_truecolor_real_text_is_pending`).

**Tmux bottom-border cursor quirk (fixed):**
In a pristine placeholder-only composer, tmux's `#{cursor_y}` can point at the box's bottom border instead of its text row.
The shared tmux reader now locates the complete box structurally and classifies every content row, so the cursor may sit on a content row or the bottom border without changing the result.
The same structural read covers multi-row composers without fixed cursor offsets, while Herdr retains its own structural composer-row scan.

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

**Primary-session guard fact (verified 2026-07-28, Grok 0.2.112 and 0.2.73).**
The firstmate PRIMARY's own `.grok/hooks/fm-primary-turnend-guard.json` invokes `bin/fm-turnend-guard-grok.sh`.
Grok 0.2.112 exposes native same-process Stop continuation in its running payload, while the genuine pre-native 0.2.73 payload omits that capability and still needs one guarded `grok --resume`.
The exact adaptive and malformed-input contract is owned by `docs/turnend-guard.md`.
The tracked Claude Stop hooks skip themselves under `GROK_AGENT`, because Grok also loads Claude-compatible project settings and otherwise creates a second blocking path.
Project-local Grok hooks require folder trust, verified with launch-time `--trust`; if the primary firstmate checkout is not trusted for Grok hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.
Grok's primary watcher protocol remains background-notify around `bin/fm-watch-arm.sh`; native Stop continuation does not provide Pi-like extension ownership.

## kimi (VERIFIED 2026-07-25, kimi 0.29.1)

Kimi Code CLI launches from the absolute path resolved from `PATH`, falling back to the executable `$HOME/.kimi-code/bin/kimi`.
Kimi 0.29.1 is excluded from automatic subscription dispatch because a guarded Herdr lifecycle run could not deterministically exit after interrupt; explicit Kimi work must not be selected by `fm-dispatch-select.mjs`.

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

[`docs/turnend-guard.md`](../../../docs/turnend-guard.md) owns Kimi's verified global hook surface and captain-approved crew wake integration.
`fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one silent always-zero hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`.
Each Kimi crew worktree receives a gitignored `.fm-kimi-turnend` token pointer, and the global hook touches that task's `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding that the hook did not fire.
The guarded turn-end signal remains a wake notification; standalone Kimi has no busy-state source until one is live-verified.

## cline (VERIFIED 2026-07-27, Cline CLI 3.0.46)

Cline runs as an interactive TUI crewmate. Unlike Kimi, a positional prompt seeds AND auto-runs the first turn, so the brief rides the launch command like claude/codex/grok.

| Fact | Value |
|---|---|
| Binary | `cline` from `PATH` (`~/.local/bin/cline`, a Node script). Detection matches `cline` in the process argv like opencode (ancestry command name may be `node`). |
| Launch | `cline -i --tui --auto-approve true [--model <id>] [--thinking <effort>] "<brief>"`. `-i --tui` opens the persistent interactive TUI; the positional brief seeds and auto-runs the first turn (verified via tmux capture). |
| Models | Provider/model shown in the status bar (e.g. `ClinePass: Kimi K3`); `--model`/`-m` selects within the active provider. Default provider is `cline` (ClinePass). |
| Busy-pane signature | A braille spinner plus `Thinking... (esc to cancel)`; `esc to cancel` is the stable token and clears the instant the turn ends. Deliberately distinct from claude/codex `esc to interrupt`. |
| Exit command | Single `Ctrl+C` exits the TUI cleanly (rc 0). There is no `/exit` slash exit. |
| Interrupt | `Esc` cancels the current turn (the footer shows `esc to cancel`). Ctrl+C would EXIT, not interrupt — do not use it to interrupt. |
| Autonomy | `--auto-approve true` (on by default; passed explicitly for version robustness); the status bar reads `Auto-approve all enabled`. |
| Trust dialog | None on a clean launch with a pre-authed provider (ClinePass). |
| Submission | Typing then Enter submits; a seeded positional prompt auto-submits on launch. |
| Environment marker | None verified; detection relies on process ancestry (`cline` in argv). |
| Composer | Bordered box with a bare `❯` (U+276F) agent glyph — already a verified empty-composer glyph. The idle placeholder (`What can I do for you?` on first ready, `Ask anything...` thereafter) is muted grey (truecolor `38;2;131;137;140`, luma ~136) and also drawn bold, so it survives the dim/faint ghost stripper and would misread as pending; the shared idle-placeholder default (`FM_COMPOSER_IDLE_RE_DEFAULT` in `fm-composer-lib.sh`, consumed by the tmux classifier and the herdr/cmux/orca backends) lists both placeholders so an empty cline composer reads empty on every backend. The composer row has no side borders, so cmux/orca reach it through the bare agent-glyph promotion (`❯`). |
| Effort | Maps to `--thinking none|low|medium|high|xhigh` (no `max`; omit rather than pass an unsupported value). A live `--thinking high` launch showed `(high)` in the status bar. |
| TTY | Even `cline config` refuses without a TTY; supervise only through a pty/pane, never a bare pipe. |

Turn-end is observed from the pane, not a hook: the `esc to cancel` spinner clears and the composer returns to its idle placeholder. cline exposes `--hooks-dir` and a `hook` subcommand, which is the path for a future primary-session turn-end guard (only needed when firstmate ITSELF runs on cline); a cline CREWMATE needs no launch-side turn-end placeholder. cline is not wired for secondmate launches, so no `backends/tmux.sh` agent-process liveness entry is required yet.

Full empirical capture evidence: [`docs/verification/cline-adapter.md`](../../../docs/verification/cline-adapter.md).

## cursor-agent (VERIFIED 2026-07-27, Cursor CLI 2026.07.16 / 2026.07.23)

cursor-agent runs as a persistent interactive TUI crewmate. A positional prompt seeds AND auto-runs the first turn (after the workspace-trust gate is cleared), so the brief rides the launch command like claude/codex/cline.

| Fact | Value |
|---|---|
| Binary | `cursor-agent` from `PATH` (`~/.local/bin/cursor-agent`, a Node app). Detection matches `cursor` in the process argv. |
| Launch | `cursor-agent --force [--model <id>] "<brief>"`. `--force` (= status-bar "Run Everything") makes the crewmate autonomous. The default `agent` subcommand is the persistent TUI; a positional prompt seeds and auto-runs once trust is cleared. |
| Models | `--model gpt-5 \| sonnet-4-thinking \| 'claude-opus-4-8[context=1m,effort=high,fast=false]'`. Effort is a MODEL bracket parameter, NOT a standalone flag — so fm-spawn passes `--model` only, no effort flag. |
| Busy-pane signature | Braille spinner + `Working` + composer hint `ctrl+c to stop` (present only mid-turn). `ctrl+c to stop` is the anchor (`FM_TMUX_CURSOR_AGENT_BUSY_REGEX_DEFAULT`); bare `Working` is NOT used because pi owns `Working...`. |
| Exit command | `/quit` (slash popup + Enter) — verified to exit cleanly. Ctrl-C and Esc do NOT exit an idle session (Esc only quits the pre-session trust dialog). |
| Interrupt | `Ctrl-C` mid-turn (the busy footer shows `ctrl+c to stop`). |
| Autonomy | `--force` (alias `--yolo`); status bar reads `Run Everything`. `--auto-review` is the softer classifier mode (not used for unattended crew). |
| **Workspace trust (blocking)** | Interactive mode shows a blocking `⚠ Workspace Trust Required` dialog (`[a] Trust / [q] Quit`). **`--trust` does NOT bypass it — it only works with `--print`/headless.** Two verified bypasses: (1) pre-seed `~/.cursor/projects/<path-slug>/.workspace-trusted` = JSON `{"trustedAt":"<iso8601>","workspacePath":"<abs path>"}` before launch (path-slug = abspath, drop leading `/`, `/`→`-`, with a length-cap+hash variant for long paths); (2) send `a` after the readiness gate detects the dialog. A pre-seeded marker was verified to skip the dialog entirely. `fm-spawn` wires both: it pre-seeds the marker before launch and its readiness gate answers a residual dialog with `a`, failing the spawn loudly instead of hanging. |
| Composer | Bare agent glyph `→` (U+2192) with idle placeholder `Plan, search, build anything` (first ready) / `Add a follow-up` (post-turn). `→` is a verified AGENT glyph in the shared classifier and bare-row promotion set (`fm-composer-lib.sh`: `FM_COMPOSER_BARE_PROMPT_RE_DEFAULT`), so the unbordered composer row is structurally recognized on every backend, and the idle placeholders read empty via the shared `FM_COMPOSER_IDLE_RE_DEFAULT` (the glyph-prefixed alternates). A dead shell (`>` `$` `%` `#`) still never promotes. |
| TTY | Interactive mode needs a pty; supervise only through a pane. |
| Auth | `cursor-agent login` (browser/device; set `NO_OPEN_BROWSER=1` on a headless box) or `--api-key`/`CURSOR_API_KEY` (the `api-key-env` account method). Verified logged-in as a Cursor account. |

The trust gate is the one integration a cursor CREWMATE needs beyond the registry facts above, and `fm-spawn` wires it: the spawn pre-seeds `.workspace-trusted` before launch and its post-launch readiness gate answers a residual dialog with `a` (once), failing the spawn instead of hanging when the pane never reaches a ready/working signal. A full live crewmate dispatch through the herdr backend is the remaining acceptance step (needs a full firstmate home). cursor is not wired for secondmate launches, so no `backends/tmux.sh` liveness entry is required yet.

Full empirical capture evidence: [`docs/verification/cursor-agent-adapter.md`](../../../docs/verification/cursor-agent-adapter.md).

## copilot (VERIFIED 2026-07-28, GitHub Copilot CLI 1.0.75)

GitHub Copilot CLI runs as a persistent interactive TUI crewmate. A positional
prompt (via `-i`) seeds AND auto-runs the first turn once the folder-trust
dialog is cleared, so the brief rides the launch command like claude/codex/
cline/cursor-agent.

| Fact | Value |
|---|---|
| Binary | `copilot` from `PATH` (`~/.local/bin/copilot`), a standalone stripped ELF executable, NOT a node/python script. `/proc/<pid>/comm` reports the runtime-internal thread name `MainThread` (consistent with a Bun-compiled single-file binary), never `copilot`/`node`/`python`; detection matches `copilot` in the process argv via a dedicated `MainThread` ancestry case. |
| Launch | `copilot --allow-all --no-ask-user [--model <id>] [--reasoning-effort <tier>] -i "<brief>"`. `-i, --interactive <prompt>` seeds and auto-runs once the trust dialog clears (verified via tmux capture). |
| Models | Enumerated live via `/model` or `copilot help config`: `claude-sonnet-5`, `claude-sonnet-4.6`, `claude-sonnet-4.5`, `claude-haiku-4.5`, `claude-fable-5`, `claude-opus-5`, `claude-opus-4.8[-fast]`, `claude-opus-4.7`, `claude-opus-4.6`, `claude-opus-4.5`, `gpt-5.6-sol`, `gpt-5.6-terra` (default), `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4`, `gpt-5.3-codex`, `gpt-5.4-mini`, `gpt-5-mini`, `gemini-3.1-pro-preview`, `gemini-3.6-flash`, `gemini-3.5-flash`, `kimi-k2.7-code`, plus `auto`. `--model` is validated before any API call (verified: a bogus id errors cleanly with exit 1). |
| Busy-pane signature | Rotating circle/quarter-phase spinner + literal `Working esc interrupt` (optionally with a ` · <size>` tool-output-size infix between the two words). Bare `esc interrupt` alone collides with opencode's own anchor, so the busy regex is the compound `Working.*esc interrupt` (`FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT`). |
| Exit command | `/exit` (verified rc 0). Double `Ctrl-C` from idle also exits (footer shows `ctrl+c again to exit`, reverting on its own if not repeated). |
| Interrupt | Single `Ctrl-C` mid-turn (`● Operation cancelled by user`; session survives). `Esc` is a no-op both mid-turn and idle — unlike cline (interrupt) or cursor-agent (dialog-quit) — it only does something inside a modal (trust dialog "No", `/model` picker cancel). |
| Autonomy | `--allow-all` (alias `--yolo`; identical, `--allow-all-tools --allow-all-paths --allow-all-urls`) is the targeted equivalent of claude's `--dangerously-skip-permissions`. `--no-ask-user` additionally disables the `ask_user` tool; a live underspecified-brief test did not stall without it, but it is shipped anyway as a zero-downside defensive addition (no attended human to answer it in a supervised pane). |
| **Trust dialog (blocking, GATED)** | Interactive mode on an untrusted directory shows a blocking `Confirm folder trust` dialog (`1. Yes` / `2. Yes, and remember` / `3. No (Esc)`). **`--allow-all` does NOT bypass it** (verified with the flag already in argv), and the untested `--add-dir` flag was probed (WI-4 T0) and also does NOT bypass it. `fm-spawn` wires a post-launch readiness gate (`copilot_wait_for_trust_clear`, invoked right after the launch `Enter`): while the dialog is present, send one default-focus `Enter` (session-scoped trust, option 1, "Yes"); once the pane reaches the busy footer or the idle status bar, proceed; on budget exhaustion (`FM_COPILOT_TRUST_POLLS`/`FM_COPILOT_POLL_INTERVAL`), fail the spawn loudly via `copilot_spawn_fail`. Deliberately **no pre-seed** of copilot's persistent trust allow-list, unlike cursor-agent's isolated per-project marker — copilot's only pre-seed target is a single shared, global, credential-bearing JSONC config file with no delegated writer and no config-dir override, so the keystroke-only mechanism gets the same guarantee with zero writes to the operator's home. See `docs/verification/copilot-adapter.md` § *Trust / permission gate* for the full options analysis and the S4 reversal procedure (trivial: nothing is ever written). |
| Submission | A seeded `-i` prompt auto-submits once trust clears; typing then Enter can require a second Enter in practice (observed intermittently when injecting text into an already-running session — not yet root-caused, possibly bracketed-paste/debounce related). |
| Environment marker | `COPILOT_CLI=1`, set for copilot-spawned child processes (verified) — the harness-detection Layer-1 marker, alongside `CLAUDECODE`/`PI_CODING_AGENT`/`GROK_AGENT`. |
| Composer | Bare agent glyph `❯` (U+276F) — the exact same codepoint already verified for claude in the shared classifier; no new glyph needed. **No idle placeholder text of any kind was observed** (first-ready and post-turn composer rows are byte-identical: just the glyph, nothing else) — unlike cline/cursor-agent, so no `FM_COMPOSER_IDLE_RE_DEFAULT` addition and no backend `IDLE_RE` override were needed. |
| Effort | Maps to `--reasoning-effort <none\|minimal\|low\|medium\|high\|xhigh\|max>` — the fullest vocabulary of any adapter (verified via `--help` AND a zero-quota pre-flight validation probe). firstmate's shared `low\|medium\|high\|xhigh\|max` axis is a full subset; no tier is omitted. |
| TTY | Interactive mode needs a pty; supervise only through a pane. |

Turn-end is observed from the pane, not a hook: the `Working.*esc interrupt`
spinner/footer clears and the composer returns to its bare `❯` idle glyph.
copilot is not wired for secondmate launches, so no `backends/tmux.sh`
agent-process liveness entry is required yet, matching cline/cursor-agent
precedent. The folder-trust readiness gate (WI-4) is now wired, so a spawn
into a genuinely fresh worktree at any path reaches a ready/working pane
without human interaction, or fails loudly within the poll budget instead of
hanging — a live end-to-end dispatch through the herdr backend is still
deferred (matching the cline/cursor-agent precedent) but is no longer
blocked on this gate.

Full empirical capture evidence: [`docs/verification/copilot-adapter.md`](../../../docs/verification/copilot-adapter.md).

## agy (VERIFIED 2026-08-01, Antigravity CLI 1.1.9)

agy runs as a persistent interactive TUI crewmate (product name: Antigravity CLI).
A `-i` / `--prompt-interactive` prompt seeds AND auto-runs the first turn once the project-trust dialog is cleared, so the brief rides the launch command like claude/codex/cline/cursor-agent/copilot.

| Fact | Value |
|---|---|
| Binary | `agy` from `PATH` (`~/.local/bin/agy`, standalone Mach-O). Detection matches `agy` in process ancestry and the env marker below. |
| Launch | `agy --dangerously-skip-permissions [--model <id>] [--effort <low\|medium\|high>] -i "<brief>"`. `-i` seeds and auto-runs once trust clears (verified via tmux capture). |
| Models | `agy models` lists effort-baked ids such as `gemini-3.6-flash-{low,medium,high}`, `gemini-3.5-flash-*`, `gemini-3.1-pro-{high,low}`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium`. |
| Model / effort interaction | Base model (e.g. `gemini-3.6-flash`) **requires** `--effort`. Baked suffix alone works. Matching baked + `--effort` works. Conflicting baked + `--effort` fails closed (`conflicts with --effort=...`). Preferred firstmate form: base model + `--effort`. Ceiling is `high`; omit `xhigh`/`max`. |
| Busy-pane signature | Braille spinner + `Generating...` / `Running...` mid-turn; stable footer token `esc to cancel` (clears the instant the turn ends). Idle footer is `? for shortcuts`. The busy token string is identical to cline's, but each harness owns its own constant and harness-scoped case (`FM_TMUX_AGY_BUSY_REGEX_DEFAULT`). No semantic task-state writer is wired yet (crewmate posture matches cline/cursor-agent/copilot). |
| Exit command | `/exit` (verified rc 0). Prints `Resume with -c (or command below):` and `agy --conversation=<uuid>`. |
| Interrupt | Single `Esc` mid-turn; body shows `Interrupted · What should Antigravity CLI do instead?`; session survives. |
| Autonomy | `--dangerously-skip-permissions` auto-approves tool permission prompts (does **not** bypass project trust). |
| **Trust dialog (blocking, GATED)** | Interactive mode on an untrusted directory shows `Do you trust the contents of this project?` (`Yes, I trust this folder` / `No, exit`). Default focus is Yes; one `Enter` accepts it and **persists** the path into `~/.gemini/antigravity-cli/settings.json` `trustedWorkspaces` (verified). `fm-spawn` wires a post-launch readiness gate only (no pre-seed of that operator-global settings file): while the dialog is present, send one Enter; once `esc to cancel` or `? for shortcuts` appears, proceed; on budget exhaustion, fail the spawn loudly. Past-trust deliberately does **not** use the substring `Antigravity CLI` because that text also appears inside the dialog body. |
| Submission | Seeded `-i` prompt auto-submits once trust clears; typing then Enter submits follow-ups. |
| Environment marker | `ANTIGRAVITY_AGENT=1` on child/tool processes (verified with clean `env -i` launch). Checked **before** `CLAUDECODE` in `fm-harness.sh` so an agy worker is never misread as claude. |
| Composer | Bordered box with bare `>` prompt glyph; **no idle placeholder text** observed. Bordered `>` already reads empty in the shared classifier; no `FM_COMPOSER_IDLE_RE_DEFAULT` addition. |
| Resume | `agy --conversation <id>` or `agy -c` / `--continue` (most recent for cwd). |
| TTY | Interactive mode needs a pty; supervise only through a pane. |
| Skill invocation | Not separately verified beyond natural language; use natural language if the exact slash skill form is uncertain. |

Turn-end is observed from the pane, not a hook: the `esc to cancel` footer clears and the composer returns to `? for shortcuts`.
agy is not wired for secondmate launches, so no `backends/tmux.sh` agent-process liveness entry is required yet, matching cline/cursor-agent/copilot.

Full empirical capture evidence: [`docs/verification/agy-adapter.md`](../../../docs/verification/agy-adapter.md).
