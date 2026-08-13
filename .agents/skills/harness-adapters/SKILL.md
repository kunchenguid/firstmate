---
name: harness-adapters
description: >-
  Agent-only reference for firstmate harness operations.
  Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
  Contains verified facts for claude, codex, opencode, pi, pi-signed, grok, kimi, cursor, and muse.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
Optional dispatch profiles in `config/crew-dispatch.json` can override that static default for one crewmate or scout dispatch by selecting concrete harness, model, and effort axes at intake.
When a matched rule or default is a profile array, load `quota-array-dispatch` for the completion-aware candidate choice after this skill establishes harness and model/provider facts.
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
Agent lifecycle mechanics - which key interrupts a turn, how many times it must be sent, whether the composer needs clearing afterwards, which command exits the agent, and which task kinds the adapter can run - are owned by the executable control plane in `bin/fm-control-lib.sh` and delivered by `bin/fm-control.sh <task-id> interrupt|exit|relaunch`.
Never hand-type an interrupt key or exit command through `fm-send`: a routing-marked lifecycle command becomes chat the agent reasons about instead of executing, which is the defect the control plane exists to remove ([`docs/agent-control.md`](../../../docs/agent-control.md)).
The per-adapter `Exit command` and `Interrupt` rows below remain the verification record for those values; the executable owner is what firstmate actually runs, so a newly verified adapter is not reachable by the control plane until its rows land in that owner.
The primary-session "no turn ends blind" guard contract and harness hook installation paths live in `docs/turnend-guard.md`.
The primary-session watcher wake protocols are rendered from `docs/supervision-protocols/` by `bin/fm-supervision-instructions.sh`.
The supervision knowledge lives here: busy state, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.
Each adapter's `Busy state` row names only which semantic source that harness uses; `bin/fm-busy-lib.sh` owns the contract itself, including verdicts, source attribution, and the verification gates that keep an unverified harness at unknown.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, tell the captain under `AGENTS.md` section 9 that the requested worker runtime is not verified yet, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime before future use.
Do not pause current work for that future-verification choice, and never launch an unverified adapter.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, its semantic busy source and trust gate in `bin/fm-busy-lib.sh`, any new composer shape, prompt glyph, or idle placeholder in `bin/fm-composer-lib.sh`'s shared screen classifier (the ONE fleet-wide owner of every composer shape and the `empty`/`pending`/`pending-unproven`/`unknown` decision - teaching it there gives every backend the shape in the same commit, and no adapter may carry its own copy), the tmux agent-process liveness classification in `bin/backends/tmux.sh` when the harness can launch a secondmate, and the verified knowledge here.

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

The primary integrations for `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, and `cursor` have empirically validated hook paths for the "no turn ends blind" guard.
`claude` and `codex` block directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`opencode`, `pi`, and `pi-signed` expose passive lifecycle callbacks and force one bounded follow-up when the shared predicate blocks.
Grok selects native blocking or its pre-native bounded resume fallback from the exact running Stop payload; [`docs/turnend-guard.md`](../../../docs/turnend-guard.md) owns that contract.
Kimi is outside the primary turn-end guard scope, while `docs/turnend-guard.md` owns its separate guarded global hook for crew wake signals.
muse is CREWMATE/SCOUT ONLY and has no primary integration at all: its plugin engine (its only hook surface) is disabled in the default build, and its Claude-compatible hook dialect names `asyncRewake` and model reawakening as explicitly unsupported, which is exactly what a firstmate primary's turn-end supervision needs.
`bin/fm-spawn.sh` refuses a `--secondmate` launch on muse for that reason.
cursor HAS a full hooks system: 20 lifecycle events configurable at project scope in `.cursor/hooks.json`, plus a Claude-Code compatibility name map that also loads `<project>/.claude/settings.json`.
Its `stop` step cannot block - exit 2 there is a silent no-op - so `bin/fm-turnend-guard-cursor.sh` parks the turn boundary on the watcher and returns one bounded `followup_message` instead.
Because Cursor loads the tracked Claude settings too, every Claude-shaped entrypoint whose event Cursor covers stands down on a Cursor-delivered payload.
The exact hook files, commands, scoping rules, and fail-open tradeoffs are owned by `docs/turnend-guard.md`.
`docs/verification/supervision.md` "Turn-end guard" owns active validation evidence.
When changing any primary turn-end hook, validate the real harness behavior in a scratch project or throwaway home before trusting it, then update that doc and the relevant concise fact below.

## Primary pre-arm (PreToolUse) seatbelt

The primary integrations for `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, and `cursor` also have wired PreToolUse-equivalent hooks that deny a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs.
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

