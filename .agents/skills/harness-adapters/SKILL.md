---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, pi, pi-signed, grok, kimi, and cursor-agent.
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

## Primary session-start and post-compaction nudges

AGENTS.md section 3 remains the behavioral owner for session start, while AGENTS.md section 8's existing always-loaded operational-input sentence owns trust and required handling for the `post-compact` kind; tracked native adapters invoke `bin/fm-sessionstart-nudge.sh` as an idempotent enforcement layer.
The wrapper prints one canonically typed `session-start` instruction to run `bin/fm-session-start.sh`; it never runs the digest, wake drain, bootstrap sweeps, lock, or supervision arm itself.
The same wrapper's exact `post-compact` mode prints a separately typed, bounded instruction to re-read the durable captain, learnings, and active-task metadata without running `bin/fm-session-start.sh`.
Full mechanics, scoping, and fail-open behavior live in `docs/sessionstart-nudge.md`.
`docs/verification/supervision.md` "Native session-start delivery" and "Native post-compaction re-anchor" own active dated commands, payloads, and evidence.

- `claude`: verified native `SessionStart` stdout injection; `.claude/settings.json` matches `startup`, `resume`, and `clear`, plus `compact` through the same wrapper's `post-compact` mode; one owner-anchored auto-compaction lab observed the agent accept the signal and re-read every named record, but that observation is not an enforcement guarantee.
- `codex`: verified session-start delivery, but no compaction lifecycle event with hook-context delivery; post-compaction remains fail-open.
- `opencode`: verified interactive session-start delivery, but no compaction lifecycle event and delivery path; post-compaction remains fail-open.
- `pi` and `pi-signed`: verified native session-start delivery; Pi exposes `session_compact`, but post-compaction nudge delivery is not end-to-end verified for either identity and remains fail-open.
- `grok`: project session-start hooks fire but stdout does not reach model context, and no compaction delivery path is verified; both limits remain fail-open.
- `kimi`: no primary session-start transport or compaction delivery path is verified; both remain fail-open.

## Primary watcher supervision

At session start, `bin/fm-session-start.sh` prints exactly one watcher supervision block for the detected primary harness.
Do not substitute another harness's wait shape when resuming supervision.
Claude's Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns tokenless re-arm around `bin/fm-watch-arm.sh`, and Grok uses tracked background-notify cycles around `bin/fm-watch-arm.sh`.
Codex uses bounded foreground checkpoints through `bin/fm-watch-checkpoint.sh` because Codex cannot reason while a foreground tool call is running.
OpenCode uses `.opencode/plugins/fm-primary-watch-arm.js`, which coordinates with the turn-end guard plugin and wakes the TUI with `client.session.promptAsync`.
Pi and pi-signed use the tracked `.pi/extensions/fm-primary-turnend-guard.ts` plus the tracked `.pi/extensions/fm-primary-pi-watch.ts`, both project-local extensions the Pi engine auto-discovers once trusted.
When changing any primary watcher adapter, update `docs/supervision-protocols/`, `docs/turnend-guard.md` if a shared idle or turn-end hook changed, and the relevant concise fact below.

## Launch profile axes

`bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, `--effort`, `--task-class`, and `--routing-source` values chosen by firstmate at intake, plus the `--exploration` marker and the claude-only `--account-profile` axis.
Do not make the shell scripts parse or match natural-language dispatch rules.

Pass `--task-class` on every crewmate and scout spawn, using the class that describes the task you just classified at intake: `rote-reversible-edit`, `bounded-implementation-proven-root-fix`, `unknown-root-diagnosis`, `adversarial-review-security-review`, `evidence-heavy-research`, `long-horizon-repository-work`, `visual-browser-sensitive-work`, `documentation-specification-decision-extraction`, or `external-wait-integration-work`.
Omit it only when the task genuinely does not fit one of those classes; the flag then defaults to `unresolved`, which records the intake as unclassified rather than guessing.
The class is telemetry, not routing: it never changes which harness, model, or effort you selected.

Pass `--routing-source captain|profile|fallback` on every crewmate and scout spawn too, naming how you actually resolved the tuple you are passing: `captain` for an explicit per-task captain instruction, `profile` for a configured crew-dispatch profile or non-secondmate pin, and `fallback` for the generic effort and harness fallback.
It is provenance, not a routing choice, and the recovery escalation ladder (`bin/fm-harness.sh escalate`) is its consumer: it may raise effort or rotate a harness only where the fallback acted, so an omitted flag records unknown provenance and leaves every wedged task's routing frozen.
A secondmate launch whose complete concrete tuple resolves from durable `config/secondmate-harness` records the separate schema-validated `secondmate-config` provenance automatically only when no explicit harness, model, effort, or positional harness override was supplied.
Bare or partial durable config and every override remain outside that provenance.
Callers do not pass that value as a one-shot substitute for persisting the tuple, and such a launch does not claim a crew-dispatch matched rule or resolved attestation.

`--account-profile <name>` names one home-local native Claude account alias from `config/claude-account-profiles`; the verified `claude` adapter is its only consumer, and a non-Claude harness, a raw launch command, or a secondmate parent launch refuses it.
Nothing selects an account for you: pass it only when the captain named the account for that task, or when re-passing an escalation verdict's emitted `account_profile=` alias unchanged (`stuck-crewmate-recovery`).
Setup, schema, and the pre-launch refusals are owned by [`docs/configuration.md`](../../../docs/configuration.md) "Claude account profiles"; never put a profile directory in a brief, report, or message.

`--exploration` records that the tuple you are launching is a deliberate rotation away from your default choice for this class, so the ledger can compare the rotated tuple against the usual one under the same observed machine load.
`fm-spawn.sh` accepts it only on a `no-mistakes` ship whose `--task-class` is `bounded-implementation-proven-root-fix`, because that class is where a mechanical accepted/step-rerun result makes the comparison readable.
Rotate on such a task when its bounded path leaves you free to choose, no captain instruction or standing dispatch profile pinned the model or effort, and the ledger has no comparable recent attempt for the alternative tuple; pass the rotated `--model` and `--effort` together with `--exploration`.

Read the ledger to check that last precondition; it is a lookup, not a judgment call:

```sh
bin/fm-model-telemetry.sh sheet --format json |
  jq '[.[] | select(.recordType=="attempt" and .taskClass=="bounded-implementation-proven-root-fix")
      | {harness,model,modelVersion,cliVersion,effort,exploration,quality,firstPassAccepted,correctionCount,stepReruns,wallSeconds,startedAt}]'
```

Compare `harness`/`model`/`modelVersion`/`cliVersion`/`effort` against the tuple you are considering: rotate when that tuple has no recent row, and skip the rotation when it already has one whose outcome fields answer the question you were about to ask.
The sheet is read-only and never modifies the ledger, so running it at intake is always safe.
Never rotate to satisfy curiosity on work whose blast radius, deadline, or captain instruction argues for the known-good tuple, and never present a rotation as the fit-based choice.

A routing alternative remains a `candidate` until its comparison is pre-registered and the telemetry owner accepts an `adopted` or `discarded` verdict.
Before collecting outcomes, run `bin/fm-model-telemetry.sh candidate-register --candidate <id> --payload <json>` with the exact task-class-blocked method, candidate and comparator model/version tuples, task classes, minimum observations per model/class, time window, and rollback criterion.
After the declared window has enough eligible outcomes from distinct task roots in every model/class cell, run `bin/fm-model-telemetry.sh candidate-verdict --comparison <mrc_uuid> --verdict <adopted|discarded> --rollback-evidence <tested|documented>:<id>`.
The returned and recorded sample names the exact model, model version, CLI version, task class, n, accepted-first-pass count, and rate for every cell; cancelled, incomplete, quota-stopped, and known execution-environment failures do not satisfy n.
Treat the transition as refused unless that command records the verdict; adoption also refuses when a candidate cell falls below the frozen rollback threshold, and no verdict may backfill outcomes from before registration, pool task classes, count retries of one task root twice, accept an `unreported` version, or weaken the frozen minimum.
This guard applies only to the routing candidate-to-adopted-or-discarded transition; it does not approve individual launches, delivery, configuration edits, or any other workflow.

Effort precedence is an explicit per-task captain instruction first, then any applicable standing dispatch profile or secondmate pin, then the generic fallback below.
Never replace an effort value supplied by either higher-precedence source.
Use the fallback only when neither the captain nor applicable standing configuration specifies effort.
Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design.
Choose intermediate levels proportionally as complexity, uncertainty, blast radius, or open-ended reasoning increases.
When a verified adapter lacks `xhigh`, cap the choice at its highest supported non-`max` level rather than omitting the intended effort silently.
Never select `max` from this fallback; use it only when the captain has explicitly expressed that per-task or standing preference.

The supported launch-profile transports below are verified locally; each row records its evidence.

| Harness | Model transport | Effort transport | Notes |
|---|---|---|---|
| claude | `--model <model>` | `--effort <low\|medium\|high\|xhigh\|max>` | Verified on Claude Code 2.1.196. |
| codex | `--model <model>` | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` | Verified on codex-cli 0.142.1. The installed binary schema contains `model_reasoning_effort`, the active config uses it, and the bundled model catalog advertises only low/medium/high/xhigh. `max` is omitted. |
| grok | `--model <model>` | `--reasoning-effort <low\|medium\|high>` | Verified on grok 0.2.99 (2026-07-13). `--effort` is an alias, but firstmate's profile axis is reasoning effort. As of 0.2.99 the ceiling is `high`; both `xhigh` and `max` are rejected with `use one of: high, medium, low`, so firstmate omits them. |
| pi / pi-signed | `--model <model>` | `--thinking <low\|medium\|high\|xhigh\|max>` | Verified 2026-07-27 on Pi and pi-signed 0.82.0. Both expose the same accepted thinking levels and completed the same model-qualified max-thinking smoke. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |
| kimi | `--model <model>` | none | Verified 2026-07-25 on Kimi Code CLI 0.29.1. |
| cursor-agent | `--model <model-variant>` or a parameterized model selector | Model-id suffix (`-low`, `-medium`, `-high`, or `-xhigh`); `-fast` remains part of the selected model id. There is no separate effort flag. | Verified 2026-08-14 on Cursor Agent 2026.08.11-e8db854. `fm-spawn` records the selected effort axis in metadata and passes the selected model id unchanged. |

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
| cursor-agent | Run `cursor-agent models`, which lists the models available to the current Cursor account. |

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
- cursor-agent: project skill integration is not yet ported or verified; use natural language.
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

