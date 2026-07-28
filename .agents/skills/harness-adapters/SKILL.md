---
name: harness-adapters
description: Agent-only reference for firstmate harness operations. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter. Contains verified facts for claude, codex, opencode, pi, grok, and traex.
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

The optional local `config/harness-overrides.json` changes HOW a harness launches (its binary, launch args, or launch env), never WHICH harness is selected.
Every verified fact in this skill still applies unchanged under an override: the recorded `harness=` stays the base adapter, and its busy signature, turn-end hook, interrupt, exit, escape, and skill-invocation forms are unaffected, because firstmate always owns the launch tail (model/effort flags, brief injection, turn-end wiring).
The full contract lives in `docs/configuration.md`.

Secondmates have their own harness knob, so a secondmate can run on a different adapter than crewmates.
`config/secondmate-harness` is the harness the primary uses to launch SECONDMATE agents, resolved through the fallback chain `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own.
An absent or `default` `config/secondmate-harness` therefore behaves exactly as the crew harness did before this knob existed (secondmates launched on the crew harness); setting it splits the two.
The [`secondmate-provisioning` skill](../secondmate-provisioning/SKILL.md) owns the complete inherited-local-material allowlist and propagation contract.
This skill owns only the harness-relevant consequence: a secondmate's own crewmates use the primary's inherited dispatch profiles and static harness value, while `config/secondmate-harness` is the primary's own setting and is never inherited - secondmates do not spawn secondmates.
Inheritance copies the literal `config/crew-harness` file, so for a secondmate's own crewmates to run on the primary's crewmate harness the captain must set `config/crew-harness` to a concrete adapter name, such as `codex`.
If `config/crew-harness` is unset or `default`, there is no concrete value to inherit, so the secondmate's own crewmates fall back to the secondmate's own/detected harness rather than the primary's effective crewmate harness.
Inheritance also copies the literal `config/crew-dispatch.json` file, so secondmates apply the same best-fit profile rules for their own crewmates.

Each adapter splits into mechanics and knowledge.
The per-task mechanics, including launch command, autonomy flag, and crewmate turn-end hook, live in `bin/fm-spawn.sh`.
The primary-session "no turn ends blind" guard contract and harness hook installation paths live in `docs/turnend-guard.md`.
The primary-session watcher wake protocols are rendered from `docs/supervision-protocols/` by `bin/fm-supervision-instructions.sh`.
The supervision knowledge lives here: busy signature, exit command, interrupt, dialogs, resume behavior, skill invocation, and quirks.

Never dispatch a crewmate or secondmate on an unverified adapter.
An adapter can also be more thoroughly verified for one ROLE than another: `traex`'s crewmate/scout face is live-verified, while its primary/secondmate face is wired and component-verified but not yet exercised as a real long-running primary session (see the traex section).
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
`claude` and `codex` block directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`opencode`, `pi`, and `grok` expose passive lifecycle callbacks for this purpose, so their tracked primary adapters force one bounded follow-up or resume when the shared predicate blocks.
The exact hook files, commands, validation transcripts, scoping rules, and fail-open tradeoffs are owned by `docs/turnend-guard.md`.
When changing any primary turn-end hook, validate the real harness behavior in a scratch project or throwaway home before trusting it, then update that doc and the relevant concise fact below.

## Primary pre-arm (PreToolUse) seatbelt

Every verified primary harness also has a wired PreToolUse-equivalent hook that denies a watcher-arm anti-pattern (shell `&`, truncating pipe, bundling, broad `pkill -f fm-watch`) before it runs.
`claude` and `codex` block directly through PreToolUse hooks; `grok` blocks the same way but requires every `$VAR` reference in its hook `command` string to carry an inline `:-default` or it fails to launch the hook entirely.
`opencode` and `pi` block by throwing from `tool.execute.before` / returning `{block: true}` from `tool_call`.
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
The wrapper prints only the instruction to run `bin/fm-session-start.sh`; it never runs the digest, wake drain, bootstrap sweeps, lock, or supervision arm itself.
Full mechanics, scoping, dated commands, payloads, and fail-open evidence live in `docs/sessionstart-nudge.md`.

- `claude`: verified native `SessionStart` stdout injection; `.claude/settings.json` matches `startup`, `resume`, and `clear`, but not `compact`.
- `codex`: verified on 0.144.4; `.codex/hooks.json` receives `source=startup`, and wrapper stdout reaches model context.
- `opencode`: verified on 1.17.18; `session.created` plus `client.session.promptAsync` starts the nudge turn in the TUI, while `opencode run` remains fail-open headless.
- `pi`: verified native `session_start`; the existing primary extension handles `startup`, `new`, and `resume` and uses `pi.sendMessage` to inject context without racing a positional launch prompt.
- `grok`: the 0.2.103 project `SessionStart` event fires with `source=new`, but stdout does not reach model context; the tracked project hook remains fail-open, and a global token-guarded fallback requires a captain decision.

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
| pi | `--model <model>` | `--thinking <low\|medium\|high\|xhigh\|max>` | Verified 2026-07-13 on Pi 0.80.6. `pi --help` advertises `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`; `pi --print --model openai-codex/gpt-5.6-sol --thinking max 'Reply with exactly OK.'` completed successfully. |
| opencode | `--model <provider/model>` | none for firstmate's interactive launch | Verified on opencode 1.17.6. `opencode run` has `--variant`, but firstmate launches the interactive `opencode --prompt` path, which has no verified effort flag. |
| traex | `--model <model>` | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` | Verified on traex 0.200.13 (2026-07-17). Same config key as codex, and the binary's own parser is authoritative: `-c model_reasoning_effort='"max"'` is rejected with "unknown variant `max`, expected one of `none`, `minimal`, `low`, `medium`, `high`, `xhigh`", so `max` is omitted. The ceiling is `xhigh`, identical to codex. |

