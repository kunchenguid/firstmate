# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files only adapt each verified harness's turn-end mechanism to that shared predicate.

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
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and uses `bin/fm-turnend-guard-grok.sh` to resume the reported session once when the shared guard returns 2.
  The adapter intentionally omits `--permission-mode`, so a passive hook cannot grant stronger permissions than the resumed session default.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, `state/.claude-autoarm.lock` has a live owner, or `state/.claude-autoarm-epoch` contains a fresh rewake outcome.
When none of those proofs appears, it re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override), then allows degraded with a visible `systemMessage`.
Any allow resets the budget.

## 2026-07-24 stale-lock incident closure

The pre-fix failure was reproduced through Claude Code 2.1.219 in a disposable plain clone and isolated `FM_HOME` with one synthetic task record, no watcher lock or beacon, and `state/.lock` set to a dead numeric owner.
The expected first transition was for `bin/fm-session-start.sh` to run, reclaim the stale owner through `bin/fm-lock.sh`, and leave the next Stop eligible for auto-arm.
Instead, the former watcher-status PreToolUse hook denied that first command, and the stale session lock then kept the Stop hook from claiming recovery.
The visible result was three consecutive `TURN WOULD END BLIND` continuations in one fresh session, each reporting that the Stop-owned auto-arm had not claimed the home.
The real Claude path and direct hermetic controls produced the same initiating denial, stale-owner veto, and repeated manual-repair wedge.
Running `bin/fm-lock.sh` directly under the same dead-owner fixture reclaimed the lock, which separated the proven acquisition path from the denied caller.
The first correction attempted to add session start to the hook's recovery set, but review showed that command classification still could not restore supervision and conflicted with required wake handling.
The replacement removes the watcher-status hook and its classifier entirely, so no fleet command is denied based on watcher status.
The durable wake queue preserves actionable events during Claude's residual active-turn window, and this unchanged bounded guard remains the Stop boundary when auto-arm recovery is absent.
The independent stale-owner correction delegates an eligible claim to the atomically serialized `bin/fm-lock.sh` path from PR 996 after the unchanged scope, AFK, and supervision-need checks.
A live verified-harness owner remains disconfirming evidence against lock takeover because the competing hook stays silent and leaves the owner unchanged.
Session start's existing read-only refusal and the Stop hook's shared liveness predicate preserve the live-owner boundary.

OpenCode, Pi, and Grok expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session but schedule one bounded follow-up when the predicate blocks.
The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `FIRSTMATE_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each adapter owns a loop latch.
Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`.
OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.

If a passive adapter cannot invoke its SDK, find `grok`, or recover a Grok session id, the next pull-based `fm-guard.sh` call reports the problem.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope; an idle secondmate endpoint with no X-mode relay poll remains healthy because it has no supervision need.
- Claude and Codex block directly, while OpenCode, Pi, and Grok use bounded passive follow-ups.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Missing `jq` or unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers the predicate, main and secondmate primary scope, child-worktree exclusion, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the cooperative `--claude` claim wait, epoch allow, re-block budget, Pi logical-run latching, missing-`jq` behavior, all five registrations, and Grok resume permission and recursion safety.
`tests/fm-subagent-pretool-check.test.sh` proves no watcher-status Bash hook remains.
`tests/fm-claude-stop-autoarm.test.sh` covers the stale-owner claim and competing-live-owner refusal.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` preserves the real fresh-session incident shape as opt-in regression coverage.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation.
