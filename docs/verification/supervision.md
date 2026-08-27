# Supervision integration verification

Audience: maintainer verification.

This record supports current session-start, turn-end, watcher-continuity, and wedge-alarm guarantees.
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
| Codex | codex-cli 0.145.0 | No usable Codex-owned source | See below; Codex-owned state classifies `unknown codex-unverified`, while an independent Herdr-native `busy` verdict remains reachable and attributed `busy herdr-native`. |
| Kimi (standalone) | not installed | No usable Kimi-owned source | No binary on `PATH`, so Kimi-owned state remains `unknown kimi-unverified`; an independent Herdr-native `busy` verdict remains reachable and attributed `busy herdr-native`. |
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
These failed Codex-owned probes do not gate Herdr's independent backend-level streaming proof: only Herdr-native `busy` is trusted, native `idle` remains inconclusive, and the source stays labeled `herdr-native` rather than making Codex appear verified.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

### Secondmate stall and Codex-on-Herdr red/green record

The six new behavioral cases were run individually on 2026-08-27 with GNU Bash 3.2.57 on macOS 26.5.1.
The unfixed revision was `2e2907964a974cac6bbd884f9d98307faf023148`, and the fixed revision was `d6a6d5f7b634581426a67a844439160a51888952`.
The same fixed-revision test definitions were copied into the unfixed tree so each pair exercised an identical assertion against the two production implementations.
Two cases were RED before and GREEN after, so they demonstrate the fix.
The other four were GREEN before and GREEN after, so they are regression guards and are not evidence that the fix changed behavior.

The exact preparation and single-case runner were:

```sh
fixed_root=$PWD
unfixed_root=$PWD/.verification-unfixed
[ ! -e "$unfixed_root" ] || exit 73
mkdir "$unfixed_root"
git archive 2e2907964a974cac6bbd884f9d98307faf023148 | tar -x -C "$unfixed_root"
cp tests/fm-busy-state.test.sh tests/fm-wake-queue.test.sh "$unfixed_root/tests/"

run_test() {
  local suite=$1 first_call=$2 test_name=$3
  bash -c '
    case "$1" in
      *fm-busy-state.test.sh) . tests/lib.sh ;;
      *fm-wake-queue.test.sh) . tests/wake-helpers.sh ;;
      *) exit 64 ;;
    esac
    eval "$(awk -v first="$2" '\''$0 == first { exit } /^\\. .*BASH_SOURCE/ { next } { print }'\'' "$1")"
    "$3"
  ' _ "$suite" "$first_call" "$test_name"
}

run_case() {
  local revision=$1 root=$2 suite=$3 first_call=$4 test_name=$5 rc
  printf 'CASE revision=%s test=%s\n' "$revision" "$test_name"
  (cd "$root" && run_test "$suite" "$first_call" "$test_name")
  rc=$?
  printf 'exit=%s\n' "$rc"
}
```

#### Fix demonstration: Codex on Herdr native busy

This proves that independent Herdr-native `busy` remains reachable even though Codex-owned semantic sources are unverified.

Unfixed command:

```sh
run_case unfixed "$unfixed_root" tests/fm-busy-state.test.sh test_arm_seeds_busy_spawn test_codex_herdr_native_busy_is_independent_proof
```

Full unfixed output:

```text
CASE revision=unfixed test=test_codex_herdr_native_busy_is_independent_proof
not ok - Herdr-native busy must remain reachable when Codex's own sources are unverified, got 'unknown codex-unverified'
exit=1
```

Fixed command:

```sh
run_case fixed "$fixed_root" tests/fm-busy-state.test.sh test_arm_seeds_busy_spawn test_codex_herdr_native_busy_is_independent_proof
```

Full fixed output:

```text
CASE revision=fixed test=test_codex_herdr_native_busy_is_independent_proof
ok - Herdr-native busy independently proves a Codex turn is active
exit=0
```

#### Regression guard: Codex on Herdr native idle

