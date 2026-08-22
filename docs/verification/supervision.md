# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, semantic busy state, allowance-park, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4, Grok 0.2.103, OpenCode 1.17.18, Pi 0.80.10, and the tracked Claude hook wiring.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Grok command shape:

```sh
grok --trust -p 'Follow any SessionStart hook context before this prompt.' \
  --permission-mode bypassPermissions --output-format plain
```

Observed result: the project hook ran, but its stdout did not reach model context.
This is the current Grok fail-open limit.

OpenCode was checked in both headless and interactive modes.
`client.session.promptAsync` accepted the nudge in both cases; the persistent TUI completed the generated turn, while `opencode run` exited before another turn.
This is the current headless fail-open limit.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
The earlier `sendUserMessage` counterfactual raced the positional prompt; the current non-triggering `pi.sendMessage` custom message did not.
The installed pi-signed 0.82.0 wrapper repeated the Pi primary extension and session-start path on 2026-07-27.
[`runtime-backends.md`](runtime-backends.md#tmux) owns the shared-ancestry evidence and authoritative selection-marker boundary.

### Run-tier source vocabulary and context-reset injection

The run tier depends on three facts only the vendor can supply: the session-open source it reports, whether hook stdout reaches model context on a context-RESET open rather than only a cold one, and whether a worker the hook detaches survives the hook returning.
The first two were measured on 2026-08-05 against a throwaway Firstmate-shaped lab carrying each harness's own tracked registration with a recorder standing in for `bin/fm-sessionstart-run.sh`.
Each open printed a source-stamped token, and the model was asked to quote that token back, so producing hook stdout could never be mistaken for delivering it.
The third is recorded below.

| Harness | Version verified | Cold open | Context reset | Context-preserving reopen |
| --- | --- | --- | --- | --- |
| Claude | 2.1.222 (Claude Code) | `source=startup`, token quoted back in both `-p` and the TUI | `/clear` reports `source=clear` and `/compact` reports `source=compact`; both re-injected a fresh token that the model quoted back | `claude --continue` reports `source=resume` |
| Codex | codex-cli 0.146.0 | `source=startup` under `codex exec`, token quoted back | Not reachable from a tracked project registration; see the limit below | `codex exec resume --last` reports `source=resume` |
| Pi | 0.82.0 | `source=startup`, token quoted back in both `-p` and the TUI | `/new` raises `session_start` reason `new`, which the extension maps to `clear`; `/compact` raises `session_compact`, and both freshly injected source-stamped tokens were quoted back | `pi -c` reports reason `startup`, not `resume` |

Two harness-specific consequences are load-bearing rather than incidental.

Codex's interactive TUI fired no project `SessionStart` hook at all in the same lab where `codex exec` fired it reliably, which matches the earlier 2026-07-28 finding for 0.145.0.
Codex's run tier is therefore verified only for `codex exec` startup and context-preserving resume.
The interactive TUI is a known uncovered gap: Firstmate has no tracked session-open, compaction, or re-emit channel there, ships no global hook, and does not claim instruction-refresh delivery for that surface.

Pi compaction was verified on 2026-08-05 with Pi 0.82.0 in the same throwaway lab after setting `.pi/settings.json` `compaction.keepRecentTokens` to 200 and completing one substantial assistant-prose turn before issuing `/compact`.
Pi reported `Compacted from 7,697 tokens`, the recorder observed `session_compact`, and the model quoted the freshly injected `source=compact` token back.
Both preconditions are load-bearing: the stock 20,000-token keep window exceeds a small lab session, and `AgentSession.compact()` aborts an in-flight turn before measuring compactable history, which otherwise discards that turn and reports `Nothing to compact (session too small)`.
Tool output alone does not grow compactable context; the completed assistant prose does.

Observed compaction output and recorder source:

```text
Compacted from 7,697 tokens
compact
```

Pi disagrees with Claude and Codex on `resume`: a new Pi process continuing a session reports `startup`, and Pi's `resume` reason is reserved for an in-process session switch.
The current adapter classification and baseline mechanics are owned by [`../sessionstart-nudge.md`](../sessionstart-nudge.md#harness-transports) and the `bin/fm-session-start.sh` header.
Their continuation classification is covered by portable tests, not claimed as live validation in this record.

### Post-start instruction refresh

The isolated real-Pi instruction-refresh regression ran on 2026-08-11 with Pi 0.84.0.
It used a scratch `FM_HOME`, a private tmux socket, and a disposable Firstmate checkout.
The historical `origin/main` implementation first reproduced the stale original marker after a real compaction.
The current implementation then recorded `source=startup`, changed and committed the lab's `AGENTS.md`, compacted the same real Pi session, and answered with the replacement marker.
The fixed run also proved that the true-start baseline remained different from the updated file after compaction.

```sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=origin/main \
FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=stale \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 reproduces stale AGENTS.md after a real compact

FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
# ok - Pi 0.84.0 re-injects updated AGENTS.md after a real compact in an isolated session
```

This is live coverage only for Pi compaction.
The portable session-start tests cover continuation classification, baseline immutability, and source-routing behavior.
Pi compaction is the only supported stale-cache refresh pair.
Codex exec exposes only startup and context-preserving resume through tracked registration; Codex interactive reset behavior remains uncovered rather than inferred from direct wrapper invocation.

### Detached session-open workers survive the hook

Session start composes its digest from local reads and runs every external-network call in a worker detached by the hook (`bin/fm-startup-network.sh`), so a harness that reaped the hook's process tree would silently stop running the sweeps rather than merely delaying them.
Verified on 2026-08-06 with Claude Code 2.1.222 in a throwaway lab whose `bin/fm-bootstrap.sh` sleeps 6s before writing a marker, so the marker can exist only if the worker outlived the hook and the whole `claude -p` process.

```text
$ claude -p --permission-mode bypassPermissions '<quote the session-start token>'
FMHOOKTOKEN-startup-1-abc123
--- claude exited at 13:38:40; polling for the detached worker's marker ---
MARKER at +4s: detached worker survived the hook
state=done
started=1786048716
finished=1786048723
```

The worker started before the harness exited and published 6s after it was gone.

The latency this buys was re-measured on 2026-08-06 against default-branch tip `8398d31`, in a throwaway home holding one remote secondmate whose host hangs 25s per SSH connection (an `FM_SSH_BIN`-shaped stub; no real host was contacted).
Both runs used the same fixture and the same `bin/fm-session-start.sh` invocation, differing only in which checkout supplied the script:

```text
before (8398d31)   real 1m21.15s   3 blocking SSH attempts inside the digest
after              real 0m3.36s    digest prints IN PROGRESS; the same 3 SSH attempts
                                   run in the detached worker and finish at +77s
```

The remaining seconds are entirely local subprocess work; the `NETWORK CHECKS` section named GitHub authentication, dead-secondmate relaunch, secondmate convergence, pending handoff delivery, and project clone refresh as not yet confirmed.

Deferring the sweeps changed only when they run, not what they conclude.
The deferred worker's published report was byte-identical to the three sweep lines the blocking baseline printed, on the same fixture:

```text
SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown; route preserved on remote-mac
SECONDMATE_SYNC: secondmate ios: skipped: remote tracked-file sync failed on remote-mac:
SECONDMATE_SYNC: secondmate ios: skipped: remote inheritance failed on remote-mac:
```

The unreachable route was preserved rather than relaunched in both runs, and the result surfaced durably as a queued `check: startup-network` wake once the worker finished.

Codex and Pi were not installed as run-tier labs in this measurement, so their evidence for this fact is NOT refreshed; `tests/fm-sessionstart-hook-live-e2e.test.sh` asserts it for each installed Claude, Codex exec, and Pi adapter and is the command that refreshes their record.
Cursor's separate primary live guard covers its source-free session-open transport but does not claim this detached-worker measurement.
A harness that did reap the worker degrades loudly rather than silently: the leftover record reads as an abandoned run needing a rerun, and the next session start re-derives every finding, because these sweeps are idempotent detectors.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-session-start.test.sh
tests/fm-startup-network.test.sh
FM_SESSIONSTART_HOOK_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

`tests/fm-sessionstart-hook-live-e2e.test.sh` is the command that refreshes the Claude, Codex exec, and Pi table above; run it after upgrading any of those harnesses.
It reports an absent adapter explicitly, asserts Pi compaction rather than noting it, and refuses to pass when none of those three adapters was installed.
Cursor's refresh command is `FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh`, recorded under [Cursor primary park](#cursor-primary-park-2026-08-13).

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1 and OpenCode 1.17.18.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were live-verified on 2026-07-28 against firstmate-launched workers wired exactly as `fm-spawn` writes them.
Each pass polled `state/<id>.busy-state` while a real turn ran.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| OpenCode | 1.17.18 | Plugin `session.status` | In a real TUI pane: seed, then `busy source=opencode-plugin event=session-busy`, then `idle source=opencode-plugin event=session-status-idle`. |
| Claude | 2.1.220 (Claude Code) | Hooks `UserPromptSubmit`, `Stop`, `StopFailure`, `SessionEnd` | `UserPromptSubmit` fired for the argv launch prompt and each steer, and `Stop` closed every completed turn. A mid-stream Escape interrupt fired no closing hook, which is why the firstmate-controlled clear exists. `StopFailure` and `SessionEnd` are wired from the four hook names present in the installed binary; only the abnormal paths they cover were not reproduced live. |
| Codex | codex-cli 0.145.0 | None usable | See below; classifies `unknown codex-unverified`. |
| Kimi (standalone) | not installed | None usable | No binary on `PATH`, so the gate stays closed and it classifies `unknown kimi-unverified`. |
| Grok | 0.2.112 | Isolated rendered-tail fallback | Retained unconverted; the approved audit could not credit a live structured-lifecycle run. |

Codex was probed two ways, both refused:

```sh
codex app-server daemon start
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

The daemon refused with `managed standalone Codex install not found`, and an interactive TUI worker neither starts nor attaches to the app-server control socket, so no client can observe its turns.
In this 2026-07-28 Codex 0.145.0 semantic-busy probe, Firstmate-written lifecycle project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while an untracked global probe fired in the same runs; Firstmate does not ship, install, recommend, or depend on that global path.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Allowance-park detection

A worker whose provider refused the turn on the account allowance keeps a live process, a live endpoint, and a normally rendered pane, so every liveness probe above reads it as healthy.
[`bin/fm-allowance-lib.sh`](../../bin/fm-allowance-lib.sh) is the single owner of that verdict, and [`bin/fm-watch.sh`](../../bin/fm-watch.sh) and [`bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh) both consult it ahead of their busy gate, because the semantic busy state above stays busy across a refused turn whose closing hook never fires.
The verdict reads two independent signals and either alone carries it, so no single vendor string is load-bearing.

Per-harness support is a gate: an adapter with no entry below reports "not parked" and behaves exactly as it did before the library existed.

| Harness | Version verified | Signal | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.241 (Claude Code) | Session record (structural, preferred) | 128 refusal records across the local transcript store, every one an assistant record carrying `"isApiErrorMessage":true` with `"apiErrorStatus":429` and `"error":"rate_limit"`. |
| Claude | 2.1.241 (Claude Code) | Rendered pane (fallback) | The pane carries the same limit notice plus a `Press Enter to continue after reset` affordance, captured from the 2026-08-17 incident panes. That affordance never reaches the transcript, so the two signals stay genuinely independent. |
| Codex, OpenCode, Pi, Grok, Kimi, Cursor, Muse | n/a | None | No refusal has been observed from these adapters, so no signature is claimed and none of them ever parks. |

The 429 conjunction, rather than `isApiErrorMessage` alone, is what separates an allowance park from the other refusals the same field marks, measured on 2026-08-23:

```sh
grep -raho '"apiErrorStatus":[0-9]*' ~/.claude/projects/ | sort | uniq -c
#     128 "apiErrorStatus":429

grep -rah '"isApiErrorMessage":true' ~/.claude/projects/ | grep -v '"apiErrorStatus"' \
  | grep -o '"text":"[^"]*"' | sort | uniq -c
#       1 "text":"Not logged in · Please run /login"
#       2 "text":"Request timed out"
```

429 is the only status the field ever takes, and the two non-allowance refusals carry no status at all.
The notice itself takes three shapes, which is why the signature matches the limit word as a class with an optional trailing clause rather than as a literal:

```sh
grep -rah '"apiErrorStatus":429' ~/.claude/projects/ | grep -o '"text":"[^"]*"' \
  | sed 's/[0-9]\{1,2\}:\?[0-9]\{0,2\}[ap]m/HH:MMxm/' | sort | uniq -c | sort -rn
#      84 "text":"You've hit your session limit · resets HH:MMxm (UTC)"
#      40 "text":"You've hit your session limit · resets HH:MMxm (UTC) · progress saved"
#       4 "text":"You've hit your weekly limit · resets HH:MMxm (UTC)"
```

Taking the last conversational record - user and assistant records only - is what makes the structural signal current state rather than history, and it discriminates on the same store:

```text
transcripts with a 429 record: 68
last conversational record IS the refusal (parked): 29
something later (resumed): 39
```

Transcripts live at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<worktree with / and . replaced by ->/<session>.jsonl`, and `bin/fm-spawn.sh` forwards firstmate's own resolved store onto the crewmate launch, so the watcher resolves the same store the crewmate writes.
At session start only `<project-dir>/<session>/tool-results/` exists; the transcript appears once the session has content, which is why the live guard below asserts on the directory rather than on a transcript.

Deterministic entry point:

```sh
tests/fm-allowance-park.test.sh
```

Refresh command for the per-harness evidence above, which launches every installed harness bare and spends no model tokens:

```sh
FM_ALLOWANCE_PARK_DRIFT=1 tests/fm-allowance-park-live-e2e.test.sh
# ok - claude (2.1.241 (Claude Code)): store resolves at /home/<user>/.claude/projects/<mangled> and a healthy worker is not read as parked
# ok - every installed harness with a verified allowance signature was exercised
```

That guard proves the store derivation still lands where the harness writes and that a healthy worker is not classified as parked.
It deliberately does not prove that a real refusal still writes the matched fields, because forcing one means exhausting the account allowance, which is the outage this detection exists to shorten; that half is refreshed by capturing the next real refusal against the counts above.

## Turn-end guard

The blocking and bounded-follow-up mechanisms were validated across six harnesses on 2026-07-08 through 2026-08-13, with Claude's replacement Stop-owned path revalidated on 2026-07-24 and Cursor's stop-hook park validated on 2026-08-13.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |
| Cursor | 2026.08.11-e8db854 | Awaited `stop` hook park returning one `followup_message` | Exit 2 ended the turn normally, proving it cannot block; a returned follow-up ran a genuine second turn; a sleeping hook held the boundary open and the wake landed after it; `loop_limit` stopped the hook being invoked at its ceiling. |

### Cursor primary park, 2026-08-13

Cursor was validated as a primary on 2026-08-13 against the installed CLI on macOS 26.5.2 arm64 with tmux 3.6a, in a throwaway firstmate home on a private tmux socket, never against a live home and never with a user-scope hook.

Mechanism facts established first, in a separate throwaway workspace:

| Question | Method | Result |
| --- | --- | --- |
| Can `stop` block? | hook exits 2 | No. The turn ended normally; Cursor's blocked-response mapper returns `{}` for the `stop` step. |
| Can `stop` force one turn? | hook returns `{"followup_message":...}` | Yes. A genuine second turn ran and answered. |
| Can `stop` park? | hook sleeps, then returns a follow-up | Yes. It is awaited; a 20s sleep held the boundary and the follow-up landed after it. |
| What is `loop_count`? | four consecutive follow-ups, then a real user message | `0,1,2,3`, then `0` again. It counts follow-up-driven stops since the last real user message. |
| Does `loop_limit` bind? | `loop_limit: 2` with an always-follow-up hook | Yes. The hook was invoked at `loop_count` 0 and 1 and never at 2. |
| Does a captain message terminate an existing park? | captain message typed during a 600s park | No. Cursor leaves the park running, and without a baton an older park can still deliver after the captain turn's next `stop` has started another park. |
| Does Cursor load `.claude/settings.json`? | Claude-shaped `SessionStart`, `PreToolUse`, `Stop` in the same workspace | `SessionStart` and `PreToolUse` fired with a CURSOR-shaped payload carrying `cursor_version`; `Stop` did not fire. |

The integration itself is exercised by the opt-in guard:

```sh
FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh
```

Observed output:

```text
harness: cursor-agent 2026.08.11-e8db854
ok - cursor primary: the sessionStart hook takes the fleet lock as the Cursor process itself
ok - cursor primary: the run-tier session start completes every stage
ok - cursor primary: sessionStart additional_context reaches model context before the first turn
ok - cursor primary: the stop-hook park delivers a real watcher wake as one follow-up
ok - cursor primary: the park owns exactly one arm cycle with a live watcher beacon
ok - cursor primary: the captain keeps control and the older park stands down after the next stop claim
ok - cursor primary: an away-mode escalation is delivered, confirmed, and processed
```

The live run proved that session start acquires the fleet lock through Cursor's structural process identity in `bin/fm-cursor-lib.sh`; `tests/fm-session-lock-ancestry.test.sh` pins the same ancestry path portably.
It also proved that Cursor's `autoarm` supervision model lets the mid-turn pull guard accept a fresh beacon after the between-turn watcher closes; `tests/fm-guard-stale-banner.test.sh` pins that model-aware verdict.
The baton is claimed only by the next `stop`, so an actionable close before that claim can still produce one real follow-up from the sole existing park; durable wake handling is idempotent, and any older park still running after the claim stands down.
Cursor's `beforeSubmitPrompt` step could close that exact window because it fires once on a real captain message and not on hook-driven follow-ups, but registering it is deliberately deferred alongside `preCompact`.

Away-mode delivery needed no daemon change once the composer reader was correct for Cursor; [`runtime-backends.md`](runtime-backends.md#composer) owns that evidence.

Cursor compaction instruction refresh is DEFERRED and not shipped, so a Cursor primary does not re-emit its digest after a compaction.
Two static facts decided that: `PreCompactRequestResponse` carries only `user_message`, and `preCompact` is absent from the `additional_context` step set (`index.js` @ 4814884), so the step cannot inject a digest and any delivery has to be routed through a later boundary.
A staged-then-delivered design is rejected because carrying a digest across two concurrently running `stop` hooks can deliver it twice or strand it indefinitely, while closing those races enlarges a critical section inside a hook Cursor awaits at the turn boundary.
Native `preCompact` firing was not observed because a real compaction could not be forced in the isolated session, so the surface has no empirical basis yet.
It is therefore recorded as uncovered in the same sense as the Codex interactive TUI, and `tests/fm-cursor-primary.test.sh` asserts `preCompact` stays unregistered so it cannot return unnoticed without its own design and evidence.

The Grok adaptive matrix ran on 2026-07-28 with separate scratch repositories and homes, dedicated tmux sockets, one target plus one control window, ambient tmux variables removed, and a socket-bound wrapper first in `PATH`.

```sh
FM_GROK_STOP_LIVE_E2E=1 \
  FM_GROK_NATIVE_BIN="$native_grok_0_2_112" \
  FM_GROK_LEGACY_BIN="$official_pre_native_grok_0_2_73" \
  tests/fm-grok-stop-live-e2e.test.sh
```

Observed bounded output:

```text
ok - grok 0.2.112 (9bbd559437aa) [stable] native Stop kept one session across false->true, two model turns, and zero resume processes
ok - grok 0.2.73 (9ff14c43bbe5) [stable] legacy Stop omitted capability, resumed exactly once, and stopped normally
ok - Grok adaptive Stop real-process matrix passed with exact target cleanup and control-window survival
```

The same run proved the Claude-compatible Stop entries stay inert under `GROK_AGENT`, the legacy resume carries `GROK_TURNEND_GUARD_ACTIVE=1`, and every replacement root is removed after exact target cleanup while its control window survives.
That inertness result is scoped to the builds it exercised: it did not establish that `GROK_AGENT` reaches a Grok HOOK process, and on grok 1.0.0 it does not, so the marker set was widened to `GROK_HOOK_EVENT` as well (docs/turnend-guard.md "Harness integrations").
`tests/fm-turnend-guard.test.sh` now pins every tracked `.claude/settings.json` hook entry against a real grok 1.0.0 hook environment so the inertness contract is covered deterministically rather than only by the opt-in live matrix.

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.
`tests/fm-watch-arm.test.sh` runs real watcher and arm cycles against durable on-disk state to verify that a delivered reason survives until post-handling acknowledgement and stops replaying after acknowledgement, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.
The same suite ingests a keyed remote-secondmate parent reply through the real adapter, establishes the incremental OPEN DECISIONS cursor, interrupts supervision, and proves re-arm replays every unacknowledged queue row plus the still-open decision through the ordinary drain path.
It also covers decision-only recovery, interrupted handling, handling-window generation reuse, non-fatal moved-generation acknowledgement with sequence-bounded consumption, and a persistent successor remaining live after recovery is acknowledged.

The Claude product live path ran with Claude Code 2.1.219 on 2026-07-24:

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.219 (Claude Code)
ok - Claude 2.1.219 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary
```

Current entry points:

```sh
tests/fm-turnend-guard.test.sh
tests/fm-supervision-instructions.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_GROK_STOP_LIVE_E2E=1 FM_GROK_NATIVE_BIN="$native_grok" FM_GROK_LEGACY_BIN="$pre_native_grok" tests/fm-grok-stop-live-e2e.test.sh
```

The Claude auto-arm false-failure, guard-predicate, and monotonic bounded fail-open correction was verified on 2026-08-02 with the installed ShellCheck 0.11.0 and isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=61 local_links=174
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=102585
```

The model-aware pull-guard predicate correction (`bin/fm-guard.sh` no longer reports a false watcher-down mid-turn under the Claude Stop auto-arm model, where the watcher runs only between turns) was verified on 2026-08-04 with the installed ShellCheck 0.11.0 and the same isolated behavior suites.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=64 local_links=188
FM_TEST_SUMMARY total=4 failed=0 skipped_gate=0 duration_ms=80078
```

The Pi extension-model pull-guard correction (`bin/fm-guard.sh` no longer reports a false watcher-down on a Pi primary during the extension's own watcher hand-off) was verified on 2026-08-13 with the installed ShellCheck 0.11.0 and isolated behavior suites.
The guard verdict itself reads only state files and process liveness, so the portable suites are the enforcing evidence; `bin/fm-harness.sh`'s Pi marker detection, which selects the model, is exercised in the same suite through `PI_CODING_AGENT`.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-guard-stale-banner.test.sh tests/fm-turnend-guard.test.sh tests/fm-session-start.test.sh tests/fm-pi-watch-extension.test.sh tests/fm-watch-arm.test.sh
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=67 local_links=243
FM_TEST_SUMMARY total=5 failed=0 skipped_gate=0 duration_ms=280160
```

The same correction was verified against a live Pi primary's own supervision evidence on 2026-08-13.
The hand-off was captured live at beacon age 63s, then the home's `state/.lock`, `state/.last-watcher-beat`, both `state/.pi-*-extension-loaded` markers, and both `.pi/extensions/*.ts` builds were copied into an isolated fixture with no watcher lock.
The fixture's copied beacon was fresh at 0s in the output below; the deterministic stale-beacon case separately verifies the grace boundary.

```sh
FM_SUPERVISION_MODEL=persistent FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
FM_SUPERVISION_MODEL=extension FM_GUARD_READ_ONLY=1 bin/fm-guard.sh
```

Observed output, before and after the model correction, then with the recorded Pi session pid replaced by a dead one:

```text
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
(silent)
●  WATCHER DOWN - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher process holds this home lock (last beat: 0s ago).
```

The broader relevant regression pass was rerun on 2026-08-02 without live-home or daemon mutation.

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watcher-lock.test.sh tests/fm-afk-inject-e2e.test.sh tests/fm-afk-return.test.sh tests/fm-x-mode.test.sh tests/fm-backend.test.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-secondmate-safety.test.sh
```

Observed output:

```text
FM_TEST_SUMMARY total=8 failed=0 skipped_gate=0 duration_ms=617507
```

The actionable-close ordering correction was reverified on 2026-08-02 against an identity-matched live successor.

```sh
tests/fm-claude-stop-autoarm.test.sh >/dev/null && echo "fm-claude-stop-autoarm: ok"
```

Observed output:

```text
fm-claude-stop-autoarm: ok
```

### Claude Stop claim publication ordering, 2026-08-18

Repeated silent supervision drops in the primary home on 2026-08-17 and 2026-08-18 were reproduced end to end against Claude Code 2.1.234 with the real tracked Stop registration, then driven to one cause.
Two reported premises were disproven by measurement before any fix was written.
The `asyncRewake` sibling fires within about a millisecond of the blocking hook and runs to completion even when that sibling exits 2, so the auto-arm was never absent.
The exit-2 continuation turn does not start until the outstanding `asyncRewake` hook completes, observed as a block at 941.25s, the async hook ending at 961.92s, and the first model tool call at 965.90s, so the next turn's start does not race the arm.

What did happen is a visibility window.
In the instrumented lab the guard printed its blind-turn banner and exited 2 on two consecutive cycles while the auto-arm was healthy and completed successfully in the same event, recording `epoch=2 outcome=rewake` and then `epoch=4 outcome=rewake`.
The identity gate's ancestry walk measured 1.375 to 1.624 seconds live and 8.857 seconds under xtrace, the gate as a whole 0.946 to 3.511 seconds, and the auto-arm's first durable evidence at 11.300 seconds under xtrace, against a nominal 800 millisecond cooperative window.
A sampler run measured the owner lock appearing at +1.70s and its `autoarm` role at +1.77s while the guard gave up at +1.81s, a 20 millisecond margin.
The guard's own wait was an iteration count over fork-heavy passes, so it ran for 2.87s and 29.85s on those two cycles for the same nominal 800 milliseconds.

Three field samples from the primary home bound the window from the other side, each taken by inspecting durable records moments after the guard printed that no recovery was under way.
Two on 2026-08-21 fired at 390 and 297 seconds of beacon staleness, and one on 2026-08-22 at 03:42 UTC fired at 815 seconds, all with seven tasks in flight.
In the third the epoch ledger recorded `epoch=1041 owner_pid=1108506 outcome=arming` written in the same second the guard declared the home unclaimed, that pid alive, both the arm wrapper and the watcher live at 40 and 39 seconds old, and the beacon 35 seconds old.
The spread rules out a near-threshold beacon and therefore a threshold-tuning fix: the staleness was genuine at every sample, and the auto-arm healed it within the same second regardless of how stale the beacon had become.
It also shows the `arming` outcome reaching the ledger while the guard was still reporting the home unclaimed, which is the case the guard's pre-fix outcome filter dropped.

An unrelated firstmate home reported the same defect independently on 2026-08-22, which is what establishes it as structural rather than local to one home or to any load condition there.
That home saw the banner fire six times in one session and be wrong every time, quoting beacon ages of 168, 422, 697, 1001 and 214 seconds where the ages measured immediately afterwards were 3 to 21 seconds, with the rewake counter advancing across every firing, exactly one monitor pair scoped to that home live, and no failure marker present.
It reached the same mechanism from its own evidence: the guard samples beacon age and claim status at the turn boundary, before the recovery hook firing on that same boundary has claimed the home, so it reports a state that is already obsolete when the reader sees it.
It also separated this defect from the wake-queue lock deadlock, because nothing deadlocked and recovery always completed on its own.

The cost that makes this worth fixing is that a false alarm every time makes a genuine failure indistinguishable from the noise, so the fix must not buy quiet by weakening the predicate.
No arm, no live watcher and no claim still blocks loudly, pinned by the re-block, dead-publisher, X-mode, stale-epoch, and exhausted-budget cases in `tests/fm-turnend-guard.test.sh`.

The portable regression reproduces that window with real concurrent processes rather than fixtures, parking a real auto-arm inside its identity gate behind a `ps` shim and asking the guard for a verdict with the claim as the only evidence on disk.

```sh
tests/fm-turnend-guard.test.sh
```

Observed output, last four lines:

```text
ok - fm-turnend-guard --claude: the early claim is the whole difference in the pre-identity window (incident regression)
ok - fm-turnend-guard --claude: an in-progress claim is trusted only while its publisher is alive and unchanged
ok - fm-turnend-guard --claude: a fresh arming epoch is recovery under way, not a missing claim
ok - fm-turnend-guard --claude: the cooperative wait is bounded by elapsed time, not by a pass count
```

Each of the four fails against an unpacked pre-fix tree, checked by running them there one at a time:

```text
not ok - no in-progress claim appeared before the auto-arm's identity gate: firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after 2 bounded attempts, and no live watcher with a fresh beacon was verified.
not ok - a live identity-matched claim must be accepted as recovery under way: expected exit 0, got 2
not ok - --claude must not force a turn against a fresh arming epoch: expected exit 0, got 2
not ok - the cooperative wait spent 24818ms of 3s sleeps for an 800ms budget (baseline 1887ms, total 26705ms): it is counting passes, not elapsed time
```

The harness-emitted half is the opt-in live guard, which now runs its whole session behind a shim that costs every pid query a fixed slice, so the identity gate reliably outlasts the cooperative wait.
The run below recorded 86 delayed pid queries and no forced continuation.

```sh
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
ok - Claude 2.1.234 (Claude Code) live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles under a loaded identity gate, and preserved the competing-live-owner boundary
```

Two adjacent defects were repaired in the same change rather than left silent.
`bin/fm-test-run.sh --check-coverage` compared `LC_ALL=C sort` inventories with a locale-sensitive `comm`, so it warned and failed on any host whose locale is not C; it now reports `FM_TEST_COVERAGE ok total=149 parallel=24 serial=113 serial_shards=4 herdr=12` under `en_US.UTF-8`.
The live auto-arm regression still asserted that the model types the session start command, which the run-tier `SessionStart` hook has made unnecessary, so it could not pass at all; it now asserts that session start ran for that home and that the model issued exactly its two wake drains.

The repo lint gate completes here once actionlint is installed, and did on 2026-08-22.

```sh
bin/fm-lint.sh
```

Observed output, exit 0:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
```

An earlier run of the same gate on 2026-08-18 exited 127 because actionlint was absent from that host, which was a missing tool rather than a result.
`tests/fm-test-run.test.sh` still cannot complete on this host because its CI YAML assertion requires ruby, which is absent.

### What the cooperative wait budget does and does not bound, 2026-08-22

The first version of the elapsed-time regression asserted the hook's TOTAL wall clock, which made it assert fixed cost rather than the defect and fail under load.
Measured on the same fixture, varying only the budget, three runs each:

```text
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0      5889 4861 5386 ms
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100    5017 5671 5374 ms
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800    6642 7148 6243 ms
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=3000   6754 6698 7372 ms
```

A budget of zero forbids every retry, so the roughly 5 seconds it still spends is fixed cost the hook pays regardless: sourcing its libraries, the primary-scope checks, and on the blocking path the budget accounting and banner.
The budget therefore bounds the retrying only, and `docs/turnend-guard.md` "Claim publication ordering" states that limit rather than claiming the hook completes within the budget.

The regression now measures the difference between a zero budget and the real one on the same host, which is exactly what the wait spent, behind a `sleep` shim charging 3 seconds per interval:

```text
base_ms=2595 waited_ms=6924 delta_ms=4329
base_ms=4389 waited_ms=6645 delta_ms=2256
base_ms=3064 waited_ms=7337 delta_ms=4273
```

A deadline-bounded wait spends one shimmed interval past its budget; the pass-count loop this replaced would spend `SYNC_WAIT_MS/100` of them, eight here for 24 seconds, so the assertion's three-interval ceiling separates the two by more than a factor of two in both directions.

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-07-24, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.219
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | Session start reclaimed a stale owner before two Stop-owned cycles, and a competing live owner prevented arm, rewake, epoch write, or lock replacement. |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| OpenCode | `FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh` | A verified successor existed before prompt handling, with no model re-arm or turn-end fallback. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |
| Grok | `FM_GROK_LIVE_E2E=1 tests/fm-grok-continuity-live-e2e.test.sh` | Native task completion surfaced the actionable close and the cycle ledger recorded `reason=actionable-signal`. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-07-27 against the tracked extension with a faithful in-process factory rebind (module cache retained, real arm children):

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, and `/fork`, plus same-instance shutdown-plus-start, the replacement generation armed again without a Pi restart and without the `watcher: not armed - Pi session is shutting down` refusal.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
Plain Pi and pi-signed share the same tracked `.pi/extensions/fm-primary-pi-watch.ts` path, so both inherit the generation owner; other primary harnesses are not applicable because they do not use this Pi extension lifecycle.

The once-per-generation recovery bound and immediate handling-successor poll were verified on 2026-08-21 with the tracked Pi extension, real watcher processes, and an isolated home.
The regression forced handling confirmation to fail, observed one recovery follow-up across the former repeat window, confirmed the successor remained live, and then proved a separate handling successor durably queued a crew event within the bounded poll window.

```sh
bin/fm-test-run.sh tests/fm-watch-recovery-loop.test.sh
```

Observed output:

```text
ok - a resurfacing handling successor stays alive and supervises instead of going blind
ok - unacknowledged recovery is announced at most once per generation and the successor stays alive
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=59357
```

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-watch-arm.test.sh
tests/fm-watch-recovery-loop.test.sh
tests/fm-wake-queue.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

The two real notification channels were bounded manually on 2026-07-10 on macOS 26.5.2 with Herdr 0.7.3.
Automated suites never execute these real notification commands.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

Herdr command:

```sh
herdr notification show 'FIRSTMATE TEST - IGNORE' \
  --body 'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)' \
  --sound request
```

Observed output:

```json
{"id":"cli:notification:show","result":{"reason":"shown","shown":true,"type":"notification_show"}}
```

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
