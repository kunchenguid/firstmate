# Native session-start adapters

AGENTS.md section 3 is the authoritative behavioral contract for session start.
This file owns how the tracked native session-open adapters deliver it, and the compatibility limits that force two tiers rather than one.

Firstmate ships two session-open tiers, and the tier is a property of the harness surface, not of the home.

| Tier | What the adapter does | Used by |
| --- | --- | --- |
| Run | Executes `bin/fm-session-start.sh` in the hook and lets its ordered digest land in model context before the first turn. | Claude, `codex exec`, Pi / pi-signed |
| Nudge | Asks the agent to run the digest through the native adapter or the tracked session-start instruction. | Grok, OpenCode, Codex interactive TUI, and run-tier sources routed to the nudge |

The run tier exists because the nudge can only ask.
An agent can defer an instruction, including when a first-command skill has its own read-only path.
Running the digest inside the hook removes that discretion, so even a session whose first command is a skill has already taken the helm.
The nudge tier remains the floor for harnesses that cannot carry hook stdout into model context, and it is never a second contract: both tiers end in the same `bin/fm-session-start.sh`.

## Source routing

`bin/fm-sessionstart-run.sh` is the single owner of what a session-open source means, so no harness matcher string has to encode that policy.
It takes `--source <name>` when the adapter knows the source natively, and otherwise reads the `source` field from a Claude/Codex-shaped JSON hook payload on stdin.

| Source | Action | Why |
| --- | --- | --- |
| `startup`, `new` | Full digest | This process has not taken the helm. |
| `clear`, `compact` | `--reemit` after a proven complete startup, otherwise full digest | This process normally has the helm and lost only its context, but an earlier hook may have been truncated after acquiring the lock. |
| `resume`, `reload`, `fork` | Delegate to the nudge wrapper | Prior context is restored, so re-running is redundant when the lock is still ours and an instruction is enough when a new process resumed an old session. |
| unreadable or unrecognized | Full digest | Taking the helm redundantly is cheap and idempotent; not taking it is the bug this tier exists to fix. |

This deliberately inverts the previous nudge matcher, which fired on `startup|resume|clear` and excluded `compact`.
Compaction is now covered because a compacted session has lost exactly the digest it needs, and resume is now excluded from the run because it restores that digest instead of losing it.

Current harness ownership of the lock and its matching `state/.session-start-complete` record together are the idempotency interlock for the whole scheme.
The full digest clears that completion record after acquiring the lock and republishes the lock owner's pid only after every stage completes, so `clear` or `compact` cannot skip startup sweeps after a truncated run.
`bin/fm-lock.sh` already treats a lock this session's own harness holds as its own, so a proven `clear` or `compact` re-emit re-verifies ownership and proceeds, while a lock another live session took meanwhile still produces the ordinary read-only digest.
On a run-tier harness the nudge cannot also fire: `resume`, `reload`, and `fork` are the only sources routed to it, and on those its own ancestry check stays silent whenever this process already holds the lock.

`bin/fm-session-start.sh --reemit` owns which work a re-emit skips; its header is the single owner of that list.

## Runtime bound

The run tier blocks session initialization while the digest runs, so `bin/fm-session-start.sh` bounds itself rather than betting on each harness's own hook timeout.
Individual steps are not all bounded - bootstrap's fleet sync is, but its `gh auth status` probe, its tool version probes, the backlog listing, and the per-task endpoint reads are not - so the whole digest runs as one bounded child, default 120s via `FM_SESSION_START_TIMEOUT`.
The shared timeout owner falls back to a pure-Bash process-group watchdog when timeout, gtimeout, and perl are unavailable, so no supported host runs the digest unbounded.
Because the child writes straight to the hook's stdout, everything emitted before the bound was hit is already delivered; the parent then prints a `STARTUP TRUNCATED` banner naming the stage that did not finish and the stages that were therefore never emitted, and still exits 0.
The registered hook timeouts sit above that budget so the harness never preempts the banner.

## Shared wrapper and safety