First launch in a fresh task root, or first ever on a machine, may show a trust or bypass-permissions confirmation.
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
The decision persists per path in `~/.pi/agent/trust.json`, so later spawns in the same task root skip it.

`fm-spawn` keeps the turn-end extension in `state/`, outside the task root, because task-local extension files make the trust gate strictly worse and would also pollute a writer's project worktree.
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
A writer launch starts inside a treehouse worktree (a git repo root), so the picker never appears and grok treats the worktree as a trusted project automatically; a reader scout starts in checkout-free scratch under `/tmp`, so inspect and clear the picker after launch when it appears.
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
`fm-spawn` writes that per-task pointer (`<task-root>/.fm-grok-turnend`, excluded through git info/exclude for writer worktrees) and a matching registry entry naming this task's `state/<id>.turn-ended`.
The hook reads `$GROK_WORKSPACE_ROOT`, which is always set for hooks and equals the task root.
This keeps the hook itself outside the task root, needs no trust grant, and writes only firstmate-owned files.
`fm-teardown` removes the pointer before returning a pooled writer worktree or deleting a reader scratch root.
Secondmate spawns skip the pointer (idle panes are healthy, no stale-pane detection for them).

**Primary-session guard fact (verified 2026-07-28, Grok 0.2.112 and 0.2.73).**
The firstmate PRIMARY's own `.grok/hooks/fm-primary-turnend-guard.json` invokes `bin/fm-turnend-guard-grok.sh`.
Grok 0.2.112 exposes native same-process Stop continuation in its running payload, while the genuine pre-native 0.2.73 payload omits that capability and still needs one guarded `grok --resume`.
The exact adaptive and malformed-input contract is owned by `docs/turnend-guard.md`.
The tracked Claude Stop hooks skip themselves under `GROK_AGENT`, because Grok also loads Claude-compatible project settings and otherwise creates a second blocking path.
Project-local Grok hooks require folder trust, verified with launch-time `--trust`; if the primary firstmate checkout is not trusted for Grok hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.
Grok's primary watcher protocol remains background-notify around `bin/fm-watch-arm.sh`; native Stop continuation does not provide Pi-like extension ownership.

## cursor-agent (VERIFIED 2026-08-14 for ordinary crew and scout launches; secondmate production-test support, Cursor Agent 2026.08.11-e8db854)

Cursor Agent launches with a positional prompt as `cursor-agent --trust --force --model <model> <brief>`.
`--force` is the unattended command-approval mode, while `--trust` bypasses the separate first-workspace confirmation that still appears under `--force` alone.

