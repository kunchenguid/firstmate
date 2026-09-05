# Native session-start adapters

AGENTS.md section 3 is the authoritative behavioral contract for session start.
This file owns how the tracked native session-open adapters deliver it, and the compatibility limits that force two tiers rather than one.

Firstmate ships two session-open tiers, and the tier is a property of the harness surface, not of the home.

| Tier | What the adapter does | Used by |
| --- | --- | --- |
| Run | Executes `bin/fm-session-start.sh` through the native session-open adapter and gates its ordered digest into model context before the first turn. | Claude, `codex exec`, Pi / pi-signed, Cursor |
| Nudge | Asks the agent to run the digest through the native adapter or the tracked session-start instruction. | Grok, OpenCode, and run-tier sources routed to the nudge |

Codex's interactive TUI has no tracked session-open, compaction, or re-emit channel and is not covered by either tier.
The run tier exists because the nudge can only ask.
An agent can defer an instruction, including when a first-command skill has its own read-only path.
Running the digest through the native adapter removes that discretion, so even a session whose first command is a skill has already taken the helm.
The nudge tier remains the floor for harnesses that cannot carry hook stdout into model context, and it is never a second contract: both tiers end in the same `bin/fm-session-start.sh`.

## Source routing

`bin/fm-sessionstart-run.sh` is the single owner of what a session-open source means, so no harness matcher string has to encode that policy.
It takes `--source <name>` when the adapter knows the source natively, and otherwise reads the `source` field from a Claude/Codex-shaped JSON hook payload on stdin.

| Source | Action | Why |
| --- | --- | --- |
| `startup`, `new` | Full digest | This is a true session start that has not taken the helm; Pi CLI continuations are refined to `resume` by the adapter before reaching this boundary. |
| `clear`, `compact` | `--reemit` after a proven complete startup, otherwise full digest | This process normally has the helm and lost only its context, but an earlier hook may have been truncated after acquiring the lock. |
| `resume`, `reload`, `fork` | Delegate to the nudge wrapper | Prior context is restored, so re-running is redundant when the lock is still ours and an instruction is enough when a new process resumed an old session. |
| unreadable or unrecognized | Full digest | Taking the helm redundantly is cheap and idempotent; not taking it is the bug this tier exists to fix. |

This deliberately inverts the previous nudge matcher, which fired on `startup|resume|clear` and excluded `compact`.
Compaction is covered where a tracked adapter delivers that source because a compacted session has lost exactly the digest it needs, and resume is excluded from the run because it restores that digest instead of losing it.

Current harness ownership of the lock and its matching `state/.session-start-complete` record together are the idempotency interlock for the whole scheme.
The full digest clears that completion record after acquiring the lock and republishes the lock owner's pid only after every stage completes, so `clear` or `compact` cannot skip startup sweeps after a truncated run.
`bin/fm-lock.sh` already treats a lock this session's own harness holds as its own, so a proven `clear` or `compact` re-emit re-verifies ownership and proceeds, while a lock another live session took meanwhile still produces the ordinary read-only digest.
On a run-tier harness the nudge cannot also fire: `resume`, `reload`, and `fork` are the only sources routed to it, and on those its own ancestry check stays silent whenever this process already holds the lock.

`bin/fm-session-start.sh --reemit` owns which work a re-emit skips, its true-start AGENTS.md baseline, and its supported stale-instruction refresh pairs; its header is the single owner of those mechanics.

## Runtime bound

The run tier blocks either hook-driven session initialization or Pi's first provider preflight while the digest runs, so `bin/fm-session-start.sh` bounds itself rather than betting on an unbounded prerequisite.
The digest makes no external-network call at all: every one it owes runs off the blocking path in the separately bounded deferred stage owned by `bin/fm-startup-network.sh`, so an unreachable host can no longer consume this budget.
What remains is still not individually bounded - tool version probes, the backlog listing, and the per-task endpoint reads are all local but unbounded subprocesses - so the whole digest runs as one bounded child, default 120s via `FM_SESSION_START_TIMEOUT`.
The shared timeout owner falls back to a pure-Bash process-group watchdog when timeout, gtimeout, and perl are unavailable, so no supported host runs the digest unbounded.
Because the child streams into the native transport as it runs, everything emitted before the bound was hit is retained for delivery; the parent then prints a `STARTUP TRUNCATED` banner naming the stage that did not finish and the stages that were therefore never emitted, and still exits 0.
The registered hook timeouts sit above that budget so the harness never preempts the banner.
The deferred startup stage deliberately runs in its own process group under its own deadline, so a truncated digest neither kills the network checks and inactive-outcome scan it was not waiting for nor orphans unbounded network work.