## Primary session start

AGENTS.md section 3 remains the behavioral owner for session start, while tracked native adapters enforce it idempotently at session open through one of two tiers.
Before inspecting or changing session-open behavior, read `docs/sessionstart-nudge.md`, the single owner of tier assignment, per-surface transports, source routing, the runtime bound, and fail-open behavior.
`docs/verification/supervision.md` "Native session-start delivery" owns active dated commands, payloads, and evidence.

## Primary watcher supervision

At session start, `bin/fm-session-start.sh` prints exactly one watcher supervision block for the detected primary harness.
Do not substitute another harness's wait shape when resuming supervision.
Claude's Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns tokenless re-arm around `bin/fm-watch-arm.sh`, and Grok uses tracked background-notify cycles around `bin/fm-watch-arm.sh`.
Codex uses bounded foreground checkpoints through `bin/fm-watch-checkpoint.sh` because Codex cannot reason while a foreground tool call is running.
OpenCode uses `.opencode/plugins/fm-primary-watch-arm.js`, which coordinates with the turn-end guard plugin and wakes the TUI with `client.session.promptAsync`.
Pi and pi-signed use the tracked `.pi/extensions/fm-primary-turnend-guard.ts` plus the tracked `.pi/extensions/fm-primary-pi-watch.ts`, both project-local extensions the Pi engine auto-discovers once trusted.
When changing any primary watcher adapter, update `docs/supervision-protocols/`, `docs/turnend-guard.md` if a shared idle or turn-end hook changed, and the relevant concise fact below.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values chosen by firstmate at intake.
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
| cursor | `--model <model>` | none | Verified 2026-08-11 on Cursor Agent CLI 2026.08.11-e8db854. No effort flag exists, so firstmate records the requested effort in task metadata and omits it from the launch. Validate ids against `cursor-agent --list-models` rather than assuming a low/medium/high family: the live catalog carries only `-high` Grok ids. |
| muse | `--model <model>` | `--reasoning-effort <low\|medium\|high\|xhigh>`, and `ultra` only for an explicit `max` | Verified 2026-08-05 on Muse Code 0.1.0-R708.1. The flag accepts `none\|minimal\|low\|medium\|high\|xhigh\|ultra` and defaults to `high`. `ultra` is muse's max-class level, so it is reachable only through an explicit captain `max`, never from the generic fallback; `none` and `minimal` sit below the shared vocabulary and stay unreachable. |

The concrete `harness` field owns adapter identity independently of the model provider: `harness=pi` with `model=xai/grok-*` is Pi using xAI, not `harness=grok`, and does not require Grok CLI login; `harness=grok` remains the standalone Grok Build CLI adapter.
Likewise, `harness=cursor` with `model=cursor-grok-4.5-*` is Cursor Agent CLI routing a Grok model, not the xAI Grok Build `grok` harness.
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
| cursor | Run `cursor-agent --list-models` (or the legacy `agent --list-models`), which lists the ids available to the current Cursor account. `cursor` is not the CLI name. |

