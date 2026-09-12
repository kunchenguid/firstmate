# Verification: the agy worker adapter

This record owns dated empirical evidence for the worker-only Antigravity CLI adapter.
The adapter reference at [`.agents/skills/harness-adapters/references/harness/agy.md`](../../.agents/skills/harness-adapters/references/harness/agy.md) owns the operating contract.

## Historical measurement: Antigravity CLI 1.2.0

The historical measurement was taken on 2026-09-11 UTC on Linux with Antigravity CLI 1.2.0 from `~/.local/bin/agy`.
The verified scope is CREWMATE and SCOUT only.

The active status row captured during the tool-running probe was:

```text
esc to cancel                                                Gemini 3.8 Flash · medium
```

The delivery fallback matches this anchored cancel-plus-effort row, not the bare words in draft text.

The measured composer boundary is a 72-character row of U+2500 BOX DRAWINGS LIGHT HORIZONTAL.
The adapter accepts only that byte-exact glyph after trimming, with a minimum width of 16 characters.
Other box-drawing glyphs, ASCII rule characters, and shorter rows fail closed to `unknown`; a future AGY boundary change is caught by the composer-matrix live guard.
A capture with three or more measured boundary rows is ambiguous by design and defers steering without selecting or extracting any AGY draft content.
Non-tmux AGY composer reads use a bounded 200-row tail while other harnesses retain the 20-row default, so long drafts preserve both measured boundaries.
The AGY inbox doorbell defers both `pending` and `unknown` composer verdicts and rings only after a proven `empty`; the watcher records the deferral and retries.
Typed AGY steering performs a final composer comparison after literal typing and before Enter; a mismatch withholds Enter, records the steer in the inbox, and reports that stray text may remain unsent in the pane.
The remaining sub-second race between that final preflight and literal typing is shared with every typed harness path; no exclusive input reservation is provided, a human typing in this window can leave firstmate's text unsent alongside their draft, Enter is never pressed on a mismatch, and the durable inbox record is the recovery copy.
Raw commands whose basename is `agy` are recorded as `raw-agy`, so they remain unwired and do not receive the verified AGY control, composer, or inbox behavior.

## Current measurement: Antigravity CLI 1.2.2

The current live measurements were taken on 2026-09-12 UTC on Linux with Antigravity CLI 1.2.2 from `~/.local/bin/agy`.
The binary had auto-updated from 1.2.0 to 1.2.2 during the marker verification, and the 1.2.0 measurements are kept in the historical section above.
The no-mistakes pipeline sandbox cannot execute the credentialed live guards because it has no worktree pool or signed-in sessions.
The passing 1.2.2 live-guard lines below are from firstmate's own 2026-09-12 runs; the lifecycle guard's newly folded doorbell assertions remain in the executable guard for a credentialed rerun.
The direct AGY composer-clear measurement is reproduced here against the real binary.

Command:

```text
~/.local/bin/agy --version
```

Output:

```text
1.2.2
```

The AGY portion of the current composer-matrix guard passed for both a real idle composer and a real unsent draft.
The measured boundary on 1.2.2 remained a 72-character U+2500 BOX DRAWINGS LIGHT HORIZONTAL row, with exactly two boundary rows per composer.
The aggregate composer-matrix guard also exercises installed non-AGY harnesses and failed on their unrelated trust screens; that exact failure is retained below rather than being masked.

## CLI surface

Command:

```text
~/.local/bin/agy --help 2>&1 | grep -E -- '--prompt-interactive|--dangerously-skip-permissions|--model|--effort|--continue|--conversation|--add-dir|--print-timeout|--output-format|--format'
```

Output:

