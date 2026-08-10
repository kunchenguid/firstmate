# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The turn-end predicate lives in `bin/fm-turnend-guard.sh` and delegates the shared supervision-need decision to its sole authority, `bin/fm-supervision-lib.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start nudge in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Current invariant

`bin/fm-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.
When work, a process-event source, or X-mode relay polling needs supervision at that boundary and no identity-matched watcher has a fresh beacon, the harness integration must either block the turn end or force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.
The mid-turn pull warning uses the model-aware supervision verdict described below, while the turn-end guard keeps the PID-strict watcher predicate.
The guard remains a backstop; [`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Guard predicates

The guard first calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must be a regular non-symlink file whose whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.
An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

For an in-scope primary, ordinary worker and scout `state/*.meta` records always count as in-flight work.
A persistent `kind=secondmate` record is excluded only when cheap durable local parent evidence positively proves it is resting: its status is readable and parseable, ends in a resting reconciliation, has no open keyed activity, decision, or blocker under `bin/fm-classify-lib.sh`, and has no open parent pending reply.
Missing, unreadable, or ambiguous status evidence and unreadable or malformed pending-reply evidence count as need.
The shared `FM_SUP_IN_FLIGHT` banner count excludes only those positively idle secondmates, so a task count never includes work that does not require a watcher.
Registered `state/procevent/*.source` records also require supervision even though they have no task metadata.
The default cross-harness mode exits silently with no supervision need.
Every mode treats `state/x-watch.check.sh` as supervision need, so X-mode relay polling remains guarded without an in-flight task.
Otherwise it calls `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`, the same PID-strict identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`: a stale beacon blocks even when a watcher pid is live, and a fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.
The turn-end guard needs that strict check because it fires at the turn boundary, where the auto-arm is bringing a fresh watcher up for the upcoming idle period, and it cooperates with that arm rather than trusting a beacon left by the cycle that just ended.
`bin/fm-guard.sh`, the pull warning, instead uses the model-aware `fm_watcher_supervision_verdict` from the same library, because it fires mid-turn when the auto-arm model runs no watcher at all.
Under the Claude Stop auto-arm model a beacon fresh within grace is healthy even with no live watcher process, and only a beacon stale beyond grace (or absent) alarms.
Under every persistent-watcher harness a live identity-matched watcher with a fresh beacon is still required, so the pull guard keeps the same strict semantics there.
Its banner names the true failing condition, either a missing live watcher process or a genuinely stale beacon with its real age, and keys the once-per-episode dedup on that condition rather than the beacon mtime.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
`FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields.

