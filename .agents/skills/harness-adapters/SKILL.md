---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, selecting a dispatch profile, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, pi, and grok.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this core reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.
Load the matching runtime reference below only when that runtime is being selected, spawned, recovered, interrupted, exited, resumed, or verified.
Do not load another runtime's reference as a substitute for the target window's recorded harness.

| Runtime | Reference | Capability summary |
|---|---|---|
| claude | [claude.md](claude.md) | Model and effort flags are verified through `max`; Stop and PreToolUse hooks block directly; Stop-owned watcher auto-arm is verified. |
| codex | [codex.md](codex.md) | Model and effort flags are verified through `xhigh`; Stop and PreToolUse hooks block directly; primary watcher uses bounded foreground checkpoints. |
| opencode | [opencode.md](opencode.md) | Model flags are verified for interactive launch, but no interactive effort flag is verified; primary guard, watcher, and PreToolUse equivalents are passive plugin callbacks. |
| pi | [pi.md](pi.md) | Model and thinking flags are verified through `max`; primary guard, watcher, and PreToolUse equivalents are Pi extensions; the model arms through `fm_watch_arm_pi`. |
| grok | [grok.md](grok.md) | Model and reasoning-effort flags are verified through `high`; primary guard is passive; watcher follows Claude-shaped background notifications. |

## Selection and verification invariants

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
Optional dispatch profiles in `config/crew-dispatch.json` can override that static default for one crewmate or scout dispatch by selecting concrete harness, model, and effort axes at intake.
The captain may override that file at session start or later; a per-task instruction such as "run this one on codex" overrides it for that dispatch only.
`default` means mirror firstmate's own harness.

Secondmates have their own harness knob, so a secondmate can run on a different adapter than crewmates.
`config/secondmate-harness` is the harness the primary uses to launch SECONDMATE agents, resolved through the fallback chain `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own.
An absent or `default` `config/secondmate-harness` therefore behaves exactly as the crew harness did before this knob existed: secondmates launch on the crew harness.
Setting it splits the two.
The [`secondmate-provisioning` skill](../secondmate-provisioning/SKILL.md) owns the complete inherited-local-material allowlist and propagation contract.
This skill owns only the harness-relevant consequence: a secondmate's own crewmates use the primary's inherited dispatch profiles and static harness value, while `config/secondmate-harness` is the primary's own setting and is never inherited because secondmates do not spawn secondmates.
Inheritance copies the literal `config/crew-harness` file, so for a secondmate's own crewmates to run on the primary's crewmate harness the captain must set `config/crew-harness` to a concrete adapter name, such as `codex`.
If `config/crew-harness` is unset or `default`, there is no concrete value to inherit, so the secondmate's own crewmates fall back to the secondmate's own or detected harness rather than the primary's effective crewmate harness.
Inheritance also copies the literal `config/crew-dispatch.json` file, so secondmates apply the same best-fit profile rules for their own crewmates.

Each adapter splits into mechanics and knowledge.
The per-task mechanics, including launch command, autonomy flag, and crewmate turn-end hook, live in `bin/fm-spawn.sh`.
The primary-session "no turn ends blind" guard contract and harness hook installation paths live in `docs/turnend-guard.md`.
The primary-session watcher wake protocols are rendered from `docs/supervision-protocols/` by `bin/fm-supervision-instructions.sh`.
The runtime references linked above own the supervision knowledge for their runtime: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, primary watcher behavior, and quirks.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, use `captain-communication` to report that the requested worker runtime is not verified, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime for future work.
Do not pause current work for that future-verification choice, and never launch an unverified adapter.
If the captain asks for a new harness, propose verifying it first: spawn a trivial supervised task using `fm-spawn`'s raw-launch-command escape hatch, confirm every fact empirically, then record the mechanics in `fm-spawn`, the busy signature in `fm-watch.sh` and `fm-tmux-lib.sh` defaults, any needed `FM_COMPOSER_IDLE_RE` empty-composer override plus any novel bare agent prompt glyph in `bin/fm-composer-lib.sh`'s shared composer classifier, the tmux agent-process liveness classification in `bin/backends/tmux.sh` when the harness can launch a secondmate, and the verified knowledge in the matching runtime reference.
`bin/fm-composer-lib.sh` is the one fleet-wide owner of the empty, dead-shell, and pending composer decision, so a new harness's own idle composer must not be misread as a dead shell.

## Detection

`bin/fm-harness.sh` prints firstmate's own harness, using verified env markers first and then process ancestry.
`bin/fm-harness.sh crew` resolves the effective crewmate harness from `config/crew-harness`.
Absent or `default` `config/crew-harness` resolves to firstmate's own harness.
`bin/fm-harness.sh secondmate` resolves the secondmate-launch harness through the chain `config/secondmate-harness` -> `config/crew-harness` -> own, so an unset `config/secondmate-harness` matches the crew harness.
`bin/fm-spawn.sh` uses `crew` mode for a crewmate or scout launch and `secondmate` mode for a `--secondmate` launch, re-resolving on every spawn so the split is durable across respawns.
An explicit per-spawn harness arg overrides either.
On `unknown`, ask the captain instead of guessing.
A captain override always beats detection.
When verifying a new adapter, record its env marker and command name in `bin/fm-harness.sh`.

For stuck recovery, the target window's harness is recorded as `harness=` in `state/<id>.meta`.
Use that value for interrupt, exit, resume, and skill-invocation facts, then load the matching runtime reference.

## Dispatch profile selection

`docs/configuration.md` owns the dispatch-profile schema, while this section is the single owner of the judgment procedure for selecting one concrete profile.
At every crewmate or scout intake, apply an explicit per-task captain override first, then the best-fitting configured rule, then the configured default, then the static crewmate harness.
When a selected rule or default is one profile object, use that concrete profile directly.

Firstmate alone resolves a matched profile array.
Run `quota-axi --json` at that intake, evaluate every configured candidate against that current output, and choose the candidate with the most real headroom.
Account for every candidate.
If any harness, model, or provider relationship, applicable quota data, or interpretation cannot be established, stop and report that candidate instead of omitting it, guessing, falling back, or calling the result quota-informed.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
When every candidate is tight, preserve the captain's strongest-reasoning class rather than silently downgrading it solely to conserve quota.
Stop and report the tight choice if that class cannot proceed.
Break genuine headroom ties without array-order or harness bias.
`quota-axi` owns how model or product windows relate to bounding account windows.
As an explicitly interim rule until successor `quota-axi-interpretation-hints-h3` lands, use the weakest applicable remaining headroom, then remove this sentence when that successor replaces it.
`bin/fm-dispatch-select.sh` is vestigial during this transition and must not be called.

After selection, pass the concrete `harness`, `model`, and `effort` axes that are set to `bin/fm-spawn.sh`.
A missing dependency, authentication failure, unresolved relationship, unavailable quota reading, unsupported backend, or version refusal blocks this dispatch rather than authorizing a guess or silent retry on another runtime.

## Supported runtime backends

`docs/configuration.md` owns runtime backend selection and schema.
The supported spawn backends are `tmux`, `herdr`, `zellij`, `orca`, and `cmux`.
`tmux` is the verified reference backend.
`herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends with their own operator guides under `docs/`.
`backend=orca` and `backend=cmux` refuse `--secondmate` until secondmate launch semantics are designed for each.
`codex-app` is not an accepted runtime backend; [`firstmate-codexapp`](../firstmate-codexapp/SKILL.md) and [`docs/codex-app-backend.md`](../../../docs/codex-app-backend.md) own that boundary.
A missing dependency, failed authentication, unknown relationship, unavailable required model, unsupported backend, or version refusal blocks dispatch rather than authorizing a guess or silent fallback.

