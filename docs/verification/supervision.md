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

Current deterministic and live entry points:

```sh
tests/fm-sessionstart-nudge.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
FM_OPENCODE_LIVE_E2E=1 tests/fm-opencode-primary-live-e2e.test.sh
```

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
Firstmate-written project hooks under `<worktree>/.codex/hooks.json` fired for neither an interactive pane whose directory trust was granted nor `codex exec`, in both cases with `--dangerously-bypass-hook-trust`, while global `~/.codex/hooks.json` `SessionStart` hooks fired in the same runs.
Codex also exposes no `StopFailure` hook, so an API-error turn end would need separate coverage even after hook discovery works.
The app-server protocol schema does define the required lifecycle (`turn/started`, plus a `turn/completed` status of `completed`, `interrupted`, `failed`, or `inProgress`), so the gate is a reachability problem rather than a protocol gap.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Turn-end guard

The direct and passive mechanisms were validated across all five harnesses on 2026-07-08 through 2026-07-12, with Claude's replacement Stop-owned path revalidated on 2026-07-24.

| Harness | Version verified | Mechanism | Observed result |
| --- | --- | --- | --- |
| Claude | 2.1.219 | Cooperative blocking `Stop` guard plus `asyncRewake` auto-arm | A fresh unsupervised session ran session start first, reclaimed a stale dead-owner lock, completed two tokenless rewake cycles with no model arm command or guard continuation, and left a competing live owner unchanged. |
| Codex | 0.142.1 | Blocking `Stop` hook | Hook process root stayed anchored to the trusted checkout and one continuation ran. |
| OpenCode | 1.17.6 | Passive `session.idle` callback | Throwing could not block, while `promptAsync` scheduled one TUI follow-up; headless remained fail-open. |
| Pi | 0.80.5 | Passive `agent_settled` callback | Exactly one guard follow-up ran for an unhealthy cycle, with no recursion across tool turns. |
| Grok | 0.2.112 native and 0.2.73 pre-native | Running-payload adaptive `Stop` | Native false-to-true continuation stayed in one process with two model turns and zero resume launches; the field-absent pre-native process launched exactly one guarded resume. |

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

The secondmate-home scope and manual-repair wake path were measured with Claude Code 2.1.207 on 2026-07-12, when a native background completion re-invoked the idle model with no human input.
The current Stop-owned main/secondmate inclusion and child-worktree exclusion are covered deterministically by `tests/fm-claude-stop-autoarm.test.sh`.
Session-lock ownership in `bin/fm-session-lock-lib.sh` is decided against a session's whole contiguous harness ancestry rather than one chosen pid, so the Stop auto-arm reaches its lock owner wherever that owner sits: the outermost pid of Claude Code's multi-level `bg-spare` hook worker chain, or an inner pid when a harness-named daemon parents the session.
Harness identity is read from the executable path and `argv[0]` as well as the command basename, because Claude Code's native installer names the per-session executable by its version (`.../share/claude/versions/2.1.220`): `ps -o comm=` reports that path on macOS and the bare version string on Linux, and neither basename names a harness.
`tests/fm-session-lock-ancestry.test.sh` pins both platforms' reporting semantics behind a deterministic process table and runs the real Stop auto-arm in version-named, daemon-parented, and combined real process trees.
`tests/fm-watch-arm.test.sh` runs a real watcher and attached arm to verify that a delivered reason survives queue draining, while an unrelated queue append cannot make a watcher cycle that delivered nothing look successful.

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

Deterministic entry points:

```sh
tests/fm-pi-watch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-turnend-guard.test.sh
```

## Wedge-alarm channels

Unicode composer whitespace and the Linux on-host wedge path were verified on 2026-08-05 with Claude Code 2.1.222, tmux 3.4, and util-linux 2.39.3 on Linux.

The live idle Claude row and public classifier were read with:

```sh
claude --version
tmux -V
wall --version | head -1
cy=$(tmux display-message -p -t %0 '#{cursor_y}')
tmux capture-pane -p -t %0 -S "$cy" -E "$cy" | od -An -t u1
(. bin/fm-backend.sh; fm_backend_composer_state tmux %0)
```

Exact output:

```text
2.1.222 (Claude Code)
tmux 3.4
wall from util-linux 2.39.3
 226 157 175 194 160  10
empty
```

The bytes are U+276F followed by U+00A0 and a newline.
The shared classifier now normalizes every non-ASCII code point in Unicode's `White_Space` property before deciding emptiness.
Real text after Unicode whitespace remains `pending`, a bare shell prompt followed by Unicode whitespace remains `unknown`, and ghost-only text remains `empty`.
Before the fix, the exact U+276F plus U+00A0 empty-row regression returned `pending` instead of `empty`, and the NBSP bare-shell precision check returned `pending` instead of `unknown`.
The pre-fix real-text safety control already returned `pending`, and the pre-fix ghost safety control already returned `empty`; neither control failed before the fix.

Claude and Codex reach the shared classifier from their bare prompt rows on tmux and Herdr.
OpenCode and Kimi reach it from bordered `>` composers.
Pi and pi-signed share the Pi renderer and reach it from bordered tmux composers or Herdr's identity-corroborated separator structure.
Grok reaches it from its bordered prompt after dark truecolor placeholder removal.
All seven tmux harness names are exercised by `tests/fm-composer-ghost.test.sh`, and the Herdr public dispatch is exercised by `tests/fm-backend-herdr.test.sh` with the exact U+276F plus U+00A0 regression and both safety controls.