## Harness integrations

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and delegates capability selection to `bin/fm-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert under Grok: they skip when `GROK_AGENT` or `GROK_WORKSPACE_ROOT` is set, or when `bin/fm-harness.sh` detects a Grok ancestor (Grok often omits `GROK_AGENT` on Stop hooks; that marker is for tool children).
  `bin/fm-claude-stop-autoarm.sh` and `bin/fm-turnend-guard.sh --claude` apply the same skip as defense in depth, so a missed settings guard cannot foreground-arm and freeze the Grok TUI.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, `state/.claude-autoarm.lock` has a live `autoarm` role owner whose eventual failure must exit 2, or `state/.claude-autoarm-epoch` contains a fresh actionable rewake owned by this event epoch.
Fresh `failed` and `failed-suppressed` outcomes enter or advance the failure progression instead of acting as unconditional recovery proof.
The auto-arm itself rechecks the healthy watcher predicate and retries a bounded number of times before reporting a genuine failure.
The first fresh exhausted-failure epoch preserves its handoff without consuming a blocked-stop count, while later fresh failed epochs advance the same monotonic progression instead of resetting it.
When none of those proofs appears, it re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override).
In Claude mode, positive watcher recovery clears the block budget, failure notice, and attended alarm together under the existing budget lock before either hook reports ordinary recovery.
The one loud attended fail-open is available only when the auto-arm has recorded an exhausted failure, its one notice is already consumed, the block budget is exhausted, and a final check finds neither a healthy watcher nor an automatic continuation.
Each epoch identity is accounted at most once under the budget lock.
Whenever both coordination locks are needed, positive auto-arm recovery and the terminal check acquire the auto-arm owner lock before the budget lock.
After that alarm, the Stop auto-arm suppresses further exit-2 continuations until positive watcher recovery, so the final fail-open remains reachable.
The alarm cannot repeat during that failure episode, and a later unhealthy stop blocks again.
A positively verified healthy watcher clears the failure notice, alarm, and block budget for a future independent episode.
A Claude failure notice describes the automatic mechanism as broken and does not direct a routine manual background arm.

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

## Captain-request follow-through

A second, independent turn-boundary predicate answers a different question: whether this turn would leave an explicit captain request unfinished.
`bin/fm-captain-commitment.sh` is its single owner and its header states the record format, the lifecycle, and the outstanding predicate in full.
It deliberately shares no state with the supervision predicate above, so neither one can corrupt the other's budget or latch, and `bin/fm-turnend-guard.sh` is unchanged by it.

The core script is harness-neutral, stores no captain message text, and keeps `tasks-axi` as the only owner of actual work.
When a record exists, every primary gets its durable surface, because `bin/fm-wake-drain.sh` prints `fm-captain-commitment.sh pending` on both the drained and the empty-queue path, which puts it in the session-start digest, on every wake-handling turn, and on the away-mode return path through `bin/fm-afk-return.sh`.
`bin/fm-session-start.sh` marks a surviving record deferred before that drain, because a session that ended without dispositioning its record is itself the interruption.

Automatic detection at the turn boundary is currently a Pi-only integration, and this is the whole of that boundary.
`.pi/extensions/fm-primary-turnend-guard.ts` opens a record from `before_agent_start` when `bin/fm-operational-input.sh classify` does not recognise the raw submitted prompt, passes the classified kind to `defer` when it does or defers unconditionally when `session_compact` fires, and injects one bounded `turn-end-guard` follow-up from `agent_settled` when `fm-captain-commitment.sh check` returns 2.
The extension classifies but never decides: which kinds actually displace a captain request is policy the owner script holds, so a startup nudge and the guard's own follow-up leave the record alone while everything else defers.
Supervision keeps precedence in that handler, and the commitment check carries its own latch so the guard predicate still runs exactly once per logical agent run.
Every other verified primary remains behaviorally unchanged and is explicitly unsupported for automatic detection: the durable record and its informational surfaces work when a record exists, but automatic open, operational defer, compaction defer, and turn-boundary refusal are absent.
Extending one means adding the same two structural signals from that harness's own submitted-prompt hook and turn-end hook, for example Claude's `UserPromptSubmit`, and never inferring a captain message from body prose.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope; a positively idle secondmate endpoint with no X-mode relay poll or registered process-event source has no supervision need.
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
- Automatic captain-request follow-through detection is Pi-only; every other primary can surface an existing record but does not automatically create, defer, or refuse on one.
- `fm-captain-commitment.sh` is inert outside a genuine primary home and silent while away mode is active.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers the supervision predicate's ordinary metadata, positively idle secondmate exclusion, active and parent-attention secondmate cases, fail-closed status and pending-reply evidence, process-event and X-mode sources, main and secondmate primary scope, child-worktree exclusion, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the live-lock and fresh-beacon guard predicate, the cooperative `--claude` claim wait, monotonic failed-epoch progression, bounded attended fail-open, post-alarm continuation suppression, positive recovery reset, Pi logical-run latching, missing-`jq` behavior, all five primary registrations, Grok native and legacy selection, typed field precedence, malformed input, and exactly-one-path safety.
`tests/fm-guard-stale-banner.test.sh` covers the pull-guard predicate, including the persistent-model fresh-leftover-beacon negative control, the auto-arm model's healthy fresh-beacon-without-a-watcher case and its stale-beacon alarm, the true-reason banner wording, and the reason-keyed episode dedup surviving a beacon mtime change.
`tests/fm-captain-commitment.test.sh` covers the follow-through owner and its integrations: an operational injection creating no commitment, a deferred request becoming one durable actionable item without storing its message, `track` refusing an absent, Done, or bodyless item, restart and compaction recovery retaining exactly one record, completion clearing the reminder, a same-turn completed request staying clean, a declared external wait staying quiet across repeated turns, away-mode and non-primary inertness, and the Pi handler's classification and latch behavior.
`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation.