This proves that Herdr-native `idle` remains inconclusive and leaves Codex explicitly `unknown codex-unverified`.

Unfixed command:

```sh
run_case unfixed "$unfixed_root" tests/fm-busy-state.test.sh test_arm_seeds_busy_spawn test_codex_herdr_native_idle_stays_unknown
```

Full unfixed output:

```text
CASE revision=unfixed test=test_codex_herdr_native_idle_stays_unknown
ok - Herdr-native idle remains inconclusive for Codex
exit=0
```

Fixed command:

```sh
run_case fixed "$fixed_root" tests/fm-busy-state.test.sh test_arm_seeds_busy_spawn test_codex_herdr_native_idle_stays_unknown
```

Full fixed output:

```text
CASE revision=fixed test=test_codex_herdr_native_idle_stays_unknown
ok - Herdr-native idle remains inconclusive for Codex
exit=0
```

#### Fix demonstration: aged busy secondmate queue

This proves that an aged foreign queue stays quiet when semantic liveness positively proves the secondmate busy.

Unfixed command:

```sh
run_case unfixed "$unfixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_busy_aged_queue_stays_quiet
```

Full unfixed output:

```text
CASE revision=unfixed test=test_secondmate_busy_aged_queue_stays_quiet
not ok - busy woke for an aged foreign row: check: secondmate wake-loop stalled: mate=mate row=7 age=10s
exit=1
```

Fixed command:

```sh
run_case fixed "$fixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_busy_aged_queue_stays_quiet
```

Full fixed output:

```text
CASE revision=fixed test=test_secondmate_busy_aged_queue_stays_quiet
ok - a provably busy secondmate with an aged queue row stays quiet
exit=0
```

#### Regression guard: aged latest-blocked secondmate queue

This proves that a latest `blocked:` status wakes above the unchanged age floor even when busy evidence exists.

Unfixed command:

```sh
run_case unfixed "$unfixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_blocked_aged_queue_wakes
```

Full unfixed output:

```text
CASE revision=unfixed test=test_secondmate_blocked_aged_queue_wakes
ok - a secondmate whose latest status is blocked wakes despite busy evidence
exit=0
```

Fixed command:

```sh
run_case fixed "$fixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_blocked_aged_queue_wakes
```

Full fixed output:

```text
CASE revision=fixed test=test_secondmate_blocked_aged_queue_wakes
ok - a secondmate whose latest status is blocked wakes despite busy evidence
exit=0
```

#### Regression guard: aged idle secondmate queue

This proves that idle-but-not-blocked liveness wakes conservatively above the unchanged age floor.

Unfixed command:

```sh
run_case unfixed "$unfixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_idle_aged_queue_wakes
```

Full unfixed output:

```text
CASE revision=unfixed test=test_secondmate_idle_aged_queue_wakes
ok - an idle non-blocked secondmate with an aged queue row wakes
exit=0
```

Fixed command:

```sh
run_case fixed "$fixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_idle_aged_queue_wakes
```

Full fixed output:

```text
CASE revision=fixed test=test_secondmate_idle_aged_queue_wakes
ok - an idle non-blocked secondmate with an aged queue row wakes
exit=0
```

#### Regression guard: aged unknown-liveness secondmate queue

This proves that unknown liveness wakes conservatively above the unchanged age floor.

Unfixed command:

```sh
run_case unfixed "$unfixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_unknown_liveness_aged_queue_wakes
```

Full unfixed output:

```text
CASE revision=unfixed test=test_secondmate_unknown_liveness_aged_queue_wakes
ok - unknown secondmate liveness fails toward waking the primary
exit=0
```

Fixed command:

```sh
run_case fixed "$fixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_unknown_liveness_aged_queue_wakes
```

Full fixed output:

```text
CASE revision=fixed test=test_secondmate_unknown_liveness_aged_queue_wakes
ok - unknown secondmate liveness fails toward waking the primary
exit=0
```

### Review-hardening red/green record