| Fact | Value |
|---|---|
| Busy state | Task-root-local `beforeSubmitPrompt` opens the turn as `busy cursor-hook`; `stop` and `SessionEnd` close it as `idle cursor-hook`, and `stop` also writes the turn-end notification. A successful firstmate Escape records `idle fm-interrupt`. A spinner, `Working`, and `ctrl+c to stop` remain rendered presentation, not state sources. |
| Exit command | One `Ctrl+D` from the empty composer exits after a short delay. |
| Interrupt | Single Escape, live-verified by cancelling an active `sleep 30` tool call. |
| Resume | `cursor-agent --continue` resumes the most recent session for the workspace. The CLI also exposes `--resume [chatId]`, `cursor-agent resume`, and `cursor-agent ls`. |
| Skill invocation | Unverified. Use natural language until firstmate's skills are ported to Cursor and an invocation is confirmed. |
| Autonomy | `--force`, with `--yolo` documented by the CLI as its alias. |
| Trust dialog | A fresh task root asks for workspace trust even under `--force`; firstmate includes `--trust` in every launch. |
| Environment marker | None verified. Detection uses the exact `cursor-agent` command name in process ancestry. |
| Composer | The idle bordered `→ Add a follow-up` placeholder is dim text and the shared composer reader already classifies it as empty. No `FM_COMPOSER_IDLE_RE` override or new bare glyph is needed. |
| Effort | Effort lives in the selected model id or parameterized model selector, never in a separate flag. `fm-spawn` records the requested effort metadata while passing the model unchanged. |
| Secondmate support | Accepted for persistent seats under the production-test override. Cursor has no verified native seat session-start delivery, Stop-hook supervision, or recovery-grade primary integration. The seat therefore operates with bounded foreground checkpoints in the same degraded shape used for Kimi-style seats; no second watcher or new Cursor control plane is added. |

The model-routing principle is: do not pay Cursor for capacity that a standalone subscription already provides.
A future model id is classified by asking whether Pedro's standalone Claude Max or Codex Pro subscription already serves that capacity, not merely by checking whether Anthropic or OpenAI made it.
Current-generation `claude-opus-5-*`, `claude-fable-5-*`, `claude-sonnet-5-*`, `gpt-5.6-*`, and `gpt-5.3-codex-*` are excluded because those standalone subscriptions already serve them.
The abundant Cursor Models pool currently permits `cursor-grok-4.6-*`, `cursor-grok-4.5-high`, and `composer-2.5*`.
The metered Other-Models pool permits `kimi-k3-{low,high,max}`, `kimi-k2.7-code`, `glm-5.2-*`, and `gemini-*-flash*` when their spend is justified.
Older `claude-4.5-sonnet`, `claude-4-sonnet`, `gpt-5.1*`, `gpt-5-mini`, and `gpt-5.4-mini/nano` remain eligible only when there is a concrete reason to test capacity the standalone plans do not serve.
Always confirm current availability with `cursor-agent models`, because the account-backed catalog can change.

Cursor project hooks and Pedro's existing global hooks compose on 2026.08.11-e8db854.
A controlled listener made the existing global hook observable without editing it: global `SessionStart`/`SessionEnd` events and a project hook fired in the same run, and a real interactive submission emitted `Start` (`beforeSubmitPrompt`) followed by `Stop`.
`fm-spawn` installs that lifecycle in the disposable task root's `.cursor/hooks.json` and, for a writer worktree, excludes only that generated file through git info/exclude so it cannot surface in project diffs or pull requests while project-owned `.cursor/` files remain reviewable.
The hooks drive the classifier through the trusted `cursor-hook` source, `SessionEnd` prevents a process exit from stranding busy state, and a successful firstmate Escape records the interrupt close directly.
The watcher can absorb ordinary turn-end wakes while a new turn is provably active.
Ordinary Cursor crewmate and scout dispatch is unattended-capable. Cursor secondmate seats are accepted only as a degraded persistent-seat production test: existing lifecycle and busy integration are reused where they already apply, while the supervising firstmate relies on bounded foreground checkpoints because native seat session-start and Stop-hook delivery are not verified. This slice does not add a Cursor primary watcher, Stop-hook adapter, session-start transport, recovery daemon, or second supervision mechanism.
Never modify Pedro's global Cursor files without his explicit approval.

Cursor's MCP and skill portability are separate follow-up work.
The current global Cursor MCP configuration is Pedro's personal file and is never a firstmate write target.