The focused suites ran with:

```sh
bin/fm-test-run.sh tests/fm-composer-ghost.test.sh tests/fm-backend-herdr.test.sh tests/fm-daemon.test.sh | grep -E '^FM_TEST_(END|SUMMARY)'
```

Exact summary:

```text
FM_TEST_END 2026-08-05T22:58:29Z tests/fm-composer-ghost.test.sh exit=0 duration_ms=4257 gate_skip=false
FM_TEST_END 2026-08-05T22:58:55Z tests/fm-backend-herdr.test.sh exit=0 duration_ms=25477 gate_skip=false
FM_TEST_END 2026-08-05T22:59:14Z tests/fm-daemon.test.sh exit=0 duration_ms=19668 gate_skip=false
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0 duration_ms=49557
FM_TEST_SUMMARY_FAMILY family=backend-dispatch count=1 duration_ms=25477 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=1 duration_ms=4257 failed=0
FM_TEST_SUMMARY_FAMILY family=watcher-wake-lock count=1 duration_ms=19668 failed=0
```

`wall` was tested and rejected as a Linux alarm channel because its message entered live agent panes.

```sh
probe='FIRSTMATE_HARMLESS_WALL_PROBE_20260805T2250Z'
printf '%s\n' "$probe" | wall
sleep 1
for pane in $(tmux list-panes -a -F '#{pane_id}'); do
  command_name=$(tmux display-message -p -t "$pane" '#{pane_current_command}')
  cursor_y=$(tmux display-message -p -t "$pane" '#{cursor_y}')
  hits=$(tmux capture-pane -p -J -t "$pane" -S -20 | grep -cF "$probe" || true)
  composer=$(. bin/fm-backend.sh; fm_backend_composer_state tmux "$pane")
  printf '%s\tcommand=%s\tcursor=%s\tprobe_hits=%s\tcomposer=%s\n' "$pane" "$command_name" "$cursor_y" "$hits" "$composer"
done
```

Exact relevant output:

```text
%58	command=claude	cursor=49	probe_hits=1	composer=empty
%0	command=claude	cursor=49	probe_hits=1	composer=empty
```

The same probe through a three-second tmux status overlay did not enter either pane and preserved both empty composers:

```sh
probe='FIRSTMATE_HARMLESS_TMUX_STATUS_PROBE_20260805T2251Z'
tmux display-message -d 3000 -t %0 "$probe"
sleep 1
for pane in %0 %58; do
  hits=$(tmux capture-pane -p -J -t "$pane" -S -20 | grep -cF "$probe" || true)
  composer=$(. bin/fm-backend.sh; fm_backend_composer_state tmux "$pane")
  printf '%s\tprobe_hits=%s\tcomposer=%s\n' "$pane" "$hits" "$composer"
done
```

Exact output:

```text
%0	probe_hits=0	composer=empty
%58	probe_hits=0	composer=empty
```

The production tmux overlay lasts through `FM_MAX_DEFER_SECS`, the following housekeeping interval, and one additional second of scheduling slack, then refreshes on the next alarm.
At defaults, a future unpredicted false `pending` therefore costs at most 315 seconds, or 5.25 minutes, before a persistent on-host warning appears.
This Linux host has no verified default off-host alert, so remote notification still requires an explicit `command:` channel.
Content stability does not authorize forced injection because a real half-typed line can remain byte-identical indefinitely.

A 2026-08-05 live incident left an away digest buffered for 1558 seconds while each daemon retry passed the rendered busy guard and then reported `composer=pending` despite the same daemon environment's `FM_COMPOSER_IDLE_RE` and a direct public classifier call both reporting `empty`.
Claude Code 2.1.221 also rendered `esc to interrupt` while idle, which is why Claude's delivery-only busy guard briefly relied on its elapsed spinner alone.
That single-signal guard was itself unsafe and has been replaced: Claude's rendered busy verdict now takes the elapsed spinner OR the escape affordance as a delimited footer field, because 2.1.223 renders the spinner row only intermittently while the affordance is present for a whole turn.
[`docs/verification/runtime-backends.md`](runtime-backends.md) owns the current per-harness busy-signature evidence and the command that refreshes it.
Each delivery defer now records its exact gate, backend, detected harness, native and rendered busy verdicts, composer verdict, idle-override presence, or post-submit acknowledgement without recording composer content.
Busy detection remains independent of `FM_COMPOSER_IDLE_RE`; the override applies only to the inject-time composer proof and the post-submit acknowledgement.

The real-tmux delivery path is exercised with:

```sh
bin/fm-test-run.sh tests/fm-daemon.test.sh | grep -F 'real tmux away delivery'
```

Exact output:

```text
ok - real tmux away delivery handles exact Claude bytes, safety guards, busy state, and idle overrides
```

The disposable pane renders the captured octal bytes `342 235 257 302 240`, followed by Claude's idle `esc to interrupt` footer, then reads the submitted operational digest.
The same public `escalate_add` and `escalate_flush` path proves the digest reaches the pane and clears the buffer, while a half-typed line and bare shell prompt remain byte-identical, an elapsed Claude spinner remains busy, and `FM_COMPOSER_IDLE_RE` governs both composer checks around submission.

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