## Shared primary integration pointers

Every verified primary harness has an empirically validated hook path for the "no turn ends blind" guard.
`docs/turnend-guard.md` owns the exact hook files, commands, scoping rules, and fail-open tradeoffs.
`docs/verification/supervision.md` "Turn-end guard" owns active validation evidence.
When changing any primary turn-end hook, validate the real harness behavior in a scratch project or throwaway home before trusting it, update that doc, and update the matching runtime reference.

Every verified primary harness also has a wired PreToolUse-equivalent hook that denies a watcher-arm anti-pattern before it runs.
The denied anti-patterns are shell `&`, truncating pipe, bundling, and broad `pkill -f fm-watch`.
`docs/arm-pretool-check.md` owns the exact hook files, commands, output-shaping quirks, and validation transcripts.
When changing any watcher-arm PreToolUse hook, validate the real harness behavior in a scratch project before trusting it, update that doc, and update the matching runtime reference.

`docs/subagent-guard.md` owns the primary delegation-shape guard contract, the local deny-list recommendation, the `FM_ALLOW_SUBAGENT=1` escape hatch, and the per-harness applicability review.
Load [claude.md](claude.md) when handling Claude's verified delegation facts.

AGENTS.md section 3 remains the behavioral owner for session start, while tracked native adapters invoke `bin/fm-sessionstart-nudge.sh` as an idempotent enforcement layer.
`docs/sessionstart-nudge.md` owns full mechanics, scoping, and fail-open behavior.
`docs/verification/supervision.md` "Native session-start delivery" owns active dated commands, payloads, and evidence.

At session start, `bin/fm-session-start.sh` prints exactly one watcher supervision block for the detected primary harness.
Do not substitute another harness's wait shape when resuming supervision.
When changing any primary watcher adapter, update `docs/supervision-protocols/`, `docs/turnend-guard.md` if a shared idle or turn-end hook changed, and the matching runtime reference.

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

Load the selected runtime reference before passing model or effort values to `fm-spawn`.
Each runtime reference owns its verified launch flags, accepted effort set, model-discovery surface, unavailable-model boundary, and skill-invocation form.
When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness.
This preserves launch success instead of passing a known-bad value.

Treat model and provider knowledge as current source-of-truth discovery, not as a permanent namespace or provider mapping.
Use the discovery surface in the current authenticated environment because supported and available models can change by version, account, and configuration.
For an unfamiliar harness or model namespace, establish support and provider identity from that harness's authoritative CLI help, model listing, or current documentation rather than guessing from a name or prefix.
If those sources do not establish the relationship needed for dispatch, fail loudly and report the unresolved candidate.
`docs/verification/model-routing.md` records dated empirical probes for the exact identifiers in the copyable dispatch example, while `delivery-quality` owns the per-task unavailable-model fallback decision.