For an unfamiliar harness or model namespace, establish support and provider identity from that harness's authoritative CLI help, model listing, or current documentation rather than guessing from a name or prefix.
A listing that reaches the account and does not contain the model is concrete evidence the model is unsupported: block that candidate and quote the result.
A discovery surface you could not reach establishes nothing; report that as uncertainty rather than turning it into a supported or unsupported verdict.

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness.
This preserves launch success instead of passing a known-bad value.
For Cursor, select the intended reasoning class through a model id the account's own `--list-models` actually returns, and leave the separate effort axis unset.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi and pi-signed: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- grok: `/<skill>`, for example `/no-mistakes` (same form as claude). Verified end to end: grok discovers the user-level `no-mistakes` skill, `/no-mistakes` invokes it, and grok drives a real `no-mistakes axi run`. Like codex's `$`/`/` popups, typing `/<skill>` opens grok's slash-autocomplete, so a too-fast Enter selects the popup entry instead of sending, and for an argument-taking command (like `/no-mistakes`'s optional task-first argument) that first Enter only expands the popup selection into an argument-hint placeholder rather than submitting - a genuine second Enter is required (see the grok section below for the 2026-07-03 incident and fix). `fm_tmux_submit_core`'s retried Enter (used by `fm-send` on the tmux backend) handles this through the shared structural composer classifier; the herdr backend needed a dedicated fix (`fm_backend_herdr_composer_state`, docs/herdr-backend.md) because its prior delta-based verification false-positived on that same popup-close content change.
- kimi: `/<skill>`, for example `/no-mistakes`.
- cursor: `/<skill>`, for example `/no-mistakes`. Cursor discovers firstmate's user-level skills. Its slash popup swallows the first Enter, so a genuine second Enter submits; the shared submit retry handles it.

## Submission acknowledgement hazards

A send or key action reporting success is not proof that the intended action happened.
OpenCode can accept and queue an Enter while leaving text visible, Grok can consume Enter in its slash popup without submitting, and Kimi can silently drop a message sent before readiness even though the send returns success.
The shared symptom is a healthy-looking pane with no work in progress, so each adapter must verify the observable postcondition that is specific to its TUI.

## claude (VERIFIED; busy-state hooks live-verified 2026-07-28 on Claude Code 2.1.220)

