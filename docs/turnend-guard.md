# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Current invariant

`bin/fm-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.
When work is in flight and no identity-matched watcher has a fresh beacon, the harness integration must either block the turn end or force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.
The guard remains a backstop; [`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Shared predicate

The guard first calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must be a regular non-symlink file whose whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.
An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

For an in-scope primary, the guard counts in-flight work from `state/*.meta`.
The default cross-harness mode exits silently with no work in flight.
Claude's `--claude` mode also treats `state/x-watch.check.sh` as supervision need, so X-mode relay polling remains guarded without an in-flight task.
Otherwise it calls `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`, the same identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`.
A stale beacon blocks even when a watcher pid is live.
A fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
`FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields.

## Harness integrations

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and delegates capability selection to `bin/fm-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert when `GROK_AGENT` is present, so Grok's Claude-compatible settings loading cannot create a second continuation path.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, `state/.claude-autoarm.lock` has a live owner, or `state/.claude-autoarm-epoch` contains a fresh rewake outcome.
When none of those proofs appears, it re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override), then allows degraded with a visible `systemMessage`.
Any allow resets the budget.

OpenCode, Pi, and pi-signed expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session but schedule one bounded follow-up when the predicate blocks.
The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `FIRSTMATE_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each passive adapter owns a loop latch.
Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.

Grok makes exactly one typed capability decision from each running Stop payload.
A boolean `stopHookActive` selects native blocking, including both false on the initial stop and true on the bounded continuation.
The camel-case field has precedence when both spellings appear; when it is absent, a boolean `stop_hook_active` selects the same native path for compatibility.
The native path returns the shared guard's status and stderr to the same Grok process and never starts `grok --resume`.
When both capability spellings are absent, the adapter preserves one pre-native `grok --resume` fallback guarded by `GROK_TURNEND_GUARD_ACTIVE` and intentionally omits `--permission-mode`.
Malformed JSON, a selected field with a non-boolean type, missing `jq`, missing hook prerequisites, or an already-active legacy guard allows the stop without starting either continuation path.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`; genuine pre-native builds can run the same tracked hook from an isolated global hook directory.

If a passive adapter cannot invoke its SDK, or the Grok legacy fallback cannot find `grok` or a session id, the next pull-based `fm-guard.sh` call reports the problem.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope; an idle secondmate endpoint with no X-mode relay poll remains healthy because it has no supervision need.
- The direct-blocking and bounded passive-follow-up split is limited to the primary integrations listed above.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/fm-kimi-turnend-hook.sh` to edit only one marker-delimited Firstmate region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers the predicate, main and secondmate primary scope, child-worktree exclusion, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the cooperative `--claude` claim wait, epoch allow, re-block budget, Pi logical-run latching, missing-`jq` behavior, all five primary registrations, Grok native and legacy selection, typed field precedence, malformed input, and exactly-one-path safety.
`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation.
This is the authoritative contract for the "no turn ends blind" primary guard referenced from AGENTS.md section 8.
The shared predicate lives in `bin/fm-turnend-guard.sh`.
Harness-specific tracked hook files only adapt each verified harness's real turn-end mechanism to that shared predicate.
Two related but separate PreToolUse seatbelts deny a bad command shape before it runs rather than detecting a blind turn end afterward: the watcher-arm seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`) and the cd-guard (`bin/fm-cd-pretool-check.sh`, `docs/cd-guard.md`).
Each seatbelt's own document defines its scope; they do not share the turn-end guard's marker-aware primary detection.

## Gap Closed

`bin/fm-guard.sh` is pull-based: it warns whenever some other supervision script happens to run, and prints nothing otherwise.
The primary can otherwise end a turn after handling wakes without resuming supervision, then sit blind until another fleet command happens to run.
On 2026-07-04, that exact gap left a parked no-mistakes gate unwatched for about nine hours.

`bin/fm-turnend-guard.sh` closes the gap by checking the primary's own turn-end path.
When tasks are in flight and there is no live identity-matched watcher with a fresh beacon, a harness hook must either block the turn end or force a bounded follow-up turn that tells the primary to resume the session-start supervision protocol for its harness.

## Shared Predicate

The guard first scopes itself to a real primary checkout.
A secondmate home runs its own primary firstmate session, so a genuine `.fm-secondmate-home` marker force-includes it whether treehouse leased it as a linked worktree or it is a git-cloned plain checkout.
The marker must be a regular non-symlink file whose first line, after all whitespace is removed, contains a non-empty identifier made only of letters, digits, dots, underscores, and dashes.
An unmarked checkout, or one with an invalid marker, falls through to the git-dir check.
That check keeps crewmate and scout worktrees inert because firstmate provisions them as linked git worktrees, where `git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`.
It also requires `AGENTS.md`, `bin/`, and the effective state directory to exist.

