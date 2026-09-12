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
The remaining sub-second race between that final preflight and literal typing is shared with every typed harness path; any race text is left unsubmitted and the durable inbox record is the recovery copy.
Raw commands whose basename is `agy` are recorded as `raw-agy`, so they remain unwired and do not receive the verified AGY control, composer, or inbox behavior.

## Current measurement: Antigravity CLI 1.2.2

The current live measurements were taken on 2026-09-12 UTC on Linux with Antigravity CLI 1.2.2 from `~/.local/bin/agy`.
The binary had auto-updated from 1.2.0 to 1.2.2 during the marker verification, so the 1.2.0 measurements below remain historical evidence.

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

Command:

```text
~/.local/bin/agy --version
```

Output:

```text
1.2.0
```

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
bash tests/fm-composer-lib.test.sh | tail -1
```

Output:

```text
ok - fm_composer_queued_enter_verdict: only proven pending is converted
```

Command:

```text
bash tests/fm-busy-adapter-wiring.test.sh | tail -1
```

Output:

```text
all fm-busy-adapter-wiring tests passed
```

Command:

```text
bash tests/fm-control.test.sh | tail -1
```

Output:

```text
ok - fm-control's arrival leaves fm-send's from-firstmate marking untouched
```

Command:

```text
bash tests/fm-send-settle.test.sh | tail -1
```

Output:

```text
ok - fm-send: an agy Escape with no acknowledgement records unknown, not idle
```

Command:

```text
bash tests/fm-control-relaunch.test.sh | tail -1
```

Output:

```text
ok - relaunch heals an item that drifted out of In flight while the task stayed live
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
FM_TEST_END 2026-09-12T09:25:13Z tests/fm-harness-liveness-drift-live-e2e.test.sh exit=0 duration_ms=21117 gate_skip=false
```

Composer-matrix command:

```text
env -u ANTIGRAVITY_AGENT FM_COMPOSER_MATRIX_LIVE=1 bin/fm-test-run.sh tests/fm-composer-matrix-live-e2e.test.sh
```

Output:

```text
ok - agy (1.2.2): real idle > composer plus shortcuts footer classifies empty
ok - agy (1.2.2): real unsent draft stays pending with styled and cursorless signals
ok - strict posture live: a blank shell row classifies unknown and injection defers
not ok - claude (2.1.269 (Claude Code)): idle composer never classified empty (last verdict: pending)
not ok - codex (codex-cli 0.153.4): idle composer never classified empty (last verdict: unknown)
not ok - live composer-matrix guard observed failures above
FM_TEST_END 2026-09-12T09:27:03Z tests/fm-composer-matrix-live-e2e.test.sh exit=1 duration_ms=106186 gate_skip=false
```

Inbox doorbell command, restricted to the AGY worker:

```text
env -u ANTIGRAVITY_AGENT FM_SEND_INBOX_LIVE_E2E=1 FM_SEND_INBOX_LIVE_HARNESSES=agy bin/fm-test-run.sh tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

Output:

```text
not ok - agy (1.2.2): doorbell not honored within 240s (acted=no acked=no)
FM_TEST_END 2026-09-12T08:56:05Z tests/fm-send-inbox-doorbell-live-e2e.test.sh exit=1 duration_ms=262154 gate_skip=false
```

Canonical lifecycle command:

```text
env -u ANTIGRAVITY_AGENT FM_AGY_LIFECYCLE_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

Output:

```text
not ok - agy (1.2.2): exit command failed
FM_TEST_END 2026-09-12T09:24:46Z tests/fm-send-inbox-doorbell-live-e2e.test.sh exit=1 duration_ms=218247 gate_skip=false
```

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