| Fact | Value |
|---|---|
| Busy state | Owned lifecycle hooks: `UserPromptSubmit` opens a turn, while `Stop`, `StopFailure`, and `SessionEnd` close it; because Claude fires no hook for a manual interrupt, `bin/fm-control.sh interrupt` reports only delivered keys and the verified endpoint or live agent, publishes no idle event, makes no cancellation claim, and leaves adapter-observed state unchanged, so a mid-turn worker typically remains busy via `claude-hook`. |
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
As defense in depth for any pane that flag cannot reach, including the captain's own firstmate composer that away-mode reads, the shared `fm_composer_strip_ghost` extractor in `bin/fm-composer-lib.sh` removes dim/faint SGR 2 ghost runs before pending-input classification on every styled reader (tmux, herdr, and Zellij).
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
| Exit command | `/quit` (slash popup needs about 1 second between text and Enter; the shared submit path used by `fm-control` handles it) |
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
| Interrupt | double Escape; known flaky while a long shell command runs, so use `bin/fm-control.sh <task-id> relaunch` for a wedged pane |

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
Pi's `packages/coding-agent/docs/settings.md` UI and display section documents `regular` as the `tuiMode` default and `fullscreen` as experimental; fullscreen can bury steers by rewriting scrollback, so Firstmate avoids it when the installed CLI supports the override.
`fm-spawn.sh --help` owns the executable-pinning and version-safe launch mechanics.
`pi-signed` is the signed wrapper identity verified on version 0.82.0 and exposes the same CLI and TUI behavior as Pi.
Firstmate records `pi-signed` without normalization and refuses rather than falling back to `pi` when that wrapper is unavailable.
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
| Skill invocation | `/<skill>` (e.g. `/no-mistakes`), same as claude. Opens a slash-autocomplete popup, so a too-fast Enter selects the popup entry instead of sending. For an argument-taking command that first Enter does not submit at all - it expands the selection into an argument-hint placeholder in the composer (e.g. `/compact` -> `/compact compaction instructions`, live-verified), leaving real text still sitting there unsubmitted; a genuine second Enter is required. `fm-send`'s retried Enter lands it on BOTH backends because the shared composer classifier recognizes that placeholder-filled text as still pending; Herdr may also confirm a real turn start through native agent state - see the incident below. |
| Autonomy | `--always-approve` (footer shows `· always-approve`); auto-approves every tool execution, verified to run fully unattended. `--permission-mode bypassPermissions` is the stronger equivalent. |
| Env marker | `GROK_AGENT=1`, set for child/tool processes on grok 0.2.73. grok does NOT set `CLAUDECODE` despite Claude compatibility, so the marker is unambiguous WHEN PRESENT, but it is not guaranteed present: a grok 1.0.0 hook process carries `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, and `GROK_WORKSPACE_ROOT` with no `GROK_AGENT`. Treat it as a fast path only; `bin/fm-harness.sh`'s ancestry walk is what guarantees grok identification, and any rule that must be reliable under grok has to test the hook markers too (owner: `docs/turnend-guard.md` "Harness integrations"). |
| Resume | `grok --resume <session-id>` (id printed on exit) or `grok -c` / `--continue` (most recent for the cwd); `--fork-session` branches a new session id. |

**Incident (2026-07-03, herdr backend only, grok 0.2.82):** two grok/herdr crewmates were sent `/no-mistakes` via `fm-send`; both left it fully typed but unsubmitted in the composer for minutes (footer still `Enter:send`), and `fm-send` exited 0 with no error.
Reproduced live: the herdr adapter's submit-verification at the time treated ANY pane-content change after Enter as "submitted", and the popup-close-with-placeholder-fill described above IS a visible content change even though nothing was actually sent.
The current tmux and Herdr adapters pass their captures and capability descriptors to `bin/fm-composer-lib.sh`, whose shared structural classifier sees placeholder-filled text on any proven content row as still pending, so the retry loop sends the needed second Enter.
See `docs/herdr-backend.md` "Composer and injection safety" for Herdr's current boundary and `tests/fm-backend-herdr.test.sh` for regression coverage.

Startup dialog: the "Run Grok Build in a project directory?" project picker appears ONLY when grok is launched from a non-project directory (home, Desktop, Downloads, `/tmp`).
`fm-spawn` launches inside the treehouse worktree (a git repo root), so the picker never appears and grok treats the worktree as a trusted project automatically - no post-launch keystroke is needed.
Pin `[hints] project_picker_disabled = true` in `~/.grok/config.toml` if a non-project launch ever needs to skip it.

**TRUECOLOR placeholder styling: covered (task afk-herdr-false-pending, 2026-07-10).**
A freshly-dismissed, never-typed-into grok composer shows a placeholder ("Type a message...") styled with a dark 24-bit TRUECOLOR foreground, not the SGR-2 dim/faint attribute the ghost stripper originally detected.
The shared ANSI-aware owner `fm_composer_strip_ghost` (`bin/fm-composer-lib.sh`) now drops a dark/muted truecolor foreground (perceived luminance below `FM_COMPOSER_GHOST_LUMA_MAX`, default 128) as well as dim/faint, so the placeholder is stripped and the row reads empty on every styled backend (tmux, herdr, and Zellij route through the same owner).
Verified live against grok 0.2.93: real input is the bright `38;2;224;222;244` (luminance ~225, kept), while grok's borders and placeholder/hint text are dark truecolor (`38;2;50;47;70` .. `38;2;110;106;134`, luminance ~51..110, dropped).
This assumes a dark terminal theme, the fleet reality; the SGR-2 signal stays theme-independent.
Regression coverage: `tests/fm-composer-ghost.test.sh` (`test_strip_ghost_drops_dark_truecolor_ghost`, `test_dark_truecolor_ghost_only_composer_is_not_pending`) and `tests/fm-backend-herdr.test.sh` (`test_composer_state_grok_dark_truecolor_placeholder_is_empty`, `test_composer_state_grok_bright_truecolor_real_text_is_pending`).

**Tmux bottom-border cursor quirk (fixed):**
In a pristine placeholder-only composer, tmux's `#{cursor_y}` can point at the box's bottom border instead of its text row.
The fleet-wide classifier now locates the complete box structurally and classifies every content row, so tmux's cursor may sit on a content row or the bottom border without changing the result.
The same shared structural read covers multi-row composers without fixed cursor offsets on every backend; adapters no longer carry their own shape scans.

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
The tracked Claude hook entries whose event Grok already covers through its own `.grok/hooks/` registration skip themselves under `GROK_AGENT` or `GROK_HOOK_EVENT`, because Grok also loads Claude-compatible project settings and otherwise creates a second blocking path; the exact marker set and why `GROK_SESSION_ID` is excluded are owned by `docs/turnend-guard.md` "Harness integrations".
Project-local Grok hooks require folder trust, verified with launch-time `--trust`; if the primary firstmate checkout is not trusted for Grok hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.
Grok's primary watcher protocol remains background-notify around `bin/fm-watch-arm.sh`; native Stop continuation does not provide Pi-like extension ownership.