For an in-scope primary checkout, it counts in-flight work from `state/*.meta`.
If no task is in flight, it exits silently.
If work is in flight, it requires `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`.
That is the same identity-matched live lock and fresh beacon check used by `bin/fm-watch-arm.sh`.
A stale beacon blocks even if a watcher pid is still live.
A fresh leftover beacon blocks if the watcher lock is missing, dead, or identity-mismatched.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repo-root `state/`.
`FM_GUARD_GRACE` controls the beacon freshness window and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard fails open and exits 0 because it cannot safely read loop-guard fields.

## Harness Integrations

All verified primary harnesses have a tracked integration:

- `claude`: `.claude/settings.json` registers a `Stop` hook command anchored through `"$CLAUDE_PROJECT_DIR"/bin/fm-turnend-guard.sh`.
- `codex`: `.codex/hooks.json` registers a `Stop` hook that reads the hook payload once, anchors the executable to the hook command process working directory, verifies that root is firstmate-shaped and hook-bearing, and pipes the original payload to that checkout's `bin/fm-turnend-guard.sh`.
- `opencode`: `.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`, lets the watcher-arm coordinator handle normal idle supervision first, runs the shared guard only when that coordinator does not act, and uses `client.session.promptAsync` to force one follow-up prompt when the guard returns 2.
- `pi`: `.pi/extensions/fm-primary-turnend-guard.ts` listens for `agent_settled`, marks the extension version loaded for session-start checks, runs the shared guard once per logical agent run, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one follow-up prompt when the guard returns 2.
- `grok`: `.grok/hooks/fm-primary-turnend-guard.json` registers a `Stop` hook that invokes `bin/fm-turnend-guard-grok.sh`.
  The adapter runs the shared guard and, when it returns 2, invokes `grok --resume <sessionId> -p <guard-reason>` with `GROK_TURNEND_GUARD_ACTIVE=1`.
  It does not pass `--permission-mode`, so the passive Stop hook cannot grant stronger tool permissions than Grok's resumed-session default.
- `devin`: `.devin/config.json` registers a direct blocking `Stop` hook anchored to the hook process working directory and invokes `bin/fm-turnend-guard.sh`.

Claude, Codex, and Devin support a direct blocking Stop hook.
For those harnesses, exit status 2 plus stderr from `bin/fm-turnend-guard.sh` blocks the stop and feeds the reason back into the model.
Their payloads include `stop_hook_active`; when it is true, the shared guard exits 0 so the harness can end after one forced continuation.

Devin CLI 3000.1.27 was validated on 2026-07-13 in isolated git repositories and tmux sessions.
Repository `.devin/config.json` loaded automatically, a Stop hook touched its sentinel after the model completed a turn, `devin` remained the foreground process, and the busy footer rendered `esc to interrupt`.
The same build exposed the Claude-compatible `stop_hook_active` payload and direct hook exit semantics used by the shared guard.

OpenCode, Pi, and Grok expose passive lifecycle callbacks for this purpose.
Their adapters fail open at the hook boundary to avoid corrupting a user session, but they force one follow-up turn when the shared predicate blocks.
Each adapter carries its own in-process or environment loop guard so the forced follow-up does not recursively schedule another follow-up.
Pi keeps that latch active across every internal tool turn and clears it only when the generated guard follow-up reaches `agent_settled`, or immediately when follow-up delivery fails.
If a passive adapter cannot call its SDK method, cannot find `grok`, or cannot recover the Grok session id, it fails open and relies on the pull-based `fm-guard.sh` warning at the next fleet command.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it points back to the active harness protocol instead of hardcoding one background-arm command.

## Empirical Validation

All harnesses were validated on 2026-07-08 in scratch repos or throwaway homes, not against the captain's live primary fleet state.

Claude Code 2.1.204 preserved the existing behavior.
Hook file used: `.claude/settings.json`.
Command run: `claude -p "Say hi in exactly one word." --dangerously-skip-permissions --output-format json` with a scratch Stop hook that printed `SMOKETEST: you must say the word BANANA before stopping` and exited 2.
Observed output: the first stop payload had `stop_hook_active=false`, the stop was blocked, the model continued with `BANANA`, and the second stop payload had `stop_hook_active=true` and was allowed.
Earlier validation on 2026-07-04 also verified that `CLAUDE_PROJECT_DIR` is set to the settings-loaded project root, while the hook command itself runs from the session cwd.