`bin/fm-sessionstart-run.sh` and `bin/fm-sessionstart-nudge.sh` share the same two eligibility owners.
They source `bin/fm-gate-refuse-lib.sh` and stay silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
They share `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so every hook uses one primary-detection owner.
The Guard Predicates section of [`turnend-guard.md`](turnend-guard.md#guard-predicates) owns marker validation, plain-checkout detection, and required Firstmate-shaped paths.

The nudge payload starts with U+2063 and the stable `FIRSTMATE_OP: ` label, carries the current `session-start` protocol kind, and retains exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.
The Ahoy skill owns the rule that this marked operational input is never a captain-authored session boundary, including its narrow legacy compatibility cases, and its own step 0 helm check is the fallback that protects a nudge-tier harness whose first command is a skill.

Before printing, the nudge wrapper reads `state/.lock` and walks at most eight parents from its own pid in its own separate, hard-coded loop, independent of `bin/fm-lock.sh`'s ancestry walk (`fm_harness_ancestry_pid()` in `bin/fm-session-lock-lib.sh`, which now walks up to sixteen parents and can extend past a claude-named match to a still-more-ancestral one) and of Pi's `lockOwnership()`.
If the lock names a live pid in that ancestry, session start already ran in this harness session and the wrapper stays silent.
Every path in both wrappers exits 0, including malformed state and adapter errors, because a Claude SessionStart exit 2 blocks session initialization.
A lock another session holds, broken GitHub auth, and a truncated digest therefore all surface as digest text the agent reads and acts on, never as a refusal to open the session.

## Harness transports

| Harness | Tier | Tracked transport | Current compatibility |
| --- | --- | --- | --- |
| Claude | Run | `.claude/settings.json` registers one unmatched `SessionStart` hook, invoked through `CLAUDE_PROJECT_DIR` with a 180s timeout; the wrapper reads `source` from the hook payload. | Native stdout context injection is supported. |
| Codex exec | Run | `.codex/hooks.json` anchors to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and pipes the hook payload into the wrapper with a 180s timeout. | Native stdout context injection is supported under `codex exec`. |
| Codex interactive TUI | Nudge | The tracked `AGENTS.md` session-start instruction and Ahoy step-zero fallback remain visible when the project hook does not fire. | Codex 0.146.0 does not fire the tracked project `SessionStart` hook in its interactive TUI. Firstmate ships no global hook and does not depend on one. |
| Pi / pi-signed | Run | `.pi/extensions/fm-primary-turnend-guard.ts` maps `session_start` reasons `startup`, `new`, `resume`, and `fork` onto wrapper sources, handles `session_compact` as the compaction equivalent, and injects the output with `pi.sendMessage`. | The custom message reaches model context without racing an initial positional prompt. Pi's `reload` reason is deliberately unmapped, as it always was. |
| OpenCode | Nudge | `.opencode/plugins/fm-primary-sessionstart-nudge.js` listens for `session.created`, runs once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Interactive TUI delivery is supported; headless `opencode run` is intentionally fail-open because the process can exit before the queued turn. That early exit is also why OpenCode cannot use the run tier. |
| Grok | Nudge | `.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project hook runs when the checkout is trusted, but Grok currently discards hook stdout from model context, so this path is intentionally fail-open and cannot use the run tier. |

Pi is the only adapter that injects a message rather than hook stdout, so whatever it injects must carry operational provenance or the Ahoy skill would have to guess whether it was captain-authored.
The extension therefore encodes an unencoded digest as `session-start` operational input before sending it, and leaves the already-encoded nudge alone.
It streams the hook to completion and retains at most 512 KiB for message delivery; this approved containment keeps the prefix and appends a loud `PI SESSION-START DELIVERY TRUNCATED` marker with direct-inspection guidance whenever the digest is incomplete.

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end plugins run later on `session.idle`, and the guard lets the watcher coordinator act first, so the plugins do not race for one lifecycle event.

Grok's guaranteed-loading alternative is a global token-guarded hook like the pattern used by `bin/fm-spawn.sh`.
That alternative expands trust and writes outside this repository, so Firstmate never installs it or grants folder trust automatically.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves the nudge wrapper's silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock, plus its exact U+2063 `FIRSTMATE_OP:`-prefixed, `session-start`-typed one-line output.
It separately proves the run wrapper's silence for the gate environment and an unmarked linked worktree.
It proves the run wrapper's source routing end to end against a real `fm-session-start.sh`, including completion-gated `--reemit` selection, resume delegation, an unrecognized source falling through to the full digest, and bounded loud delivery of an oversized Pi digest.
`tests/fm-session-start.test.sh` proves the runtime bound through the forced pure-Bash fallback: a TERM-resistant digest that exceeds its budget is force-killed with its grandchild, still emits its completed stages, names the incomplete stage and every stage it never reached, leaves no completion proof, and exits 0.
`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` exercise native startup paths with first-message and later-message Ahoy regressions.
`tests/fm-sessionstart-hook-live-e2e.test.sh` is the opt-in live guard that confirms each installed run-tier adapter invokes the run wrapper and delivers its output into context.
It verifies the context-preserving reopen source for every installed run-tier harness and context-reset delivery wherever the tracked TUI surface is reachable.
`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery.

[`verification/supervision.md`](verification/supervision.md#native-session-start-delivery) records the active version-scoped transport evidence.