## cursor (VERIFIED CREWMATE/SCOUT 2026-08-11 on tmux and 2026-08-12 on Herdr, and SECONDMATE/PRIMARY 2026-08-13, Cursor Agent CLI 2026.08.11-e8db854)

Cursor Agent CLI runs crewmate, scout, secondmate, and primary work.
Its primary supervision is the stop-hook park in [`docs/supervision-protocols/cursor.md`](../../../docs/supervision-protocols/cursor.md), registered in tracked `.cursor/hooks.json`; a Cursor primary or secondmate must be launched with `--trust` or no project hook loads at all.
Do not confuse `harness=cursor` using a `cursor-grok-4.5-*` model with `harness=grok`, which is the separate xAI Grok Build CLI and credential surface.

| Fact | Value |
|---|---|
| Binary | Resolved through `fm_cursor_resolve_binary` (bin/fm-cursor-lib.sh). `cursor` is NOT the CLI: the installed names are `cursor-agent` and the legacy alias `agent`, both symlinked into `~/.local/share/cursor-agent/versions/<version>/cursor-agent`. The STABLE launcher is used, never the versioned target, which the CLI replaces on its own auto-update. |
| Launch | A positional prompt with `--trust`, `--yolo`, `--model <model>` when selected, and `--workspace <absolute-task-worktree>`, behind `env -u` of the foreign primary markers. |
| Models | Validate against `cursor-agent --list-models` for the current account rather than a fixed list; that list has already drifted once. The live catalog contains only `-high` Grok ids (`cursor-grok-4.5-high`, `cursor-grok-4.5-high-fast`) and several `xhigh` ids, so an assumed low/medium Grok id is invalid. |
| Busy state | Its own per-conversation transcript, folded on demand by `bin/fm-busy-lib.sh` (source `cursor-transcript`). Each turn is bracketed by a `role:user` open and a typed `turn_ended` close covering `success` and `aborted`, so unlike Claude's `Stop` hook this source covers manual interruption. Nothing is armed and no record is ever seeded. Backend-agnostic, and confirmed identical on tmux and Herdr. |
| Exit command | `/exit` |
| Interrupt | Single Escape. The composer returns to its placeholder rather than the cancelled prompt, so NO clear key is needed (unlike muse). `bin/fm-control-lib.sh` claims no cancellation acknowledgement: the aborted transcript close appeared within seconds in some runs and not within twenty in others. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`. Cursor discovers firstmate's user-level skills; `/no-mistakes` autocompleted with firstmate's own description and invoked the skill. |
| Slash submission | The popup is REAL and swallows the first Enter: the first closes the popup and a SECOND submits, the same hazard as grok. The submit core's retried Enter covers it. |
| Autonomy | `--yolo`, the documented alias for `--force`, whose TUI footer reads `Run Everything`. |
| Trust dialog | `--trust` suppresses it. `--yolo` does NOT, and every task gets a fresh worktree path, so without `--trust` every spawn would block on it. |
| Environment marker | `CURSOR_INVOKED_AS=cursor-agent` on the agent process and its children, plus `CURSOR_AGENT=1` on child/tool processes. Other `CURSOR_*` endpoint and credential variables are not identity markers. |
| Effort | No effort flag exists. The requested axis is recorded in task metadata and never reaches the launch command. |
| Composer | A BARE row whose prompt glyph is `→` (U+2192); no border. Idle placeholders are `Plan, search, build anything` fresh and `Add a follow-up` after a turn, drawn de-emphasised so a styled capture separates them from real typed text. |
| Primary hooks | Tracked project-scope `.cursor/hooks.json` registers `stop`, `sessionStart`, and two `preToolUse` seatbelts, all anchored through `$CURSOR_PROJECT_DIR`. Cursor ALSO loads `<project>/.claude/settings.json`, so the tracked Claude entries stand down on a Cursor-delivered payload; `docs/turnend-guard.md` owns that predicate. |
| Primary limits | `stop` does not fire in headless `cursor-agent -p`. `preCompact` is deliberately unregistered because it cannot inject context, so a Cursor primary does not re-emit its digest after a compaction; that surface is deferred to a follow-up. Project hooks need `--trust`. |

**Detection ordering is load-bearing.**
Cursor does NOT clear an inherited `CLAUDECODE`, so a cursor worker under a claude primary carries both markers and whichever is tested first wins.
`bin/fm-harness.sh` tests the cursor markers BEFORE the `CLAUDECODE` check, and the launch additionally clears the foreign markers.
Both are kept: launch sanitization only covers sessions fm-spawn started, while the ordering also covers a cursor session a human started by hand.

**The `node` process-name caveat.**
Cursor runs as a bundled node script, so tmux reports `#{pane_current_command}` as a bare `node` while `ps -o comm=` carries the cursor-agent install path.
`node` matches no harness name pattern, so identity comes from Cursor's own name or install tree in the path or argv[0] (`bin/fm-cursor-lib.sh`).
An unrelated `node` or `agent` is deliberately left `other`, which the liveness callers fold into `ambiguous` rather than `dead`.
Because the versioned install path is what identifies the alias, an auto-update changes the resolved target but not the identity rule.