The review-hardening pass added three behavioral cases on the same platform and Bash version recorded above.
The unfixed revision was `63308ac0cc3f831959be25d0f66836453b6ae641`, and the fixed version was its review working tree with the source and test changes recorded in this section.
The Kimi native-busy and dead-endpoint cases were RED before and GREEN after, so they demonstrate the fixes.
The Kimi native-idle case was GREEN before and GREEN after, so it is a regression guard and is not evidence that the fix changed behavior.

The exact additional preparation reused `run_test` and `run_case` from above:

```sh
review_unfixed_root=$PWD/.verification-review-unfixed
[ ! -e "$review_unfixed_root" ] || exit 73
mkdir "$review_unfixed_root"
git archive 63308ac0cc3f831959be25d0f66836453b6ae641 | tar -x -C "$review_unfixed_root"
cp tests/fm-busy-state.test.sh tests/fm-wake-queue.test.sh "$review_unfixed_root/tests/"
```

#### Fix demonstration: Kimi on Herdr native busy

This proves that independent Herdr-native `busy` remains reachable even though Kimi-owned semantic sources are unverified.

Unfixed command:

```sh
run_case 63308ac-unfixed "$review_unfixed_root" tests/fm-busy-state.test.sh test_arm_seeds_busy_spawn test_kimi_herdr_native_busy_is_independent_proof
```

Full unfixed output:

```text
CASE revision=63308ac-unfixed test=test_kimi_herdr_native_busy_is_independent_proof
not ok - Herdr-native busy must remain reachable when Kimi's own sources are unverified, got 'unknown kimi-unverified'
exit=1
```

Fixed command:

```sh
run_case review-fixed "$fixed_root" tests/fm-busy-state.test.sh test_arm_seeds_busy_spawn test_kimi_herdr_native_busy_is_independent_proof
```

Full fixed output:

```text
CASE revision=review-fixed test=test_kimi_herdr_native_busy_is_independent_proof
ok - Herdr-native busy independently proves a Kimi turn is active
exit=0
```

#### Regression guard: Kimi on Herdr native idle

This proves that Herdr-native `idle` remains inconclusive and leaves Kimi explicitly `unknown kimi-unverified`.

Unfixed command:

```sh
run_case 63308ac-unfixed "$review_unfixed_root" tests/fm-busy-state.test.sh test_arm_seeds_busy_spawn test_kimi_herdr_native_idle_stays_unknown
```

Full unfixed output:

```text
CASE revision=63308ac-unfixed test=test_kimi_herdr_native_idle_stays_unknown
ok - Herdr-native idle remains inconclusive for Kimi
exit=0
```

Fixed command:

```sh
run_case review-fixed "$fixed_root" tests/fm-busy-state.test.sh test_arm_seeds_busy_spawn test_kimi_herdr_native_idle_stays_unknown
```

Full fixed output:

```text
CASE revision=review-fixed test=test_kimi_herdr_native_idle_stays_unknown
ok - Herdr-native idle remains inconclusive for Kimi
exit=0
```

#### Fix demonstration: dead endpoint with a stale busy record

This proves that an aged queue wakes when the recorded endpoint is dead even if its last semantic record still says busy.

Unfixed command:

```sh
run_case 63308ac-unfixed "$review_unfixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_dead_endpoint_with_stale_busy_record_wakes
```

Full unfixed output:

```text
CASE revision=63308ac-unfixed test=test_secondmate_dead_endpoint_with_stale_busy_record_wakes
not ok - dead-endpoint did not wake for an aged foreign row: out=checkpoint: no actionable wake within 2s; err=
exit=1
```

Fixed command:

```sh
run_case review-fixed "$fixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_dead_endpoint_with_stale_busy_record_wakes
```

Full fixed output:

```text
CASE revision=review-fixed test=test_secondmate_dead_endpoint_with_stale_busy_record_wakes
ok - a dead secondmate endpoint wakes despite its stale busy record
exit=0
```

### Agent-liveness suppression red/green record