Codex `codex-cli 0.142.1` was validated with a scratch `.codex/hooks.json` Stop hook.
Hook file used: `.codex/hooks.json`.
Command run: `codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Say hi in exactly one word.'`.
Observed output: the first model output was `Hi`, the Stop hook exited 2, Codex logged `hook: Stop Blocked`, the model continued with `CODEXHOOK`, and the second hook call had `stop_hook_active=true`.
The Stop payload included `cwd`.
Command run for root-signal probe: `codex exec --ephemeral --json --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --output-last-message last.txt 'Use the shell tool to run mkdir -p outside && cd outside && pwd, then use the shell tool again to run pwd. Your final answer must include the two observed outputs.'`.
Observed output: the first command printed `<scratch>/outside`, the second command printed `<scratch>`, the Stop hook process `pwd -P` printed `<scratch>`, payload `cwd` printed `<scratch>`, and `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, and `CODEX_CWD` were empty.
The tracked command therefore treats hook process PWD as the hook-loaded firstmate root and does not let payload `cwd` choose an executable.
It still passes the original payload to `bin/fm-turnend-guard.sh`, so the shared loop guard reads `stop_hook_active`.

OpenCode 1.17.6 was validated with project plugins under scratch `.opencode/plugins/`.
Hook file used: `.opencode/plugins/fm-smoke.js` for throw testing and `.opencode/plugins/fm-primary-turnend-guard.js` for follow-up testing.
Command run for passive behavior: `opencode run --print-logs --log-level DEBUG --dangerously-skip-permissions 'Say hi in exactly one word.'`.
Observed output: the plugin received `session.idle`, threw an error, and `opencode run` still exited 0 with `Hi`, proving `session.idle` cannot block directly.
Command run for follow-up behavior: `OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt 'Say hi in exactly one word.' --print-logs --log-level INFO`.
Observed output: the plugin called `client.session.promptAsync`, the TUI ran a second turn, and the second model output contained `OPENCODEHOOK`.
In noninteractive `opencode run`, `promptAsync` returned successfully but the process exited before displaying the follow-up, so this adapter is trusted for primary TUI sessions and documented as passive/fail-open in headless mode.

Pi 0.80.5 was re-validated on 2026-07-09 in a disposable primary-shaped clone with isolated `PI_CODING_AGENT_DIR`, isolated `FM_HOME`, and tmux socket `fm-pi-q6-lab`.
Hook files used: the tracked `.pi/extensions/fm-primary-turnend-guard.ts` and `.pi/extensions/fm-primary-pi-watch.ts`.
Commands run inside separate interactive turns: `printf PI_E2E_BASH_ONE` through Pi's bash tool, `README.md:1-5` through Pi's read tool, and `printf PI_E2E_BASH_TWO` through Pi's bash tool.
Command used to make the shared predicate unhealthy: `: > "$FM_HOME/state/pi-e2e.meta"`.
The next no-tool prompt produced exactly one `TURN WOULD END BLIND` follow-up, and that follow-up called `fm_watch_arm_pi` once with output `watcher: started Pi extension arm child 1`.
The three earlier tool turns produced no guard follow-up because no work was in flight.
Command used to fire the watcher: `printf 'done: pi e2e watcher fire\n' > "$FM_HOME/state/pi-e2e.status"`.
Observed output after the wake: Pi ran `bin/fm-wake-drain.sh`, read the terminal status, called `fm_watch_arm_pi`, and rendered `watcher: started Pi extension arm child 2`.
The complete pane contained one guard message and zero foreground `bin/fm-watch-arm.sh` bash calls.
`/quit` printed `PI_EXIT=0`, and the second arm process plus its watcher child were both gone afterward.

Grok 0.2.91 was validated with a scratch `GROK_HOME` and symlinked auth/config.
Hook file used for tracked project-hook loading: `<scratch-project>/.grok/hooks/fm-smoke.json`, matching the tracked `.grok/hooks/fm-primary-turnend-guard.json` location.
Command run for project-hook loading: `GROK_HOME="$scratch/grok-home" grok --trust -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the project Stop hook fired under `--trust` and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`.
Hook file used for passive behavior and forced-resume behavior: `$GROK_HOME/hooks/fm-primary-turnend-guard.json` plus `bin/fm-turnend-guard-grok.sh`.
Command run for passive behavior: `GROK_HOME="$scratch/grok-home" grok -p 'Say hi in exactly one word.' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the global Stop hook fired and received `GROK_HOOK_EVENT=stop`, `GROK_WORKSPACE_ROOT`, and a payload containing `sessionId`, but exiting 2 did not make the model continue.
Command run for forced resume behavior: the Stop hook ran `GROK_TURNEND_GUARD_ACTIVE=1 GROK_HOME="$scratch/grok-home" grok --resume "$session_id" -p 'SMOKETEST: say exactly GROKRESUMEHOOK...' --permission-mode bypassPermissions --output-format plain --leader-socket "$scratch/leader.sock"`.
Observed output: the outer turn printed `Hi`, the nested resumed turn printed `GROKRESUMEHOOK`, and the nested Stop hook saw `GROK_TURNEND_GUARD_ACTIVE=1` and did not recurse.
That validation command used `--permission-mode bypassPermissions` only to keep the scratch smoke unattended; the tracked adapter intentionally omits `--permission-mode`.
Project-local Grok hooks did not fire in scratch single mode without a trust grant.
The primary integration therefore requires the primary firstmate checkout to be trusted for Grok hooks, which can be done with `/hooks-trust` or launch-time `--trust`.
If Grok declines to load project hooks, this primary guard fails open and `fm-guard.sh` remains the next-command alarm.

