# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Live continuation and heartbeat

Verified on 2026-09-26 with Pi 0.87.1 and pi-openai-codex-compat 0.0.16 in a named isolated Herdr session, using the actual candidate extensions and a deterministic offline provider.
The public regression and real-host commands are:

```sh
bash tests/fm-task-handoff.test.sh
bash tests/fm-pi-branch-extension.test.sh
bash tests/fm-periodic-stow.test.sh
bash tests/fm-pi-primary-types.test.sh
FM_PERIODIC_STOW_HERDR_LIVE=1 bash tests/fm-periodic-stow-herdr-live-e2e.test.sh
```

The live guard's terminal assertion is:

```text
ok - real Pi 0.87.1 with pi-openai-codex-compat 0.0.16 accepted heartbeat and retained live continuation through provider success and compaction
```

It verifies Pi's actual before-settle continuation entry and actual compaction while the same process remains alive; controlled fixtures separately prove semantic assessment, exact executor receipts, dependency release, uncertain effects, and three-duty heartbeat receipts.
The guarded lab helper verifies the default fleet is unchanged after teardown.
This is not a process-exit recovery or production fleet exercise.

## Native session-start delivery

The cross-harness transport pass ran on 2026-07-17 with Codex 0.144.4 and Pi 0.80.10.

Codex command shape:

```sh
codex exec --ephemeral --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox \
  --output-last-message last.txt \
  'Follow any SessionStart hook context before this prompt.'
```

Observed result: the `SessionStart` hook completed and its stdout reached model context.

Pi command shape:

```sh
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts \
  --no-context-files --no-session \
  'After obeying any earlier session-start instruction, reply with exactly PI_SMOKE_DONE.'
```

