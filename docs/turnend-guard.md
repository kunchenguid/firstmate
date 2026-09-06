# Primary turn-end supervision guard

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start adapters in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Current invariant

`bin/fm-guard.sh` is a separate pull-based warning for worktree tangles and queued wakes, and it no longer reports watcher liveness.
The turn-end guard closes the supervision gap at the primary's own turn boundary.
When work, a process-event source, or Relay polling needs supervision at that boundary and no identity-matched watcher has a fresh beacon, the harness integration must either block the turn end or force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.
The turn-end guard keeps the PID-strict watcher predicate.
Away mode is the one place the turn-end guard accepts a different supervisor: while `state/.afk` exists the away-mode daemon owns supervision, so a live identity-matched daemon with a fresh beacon satisfies that boundary in place of a watcher process holding the lock.
The guard remains a backstop; [`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Guard predicates

The guard first calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must be a regular non-symlink file whose whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.
An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

For an in-scope primary, the guard counts in-flight work from `state/*.meta`.
Registered `state/procevent/*.source` records also require supervision even though they have no task metadata.
The default cross-harness mode exits silently with no supervision need.
Every mode treats `state/x-watch.check.sh` as supervision need, so Relay polling remains guarded without an in-flight task.
Otherwise it calls `fm_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`, the same PID-strict identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`: a stale beacon blocks even when a watcher pid is live, and a fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.
The turn-end guard needs that strict check because it fires at the turn boundary, where the auto-arm is bringing a fresh watcher up for the upcoming idle period, and it cooperates with that arm rather than trusting a beacon left by the cycle that just ended.
The removed mid-turn watcher warning has no replacement in `bin/fm-guard.sh`; [`architecture.md`](architecture.md) owns that guard's remaining worktree-tangle and queued-wakes scope.

While `state/.afk` exists the away-mode daemon (`bin/fm-supervise-daemon.sh`) owns supervision and runs the watcher one-shot: the watcher exits on every wake and the daemon starts its replacement, so a turn boundary regularly lands in a hand-off where no watcher process holds the lock and nothing is wrong.
The turn-end guard therefore accepts `fm_afk_daemon_owns_supervision` from `bin/fm-wake-lib.sh` as proof of supervision on that path: away mode must be active, and this home's `state/.supervise-daemon.lock` must name a live pid whose current process identity still matches the identity the daemon recorded for itself.
That is the same identity discipline the watcher lock uses, so a recycled pid, a lock left behind by a killed daemon, and a daemon that never recorded its identity all fail it.
A daemon that cannot record its own identity at startup logs a warning and keeps running, because a supervisor must not refuse to run over an unreadable `ps`; that warning is what names the cause when the guard then keeps blocking away-mode turn boundaries for the rest of that daemon's life.
The proof covers ownership only, never freshness: the fresh-beacon half of the predicate is unchanged, so a daemon that stops restarting its watcher still blocks once the beacon passes grace, and a home with no daemon and no watcher blocks exactly as it did before.
With away mode off the daemon lock proves nothing and the strict watcher predicate is unchanged.

`FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
`FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields.

## Harness integrations

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- Cursor registers a `stop` hook in `.cursor/hooks.json` and delegates the whole turn boundary to `bin/fm-turnend-guard-cursor.sh`, the park described below.
  Cursor also loads `<project>/.claude/settings.json`, so every tracked Claude-shaped entrypoint whose event Cursor covers stands down on a Cursor-delivered payload through `bin/fm-hook-host-lib.sh`.
  That predicate reads the delivered payload's own `cursor_version`, never the environment: Cursor exports `CURSOR_INVOKED_AS`, `CURSOR_PROJECT_DIR`, and `CURSOR_VERSION` into every child process, so an environment guard would also disable the hooks of a Claude session started by hand from a Cursor pane, which is the hazard the `GROK_SESSION_ID` exclusion below records.
  The guarded set is the `SessionStart` entry, the two `PreToolUse` Bash entries, and both `Stop` entries.
  Cursor 2026.08.11-e8db854 does not fire the Claude-shaped `Stop` entry at all, but it is guarded anyway because Cursor has no `asyncRewake`: if a later build did fire it, `bin/fm-claude-stop-autoarm.sh` would run synchronously inside Cursor's stop step and hold that turn open for its declared multi-hour timeout, exactly the wedge grok 1.0.0 produced.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and delegates capability selection to `bin/fm-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert when `GROK_AGENT` or `GROK_HOOK_EVENT` is present, so Grok's Claude-compatible settings loading cannot create a second continuation path.
  Both markers are required because Grok does not inject the same variables into every process kind: grok 0.2.73 set `GROK_AGENT` for child and tool processes, while grok 1.0.0 hook processes carry `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, and `GROK_WORKSPACE_ROOT` but no `GROK_AGENT`.
  A guard keyed on `GROK_AGENT` alone therefore stopped firing on grok 1.0.0, and the resulting Claude-only auto-arm ran synchronously under Grok - Grok has no `asyncRewake`, so it waited on the foregrounded watcher for the declared 28800-second timeout and the Grok turn never ended.
  Do NOT widen this guard to `GROK_SESSION_ID`: Grok injects that into every child process, so it can survive into a Claude session that Grok launched and would silently disable Claude's own continuity.
  The same marker guard carries every tracked `.claude/settings.json` entry whose event Grok already covers through its own `.grok/hooks/` registration, which is both `Stop` entries, the `SessionStart` entry, and the two `PreToolUse` Bash entries; `bin/fm-subagent-pretool-check.sh` is the one deliberate unguarded exception because no Grok registration covers the subagent-spawn event, recorded in [`subagent-guard.md`](subagent-guard.md) "Known residual gap".
  `tests/fm-turnend-guard.test.sh` pins that inventory so neither the guarded set nor the exception can change silently.

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes, which re-opened the 2026-07-21 blind window under the default one-shot behavior.
The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds) and allows the stop when the watcher is healthy, the auto-arm's generation claim is open, or `state/.claude-autoarm-epoch` contains a fresh actionable rewake owned by this event epoch.
The claim is the ledger entry itself: the epoch sequence in `state/.claude-autoarm-epoch` is a monotonic claim generation, line 1 is the classic epoch record, and line 2 records the claiming process's mandatory pid-identity (`fm_autoarm_claim_open` and `fm_autoarm_claim_next` in `bin/fm-wake-lib.sh` own the contract).
A claim is open while its outcome is `arming`, its owner pid is alive, its recorded identity successfully recomputes and matches that pid, and it is not stuck - stuck meaning the entry and the watcher beacon are both older than the guard grace, which proves the owner hung mid-arm (a healthy hours-long foregrounded cycle keeps the beacon beating, and every arming phase with no watcher is bounded in seconds).
Anything else - a finished outcome, a dead or identity-mismatched owner, a stuck owner, an identityless entry, or no entry - lets the next Stop-owned firing take the next generation and arm; taking a newer generation is the reclaim, and a steady-state predecessor is never signalled or revoked.
No mutex is held across arming or output: `state/.claude-autoarm.lock` survives only as a micro-mutex serializing individual ledger writes, and a superseded owner goes completely silent - ownership is re-verified before every arm invocation, episode-state mutation, ledger write, and continuation.
The irrevocable commit point of a translation is the exit status, because the harness delivers the collected stderr banner only on exit 2, so an owned terminal commit decides the exit: markerless outcomes commit with the ledger write, while the once-per-episode failure notice commits only when its marker is created after the winning failed write in the same critical section.
A generation whose required marker cannot be created is refused and exits 0 silently even after printing; its terminal ledger entry is superseded by a later firing, which retries the notice.
Without those boundaries a cycle that armed, delivered one rewake, and exited left both Stop participants deferring to its leftover lock indefinitely (2026-08-14: two tasks in flight, a beacon 40 minutes cold, every turn blind until an operator intervened), and a hook that hung mid-arm kept a live pid on the lock so the watcher was never auto-re-armed again (2026-08-26).
Two bounded residuals are accepted intent, each costing at most one extra continuation turn absorbed by the durable idempotent wake queue: an owner that dies between its owned terminal write and its own process exit, and a hung old-build owner that resumes during the one legacy upgrade window.
A legacy build's lock-holding claim (recognizable by its `autoarm` role file) still defers or reclaims under the legacy abandonment proof, with a live identity-verified stuck owner retired via TERM before its lock is removed and an unverified pid never signalled, so an upgrade mid-session can neither double-arm nor deadlock, and a failed reclaim re-blocks rather than allowing a blind stop.
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

Cursor cannot block a turn end at all: its blocked-response mapper returns an empty object for the `stop` step, so exit 2 is a silent no-op, verified both statically and live.
`bin/fm-turnend-guard-cursor.sh` therefore never exits 2 and never writes a banner expecting it to be read; every path exits 0 and its only channel is at most one `followup_message` on stdout.
Cursor runs that hook synchronously and awaits it, so one script owns both halves of the boundary.
While supervision is needed it PARKS: it runs `bin/fm-watch-arm.sh` as its own tracked child, holds the boundary open until the watcher closes, and returns an actionable close as one `watcher`-kind follow-up, spending no model tokens while parked.
This is the same between-turns shape as Claude's Stop auto-arm, while the turn-end park itself remains responsible for restoring supervision.
The park stands down without arming when `PI_CODING_AGENT=true` and neither `CURSOR_AGENT` nor `CURSOR_INVOKED_AS` is set.
Pi-with-Cursor-provider sessions (pi-cursor-sdk) load project `.cursor/hooks.json` into the Pi process, and a Cursor park there would race Pi's extension-owned `fm_watch_arm_pi` continuity, resurface rearm wakes, and abort in-flight asks.
`fm-spawn`'s cursor launch clears `PI_CODING_AGENT`; a hand-started cursor-agent may still inherit it.
When either Cursor identity marker is present, the park still runs despite a leaked `PI_CODING_AGENT`.
When the park cannot establish a cycle it asks this shared guard with `--cursor` and renders a returned exit 2 as one bounded `turn-end-guard` follow-up, capped by `FM_CURSOR_TURNEND_BLOCK_BUDGET` (default 3) consecutive unproductive nags per session; a delivered wake resets that budget because it is productive work.
The follow-up loop is bounded TWICE, because either bound alone is insufficient.
`loop_limit` in `.cursor/hooks.json` is Cursor's own ceiling and the only one that still holds if the adapter is broken or replaced: once `loop_count` reaches it Cursor stops invoking the hook, verified live.
`FM_CURSOR_TURNEND_LOOP_CEILING` (default 180) bounds the payload's `loop_count` from inside and sits deliberately BELOW the registered `loop_limit`, so firstmate's bound bites first and emits one final loud notice instead of supervision going silently dark at Cursor's ceiling.
`loop_count` is Cursor's richer analogue of `stop_hook_active`: verified live as 0 on the first stop after a real user message, +1 per follow-up-driven stop, and reset to 0 by the next real user message.

A captain message typed while the hook is parked is accepted and runs its turn immediately, and Cursor does NOT terminate the parked hook.
The older park remains the recorded owner until that captain turn ends and the next `stop` hook claims the baton, so an actionable watcher close in that window can still be delivered by the older park as one follow-up.
That delivery is bounded and safe: only one park exists before the next `stop` claim, so it is a real wake and never a stale duplicate of another park's wake, while the durable wake queue makes handling idempotent.
Each invocation publishes its sequence in `state/.cursor-park-owner` under the short publication and commit lock `state/.cursor-park-owner.lock`.
The same bounded critical section covers the final owner and away-mode checks, follow-up output, and repair-budget commit, so the next `stop` claim makes an older park that is still running stand down without emitting or changing shared state.
The lock is never held while the arm is sleeping, while the hook is polling, or while output is prepared.
The park revalidates session ownership while polling and again inside the final commit section, but it deliberately does not hold the fleet session lock across output because an awaited hook must not block home-wide session acquisition; the remaining microsecond takeover window can produce at most one harmless wake that drains the durable queue.
Without those records an older park still running after the next `stop` could leak one process and one stale duplicate wake.
Cursor's `beforeSubmitPrompt` step fires once on a real captain message and does not fire for hook-driven follow-ups, so invalidating the park baton there would close the pre-claim window exactly.
That hook is deliberately left to a follow-up alongside the deferred `preCompact` surface and is not registered in this change.

If a passive adapter cannot invoke its SDK, or the Grok legacy fallback cannot find `grok` or a session id, that adapter fails open silently at the host boundary; the removed mid-turn watcher warning provides no fallback report.
When the shared turn-end guard itself returns a block, its message uses `bin/fm-supervision-instructions.sh --repair-line`, so the delivered recovery instruction follows the active harness protocol rather than duplicating one here.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope; an idle secondmate endpoint with no Relay poll remains healthy because it has no supervision need.
- The blocking and bounded-follow-up mechanisms are limited to the primary integrations listed above.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Cursor's `stop` step does not fire in headless `cursor-agent -p`, the same class of limit as OpenCode headless; firstmate primaries run interactive.
- A Cursor primary must be launched with `--trust`, or its project hooks never load and the whole integration is inert.
- Cursor's `preCompact` step is deliberately unregistered: its response can return only `user_message` and it is absent from Cursor's `additional_context` step set, so a post-compaction re-emit needs its own design and is deferred to a follow-up ([`sessionstart-nudge.md`](sessionstart-nudge.md) owns that uncovered surface).
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/fm-kimi-turnend-hook.sh` to edit only one marker-delimited Firstmate region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers the predicate, main and secondmate primary scope, child-worktree exclusion, `FM_HOME` and `FM_STATE_OVERRIDE` precedence, the live-lock and fresh-beacon guard predicate, the cooperative `--claude` open-generation claim wait, monotonic failed-epoch progression, bounded attended fail-open, post-alarm continuation suppression, positive recovery reset, generation and legacy claim cases that must block or clear instead of allowing a blind stop, away-mode daemon ownership between watcher cycles and over a watcher lock left behind by an exited watcher, plus its dead, pid-reused, absent, stale-beacon, and away-mode-off negatives, Pi logical-run latching, missing-`jq` behavior, all five primary registrations, Grok native and legacy selection, typed field precedence, malformed input, and exactly-one-path safety.
`tests/fm-guard-stale-banner.test.sh` proves the pull guard emits no watcher-liveness output under any supervision model while preserving the queued-wakes and worktree-tangle alarms, the branch actor exemption, and read-only behavior.
`tests/fm-cursor-primary.test.sh` covers the Cursor park end to end over real processes with no harness installed: each tracked Claude-shaped entrypoint standing down on a Cursor payload, both follow-up sources, the bounded repair nag and its reset, the nested loop bounds, supersession, away-mode and lock-ownership inertness, Pi-host stand-down without Cursor identity and continued parking when `PI_CODING_AGENT` leaks alongside `CURSOR_AGENT` or `CURSOR_INVOKED_AS`, child-worktree exclusion, and that the adapter never exits 2.
`FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh` is the opt-in guard that proves the same behavior against the installed cursor-agent and fails naming the harness and version.
`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the 2026-07-24 Claude `asyncRewake` revalidation.