**Cursor parks its terminal cursor outside its composer.**
`#{cursor_y}` pointed below the footer both when idle and with real text typed, and `#{cursor_flag}` was 0, so tmux's cursor row is not a composer locator for a Cursor pane and the cursor-ANCHORED read answers `unknown` in every state.
`bin/fm-tmux-lib.sh` therefore reclassifies a pane it can prove is Cursor the way every cursorless backend already classifies it, letting the bottom-most shape win, so the composite `fm_tmux_composer_state` now reports a real `empty` or `pending` for a Cursor pane on tmux (verified 2026-08-13).
That gate is Cursor's own structural process identity from `bin/fm-cursor-lib.sh`, never the verdict alone, so the strict blank-cursor-row posture stays in force for every other harness and a dead shell still never reads `empty`.
This is what makes away-mode escalation delivery work against a Cursor primary: `bin/fm-supervise-daemon.sh` needs an affirmatively-empty composer before it types, and it needed no Cursor-specific branch once the reader was correct.
Submission is additionally acknowledged from the idle-to-busy transition, which is why cursor's `ctrl+c to stop` token is part of the delivery busy union in `bin/fm-composer-lib.sh`.
Match that TOKEN and never the spinner verb: the same version rendered `Working` in one turn and `Running` in the next.

**Delivery confirmation is verified on tmux and Herdr only.**
Herdr reports a Cursor pane `blocked` in EVERY state - idle, mid-turn, and after - so its native idle-baseline submit path is unreachable for Cursor and the composer branch runs instead; that branch reads a mid-turn row carrying the placeholder beside `ctrl+c to stop`, which is `pending`.
`bin/backends/herdr.sh` therefore confirms a Cursor submit from a rendered-footer idle-to-busy transition, taking the baseline before the first Enter so an already-busy pane never confirms.
Zellij, cmux, and Orca share a submit core that never consults that footer, so a Cursor steer there LANDS but `bin/fm-send.sh` reports delivery unconfirmed and exits non-zero.
Treat that as a known limitation of those three backends rather than a lost message: the steer is in the pane and the worker's own recorded state still comes from its transcript fold.
Teaching the shared core the same transition is deliberately separate work, because it changes the submit path for every harness on those three backends and needs its own live validation on each.

The composer's reverse-video placeholder remnant is taught to the ONE fleet-wide screen classifier in `bin/fm-composer-lib.sh`, not to any adapter.
Herdr additionally draws the composer's rules with half-block glyphs, which the same shared classifier owns as structural edges; without them a bare composer's wrap region swallows the footer below it and an idle pane reads `pending`.
`docs/verification/runtime-backends.md` "Cursor Agent CLI" owns the dated captures, and the drift guard that refreshes them is:

```bash
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

Firstmate acquires and enters the treehouse worktree before launching Cursor, then passes that same absolute path through `--workspace`.
NEVER pass Cursor's own `-w/--worktree`: it allocates a SECOND worktree under `~/.cursor/worktrees` and would break firstmate's worktree-isolation contract.
The raw CLI accepts repeatable `--add-dir <path>` for deliberate multi-root workspaces; the adapter adds none, and the brief rides inline as the positional prompt, so the private brief directory needs no grant.

Spawn a Cursor scout with an explicit model:

```bash
bin/fm-spawn.sh <task-id> <project> --scout --harness cursor --model cursor-grok-4.5-high
```

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

[`docs/turnend-guard.md`](../../../docs/turnend-guard.md) owns Kimi's verified global hook surface and captain-approved crew wake integration.
`fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one silent always-zero hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`.
Each Kimi crew worktree receives a gitignored `.fm-kimi-turnend` token pointer, and the global hook touches that task's `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding that the hook did not fire.
The guarded turn-end signal remains a wake notification; standalone Kimi has no busy-state source until one is live-verified.

## muse (VERIFIED 2026-08-05, Muse Code 0.1.0-R708.1, build sha 427a430436)

Muse Code is a CREWMATE and SCOUT adapter only.
`bin/fm-spawn.sh` refuses `--secondmate` on muse, and muse has no supervision protocol under `docs/supervision-protocols/`, so a firstmate primary detected as muse falls back to the `unknown` protocol.

| Fact | Value |
|---|---|
| Binary | Executable `muse` from `PATH`, resolved to an absolute path; spawning refuses if it is absent. The installed launcher `~/.local/bin/muse` `exec`s `~/.local/bin/muse-bin-<version>`, so the LIVE process name carries the version and changes on every auto-update. |
| Launch | Positional prompt, the Grok/Pi shape, so the brief rides the launch command. |
| Models | `--model <model>`; the only provider is `meta`. |
| Busy state | Its own durable session event log, folded on demand by `bin/fm-busy-lib.sh`. There is no hook or plugin writer, so nothing is armed and no busy record is ever seeded. |
| Exit command | `/exit` (the popup shows `/exit  Quit when idle`); one Enter submits it, and the pane prints `To continue this session, run muse resume <session-uuid>`. |
| Interrupt | Single Escape, which closes the run with `terminal: cancelled` AND restores the interrupted prompt into the composer as real bright text, so `fm-control` follows Escape with `C-u` to clear it; `fm-send`'s legacy key path reads the same composer-clear table. |
| Skill invocation | `/<skill>`, the claude/grok form. |
| Autonomy | `--yolo`, which disables approval, disables the sandbox, and trusts the workspace for the run. |
| Trust dialog | `Do you trust this workspace?` with `1 Trust and continue` preselected, accepted by Enter. `--yolo` suppresses it entirely, which is what firstmate relies on because every task gets a fresh worktree path. |
| Environment marker | None. Detection is process ancestry on the anchored prefix `muse-bin-*`. The launch clears foreign primary markers before Muse starts so their higher detection precedence cannot override that ancestry. `MUSE_CURRENT_SESSION_LOG` is a session-log PATH rather than an identity, and its export to tool subprocesses is unverified. |
| Composer | Bordered box whose prompt glyph is `⟩` (U+27E9) in truecolor `38;2;90;160;255`, luminance ~149.9 - the narrowest margin over the 128 ghost threshold in the fleet. Typed text is `38;2;204;211;219` (~209.8). No idle placeholder or ghost text was observed. |
| Effort | `--reasoning-effort`, default `high`; see the launch-profile table above for the mapping. |
| Resume | `muse resume --last` or `muse resume <session-uuid>`; bare `muse resume` opens a picker. |

### Credentials are a spawn preflight, not a screen check

muse reads `META_API_KEY` (which always wins) or a stored credential at `${XDG_CONFIG_HOME:-$HOME/.config}/muse/auth.json`, written by `muse login` (an OIDC device-code flow) or `muse auth set --api-key-stdin`.
`bin/fm-spawn.sh` accepts `META_API_KEY` only when it can prove the backend worker already has it, because a command-scoped caller variable does not cross a long-lived backend daemon and the secret must never enter launch argv.
The supported fleet path is the stored credential, and `fm-spawn` resolves the non-secret `XDG_CONFIG_HOME` and `XDG_DATA_HOME` roots to absolute paths before preflight and forwarding to keep authentication and session-log binding aligned with the worker.
`bin/fm-spawn.sh` refuses the launch when neither worker-reachable path is present, because an unauthenticated pane does NOT exit: it sits on `Sign in at this page: https://auth.meta.com/oauth/device/?code=XXXX-XXXX` / `Waiting for approval…` indefinitely, which supervision would read as a wedged worker rather than a missing credential.
Escalate that refusal to the captain as a needed credential.