When a requested effort value is outside the harness-specific accepted set, `fm-spawn` records the requested `effort=` in meta but emits no effort flag for that harness.
This preserves launch success instead of passing a known-bad value.

## no-mistakes skill invocation

Send the validation skill using the target harness's skill invocation form.
Natural language is acceptable if uncertain.

- claude: `/<skill>`, for example `/no-mistakes`.
- codex: `$<skill>`, for example `$no-mistakes`; `/<skill>` is claude-only and codex rejects it as "Unrecognized command".
- traex: `$<skill>`, the same codex-style popup. But `~/.trae/skills` has no `no-mistakes` skill, so a traex crewmate cannot run the gated pipeline at all; do not route gated work to one (see the traex section below).
- opencode: no separate verified skill invocation beyond normal slash-command behavior; use natural language if the exact skill command is uncertain.
- pi: no separate verified skill invocation beyond normal command behavior; use natural language if the exact skill command is uncertain.
- grok: `/<skill>`, for example `/no-mistakes` (same form as claude). Verified end to end: grok discovers the user-level `no-mistakes` skill, `/no-mistakes` invokes it, and grok drives a real `no-mistakes axi run`. Like codex's `$`/`/` popups, typing `/<skill>` opens grok's slash-autocomplete, so a too-fast Enter selects the popup entry instead of sending, and for an argument-taking command (like `/no-mistakes`'s optional task-first argument) that first Enter only expands the popup selection into an argument-hint placeholder rather than submitting - a genuine second Enter is required (see the grok section below for the 2026-07-03 incident and fix). `fm_tmux_submit_core`'s retried Enter (used by `fm-send` on the tmux backend) already handles this correctly by reading the cursor row; the herdr backend needed a dedicated fix (`fm_backend_herdr_composer_state`, docs/herdr-backend.md) because its prior delta-based verification false-positived on that same popup-close content change.

## claude (VERIFIED)

| Fact | Value |
|---|---|
| Busy-pane signature | the spinner status line `<glyph> <Verb>… (<status>)`, e.g. `✻ Whatchamacalliting… (2s · thinking with high effort)`. Recorded on 2.1.207 and re-verified on 2.1.220 (2026-07-28): claude renders NO `esc to interrupt` hint at all, so the hint regex never fires on it, and the spinner shape in `bin/fm-tmux-lib.sh` is the only signature that sees a busy claude. |
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

**No-break space in the composer (verified 2026-07-28, Claude Code 2.1.220).**
claude renders its bare composer prompt as `❯` followed by U+00A0 NO-BREAK SPACE, not an ASCII space (`tmux capture-pane -e | od -c` shows `342 235 257 302 240`).
POSIX `[:space:]` does not cover U+00A0, so an ASCII-only trim left the row non-empty and every idle claude composer classified as pending input.
That single misread broke both readers built on the composer verdict: `fm-send` exited non-zero with a false "Enter swallowed" for steers the target had already received, which invites the caller to re-send and dispatch the same instruction twice, and the away-mode injector read every idle claude pane as holding typed text.
The fix is `fm_composer_trim` in the shared `bin/fm-composer-lib.sh`, which counts U+00A0 as whitespace for every adapter at once; regression coverage is in `tests/fm-composer-lib.test.sh` and `tests/fm-tmux-submit-busy.test.sh`.
Sending to a BUSY claude relies on the same busy-queued-Enter fallback recorded under opencode below, which needed the widened busy signature in the table above before it could see a busy claude at all.

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
The fallback is harness-generic, but it is only as good as the busy signature
it asks: a harness whose busy line the spinner regex misses reads idle, and the
fallback silently stops rescuing it (that is exactly what happened to claude
until 2026-07-28 - see the claude section above).
Regression coverage: `tests/fm-tmux-submit-busy.test.sh` covers the four
opencode scenarios (busy + pending -> `empty`, idle + pending -> `pending`,
busy + cleared -> `empty`, idle + cleared -> `empty`) plus claude's own cleared
-> `empty` and idle-swallow -> `pending` cases.

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

## grok (VERIFIED 2026-06-29, grok 0.2.73; slash-submit re-verified 2026-07-03 on 0.2.82; reasoning-effort ceiling re-verified 2026-07-13 on 0.2.99; exit paths re-verified 2026-07-19 on grok 0.2.103)

Grok Build TUI (`grok`), a Claude-Code-compatible CLI from xAI.
Launch with a positional prompt: `grok --always-approve "$(cat <brief>)"`.
For Grok's supported reasoning-effort values and omission behavior, see the [launch-profile-axes table](#launch-profile-axes).

| Fact | Value |
|---|---|
| Busy-pane signature | `Ctrl+c:cancel` (the mid-turn cancel hint in grok's keybind bar, shown iff a turn is running; the spinner line is a braille glyph + `<status>… N.Ns` + `[stop]`, e.g. `⠹ Thinking… 1.1s … [stop]`). Idle keybind bar shows only `Shift+Tab:mode │ Ctrl+.:shortcuts`. The ASCII `Ctrl+c:cancel` is the busy regex (avoids locale fragility of matching braille). |
| Exit command | `/exit` typed into the composer exits the TUI cleanly and prints `Resume this session with: grok --resume <session-id>`; `Ctrl+Q` double-press within 1000ms remains a fallback; `Ctrl+D` is the quit key in VS Code family terminals; `Ctrl+C` is the interrupt, not the exit. |
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

## traex (VERIFIED 2026-07-17, traex 0.200.13; primary/secondmate surfaces added 2026-07-20)

TRAE CLI 2.0, a fork of `openai/codex` maintained by the TRAE team, so it inherits codex's launch shape, `notify=` turn-end, `esc to interrupt` busy line, `$<skill>` popup, and codex's primary supervision shape (foreground checkpoint, blocking Stop hook).
The crewmate/scout face is fully verified including live runs.
The primary and secondmate faces are wired (parity work P1-P4) and component-verified - the `.trae/hooks.json` guard and PreToolUse seatbelts, the `traex.md` checkpoint protocol, the lock and liveness arms, and the no-notify secondmate launch - but a real long-running traex primary session (watcher-checkpoint loop, wake handling, afk, X mode) has not been exercised end to end, so treat that as the remaining live gap (see "Scope").

**The binary is `traex`. Never `traecli`.**
On a box that kept the TRAE CLI 1.0 install, `traecli`, `trae-cli`, `trae-agent`, `coco`, and `ta` all resolve to **coco 1.0 - a different agent** (verified: `traex --version` prints `traecli 0.200.13`, while `traecli --version` prints `coco version 0.120.47`).
Launching one of those names would leave firstmate supervising the wrong agent while believing it drives TRAE 2.0.
The trap is easy to walk into because **traex prints the wrong command itself**: on `/quit` it prints `To continue this session, run traecli resume <id>` (verified verbatim).
The correct resume is `traex resume <id>`; never copy traex's own printed resume line.

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt` - matches the DEFAULT regex with NO override |
| Exit command | `/quit` (also `/exit`); opens a slash popup, same settle as codex |
| Interrupt | single Escape (pane shows `■ Interrupted by user`) |
| Skill invocation | `$<skill>`, codex-style popup (`/<skill>` is claude-only) |
| Autonomy | `-y` (long form `--dangerously-bypass-approvals-and-sandbox`) |
| Model flag | `-m`/`--model <MODEL>` |
| Effort flag | `-c model_reasoning_effort="<none\|minimal\|low\|medium\|high\|xhigh>"`; see the [launch-profile-axes table](#launch-profile-axes) |
| Turn-end hook | codex-style `-c notify=[...]`, fires in TUI and exec, needs NO hook trust |
| Env marker | `TRAECLI_SESSION_INBOX` (see the detection warning below) |
| Resume | `traex resume [SESSION_ID] [--last]`, plus `fork` |

**Busy signature: the anchor is `esc to interrupt` and nothing else.**
The default `FM_TMUX_BUSY_REGEX_DEFAULT` matches unchanged; no `FM_BUSY_REGEX` override is needed.
Two observed properties make the anchor load-bearing rather than incidental.
The status VERB and spinner GLYPH both vary - `◆ ❖ ◇ ◈` with `Working…`, `Thinking longer…`, `Running command…`, and `Poking the model…` all seen live - so anchoring on any verb would be fragile.
And `Working…` uses a Unicode ellipsis (U+2026, bytes `e2 80 a6`), so the default's `Working\.\.\.` alternative does **not** match: `esc (to )?interrupt` is the only alternative that fires on a traex busy line.
Verified in both directions against firstmate's own `fm_pane_is_busy` on a live pane: busy renders BUSY, idle renders NOT-BUSY.
The idle pane's `esc again to edit previous message` hint contains `esc` but not `interrupt`, so it does not false-positive.

**Composer classification: no override needed.**
Verified against the real `fm_tmux_composer_state`: an idle composer reads `empty` (its ghost placeholder is dim SGR 2, already stripped by `fm_composer_strip_ghost`, and `❯` is already a known agent glyph), and the trust dialog reads `unknown`, so firstmate will not inject into it.

**Detection: use `TRAECLI_SESSION_INBOX`, never `TRAECLI_SESSION_ID`.**
traex sets `TRAECLI_SESSION_INBOX` for its shell-tool children, and the substring `INBOX` appears nowhere in the coco 1.0 binary, so it cleanly separates 2.0 from 1.0.
`TRAECLI_SESSION_ID` is present in BOTH binaries and therefore cannot tell them apart - do not use it as a marker.
traex is a codex fork and also exports `CODEX_CI=1`, `CODEX_THREAD_ID`, `CODEX_SANDBOX`, and `CODEX_SANDBOX_NETWORK_DISABLED`, so its marker must be tested before any codex inference or every traex child reads as codex.
`bin/fm-harness.sh`'s ancestry arm matches the command name `traex` EXACTLY, never a `*trae*` glob, because such a glob would report traex for coco's process names.

**Startup dialogs: expect ONE, possibly TWO, and `-y` suppresses neither.**
First run per repo shows the directory-trust dialog (`Do you trust the contents of this directory?` / `❯ 1. Yes, continue` / `2. No, quit`); Enter accepts.
It is keyed to the REPOSITORY ROOT, not the worktree - launched inside a worktree it says "Trusting will apply to the repository root" - so later worktrees of the same project skip it, exactly like codex.
Accepting writes `[projects."<repo-root>"] trust_level = "trusted"` into `traecli.toml`, so traex grows the user's own config as projects are trusted; that file is traex's to manage and firstmate must not hand-edit it.
A SECOND dialog appears when any configured hook is new or changed: `Hooks need review` / `1. Review hooks` / `❯ 2. Trust all and continue` / `3. Continue without trusting (hooks won't run)`.
It is not triggered by firstmate's own wiring (see hook trust below), but it WILL stall a crewmate whenever the user's `traecli.toml` hooks change, so peek the pane after spawn and answer whatever is showing.

**Hook trust: why the turn-end signal is `notify=` and not `[[hooks.Stop]]`.**
traex has two independent gates, and directory trust is NOT hook trust: with a directory already `trust_level = "trusted"`, a user-config `[[hooks.PreToolUse]]` still did not run.
Hook trust is content-addressed - `[hooks.state."<config-path>:<event>:<i>:<i>"] trusted_hash = "sha256:<hash of the hook command>"` - so a per-task hook command (which necessarily embeds that task's own turn-end path) hashes differently every task and could never match a stored hash.
An untrusted hook in non-interactive `exec` mode is **silently ignored**: no prompt, no warning, the tool call just proceeds.
That is a fail-OPEN, invisible failure, which is exactly what a turn-end signal must never do.
`-c notify=[...]` is not hook-trust-gated (verified firing with no bypass flag, in both TUI and exec), needs nothing written into the worktree, and is therefore what `fm-spawn` wires.
`--dangerously-bypass-hook-trust` runs enabled hooks without persisted trust for one invocation and prints its own warning; firstmate does not use it.

**PreToolUse deny works, and `-y` does not override it.**
With hook trust bypassed, a claude-style `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}` blocked the command: the pane showed `hook: PreToolUse Blocked` and the reason reached the model, even under `-y`.
So the deny semantics an arm seatbelt would need are present - but any such hook is subject to the trust gate above.

**Primary and secondmate surfaces (parity P1-P4, 2026-07-20).**
traex is now wired as a full-role harness, mirroring codex because it is a codex fork:
- `.trae/hooks.json` (tracked, a mechanical copy of `.codex/hooks.json`) carries the Stop turn-end guard and the two PreToolUse seatbelts. Verified: the Stop guard blocks on exit 2 with `stop_hook_active` reentry (scout §4.3), and a live `bin/fm-watch.sh --arm` was blocked end to end through the real policy (`[watcher-direct]`).
- `docs/supervision-protocols/traex.md` is codex's foreground-checkpoint protocol; `bin/fm-supervision-instructions.sh` renders it and its checkpoint repair line for `--harness traex`.
- `bin/fm-lock.sh` `HARNESS_RE` recognizes a traex session-lock holder; `bin/backends/tmux.sh`'s agent-liveness arm classifies a live traex pane as alive.
- `bin/fm-spawn.sh` launches a traex secondmate with codex's no-notify shape (turn-end rides the `.trae/hooks.json` guard inside the secondmate home). The earlier fail-closed refusal is gone.

The **remaining live gap**: no real long-running traex primary session (watcher-checkpoint loop, wake handling, afk, X mode) or full live secondmate-home charter run has been exercised end to end; the surfaces above are component-verified (isolated homes, deterministic launch shapes, unit tests). Before running firstmate itself on traex as a primary, exercise a real primary session in a throwaway home and confirm the checkpoint+guard loop.

**Hook trust is the operational precondition for the primary/secondmate guards.**
The `.trae/hooks.json` hooks load only after the firstmate checkout is granted directory trust AND a one-time hooks-review "Trust all" (default selection, single Enter). The fixed command hashes stay trusted across new sessions, `exec`, and `resume`.
First launch in any NEW firstmate home (a secondmate home, or the primary on a fresh box) therefore shows TWO dialogs: directory trust, then hooks review. Peek the pane after spawn and press Enter for both.
Until trust is established the guard and seatbelts are inert, and an untrusted hook in headless `exec` is silently ignored (fail-open) - so any headless traex use must confirm trust is already established.

**A traex crewmate cannot run the no-mistakes gate until the skill is installed.**
`~/.trae/skills` holds 58 skills but no `no-mistakes`, even though the `no-mistakes` binary is on PATH and the skill exists for claude.
Parity P0 is to install it into a shared skill root - `~/.agents/skills/no-mistakes/` (recommended, serves every harness) or `~/.trae/skills/no-mistakes/`. Verified: dropped into `$TRAE_HOME/skills`, `$no-mistakes` lists in the popup and injects the SKILL.md content, and the model reaches `no-mistakes axi` in a traex shell child.
Until it is installed there, do not route gated-pipeline work to a traex crewmate; fast-path work (direct-PR, local-only) is unaffected.

**Startup noise.**
Every launch prints a non-fatal `Failed to update built-in plugin marketplace 'traex-bd-plugins': ... git@code.byted.org: Permission denied (publickey...)` when no `code.byted.org` SSH key is present.
It does not match the busy regex and does not corrupt supervision.