```text
  --add-dir                       Add a directory to the workspace (repeatable) (default [])
  -c                              Short alias for --continue
  --continue                      Continue the most recent conversation
  --conversation                  Resume a previous conversation by ID
  --dangerously-skip-permissions  Auto-approve all tool permission requests without prompting
  --effort                        Reasoning effort for the current CLI session (low|medium|high)
  -i                              Short alias for --prompt-interactive
  --input-format                  Input format for print mode (text, stream-json). stream-json reads one NDJSON message per line from stdin and runs a turn for each; it requires --output-format stream-json (default text)
  --model                         Model for the current CLI session
  --output-format                 Output format for print mode (text, json, stream-json) (default text)
  --print-timeout                 Timeout for print mode wait (default 5m0s)
  --prompt-interactive            Run an initial prompt interactively and continue the session
```

Command:

```text
~/.local/bin/agy models
```

Output:

```text
Fetching available models...
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
gemini-3.7-flash-high	Gemini 3.7 Flash (High)
gemini-3.7-flash-medium	Gemini 3.7 Flash (Medium)
gemini-3.7-flash-low	Gemini 3.7 Flash (Low)
gemini-3.6-flash-high	Gemini 3.6 Flash (High)
gemini-3.6-flash-medium	Gemini 3.6 Flash (Medium)
gemini-3.6-flash-low	Gemini 3.6 Flash (Low)
gemini-3.1-pro-high	Gemini 3.1 Pro (High)
gemini-3.1-pro-low	Gemini 3.1 Pro (Low)
claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)
```

## Portable regressions

Command:

```text
bash tests/fm-composer-lib.test.sh >/dev/null && printf 'exit=0\n'
```

Output:

```text
exit=0
```

Command:

```text
bash tests/fm-busy-adapter-wiring.test.sh >/dev/null && printf 'exit=0\n'
```

Output:

```text
exit=0
```

Command:

```text
bash tests/fm-control.test.sh >/dev/null && printf 'exit=0\n'
```

Output:

```text
exit=0
```

Command:

```text
bash tests/fm-send-settle.test.sh >/dev/null && printf 'exit=0\n'
```

Output:

```text
exit=0
```

Command:

```text
bash tests/fm-control-relaunch.test.sh >/dev/null && printf 'exit=0\n'
```

Output:

```text
exit=0
```

These suites cover the shared classifier, generated hook lifecycle, stale-generation wake rejection, teardown retirement, non-agy cleanup refusal, control interruption, and data-plane interruption.

## Live guards

The 1.2.0 live-guard outputs below are historical evidence from 2026-09-11.

Command:

```text
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh | grep -E 'agy 1\.2\.0|harness liveness: agy|checked 3|FM_TEST_END'
```

Output:

```text
# agy 1.2.0: title='agy' foreground=[agy ]
ok - harness liveness: agy 1.2.0 classifies alive
# checked 3 installed harness(es)
FM_TEST_END 2026-09-11T03:08:58Z tests/fm-harness-liveness-drift-live-e2e.test.sh exit=0 duration_ms=1084 gate_skip=false
```

Marker-proof command, recorded 2026-09-12:

Command:

```text
env -u ANTIGRAVITY_AGENT FM_HARNESS_LIVENESS_DRIFT=1 FM_HARNESS_LIVENESS_DRIFT_AGY_MARKER=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh | grep -E 'harness marker: agy'
```

The binary auto-updated from 1.2.0 to 1.2.2 during verification.
The marker probe uses AGY print mode with `gemini-3.8-flash-low`, from a temporary workspace, so it does not depend on the interactive pane responding to a tool prompt.

Output:

```text
ok - harness marker: agy 1.2.2 exports ANTIGRAVITY_AGENT=1 and detects as agy from a tool process
```

Command:

```text
FM_COMPOSER_MATRIX_LIVE=1 bin/fm-test-run.sh tests/fm-composer-matrix-live-e2e.test.sh | grep -E 'ok - agy|ok - strict posture|ok - live composer-matrix'
```

Output:

```text
ok - agy (1.2.0): real idle > composer plus shortcuts footer classifies empty
ok - agy (1.2.0): real unsent draft stays pending with styled and cursorless signals
ok - strict posture live: a blank shell row classifies unknown and injection defers
ok - live composer-matrix guard verified 4 live surface(s)
```