## kimi (VERIFIED 2026-08-16, kimi 0.36.1; trust and submit paths)

Kimi Code CLI launches from the absolute path resolved from `PATH`, falling back to the executable `$HOME/.kimi-code/bin/kimi`.

Scope of that verification: the trust dialog, the workspace-trust record format, launch, and the composer/submit paths were exercised live on 0.36.1, but a full model turn was NOT, because the Kimi Code CLI credential is expired (`kimi_code_cli_credential_expired`, [`docs/verification/dispatch-auth.md`](../../../docs/verification/dispatch-auth.md)) and no usable Kimi authentication was available.
Treat everything downstream of an accepted submission — real turn execution, turn-end hook firing under a live model, and busy state during a genuine turn — as still assumed rather than verified until Kimi authentication is restored.

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
| Trust dialog | Kimi 0.36.1 shows a per-root "Trust this folder / Don't trust" dialog in a fresh task root. `fm-spawn` pre-trusts the validated writer worktree or reader scratch before launch by writing `~/.kimi-code/workspace-trust/<workspace-id>` in Kimi's native `{"root":"<task-root>","trustedAt":<ms>}` format. The workspace ID is `wd_<lowercase-basename-slug>_<first-12-sha256-of-normalized-root>`. |
| Slash submission | One Enter submits, with no popup swallow or settle hazard. |
| Environment marker | None; detection relies on process ancestry command name `kimi`. |
| Composer | Bordered box with a bare `>` prompt glyph and no observed ghost or placeholder text. |
| Effort | No reasoning-effort flag exists, so requested effort is recorded in task metadata but omitted from launch. |

`fm-spawn.sh` launches Kimi bare, waits for the composer box or `Welcome to Kimi Code!`, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires a cleared composer plus either the echoed `✨` submission or nonzero context before accepting delivery.
This launch-then-send shape is mandatory because Kimi rejects a positional brief as an unknown command.
Sending before readiness was reproduced as a silent drop with a zero exit status, an empty composer, `context: 0%`, no echoed user message, and a healthy-looking idle pane.
The brief path must be absolute because the brief lives outside the task root, and Kimi reads it there without `--add-dir`.

Observed live spinner captures included optional leading whitespace, a moon-phase glyph, whitespace around `·`, and rotating tip text, with the same shape observed during tool execution.
Because every captured spinner row had whitespace on both sides of `·`, the matcher requires that whitespace, deliberately does not match the never-observed zero-whitespace form, and does not require trailing tip text.
The startup input-readiness window is the established cause of Kimi's first-Enter delivery defect, while the banner is not the cause.
An early Enter can expand Kimi's composer to multiple content rows, leaving the pointer text on the first row and the cursor on an empty later row, which is the same single-cursor-row reading defect exposed by Grok's bottom-border cursor quirk.
The shared tmux reader now locates the complete bordered composer and treats real text on any content row as positive evidence that submission is still pending.
No rendering signal is trustworthy for proving that Kimi will accept input during this window, so delivery retries Enter through the shared submit core and retains the existing postcondition verification rather than relaxing readiness or delivery checks.
The shared tmux submit core gives a Kimi target one final bare Enter after its normal retry budget when the composer still proves pending, covering the verified first-submit swallow without retyping the message.
That mitigation is implemented once in the submit core and selected by the harness argument threaded through `fm_backend_send_text_submit`, so `fm-send`, the `fm-spawn` brief-pointer submit, and the away-supervisor daemon all inherit it from the one owner.
Kimi's footer tip rotates independently and can display `ctrl+c: cancel` while completely idle, which is one reason no Kimi rendered signature is a state source.
The idle status bar can contain lowercase `thinking`, which is the model's effort label rather than a busy signal.
The delivery-only spinner match covers the full moon-phase glyph set rather than one frame, but it remains locale- and emoji-font-sensitive because Kimi exposes no stable ASCII busy token.

[`docs/turnend-guard.md`](../../../docs/turnend-guard.md) owns Kimi's verified global hook surface and captain-approved crew wake integration.
`fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one silent always-zero hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`.
Each Kimi task root receives a `.fm-kimi-turnend` token pointer, excluded from Git for writer worktrees, and the global hook touches that task's `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding that the hook did not fire.
The guarded turn-end signal remains a wake notification; standalone Kimi has no busy-state source until one is live-verified.
