# Native session-start and post-compaction nudges

AGENTS.md section 3 is the authoritative behavioral contract for session start.
The tracked native adapters inject one instruction and never run the digest, acquire the lock, perform bootstrap work, drain notifications, or arm supervision themselves.
The payload starts with U+2063 and the stable `FIRSTMATE_OP: ` label, carries the current `session-start` protocol kind, and retains exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.
The Ahoy skill owns the rule that this marked operational input is never a captain-authored session boundary, including its narrow legacy compatibility cases.

The same wrapper also accepts `post-compact` and emits one `post-compact` instruction after a supported harness compacts context.
That instruction tells the agent to re-read `data/captain.md`, `data/captain-shared.md`, `data/learnings.md`, and active `state/*.meta` files before further action.
The wrapper also appends the same bounded `RECORD CONTRADICTIONS` section as session start when backlog, metadata, last status events, endpoint liveness, recorded pull-request reality, or old orphan status logs disagree.
It prints no contradiction heading or healthy row when those records agree.
It explicitly forbids running `bin/fm-session-start.sh`, and the wrapper itself performs no fleet mutation.
The away-mode stub in AGENTS.md section 8 is the always-loaded trust pointer and routes required handling for this kind to `afk`, while this document owns its transport mechanics and compatibility limits.

Firstmate ships two session-open tiers, selected by harness capability: run-tier adapters execute `bin/fm-session-start.sh` before the first turn, while nudge-tier adapters ask the agent to run it.
The run tier blocks initialization while the digest runs, so the digest is bounded by `FM_SESSION_START_TIMEOUT` and performs no external-network call on its blocking path.
Network checks run in the separately bounded deferred stage owned by `bin/fm-startup-network.sh`; an unreachable host therefore cannot consume the session-start budget.

## Shared wrapper and safety

`bin/fm-sessionstart-nudge.sh` is the single command every harness adapter invokes.
No argument selects the session-start instruction, while the exact `post-compact` argument selects the bounded re-anchor.
It sources `bin/fm-gate-refuse-lib.sh` and stays silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
It shares `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so the hooks use one primary-detection owner.
The Guard Predicates section of [`turnend-guard.md`](turnend-guard.md#guard-predicates) owns marker validation, plain-checkout detection, and required Firstmate-shaped paths.

Before printing a session-start instruction, the wrapper reads `state/.lock` and walks at most eight parents from its own pid in its own separate, hard-coded loop, independent of `bin/fm-lock.sh`'s ancestry walk (`fm_harness_ancestry_pid()` in `bin/fm-session-lock-lib.sh`, which now walks up to sixteen parents and can extend past a claude-named match to a still-more-ancestral one) and of Pi's `lockOwnership()`.
If the lock names a live pid in that ancestry, session start already ran in this harness session and the wrapper stays silent.
The `post-compact` path does not apply that suppression because a healthy compacting session already owns the lock and still needs the re-anchor.
Every path exits 0, including malformed state and adapter errors, because a Claude SessionStart exit 2 blocks session initialization.

## Harness transports

| Harness | Tracked transport | Session-start compatibility | Post-compaction compatibility |
| --- | --- | --- | --- |
| Claude | `.claude/settings.json` registers `SessionStart` for `startup`, `resume`, and `clear`, plus a separate `compact` entry that calls the same wrapper with `post-compact`, all through `CLAUDE_PROJECT_DIR`. | Native stdout context injection is supported. | Delivery is live-verified for automatic compaction; after the always-loaded trust owner was added, one live run observed the agent accept the signal and directly re-read every named record without rerunning session start, but that compliance observation is not an enforcement guarantee. |
| Codex | `.codex/hooks.json` anchors to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and executes the wrapper. | Native stdout context injection is supported. | Fail-open: no compaction lifecycle event with hook-context delivery is verified, so no post-compaction registration is claimed. |
| OpenCode | `.opencode/plugins/fm-primary-sessionstart-nudge.js` listens for `session.created`, runs once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Interactive TUI delivery is supported; headless `opencode run` is intentionally fail-open because the process can exit before the queued turn. | Fail-open: no compaction lifecycle event and delivery path is verified for this adapter. |
| Pi / pi-signed | `.pi/extensions/fm-primary-turnend-guard.ts` handles `session_start` reasons `startup`, `new`, and `resume`, then injects the wrapper output with `pi.sendMessage`. | The custom message reaches model context without racing an initial positional prompt. | Fail-open: Pi exposes `session_compact`, but post-compaction nudge delivery has not been verified end to end for either Pi identity, so the extension does not claim the guard. |
| Grok | `.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project hook runs when the checkout is trusted, but Grok currently discards hook stdout from model context, so this path is intentionally fail-open. | Fail-open: no compaction lifecycle event with model-context delivery is verified. |
| Kimi | No primary session-start nudge transport is registered. | Fail-open: session-start delivery is outside the current tracked family. | Fail-open: no compaction lifecycle event with model-context delivery is verified. |

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end plugins run later on `session.idle`, and the guard lets the watcher coordinator act first, so the plugins do not race for one lifecycle event.

Grok's guaranteed-loading alternative is a global token-guarded hook like the pattern used by `bin/fm-spawn.sh`.
That alternative expands trust and writes outside this repository, so Firstmate never installs it or grants folder trust automatically.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves wrapper silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock.
It proves exact U+2063 `FIRSTMATE_OP:`-prefixed, `session-start`-typed one-line output for a plain primary and a marked linked secondmate primary.
It also executes the tracked Claude `compact` hook command and proves `post-compact` contradiction output, consistent-record silence, mutation-free behavior, owned-lock delivery, and fail-open handling of an unknown wrapper mode.
`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` exercise native startup paths with first-message and later-message Ahoy regressions.
`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery.

[`verification/supervision.md`](verification/supervision.md#native-post-compaction-re-anchor) records the active version-scoped post-compaction transport evidence.