Command:

```text
FM_AGY_LIFECYCLE_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-send-inbox-doorbell-live-e2e.test.sh | grep -E 'ok - agy|FM_TEST_END'
```

Output:

```text
ok - agy (1.2.0): canonical spawn, hooks, control/data interrupts, Stop, exit, and teardown passed
FM_TEST_END 2026-09-11T03:12:12Z tests/fm-send-inbox-doorbell-live-e2e.test.sh exit=0 duration_ms=73455 gate_skip=false
```

The lifecycle guard proves canonical `fm-spawn` hook generation and brief submission, a real running tool, control-plane and data-plane Escape delivery, unconfirmed state handling, natural Stop idle and turn-end publication, exit, and teardown.

### Current live-guard measurements: Antigravity CLI 1.2.2

Marker and liveness command, run with the inherited marker removed:

```text
env -u ANTIGRAVITY_AGENT FM_HARNESS_LIVENESS_DRIFT=1 FM_HARNESS_LIVENESS_DRIFT_AGY_MARKER=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

Output:

```text
ok - harness liveness: agy 1.2.2 classifies alive
ok - harness marker: agy 1.2.2 exports ANTIGRAVITY_AGENT=1 and detects as agy from a tool process
# checked 3 installed harness(es)
FM_TEST_END 2026-09-12T10:44:46Z tests/fm-harness-liveness-drift-live-e2e.test.sh exit=0 duration_ms=23421 gate_skip=false
```

The liveness and marker guard passed against AGY 1.2.2 on 2026-09-12.

Composer-matrix command:

```text
env -u ANTIGRAVITY_AGENT FM_COMPOSER_MATRIX_LIVE=1 bin/fm-test-run.sh tests/fm-composer-matrix-live-e2e.test.sh
```

Output:

```text
ok - claude (2.1.269 (Claude Code)): real idle composer classifies empty
ok - codex (codex-cli 0.153.4): real idle composer classifies empty
ok - agy (1.2.2): real idle > composer plus shortcuts footer classifies empty
ok - agy (1.2.2): real unsent draft stays pending with styled and cursorless signals
ok - strict posture live: a blank shell row classifies unknown and injection defers
```

Firstmate's 2026-09-12 run supplied all five passing lines above.

The standalone inbox-doorbell guard was not rerun separately after the fixture correction.
The canonical lifecycle guard below contains the AGY doorbell acted-and-acked assertion.

```text
env -u ANTIGRAVITY_AGENT FM_SEND_INBOX_LIVE_E2E=1 FM_SEND_INBOX_LIVE_HARNESSES=agy bin/fm-test-run.sh tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

Canonical lifecycle command:

```text
env -u ANTIGRAVITY_AGENT FM_AGY_LIFECYCLE_LIVE_E2E=1 FM_AGY_LIFECYCLE_TMUX_WIDTH=220 bin/fm-test-run.sh tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

Narrow-pane lifecycle command:

```text
env -u ANTIGRAVITY_AGENT FM_AGY_LIFECYCLE_LIVE_E2E=1 FM_AGY_LIFECYCLE_TMUX_WIDTH=80 bin/fm-test-run.sh tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

Width-120 lifecycle command:

```text
env -u ANTIGRAVITY_AGENT FM_AGY_LIFECYCLE_LIVE_E2E=1 FM_AGY_LIFECYCLE_TMUX_WIDTH=120 bin/fm-test-run.sh tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

The no-mistakes pipeline sandbox cannot execute these credentialed post-fix lifecycle runs because it has no worktree pool or signed-in AGY session.
The following is the firstmate run, 2026-09-12, real environment, gate tip 30f3d426, Antigravity CLI 1.2.2.
The expected-guided submit comparison matches each extracted row in order, permits zero or more ASCII spaces only between rows, and preserves interior row spaces exactly.

Lifecycle guard (`tests/fm-send-inbox-doorbell-live-e2e.test.sh` with `FM_AGY_LIFECYCLE_LIVE_E2E=1`):

```text
ok - agy (1.2.2): canonical spawn, hooks, doorbell, control/data interrupts, Stop, exit, and teardown passed
FM_TEST_END 2026-09-12T17:05:52Z exit=0 duration_ms=90716
ok - agy (1.2.2): canonical spawn, hooks, doorbell, control/data interrupts, Stop, exit, and teardown passed
FM_TEST_END 2026-09-12T17:07:40Z exit=0 duration_ms=108511
ok - agy (1.2.2): canonical spawn, hooks, doorbell, control/data interrupts, Stop, exit, and teardown passed
FM_TEST_END 2026-09-12T17:11:09Z exit=0 duration_ms=208349
```

Composer-matrix guard (`FM_COMPOSER_MATRIX_LIVE=1`):

```text
ok - claude (2.1.269 (Claude Code)): real idle composer classifies empty
ok - codex (codex-cli 0.153.4): real idle composer classifies empty
ok - agy (1.2.2): real idle > composer plus shortcuts footer classifies empty
ok - agy (1.2.2): real unsent draft stays pending with styled and cursorless signals
ok - strict posture live: a blank shell row classifies unknown and injection defers
ok - live composer-matrix guard verified 4 live surface(s)
```

Liveness/marker guard (`FM_HARNESS_LIVENESS_DRIFT=1`):

```text
ok - harness liveness: agy 1.2.2 classifies alive
```

Portable suites passed: `fm-composer-lib`, `fm-busy-adapter-wiring`, `fm-control`, `fm-gemini-harness`, and `fm-tmux-agent-liveness`.

Real-binary composer-clear measurement, run on 2026-09-12 against AGY 1.2.2.
The trust dialog was accepted before the composer probes.

```text
env -u ANTIGRAVITY_AGENT bash -c '
set -eu
lab=$(mktemp -d)
export TMUX_TMPDIR="$lab"
trap '\''tmux kill-server >/dev/null 2>&1 || true; rm -rf "$lab"'\'' EXIT
. bin/fm-tmux-lib.sh
version=$(agy --version 2>/dev/null | head -1)
tmux new-session -d -s agyclear -x 220 -y 50 -c "$PWD" -- agy --dangerously-skip-permissions --effort low
for _ in $(seq 1 60); do
  screen=$(tmux capture-pane -p -t agyclear:0 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -qi '\''Do you trust'\''; then
    tmux send-keys -t agyclear:0 Enter
  fi
  state=$(fm_tmux_composer_state agyclear:0 agy || true)
  [ "$state" = empty ] && break
  sleep 1
done
[ "$state" = empty ]
draft=$(printf '\''AGY_CTRL_U_MEASURED_DRAFT_%.0s'\'' $(seq 1 20))
tmux send-keys -t agyclear:0 -l "$draft"
for _ in $(seq 1 20); do
  screen=$(fm_tmux_composer_capture agyclear:0)
  printf '%s\n' "$screen" | grep -Fq AGY_CTRL_U_MEASURED_DRAFT && break
  sleep 1
done
printf '\''version=%s\n'\'' "$version"
printf '\''before_clear=%s\n'\'' "$(fm_tmux_composer_state agyclear:0 agy)"
tmux send-keys -t agyclear:0 C-u
after=unknown
for _ in $(seq 1 20); do
  after=$(fm_tmux_composer_state agyclear:0 agy || true)
  [ "$after" = empty ] && break
  sleep 0.25
done
printf '\''clear_key=C-u\n'\''
printf '\''after_clear=%s\n'\'' "$after"
[ "$after" = empty ]
'
```

Output:

```text
version=1.2.2
before_clear=pending
clear_key=C-u
after_clear=empty
```

C-u is the measured AGY composer-clear key and the pending-to-empty transition passed in the isolated tmux lab.
The measured draft was one long line that wrapped across the composer, rather than a literal newline between input lines.
Escape does not clear the composer, and C-c does not clear it and arms AGY's double-press exit warning.

### Coverage of later commits

The recorded live evidence above was run against gate tip `30f3d426`, so it remains evidence for the shared tmux lifecycle path rather than a fresh proof of the final tip.
Commit `7e10435` touched `bin/fm-backend.sh`, `bin/fm-composer-lib.sh`, `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, `docs/verification/agy.md`, `docs/verification/runtime-backends.md`, and `tests/fm-send-inbox-doorbell-live-e2e.test.sh`; the cleanup-helper consolidation is covered by the `fm-busy-adapter-wiring`, `fm-control`, and `fm-teardown` portable regressions.
Commit `26ab875` touched `.agents/skills/harness-adapters/references/harness/agy.md`, `bin/fm-backend.sh`, `bin/fm-tmux-lib.sh`, and `docs/verification/agy.md`; its unused-helper removal leaves the composer and control paths covered by `fm-composer-lib` and `fm-control`, while its code-site race text is documentation-only.
Commit `d4f081c` touched `bin/backends/zellij.sh` and `tests/fm-backend-zellij.test.sh`; the plain-capture fallback is covered by the `fm-backend-zellij` regression.
The multiline status-note serialization in this round is covered by the multiline AGY exit case in `tests/fm-control.test.sh`.
Final-tip live evidence is from firstmate's real-environment run on 2026-09-12 against gate tip `451cce13`, Antigravity CLI 1.2.2.
Lifecycle guard (`FM_AGY_LIFECYCLE_LIVE_E2E=1`): width 80 -> `ok - agy (1.2.2): canonical spawn, hooks, doorbell, control/data interrupts, Stop, exit, and teardown passed` (`FM_TEST_END 2026-09-12T18:39:52Z exit=0 duration_ms=55394`).
Lifecycle guard (`FM_AGY_LIFECYCLE_LIVE_E2E=1`): width 120 -> `ok - agy (1.2.2): canonical spawn, hooks, doorbell, control/data interrupts, Stop, exit, and teardown passed` (exit=0, run at 18:42Z).
Lifecycle guard (`FM_AGY_LIFECYCLE_LIVE_E2E=1`): width 220 -> `ok - agy (1.2.2): canonical spawn, hooks, doorbell, control/data interrupts, Stop, exit, and teardown passed` (`FM_TEST_END 2026-09-12T18:45:00Z exit=0 duration_ms=53097`).
Composer-matrix guard exited 0 with all six ok lines:

```text
ok - claude (2.1.269 (Claude Code)): real idle composer classifies empty
ok - codex (codex-cli 0.153.4): real idle composer classifies empty
ok - agy (1.2.2): real idle > composer plus shortcuts footer classifies empty
ok - agy (1.2.2): real unsent draft stays pending with styled and cursorless signals
ok - strict posture live: a blank shell row classifies unknown and injection defers
ok - live composer-matrix guard verified 4 live surface(s)
```

Liveness/marker guard: `ok - harness liveness: agy 1.2.2 classifies alive`.
Two initial attempts at 120 and 220 failed `doorbell instruction was not acted on` while the pane showed the doorbell delivered and the worker mid-way through acting on it; agy 1.2.2 keeps the brief's `sleep 60` running as a background task and the low-effort model needs three tool calls to act, which occasionally exceeds the test's 120-second wait; identical re-runs passed.
The lifecycle guard now waits for the initial `1 task(s)` status to clear before sending the doorbell and allows 240 seconds for the acted-and-acknowledged result.

## Repository gates

Command:

```text
bin/fm-doc-audience-check.sh
```

Output:

```text
fm-doc-audience-check: ok surfaces=99 local_links=379
```

Command:

```text
bin/fm-lint.sh
```

Output:

```text
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: local changed-file mode; ShellCheck source following disabled
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
```

The repository lint and every touched suite are rerun before delivery, and this record is the single owner for current agy measurements.