**2026-07-09 update:** grok 0.2.93 broke the `.grok/hooks/fm-primary-turnend-guard.json` Stop hook with `hook not executed: required env var(s) not set: ${root}`, because grok's own `${VAR}` expansion over the raw `command` string does not tolerate a bare local variable assigned earlier in the same `bash -lc` script.
The hook command was fixed to reference `${GROK_WORKSPACE_ROOT:-}` directly everywhere instead of assigning it to `$root` first, and re-validated against grok 0.2.93 to fire and complete cleanly.
See `docs/arm-pretool-check.md`'s "Harness wiring" section for the same Grok expansion requirement; that document's Grok hook shares the same fix.

### 2026-07-12: secondmate-home enablement and the autonomous background-notify wake

The guard originally early-exited in every secondmate home on the `.fm-secondmate-home` marker.
That was a scoping choice inherited from the guard's primary-only origin, not a defense against any secondmate-specific hazard.
A genuinely marked secondmate home is now force-included as a guarded primary regardless of whether it is a treehouse-leased linked worktree or a git-cloned plain checkout.
Only unmarked child worktrees fall through to the linked-worktree exemption, and marker validation prevents an empty, malformed, or symlink marker from spoofing inclusion.

"No turn ends blind" for a secondmate is delivered by the same two mechanisms the main primary relies on.
Mechanism B, the turn-end backstop, is this guard; its secondmate-home behavior is covered by hermetic tests in `tests/fm-turnend-guard.test.sh` (`test_hook_blocks_in_secondmate_own_home`, `test_hook_blocks_in_treehouse_leased_secondmate_home`, `test_hook_silent_in_idle_secondmate_home`, `test_hook_secondmate_loop_guard_allows_retry`, `test_hook_secondmate_reinvoke_recovery_loop`, `test_hook_silent_in_secondmate_child_worktree`, and `test_hook_exempts_linked_worktree_with_stray_marker`).
Mechanism A, the autonomous wake, is a harness property: when a background watcher task exits, the harness re-invokes the model, which drains the wake, advances children, and re-arms a fresh watcher.
Mechanism A cannot be a hermetic CI assertion because it requires a live model session, so it is recorded here as a dated first-hand measurement while `test_hook_secondmate_reinvoke_recovery_loop` covers the guard's deterministic half of the same recovery loop.

Autonomous-re-invoke measurement, run first-hand on Claude Code 2.1.207 (Darwin 25.5.0) on 2026-07-12.
Procedure: launch a detached `run_in_background` Bash task that models a one-shot watcher - it records a launch epoch, runs `sleep 25`, then records a completion epoch just before exit, writing only to the session scratchpad - then end the turn with no further tool calls and no pending question, a genuinely idle session with no human input.
Observed marker timestamps:

```
launch_epoch    = 1783890980   (14:16:20)   turn ends, session goes idle
complete_epoch  = 1783891005   (14:16:45)   background task exits, 25s idle
reinvoke_epoch  = 1783891016   (14:16:56)   MODEL RE-INVOKED
--------------------------------------------------------------
wake latency (task complete -> model re-invoked): 11s, with ZERO human input
```

The re-invocation arrived as a `<task-notification>` whose accompanying system notice stated verbatim "No human input has been received since the last genuine user message in this conversation".
So the model was re-invoked solely by the background task's completion while idle, which is Mechanism A - the same background-notify wake the Claude supervision protocol relies on for the main primary.
This matches the harness tool contract that a `run_in_background` task "keeps running across turns and re-invokes you when it exits", and reproduces the 11s latency the task audit measured independently on the same harness version.
No Herdr command was issued and no fleet state was touched; the experiment wrote only to the session scratchpad, which was discarded.

## Tests

`tests/fm-turnend-guard.test.sh` covers the shared predicate, primary scoping (including a secondmate's own home being guarded like the main primary while its child worktrees stay exempt), `FM_HOME` and `FM_STATE_OVERRIDE` precedence, Pi logical-run latch behavior for no-tool and multi-tool runs, fail-open behavior without `jq`, tracked hook registration for the established adapters, and the Grok adapter's forced-resume loop guard and permission-mode regression.
The default behavior suite does not invoke live language-model harnesses.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` opts into the isolated interactive Pi regression recorded above.