## Shared wrapper and safety

`bin/fm-sessionstart-run.sh` checks one eligibility test ahead of both of the ones below: `FM_SESSION_ROLE=advisor` (`fm_session_role_is_advisor` in `bin/fm-primary-scope-lib.sh`) takes the read-only digest path unconditionally, before any lock, bootstrap, or drain; [`configuration.md`](configuration.md#advisor-session-role-fm_session_role) owns that contract.

`bin/fm-sessionstart-run.sh` and `bin/fm-sessionstart-nudge.sh` share the same two eligibility owners.
They source `bin/fm-gate-refuse-lib.sh` and stay silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
They share `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so every hook uses one primary-detection owner.
The Guard Predicates section of [`turnend-guard.md`](turnend-guard.md#guard-predicates) owns marker validation, plain-checkout detection, and required Firstmate-shaped paths.

The nudge payload starts with U+2063 and the stable `FIRSTMATE_OP: ` label, carries the current `session-start` protocol kind, and retains exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.
The Ahoy skill owns the rule that this marked operational input is never a captain-authored session boundary, including its narrow legacy compatibility cases, and its own step 0 helm check is the fallback that protects a nudge-tier harness whose first command is a skill.

Before printing, the nudge wrapper reads `state/.lock` and walks at most eight parents from its own pid in its own separate, hard-coded loop, independent of `bin/fm-lock.sh`'s ancestry walk (`fm_harness_ancestry_pid()` in `bin/fm-session-lock-lib.sh`, which now walks up to sixteen parents and can extend past a claude-named match to a still-more-ancestral one) and of Pi's `lockOwnership()`.
If the lock names a live pid in that ancestry, session start already ran in this harness session and the wrapper stays silent.
Every ordinary transport path in both wrappers exits 0, including malformed state and adapter errors, because a Claude SessionStart exit 2 blocks session initialization.
The run wrapper's internal `--pi-prerequisite` mode uses silent exit 3 only for an intentional gate or scope stand-down, letting Pi distinguish ineligibility from an eligible empty native result without changing any harness hook's exit contract.
A lock another session holds and a truncated digest therefore surface as digest text, while broken GitHub auth surfaces through the deferred network result inline or as a wake; none becomes a refusal to open the session.

## Harness transports

| Harness | Tier | Tracked transport | Current compatibility |
| --- | --- | --- | --- |
| Claude | Run | `.claude/settings.json` registers one unmatched `SessionStart` hook, invoked through `CLAUDE_PROJECT_DIR` with a 180s timeout; the wrapper reads `source` from the hook payload. | Native stdout context injection is supported. |
| Codex exec | Run | `.codex/hooks.json` anchors to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and pipes the hook payload into the wrapper with a 180s timeout. | Native stdout context injection is supported under `codex exec`. |
| Codex interactive TUI | Uncovered | None. | Codex 0.146.0 does not fire the tracked project `SessionStart` hook in its interactive TUI; Firstmate ships no global hook, has no tracked compaction or re-emit channel, and does not claim instruction-refresh delivery for this surface. |
| Pi / pi-signed | Run | `.pi/extensions/fm-primary-turnend-guard.ts` maps `session_start` reasons `startup`, `new`, `resume`, and `fork` onto wrapper sources, refines a Pi-reported `startup` to `resume` only when a continuation, resume-selection, or explicit-session flag accompanies a session header older than the current process, maps a fork flag to `fork`, and handles `session_compact` as the compaction equivalent; setup-created entries such as `--name` are not restoration evidence. | Each mapped session generation starts one native prerequisite, and `before_agent_start` awaits its matching result and returns one persistent context message before the first provider call; Pi's `reload` reason is deliberately unmapped, as it always was. |
| OpenCode | Nudge | `.opencode/plugins/fm-primary-sessionstart-nudge.js` listens for `session.created`, runs once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Interactive TUI delivery is supported; headless `opencode run` is intentionally fail-open because the process can exit before the queued turn. That early exit is also why OpenCode cannot use the run tier. |
| Grok | Nudge | `.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project hook runs when the checkout is trusted, but Grok currently discards hook stdout from model context, so this path is intentionally fail-open and cannot use the run tier. |
| Cursor | Run | `.cursor/hooks.json` registers `sessionStart`, anchored through `$CURSOR_PROJECT_DIR` with a 180s timeout, invoking `bin/fm-sessionstart-cursor.sh`. | Cursor's payload has no `source` field, so the registration supplies `--source` itself, and the adapter returns the digest as `additional_context`. Project hooks load only when the workspace is launched with `--trust`. |
| Cursor compaction | Uncovered | None. | Cursor's `preCompact` response can return only `user_message` and is absent from Cursor's `additional_context` step set, so it cannot inject a re-emit digest. Delivering one needs its own design and is deliberately deferred to a follow-up; a Cursor primary does not re-emit its digest after a compaction. |

Cursor's `sessionStart` fires at every session open with no source distinction, including a resumed session, so a resume re-runs the full digest; that is redundant and idempotent rather than a lost helm.
Cursor's compaction surface is uncovered in the same sense as Codex's interactive TUI above: Firstmate registers nothing for `preCompact`, so a compacted Cursor session keeps whatever context survived rather than receiving a fresh digest.

Pi is the only adapter that injects a message rather than hook stdout, so whatever it injects must carry operational provenance or the Ahoy skill would have to guess whether it was captain-authored.
For `session_start`, the extension activates a session-id and monotonic-generation owner synchronously, starts the wrapper once, and makes `before_agent_start` await that same promise before returning Pi's persistent `message` result.
Replacement or shutdown stops the matching process group, and stale generations cannot deliver into the active session.
An eligible native failure or empty result settles before the extension returns the existing exact manual instruction, so native and manual startup never run concurrently.
An intentional gate or non-primary stand-down returns no message, and context-preserving sources retain their existing silent result when the current process already holds the lock.
Manual and automatic compaction retain the existing persistent delivery path because an automatic retry may have no new `before_agent_start`, but that path shares the same generation cancellation and exactly-once claim.
The extension encodes an unencoded digest or fallback as `session-start` operational input and leaves an already-encoded nudge alone.
It streams the hook to completion and retains at most 512 KiB for message delivery; this approved containment keeps the prefix and appends a loud `PI SESSION-START DELIVERY TRUNCATED` marker with direct-inspection guidance whenever the digest is incomplete.

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end plugins run later on `session.idle`, and the guard lets the watcher coordinator act first, so the plugins do not race for one lifecycle event.

Grok's guaranteed-loading alternative is a global token-guarded hook like the pattern used by `bin/fm-spawn.sh`.
That alternative expands trust and writes outside this repository, so Firstmate never installs it or grants folder trust automatically.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves the nudge wrapper's silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock, plus its exact U+2063 `FIRSTMATE_OP:`-prefixed, `session-start`-typed one-line output.
It separately proves the run wrapper's silence for the gate environment and an unmarked linked worktree, including the internal Pi prerequisite's explicit silent stand-down.
It proves the run wrapper's source routing end to end against a real `fm-session-start.sh`, including completion-gated `--reemit` selection, resume delegation, Pi CLI continuation classification, an unrecognized source falling through to the full digest, and bounded loud delivery of an oversized Pi digest.
The same portable suite proves provider exclusion until settlement, exactly-one execution and context delivery, interruption, process-tree retirement, two rapid replacements, stale completion, eligible empty output, spawn error, wrapper timeout output, truncation, ineligible stand-down, and compaction cancellation through the extension's public event surface.
`tests/fm-session-start.test.sh` proves the runtime bound through the forced pure-Bash fallback: a TERM-resistant digest that exceeds its budget is force-killed with its grandchild, still emits its completed stages, names the incomplete stage and every stage it never reached, leaves no completion proof, and exits 0.
`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` exercise native startup paths with first-message and later-message Ahoy regressions.
`tests/fm-cursor-primary.test.sh` proves the Cursor adapter over real processes: `sessionStart` emits the whole digest as `additional_context` with a caller-supplied `--source`, stays silent in a child worktree, lets the run wrapper stand down on the Cursor-delivered duplicate, and keeps `preCompact` unregistered so the deferred surface cannot be reintroduced unnoticed.
`FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh` proves the injected digest actually reaches model context in a real cursor-agent session.
`tests/fm-sessionstart-hook-live-e2e.test.sh` is the opt-in live guard for the Claude, Codex exec, and Pi run-tier adapters; it confirms each installed adapter in that suite invokes the run wrapper and delivers its output into context.
It verifies context-preserving reopen sources for those adapters and context-reset delivery wherever their tracked TUI surface is reachable.
Its separate `FM_PI_SESSIONSTART_RACE_LIVE_E2E=1` mode uses real Pi with an offline deterministic provider and a barrier-controlled `/new` digest, proving both an immediate prompt and a completed-before-prompt control make their first provider call with exactly one native startup context and no manual execution.
Cursor uses the separate primary live guard named above because its source-free `sessionStart` and stop-hook park are validated together.
`tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh` is the separate opt-in real-Pi guard for a post-start AGENTS.md update followed by compaction.
`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery.

[`verification/supervision.md`](verification/supervision.md#native-session-start-delivery) records the active version-scoped transport evidence.