The subsequent liveness-hardening case ran on the same platform and Bash version recorded above.
The unfixed revision was `682dd8d0fe7dc5e75fa2bdd6a7bd3e9974b2c4b2`, and the fixed version was its review working tree with the source and test changes recorded in this section.
The bare-shell stale-busy case was RED before and GREEN after, so it demonstrates the fix.

The exact additional preparation reused `run_test` and `run_case` from above:

```sh
agent_unfixed_root=$PWD/.verification-agent-unfixed
[ ! -e "$agent_unfixed_root" ] || exit 73
mkdir "$agent_unfixed_root"
git archive 682dd8d0fe7dc5e75fa2bdd6a7bd3e9974b2c4b2 | tar -x -C "$agent_unfixed_root"
cp tests/fm-wake-queue.test.sh tests/wake-helpers.sh "$agent_unfixed_root/tests/"
```

#### Fix demonstration: bare shell with a stale busy record

This proves that an aged queue wakes when a secondmate agent exits to a bare shell even if the endpoint remains present and its last semantic record still says busy.

Unfixed command:

```sh
run_case 682dd8d-unfixed "$agent_unfixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_bare_shell_with_stale_busy_record_wakes
```

Full unfixed output:

```text
CASE revision=682dd8d-unfixed test=test_secondmate_bare_shell_with_stale_busy_record_wakes
not ok - bare-shell did not wake for an aged foreign row: out=checkpoint: no actionable wake within 2s; err=
exit=1
```

Fixed command:

```sh
run_case review-fixed "$fixed_root" tests/fm-wake-queue.test.sh test_self_held_lock_reclaims_instead_of_deadlocking test_secondmate_bare_shell_with_stale_busy_record_wakes
```

Full fixed output:

```text
CASE revision=review-fixed test=test_secondmate_bare_shell_with_stale_busy_record_wakes
ok - a bare-shell secondmate wakes despite its stale busy record
exit=0
```

## Turn-end guard

The blocking and bounded-follow-up mechanisms were validated across six harnesses on 2026-07-08 through 2026-08-13, with Cursor's stop-hook park validated on 2026-08-13 and Claude's replacement Stop-owned path revalidated on 2026-08-14.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.232 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | Two real sessions shared an isolated home: the read-only session traced the foreign live-owner gate and finished without a guard loop, then the lock-owning session restored supervision and delivered an actionable rewake without human intervention. |
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

The Claude product live path ran with Claude Code 2.1.232 on 2026-08-14.
Claude's current [hooks reference](https://code.claude.com/docs/en/hooks), read the same day, states that all matching hooks run in parallel, that Stop exit 2 prevents stopping and continues the conversation, and that `asyncRewake` wakes Claude on exit 2; it documents no sibling cancellation that would support the earlier short-circuit explanation.
The live check deliberately separated the competing session from the lock owner, which is the condition that falsified that earlier hook-order explanation: the blocked Stop produced an auto-arm entry trace naming `gate-live-session-owner`, while a lock-owning Stop delivered `asyncRewake` normally.
An absent entry trace on the blocked Stop would have falsified the identity-gate diagnosis; a claimed owner cycle without delivered `Stop hook feedback` would have supported the discarded-rewake candidate.

```sh
claude --version
FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh
```

Observed output:

```text
2.1.232 (Claude Code)
ok - Claude 2.1.232 (Claude Code) live E2E let the read-only competing session finish, then restored supervision from the lock-owning Stop hook without human intervention
```

The two-session regression was also required to fail against its immediate unfixed parent, `fe30ee2e2ccf678bba877659e47bae71318a5fab`, on 2026-08-14.
The portable control kept the current real-process regression and shared test helper while restoring the parent implementation.