### Foreign personal context is a real privacy boundary

muse loads the OPERATOR's foreign personal rules from `~/.claude` into every run and ships them to Meta-hosted inference, printing a first-launch notice that names the included Claude Code personal rules and `/settings` control.
An isolated `XDG_CONFIG_HOME` does NOT prevent this, and the notice is shown only once per config (`tui.foreign_context_notice_shown` in `settings.json`), so a silent later launch is still loading them.
`--no-foreign-personal-context` is `muse exec` ONLY: the interactive TUI rejects it with `unexpected argument`.
The control that reaches a pane worker is `MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on`, which `fm-spawn` sets on every muse launch.
It was verified to drop the foreign `rules_file` context block while KEEPING a project's own `AGENTS.md` rules, which the crewmate contract depends on.

### Session event log and the busy fold

Sessions persist to `${XDG_DATA_HOME:-$HOME/.local/share}/muse/sessions/YYYY/MM/DD/<session-uuid>/session.jsonl`, and `fm-spawn` writes `state/<id>.muse-session` pinning that root, the task worktree, its binding incarnation, and every pre-existing matching main log so the classifier binds a pane to its one new log.
After unique resolution, the classifier persists the exact main log in `state/<id>.muse-session-current`, folds that path directly while the bounded current-day main-session namespace is unchanged, and requires unique resolution again when that namespace changes, the path disappears, or a new spawn binding supersedes the incarnation.
Each submitted turn is bracketed by `{"payload":{"kind":"run","run_id":"<uuid>","event":{"kind":"started"` and a matching `"event":{"kind":"terminal"`, whose `terminal` value was observed as `completed` and `cancelled`.
Because the interrupt path produces a real terminal, this source covers interruption, which Claude's `Stop` hook does not.
Never use `--no-session-log` for a crewmate: it disables the only busy source muse has.

Two traps the fold already handles, which any change here must preserve.
muse also emits nested `"record":{"kind":"terminal"}` cleanup-effect payloads that are NOT run terminals, so the match is anchored on the full structural prefix rather than a `"kind":"terminal"` search.
muse's own native sub-agents write independent run lifecycles one directory deeper under `subagent/<child-session-id>/session.jsonl`, so the resolver is depth-bounded and folds only the main log.

The recorded sessions root is the resolved `XDG_DATA_HOME` that `fm-spawn` also forwards to the worker launch, so the binding and pane remain aligned across a long-lived backend daemon.

Both halves of the fold are trusted with no opt-in: an open run reads `busy`, a settled log reads `idle`, and only a resolution failure - no binding, no matching log, an unreadable or run-free log - reads `unknown`.
[`docs/verification/muse.md`](../../../docs/verification/muse.md) owns the credentialed evidence for trusting idle and the post-upgrade refresh procedure.

### Native sub-agents and worktrees

muse fans out to its own sub-agents, but worktree isolation is per-child and opt-in: `--subagent-worktree-isolation` is a compatibility flag whose capability "defaults on" while "omission stays shared", and no nested git worktree appeared in any verified lab run.
Firstmate deliberately does NOT exclude any muse path from `fm-teardown.sh`'s uncommitted-work check.
Firstmate writes `.claude/settings.local.json` itself, which is why that path is excluded for claude; it does not write muse's, so a nested muse worktree or leftover scratch is the agent's own work product and MUST be able to refuse teardown.
A teardown refusal naming muse scratch is therefore correct behavior: inspect it rather than forcing past it.

### Maturity caveats

muse is a day-0 `0.1.0` beta whose launcher polls a release channel hourly and can replace the running binary underneath the fleet, changing the process name with it.
The captain accepted that risk, so firstmate does NOT set `MUSE_NO_AUTO_UPDATE=1`; a fleet that later wants stability can set it in the launch environment without any adapter change.
Its plugin/hook engine reports `plugins are not available in this build` unless `MUSE_EXPERIMENTAL_PLUGINS=on`, which is why the busy source reads the session log instead of installing a hook.
