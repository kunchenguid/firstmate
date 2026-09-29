# Native session-start adapters

This doc is for operators who need to know which harnesses run `bin/fm-session-start.sh` when a session opens, which only nudge the agent to run it, and how clear, compaction, and resume are handled.
AGENTS.md section 3 is the authoritative behavioral contract for session start.
This file owns how the tracked native session-open adapters deliver it, and the compatibility limits that force two tiers rather than one.

One term recurs throughout:

- The digest is the ordered startup report that `bin/fm-session-start.sh` prints.

## Find a topic

| Question | Section |
| --- | --- |
| Which harness runs the digest and which only nudges it | [Tier by harness](#tier-by-harness) |
| What each session-open source triggers | [Source routing](#source-routing) |
| How long the digest may block and what happens when it runs out of time | [Runtime bound](#runtime-bound) |
| When the wrappers stay silent and which exit codes they use | [Shared wrapper and safety](#shared-wrapper-and-safety) |
| How one harness wires its session-open hook | [Harness transports](#harness-transports) |
| Which tests prove each guarantee | [Regression coverage](#regression-coverage) |

## Session-open tiers

Firstmate ships two session-open tiers.
The tier is a property of the harness surface, not of the home.

| Tier | What the adapter does | Used by |
| --- | --- | --- |
| Run | Executes `bin/fm-session-start.sh` through the native session-open adapter and gates its ordered digest into model context before the first turn. | Claude, `codex exec`, Pi / pi-signed, omp, Cursor |
| Nudge | Asks the agent to run the digest through the native adapter or the tracked session-start instruction. | Grok, OpenCode, and run-tier sources routed to the nudge |

Codex's interactive TUI has no tracked session-open, compaction, or re-emit channel and is not covered by either tier.

### Tier by harness

| Harness surface | Tier | Details |
| --- | --- | --- |
| Claude | Run | [Claude](#claude) |
| Codex exec | Run | [Codex exec](#codex-exec) |
| Codex interactive TUI | Uncovered | [Codex interactive TUI](#codex-interactive-tui) |
| Pi / pi-signed | Run | [Pi and pi-signed](#pi-and-pi-signed) |
| OpenCode | Nudge | [OpenCode](#opencode) |
| Grok | Nudge | [Grok](#grok) |
| Cursor | Run | [Cursor](#cursor) |
| omp | Run | [omp](#omp) |
| Cursor compaction | Uncovered | [Cursor compaction](#cursor-compaction) |

### Why the run tier exists

The run tier exists because the nudge can only ask.
An agent can defer an instruction, including when a first-command skill has its own read-only path.
Running the digest through the native adapter removes that discretion, so even a session whose first command is a skill has already taken the helm.

The nudge tier remains the floor for harnesses that cannot carry hook stdout into model context.
It is never a second contract: both tiers end in the same `bin/fm-session-start.sh`.

## Source routing

`bin/fm-sessionstart-run.sh` is the single owner of what a session-open source means.
Because of that, no harness matcher string has to encode that policy.
The run wrapper learns the source in one of two ways:

- It takes `--source <name>` when the adapter knows the source natively.
- Otherwise it reads the `source` field from a Claude/Codex-shaped JSON hook payload on stdin.

A re-emit (`--reemit`) reprints the digest for a process that already has the helm and lost only its context.

| Source | Action | Why |
| --- | --- | --- |
| `startup`, `new` | Full digest | This is a true session start that has not taken the helm; Pi CLI continuations are refined to `resume` by the adapter before reaching this boundary. |
| `clear`, `compact` | `--reemit` after a proven complete startup, otherwise full digest | This process normally has the helm and lost only its context, but an earlier hook may have been truncated after acquiring the lock. |
| `resume`, `reload`, `fork` | Delegate to the nudge wrapper | Prior context is restored, so re-running is redundant when the lock is still ours and an instruction is enough when a new process resumed an old session. |
| unreadable or unrecognized | Full digest | Taking the helm redundantly is cheap and idempotent; not taking it is the bug this tier exists to fix. |

### Change from the previous nudge matcher

This routing deliberately inverts the previous nudge matcher, which fired on `startup|resume|clear` and excluded `compact`.

- Compaction is covered where a tracked adapter delivers that source, because a compacted session has lost exactly the digest it needs.
- Resume is excluded from the run because it restores that digest instead of losing it.

### Lock and completion interlock

Two records together are the idempotency interlock for the whole scheme:

- Current harness ownership of the lock.
- Its matching `state/.session-start-complete` record.

The full digest updates the completion record in this order:

1. It acquires the lock.
2. It clears the completion record.
3. It republishes the lock owner's pid only after every stage completes.

So `clear` or `compact` cannot skip startup sweeps after a truncated run.

`bin/fm-lock.sh` treats a lock as this session's own when it is owned through either of these:

- The shared ancestry verdict.
- A trusted same-session Claude id.

So a proven `clear` or `compact` re-emit re-verifies ownership and proceeds.
A lock another live session took meanwhile still produces the ordinary read-only digest.

### Nudge wrapper on a run-tier harness

On a run-tier harness, only `resume`, `reload`, and `fork` are routed to the nudge wrapper.
The nudge wrapper has its own separate ancestry-only check, which normally stays silent when this process already holds the lock.
A background Claude helper-chain recycle can break that ancestry.
The wrapper may then emit a redundant nudge even though the shared same-session verdict still owns the lock.
The requested session start remains idempotent.

### Re-emit mechanics

`bin/fm-session-start.sh --reemit` owns these re-emit details:

- Which work a re-emit skips.
- Its true-start AGENTS.md baseline.
- Its supported stale-instruction refresh pairs.

The `bin/fm-session-start.sh` header is the single owner of those mechanics.

## Runtime bound

While the digest runs, the run tier blocks one of two things:

- Hook-driven session initialization.
- Pi's first provider preflight.

So `bin/fm-session-start.sh` bounds itself rather than betting on an unbounded prerequisite.

### Network work stays off the blocking path

The digest makes no external-network call at all.
Every network call it owes runs off the blocking path, in the separately bounded deferred stage owned by `bin/fm-startup-network.sh`.
So an unreachable host can no longer consume this budget.

### Digest timeout

Some digest work remains local but unbounded:

- Tool version probes.
- The backlog listing.
- The per-task endpoint reads.

So the whole digest still runs as one bounded child, default 120s via `FM_SESSION_START_TIMEOUT`.

The per-item backlog row reads inside bootstrap's reconcile and close-replay sweeps are the exception.
Each of those reads is bounded by `FM_BACKLOG_ROW_TIMEOUT_SECS` (default 10s) through `bin/fm-backlog-transition-lib.sh`.
The first bound hit latches the sweep.
Later reads in that sweep then return immediately while still naming their own item.

When timeout, gtimeout, and perl are unavailable, the shared timeout owner falls back to a pure-Bash process-group watchdog.
So no supported host runs the digest unbounded.

### When the bound is hit

The child streams into the native transport as it runs.
So everything emitted before the bound was hit is retained for delivery.
The parent then prints a `STARTUP TRUNCATED` banner that names:

- The stage that did not finish.
- The stages that were therefore never emitted.

The parent still exits 0.
The registered hook timeouts sit above that budget, so the harness never preempts the banner.

The deferred startup stage deliberately runs in its own process group under its own deadline.
So a truncated digest does neither of these:

- Kill the network checks and inactive-outcome scan it was not waiting for.
- Orphan unbounded network work.

## Shared wrapper and safety

`bin/fm-sessionstart-run.sh` and `bin/fm-sessionstart-nudge.sh` share the same two eligibility owners.

- They source `bin/fm-gate-refuse-lib.sh` and stay silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
- They share `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so every hook uses one primary-detection owner.

The Guard Predicates section of [`turnend-guard.md`](turnend-guard.md#guard-predicates) owns marker validation, plain-checkout detection, and required Firstmate-shaped paths.

### Nudge payload

The nudge payload has three parts:

- It starts with U+2063 and the stable `FIRSTMATE_OP: ` label.
- It carries the current `session-start` protocol kind.
- It retains exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.

The Ahoy skill owns the rule that this marked operational input is never a captain-authored session boundary, including its narrow legacy compatibility cases.
The Ahoy skill's own step 0 helm check is the fallback that protects a nudge-tier harness whose first command is a skill.

### Nudge wrapper lock check

Before printing, the nudge wrapper reads `state/.lock` and walks at most eight parents from its own pid.
It does this in its own separate, hard-coded loop, independent of two other ownership checks:

- The shared sixteen-hop ancestry walk in `bin/fm-session-lock-lib.sh` that `bin/fm-lock.sh` uses for anchor selection and ownership.
- Pi's `lockOwnership()`.

If the lock names a live pid in that ancestry, session start already ran in this harness session and the wrapper stays silent.

### Exit codes

Every ordinary transport path in both wrappers exits 0, including malformed state and adapter errors.
The reason is that a Claude SessionStart exit 2 blocks session initialization.

The run wrapper's internal `--pi-prerequisite` mode uses silent exit 3 only for an intentional gate or scope stand-down.
That exit lets Pi distinguish ineligibility from an eligible empty native result.
It does not change any harness hook's exit contract.

These conditions therefore surface as follows:

- A lock another session holds surfaces as digest text.
- A truncated digest surfaces as digest text.
- Broken GitHub auth surfaces through the deferred network result, inline or as a wake.

None of these becomes a refusal to open the session.

## Harness transports

Each subsection below gives one harness surface's tier, its tracked transport, and its current compatibility.

### Claude

Claude is a run-tier harness.
`.claude/settings.json` registers one unmatched `SessionStart` hook, invoked through `CLAUDE_PROJECT_DIR` with a 180s timeout.
The wrapper reads `source` from the hook payload.
Native stdout context injection is supported.

### Codex exec

Codex exec is a run-tier harness.
The `.codex/hooks.json` transport does three things:

1. It anchors to the hook process working directory.
2. It verifies a Firstmate-shaped hook-bearing root.
3. It pipes the hook payload into the wrapper with a 180s timeout.

Native stdout context injection is supported under `codex exec`.

### Codex interactive TUI

The Codex interactive TUI is uncovered and has no tracked transport.
Codex 0.146.0 does not fire the tracked project `SessionStart` hook in its interactive TUI.
Firstmate ships no global hook and has no tracked compaction or re-emit channel for it.
Firstmate does not claim instruction-refresh delivery for this surface.

### Pi and pi-signed

Pi and pi-signed are run-tier harnesses.
The tracked transport is `.pi/extensions/fm-primary-turnend-guard.ts`.
The extension maps Pi events onto wrapper sources:

- It maps `session_start` reasons `startup`, `new`, `resume`, and `fork` onto wrapper sources.
- It refines a Pi-reported `startup` to `resume` only when a continuation, resume-selection, or explicit-session flag accompanies a session header older than the current process.
- It maps a fork flag to `fork`.
- It handles `session_compact` as the compaction equivalent.
- Pi's `reload` reason is deliberately unmapped, as it always was.

Setup-created entries such as `--name` are not restoration evidence.

Each mapped session generation starts one native prerequisite.
`before_agent_start` awaits its matching result and returns one persistent context message before the first provider call.

#### Pi message delivery

Pi is the only adapter that injects a message rather than hook stdout.
So whatever it injects must carry operational provenance, or the Ahoy skill would have to guess whether it was captain-authored.

For `session_start`, the extension does the following:

1. It activates a session-id and monotonic-generation owner synchronously.
2. It starts the wrapper once.
3. It makes `before_agent_start` await that same promise before returning Pi's persistent `message` result.

Replacement or shutdown stops the matching process group.
Stale generations cannot deliver into the active session.

An eligible native failure or empty result settles before the extension returns the existing exact manual instruction.
So native and manual startup never run concurrently.

An intentional gate or non-primary stand-down returns no message.
Context-preserving sources retain their existing silent result when the current process already holds the lock.

Manual and automatic compaction retain the existing persistent delivery path, because an automatic retry may have no new `before_agent_start`.
That path still shares the same generation cancellation and exactly-once claim.

The extension encodes an unencoded digest or fallback as `session-start` operational input and leaves an already-encoded nudge alone.

#### Pi delivery size limit

The extension streams the hook to completion and retains at most 512 KiB for message delivery.
Whenever the digest is incomplete, this approved containment keeps the prefix and appends a loud `PI SESSION-START DELIVERY TRUNCATED` marker with direct-inspection guidance.

### OpenCode

OpenCode is a nudge-tier harness.
The `.opencode/plugins/fm-primary-sessionstart-nudge.js` plugin does three things:

- It listens for `session.created`.
- It runs once per session id.
- It calls `client.session.promptAsync` only when the wrapper prints a nudge.

Interactive TUI delivery is supported.
Headless `opencode run` is intentionally fail-open, because the process can exit before the queued turn.
That early exit is also why OpenCode cannot use the run tier.

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end plugins run later, on `session.idle`.
The guard lets the watcher coordinator act first, so the plugins do not race for one lifecycle event.

### Grok

Grok is a nudge-tier harness.
`.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`.
The project hook runs when the checkout is trusted.
Grok currently discards hook stdout from model context.
So this path is intentionally fail-open and cannot use the run tier.

Grok's guaranteed-loading alternative is a global token-guarded hook like the pattern used by `bin/fm-spawn.sh`.
That alternative expands trust and writes outside this repository.
So Firstmate never installs it or grants folder trust automatically.

### Cursor

Cursor is a run-tier harness for session open.
`.cursor/hooks.json` registers `sessionStart`, anchored through `$CURSOR_PROJECT_DIR` with a 180s timeout, invoking `bin/fm-sessionstart-cursor.sh`.
Cursor's payload has no `source` field, so the registration supplies `--source` itself.
The adapter returns the digest as `additional_context`.
Project hooks load only when the workspace is launched with `--trust`.

Cursor's `sessionStart` fires at every session open with no source distinction, including a resumed session.
So a resume re-runs the full digest.
That is redundant and idempotent rather than a lost helm.

### omp

omp is a run-tier harness.
The tracked transport is `.omp/extensions/fm-primary-turnend-guard.ts`, which is auto-discovered from the home with no trust gate.
The extension starts the wrapper at `session_start`.
It has `before_agent_start` await the wrapper and return one persistent context message before the first provider call, exactly as Pi's does.
`session_compact` is the compaction equivalent.

omp's `session_start` carries no reason field (verified 18.1.11).
So the source is derived following the Cursor precedent:

| omp session start | Source |
| --- | --- |
| The first start of the process | `startup` |
| The first start of the process, when the launch line carried `--continue`/`-c` or `--resume`/`-r` | `resume` |
| A later in-process start (`/new`, `/resume`, `/fork`) | `clear` |

A later in-process `clear` re-emits only when this lock owner completed a full startup.
`before_agent_start` message delivery was verified to reach model context on 18.1.11.

### Cursor compaction

Cursor compaction is uncovered and has no tracked transport.
Cursor's `preCompact` response can return only `user_message` and is absent from Cursor's `additional_context` step set.
So it cannot inject a re-emit digest.
Delivering one needs its own design and is deliberately deferred to a follow-up.
A Cursor primary does not re-emit its digest after a compaction.

Cursor's compaction surface is uncovered in the same sense as [Codex's interactive TUI](#codex-interactive-tui).
Firstmate registers nothing for `preCompact`.
So a compacted Cursor session keeps whatever context survived rather than receiving a fresh digest.

## Regression coverage

### Wrapper and Pi extension suite

`tests/fm-sessionstart-nudge.test.sh` is a portable suite.
It proves the nudge wrapper's silence for these cases:

- Both gate signals.
- An unmarked linked worktree.
- A missing state directory.
- An already-owned lock.

It also proves the nudge wrapper's exact U+2063 `FIRSTMATE_OP:`-prefixed, `session-start`-typed one-line output.

It separately proves the run wrapper's silence for the gate environment and an unmarked linked worktree, including the internal Pi prerequisite's explicit silent stand-down.

It proves the run wrapper's source routing end to end against a real `fm-session-start.sh`, including:

- Completion-gated `--reemit` selection.
- Resume delegation.
- Pi CLI continuation classification.
- An unrecognized source falling through to the full digest.
- Bounded loud delivery of an oversized Pi digest.

Through the extension's public event surface, the same portable suite proves:

- Provider exclusion until settlement.
- Exactly-one execution and context delivery.
- Interruption.
- Process-tree retirement.
- Two rapid replacements.
- Stale completion.
- Eligible empty output.
- Spawn error.
- Wrapper timeout output.
- Truncation.
- Ineligible stand-down.
- Compaction cancellation.

### Runtime bound test

`tests/fm-session-start.test.sh` proves the runtime bound through the forced pure-Bash fallback.
It uses a TERM-resistant digest that exceeds its budget and proves that the digest:

- Is force-killed with its grandchild.
- Still emits its completed stages.
- Names the incomplete stage and every stage it never reached.
- Leaves no completion proof.
- Exits 0.

### Native startup and Ahoy tests

`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` exercise native startup paths with first-message and later-message Ahoy regressions.

### Cursor tests

`tests/fm-cursor-primary.test.sh` proves the Cursor adapter over real processes:

- `sessionStart` emits the whole digest as `additional_context` with a caller-supplied `--source`.
- It stays silent in a child worktree.
- It lets the run wrapper stand down on the Cursor-delivered duplicate.
- It keeps `preCompact` unregistered, so the deferred surface cannot be reintroduced unnoticed.

`FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh` proves the injected digest actually reaches model context in a real cursor-agent session.

### Live run-tier guards

`tests/fm-sessionstart-hook-live-e2e.test.sh` is the opt-in live guard for the Claude, Codex exec, and Pi run-tier adapters.
It confirms each installed adapter in that suite invokes the run wrapper and delivers its output into context.
It verifies context-preserving reopen sources for those adapters, and context-reset delivery wherever their tracked TUI surface is reachable.

Its separate `FM_PI_SESSIONSTART_RACE_LIVE_E2E=1` mode uses real Pi with an offline deterministic provider and a barrier-controlled `/new` digest.
That mode proves both an immediate prompt and a completed-before-prompt control make their first provider call with exactly one native startup context and no manual execution.

Cursor uses the separate primary live guard named in [Cursor tests](#cursor-tests) because its source-free `sessionStart` and stop-hook park are validated together.

`tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh` is the separate opt-in real-Pi guard for a post-start AGENTS.md update followed by compaction.

### Guard, monitoring, and away-mode tests

`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery.

### Transport evidence

[`verification/supervision.md`](verification/supervision.md#native-session-start-delivery) records the active version-scoped transport evidence.