```sh
test "$(git -C .review-unfixed-stop-guard rev-parse --show-toplevel)" = "$PWD/.review-unfixed-stop-guard" && rm -rf "$PWD/.review-unfixed-stop-guard"
git clone -q . .review-unfixed-stop-guard
git -C .review-unfixed-stop-guard checkout -q fe30ee2e2ccf678bba877659e47bae71318a5fab
cp tests/fm-turnend-guard.test.sh tests/fm-claude-stop-autoarm-live-e2e.test.sh tests/lib.sh .review-unfixed-stop-guard/tests/
(cd .review-unfixed-stop-guard && bash -o pipefail -c 'tests/fm-turnend-guard.test.sh 2>&1 | tail -8')
```

Observed output and exit status `1`:

```text
ok - tracked .claude/settings.json entries: 5 inert under grok, the documented subagent exception still armed, all live under Claude
ok - .codex/hooks.json: Stop hook uses hook process root when payload cwd is outside
ok - .codex/hooks.json: Stop hook ignores nested git root guard scripts
ok - .opencode primary plugin: guard path is anchored to worktree, not directory
ok - .pi primary extension: no-tool and multi-tool runs each inject exactly one guard follow-up
ok - .pi primary extension: delivery failure resets the logical-run latch
ok - fm-turnend-guard --claude: re-blocks a loop-guarded stop while unhealthy and unclaimed (incident regression)
not ok - a read-only session must not be trapped by a guard whose matching auto-arm cannot own recovery: expected exit 0, got 2
```

The real-Claude control used the same parent fixture and the current env-gated live guard.
The test-only gate bypass is confined to its disposable Claude processes so the live guard can execute from a no-mistakes validation worktree.

```sh
cp tests/fm-claude-stop-autoarm-live-e2e.test.sh .review-unfixed-stop-guard/tests/
(cd .review-unfixed-stop-guard && bash -o pipefail -c "FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh 2>&1 | grep '^not ok -'")
```

Observed output and exit status `1`:

```text
not ok - read-only Claude session was trapped by the blind-turn guard: session=fa5c402a-511c-4cf2-b323-a9a5da85b70c
```

The corresponding green live result is recorded immediately above, and the green portable suite result is recorded in the focused 2026-08-14 run below.

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

The foreign-session Stop-loop correction, bounded entry trace, and one-shot repeated-block escalation were verified on 2026-08-14 with ShellCheck 0.11.0.
The portable suite uses real operating-system processes without a vendor harness, while the credentialed live guard above supplies the separate Claude-dependent verdict.

```sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh tests/fm-claude-stop-autoarm.test.sh tests/fm-turnend-guard.test.sh tests/fm-supervision-instructions.test.sh | tail -8
```

Observed output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-doc-audience-check: ok surfaces=67 local_links=233
FM_TEST_END 2026-08-14T02:34:08Z tests/fm-supervision-instructions.test.sh exit=0 duration_ms=711 gate_skip=false
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0 duration_ms=141882
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=711 failed=0
FM_TEST_SUMMARY_FAMILY family=unclassified count=1 duration_ms=63319 failed=0
FM_TEST_SUMMARY_FAMILY family=watcher-wake-lock count=1 duration_ms=76892 failed=0
FM_TEST_SLOWEST rank=1 script=tests/fm-turnend-guard.test.sh duration_ms=76892
FM_TEST_SLOWEST rank=2 script=tests/fm-claude-stop-autoarm.test.sh duration_ms=63319
FM_TEST_SLOWEST rank=3 script=tests/fm-supervision-instructions.test.sh duration_ms=711
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

## Watcher continuity

The cross-harness evidence combines the 2026-07-17 live pass with Claude's replacement Stop-owned path revalidated on 2026-08-14, all against isolated project and home state.
No credential material was copied into a fixture.

```text
Claude Code 2.1.232
codex-cli 0.144.4
OpenCode 1.17.18
Pi 0.80.10
grok 0.2.103 (89c3d36fb6f1) [stable]
```

| Harness | Exact opt-in command | Observed guarantee |
| --- | --- | --- |
| Claude | `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | A read-only competing session defers without a guard loop, then the lock-owning session restores supervision and receives the actionable rewake. |
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
