---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, opencode, and pi.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, resume, or adapter verification.

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name.
Optional dispatch profiles in `config/crew-dispatch.json` can override that static default for one crewmate or scout dispatch by selecting concrete harness, model, and effort axes at intake.
The captain may override that file at session start or later; a per-task instruction such as "run this one on opencode" overrides it for that dispatch only.
`default` means mirror firstmate's own harness.

Secondmates have their own harness knob, so a secondmate can run on a different adapter than crewmates.
`config/secondmate-harness` is the harness the primary uses to launch SECONDMATE agents, resolved through the fallback chain `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own.
An absent or `default` `config/secondmate-harness` therefore behaves exactly as the crew harness did before this knob existed (secondmates launched on the crew harness); setting it splits the two.
The [`secondmate-provisioning` skill](../secondmate-provisioning/SKILL.md) owns the complete inherited-local-material allowlist and propagation contract.
This skill owns only the harness-relevant consequence: a secondmate's own crewmates use the primary's inherited dispatch profiles and static harness value, while `config/secondmate-harness` is the primary's own setting and is never inherited - secondmates do not spawn secondmates.
Inheritance copies the literal `config/crew-harness` file, so for a secondmate's own crewmates to run on the primary's crewmate harness the captain must set `config/crew-harness` to a concrete adapter name, such as `opencode`.
If `config/crew-harness` is unset or `default`, there is no concrete value to inherit, so the secondmate's own crewmates fall back to the secondmate's own/detected harness rather than the primary's effective crewmate harness.
Inheritance also copies the literal `config/crew-dispatch.json` file, so secondmates apply the same best-fit profile rules for their own crewmates.

Each adapter splits into mechanics and knowledge.
The per-task mechanics, including launch command, autonomy flag, and crewmate turn-end hook, live in `bin/fm-spawn.sh`.
The primary-session "no turn ends blind" guard contract and harness hook installation paths live in `docs/turnend-guard.md`.
The primary-session watcher wake protocols are rendered from `docs/supervision-protocols/` by `bin/fm-supervision-instructions.sh`.
The supervision knowledge lives here: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, tell the captain under `AGENTS.md` section 9 that the requested worker runtime is not verified yet, use firstmate's own verified runtime for current work, and ask only whether to verify the requested runtime before future use.
Do not pause current work for that future-verification choice, and never launch an unverified adapter.
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
`claude` blocks directly through a Stop hook that preserves exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`opencode` and `pi` expose passive lifecycle callbacks for this purpose, so their tracked primary adapters force one bounded follow-up or resume when the shared predicate blocks.
The exact hook files, commands, validation transcripts, scoping rules, and fail-open tradeoffs are owned by `docs/turnend-guard.md`.
When changing any primary turn-end hook, validate the real harness behavior in a scratch project or throwaway home before trusting it, then update that doc and the relevant concise fact below.

## Primary pre-arm (PreToolUse) seatbelt

Every verified primary harness also has a wired PreToolUse-equivalent hook that denies a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs.
`claude` blocks directly through a PreToolUse hook.
`opencode` and `pi` block by throwing from `tool.execute.before` / returning `{block: true}` from `tool_call`.
The exact hook files, commands, output-shaping quirks (Claude Code only honors the deny when stdout is empty), and validation transcripts are owned by `docs/arm-pretool-check.md`.
When changing any primary PreToolUse hook, validate the real harness behavior in a scratch project before trusting it, then update that doc.

## Primary session-start nudge

AGENTS.md section 3 remains the behavioral owner for session start, while tracked native adapters invoke `bin/fm-sessionstart-nudge.sh` as an idempotent enforcement layer.
The wrapper prints only the instruction to run `bin/fm-session-start.sh`; it never runs the digest, wake drain, bootstrap sweeps, lock, or supervision arm itself.
Full mechanics, scoping, dated commands, payloads, and fail-open evidence live in `docs/sessionstart-nudge.md`.

- `claude`: verified native `SessionStart` stdout injection; `.claude/settings.json` matches `startup`, `resume`, and `clear`, but not `compact`.
- `opencode`: verified on 1.17.18; `session.created` plus `client.session.promptAsync` starts the nudge turn in the TUI, while `opencode run` remains fail-open headless.
- `pi`: verified native `session_start`; the existing primary extension handles `startup`, `new`, and `resume` and uses `pi.sendMessage` to inject context without racing a positional launch prompt.

## Primary watcher supervision

At session start, `bin/fm-session-start.sh` prints exactly one watcher supervision block for the detected primary harness.
Do not substitute another harness's wait shape when resuming supervision.
Claude uses a tracked background-notify cycle around `bin/fm-watch-arm.sh`.
OpenCode uses `.opencode/plugins/fm-primary-watch-arm.js`, which coordinates with the turn-end guard plugin and wakes the TUI with `client.session.promptAsync`.
Pi uses the tracked `.pi/extensions/fm-primary-turnend-guard.ts` plus the tracked `.pi/extensions/fm-primary-pi-watch.ts`, both project-local extensions Pi auto-discovers once trusted.
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
| pi | `--model <model>` | `--thinking <off\|minimal\|low\|medium\|high\|xhigh\|max>` | Verified 2026-07-13 on Pi 0.80.6. `pi --help` advertises `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`, and firstmate threads all of them through `--thinking`; `pi --print --model openai-codex/gpt-5.6-sol --thinking max 'Reply with exactly OK.'` completed successfully. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness.
This preserves launch success instead of passing a known-bad value.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.

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

## opencode (VERIFIED 2026-06-11, v1.15.7-1.17.6; 1.18.4 busy-queue re-verified 2026-07-20)

| Fact | Value |
|---|---|
| Busy-pane signature | `esc interrupt` (dotted spinner footer; note no "to") |
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