Observed result: `PI_SMOKE_DONE`, with one session-start execution.
That cold positional-prompt check established eventual custom-message delivery, but it did not submit immediately after `/new` while native digest generation was still running, so its earlier race-free inference is superseded by the provider-prerequisite evidence below.
[`runtime-backends.md`](runtime-backends.md#harness-detection-precedence) owns the shared-ancestry evidence and authoritative selection-marker boundary.

### Run-tier source vocabulary and context-reset injection

The run tier depends on three facts only the vendor can supply: the session-open source it reports, whether hook stdout reaches model context on a context-RESET open rather than only a cold one, and whether a worker the hook detaches survives the hook returning.
The first two were measured on 2026-08-05 against a throwaway Firstmate-shaped lab carrying each harness's own tracked registration with a recorder standing in for `bin/fm-sessionstart-run.sh`.
Each open printed a source-stamped token, and the model was asked to quote that token back, so producing hook stdout could never be mistaken for delivering it.
The third is recorded below.

| Harness | Version verified | Cold open | Context reset | Context-preserving reopen |
| --- | --- | --- | --- | --- |
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

Pi disagrees with Codex on `resume`: a new Pi process continuing a session reports `startup`, and Pi's `resume` reason is reserved for an in-process session switch.
The current adapter classification and baseline mechanics are owned by [`../sessionstart-nudge.md`](../sessionstart-nudge.md#harness-transports) and the `bin/fm-session-start.sh` header.
Their continuation classification is covered by portable tests, not claimed as live validation in this record.

### Pi `/new` provider prerequisite

The real offline Pi regression ran on 2026-08-26 with Pi 0.84.0, an isolated home and session directory, a barrier-controlled native digest, and a deterministic local `streamSimple` provider.
The provider makes no HTTP request and requires no user credential.
Its missing-native branch deliberately requests `bin/fm-session-start.sh`, so an escaped first call reproduces the duplicate-producing manual path rather than passing vacuously.

```sh
FM_PI_SESSIONSTART_RACE_LIVE_E2E=1 \
  tests/fm-sessionstart-hook-live-e2e.test.sh
```

Observed output:

```text
ok - Pi 0.84.0: immediate and completed-before-prompt /new paths each made one first provider call with exactly one native startup context and no manual execution
# fm-sessionstart-hook-live-e2e.test.sh: offline Pi /new race assertions passed
```

The immediate case submitted its first prompt only after the native `clear` child published `started`, held the child behind a release barrier, and proved the provider log remained absent for 500 milliseconds before release.
After release, the first payload reported one native context and no manual result, the session persisted one matching custom message, and the fixture recorded one native execution.
The control case let native generation complete before prompt submission and produced the same first-payload result.
The portable public-event regression in `tests/fm-sessionstart-nudge.test.sh` separately covers interruption, process-tree retirement, two rapid replacements, stale completion, empty output, spawn error, timeout output, truncation, ineligible stand-down, and compaction cancellation.

### Post-start instruction refresh

The current real-Pi instruction-refresh guard uses a scratch `FM_HOME`, a named Herdr lab, and a disposable Firstmate checkout.
It reads completed native assistant messages rather than prompt echoes before compacting, so the tested long answer has actually left the model context.
On 2026-09-25 both the pruning candidate and its unchanged baseline received the updated instruction before the post-compaction question but answered with the old marker.
There is therefore no current passing claim that Pi refreshes a changed `AGENTS.md` after compaction; the equal baseline and candidate result also gives no evidence that this pruning caused the limitation.

```sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
```

This is live coverage only for Pi compaction.
The portable session-start tests cover continuation classification, baseline immutability, and source-routing behavior.
Pi compaction is the only supported stale-cache refresh pair.
Codex exec exposes only startup and context-preserving resume through tracked registration; Codex interactive reset behavior remains uncovered rather than inferred from direct wrapper invocation.

### Detached session-open workers survive the hook

`tests/fm-sessionstart-hook-live-e2e.test.sh` checks whether detached startup workers survive their session-open hook for installed Codex exec and Pi adapters.
The previous measurement used a removed harness and does not establish retained-runtime behavior.
A worker reaped by its host remains a reported abandoned run; the next session start can rerun the idempotent sweeps.

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-session-start.test.sh
tests/fm-startup-network.test.sh
FM_SESSIONSTART_HOOK_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_PI_SESSIONSTART_RACE_LIVE_E2E=1 tests/fm-sessionstart-hook-live-e2e.test.sh
FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```

`tests/fm-sessionstart-hook-live-e2e.test.sh` is the command that refreshes the Codex exec and Pi table above; run it after upgrading any of those harnesses.
It reports an absent adapter explicitly, asserts Pi compaction rather than noting it, and refuses to pass when neither adapter was installed.

The Ahoy first-message boundary was reverified on 2026-07-22 with Pi 0.81.1.
Marked current operational input and the two exact legacy compatibility shapes selected Bearings, while genuine near-miss captain messages remained real boundaries.
The detailed reconciliation and task chronology stay in the private audit report and PR evidence.

## Semantic busy state

The per-adapter semantic sources behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) were verified on the dates below. Pi push-source passes poll `state/<id>.busy-state`; Codex and TraeX use the public native-state classifier.

| Harness | Version verified | Semantic source | Observed result |
| --- | --- | --- | --- |
| Pi | 0.82.0 | Extension `agent_start` / `agent_settled` with `ctx.isIdle()` | The spawn seed `busy source=fm-spawn`, then `busy source=pi-ext event=agent-start`, then `idle source=pi-ext event=agent-settled`; the turn-end marker was still touched. |
| Codex | codex-cli 0.159.1 | Herdr native status plus exact process liveness | 2026-10-02 portable public-interface coverage: native working/idle/blocked/waiting, live native-unknown, exited and unproven process cases; a forbidden reader beside a 64 MiB transcript binding was not executed. |
| TraeX | 0.207.1 internal | Herdr native status plus exact process liveness | The same 2026-10-02 public-interface contract passed; native unknown with an exact live TraeX process is deliberately idle. |

The retired 2026-09-29 transcript lifecycle evidence is recorded in [runtime backend verification](runtime-backends.md#historical-transcript-input-observation-not-a-send-prerequisite). It remains recovery evidence, not the current ordinary state contract.

The earlier Codex 0.145.0 probe on 2026-07-28 tried two push paths, both refused:

```sh
codex exec --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust 'Reply with exactly PROBE2.'
```

That installation refused daemon startup with `managed standalone Codex install not found`; its interactive TUI did not expose its turns through the app-server control socket.
In this 2026-07-28 Codex 0.145.0 semantic-busy probe, Firstmate-written lifecycle project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while an untracked global probe fired in the same runs; Firstmate does not ship, install, recommend, or depend on that global path.
Neither old hook discovery failures nor old daemon reachability establish a current transcript limitation.
The 0.156.1 hook probe still omitted a closing hook on API failure. Current ordinary Codex and TraeX state accepts the documented loss of transcript turn precision instead of depending on that log.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Current default-TUI refresh (Linux, named Herdr lab, private mount/PID/network namespaces, no real provider or credentials):

```sh
FM_BUSY_TRANSCRIPT_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-busy-transcript-live-e2e.test.sh
```

The 2026-09-29 run on Herdr 0.8.0 passed all per-tool lifecycle and input-consumption assertions with Codex 0.158.0 and TraeX 0.207.1.
The exact stable success lines were:

```text
ok - codex default TUI startup and completion
ok - codex active turn and user interrupt
ok - codex real tool failure and simulated API failure
ok - codex process exit overrides a completed transcript
ok - codex endpoint death
ok - traex default TUI startup and completion
ok - traex active turn and user interrupt
ok - traex real tool failure and simulated API failure
ok - traex process exit overrides a completed transcript
ok - traex endpoint death
```

The guard preserves the managed TUI flags and positional operational brief; it does not use `exec`, `--no-daemon`, a remote app-server, or shared daemon configuration.
Provider responses and HTTP 401 are simulated; tool execution, interrupt keys, vendor transcript emission, process exit and classification run for real.
This does not verify an authenticated provider's availability or the allocator that provisions a worktree.
The exact binding, version-independent structural identity, per-record size limit, streaming whole-transcript validation, and missing-log behavior belong to [`fm-busy-transcript.py`](../../bin/fm-busy-transcript.py).
Those properties govern retained recovery/lifecycle observation only.
Ordinary state and message submission no longer consult this reader or derive identity, consumption, deduplication, or receipt guarantees from vendor logs.
The portable regressions cover stale generations, child/mismatched/ambiguous sessions and missing, corrupt, truncated or replaced logs as lifecycle evidence.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Turn-end guard

The retained observations below are version-scoped; current refresh commands follow in the continuity section.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |

## Watcher continuity

The retained cross-harness evidence is from the 2026-07-17 live pass against isolated project and home state.
No credential material was copied into a fixture.

```text
codex-cli 0.144.4
Pi 0.80.10
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Codex | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-continuity-live-e2e.test.sh` | The one-second foreground checkpoint returned without switching to the arm wrapper. |
| Pi | `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` | One initial tool call led to extension-owned successors and clean child retirement on exit. |

Pi 0.81.1 repeated the continuity and clean-exit lifecycle on 2026-07-23 after the Calm presentation changes.

Pi same-process session-transition ownership was verified on 2026-09-01 against the tracked extension with provider-free public lifecycle events, retained and fresh extension-module rebinds, and real arm children:

```sh
pi --version
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
```

Observed guarantee: after ordinary `session_shutdown` for `/new`, `/resume`, `/fork`, and reload, plus same-instance shutdown-plus-start, an owning `session_start` armed the replacement generation before any model turn and without the `watcher: not armed - Pi session is shutting down` refusal.
A fresh module rebind also received exactly once the actionable close whose first delivery was still in flight at shutdown, while retaining one live successor.
Stale prior-generation tool callbacks could not mutate the active child, repeated transitions kept exactly one live arm cycle, and terminal `quit` still refused late rearm.
The strict no-emit check used the installed Pi SDK declarations to hold the lifecycle event contract.
Pi uses `.pi/extensions/fm-primary-pi-watch.ts`; Codex does not use this extension lifecycle.

On 2026-09-02 the same suite, the strict typecheck, and the credential-free real-SDK guard were rerun against `@earendil-works/pi-coding-agent` 0.84.4 after the extension stopped waiting for `before_agent_start` before settling a main delivery; [`runtime-backends.md`](runtime-backends.md#2026-09-02-streaming-time-watcher-delivery) owns the exact commands and output.
Observed guarantee: a wake delivered while main was streaming was followed by a verified successor and by delivery of the next actionable close, a replacement replayed only the follow-up Pi had not consumed, an exhausted restoration delivered its typed failure without launching an arm past the retry bound, and a verified successor that failed while a branch settlement still held its wake took the ordinary bounded retry once that delivery settled.

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
