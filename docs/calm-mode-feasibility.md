# Calm-mode harness feasibility

This maintainer-verification record owns the version-scoped Pi renderer taxonomy, mechanism boundaries, and current empirical evidence for Firstmate Calm mode.
[`calm.md`](calm.md) owns current operator-facing behavior and usage.

## Required presentation boundary

A qualifying Calm implementation must auto-load from the trusted project and read the effective Firstmate home's persisted choice on every Pi session start.
While active, it must leave only genuine captain prompts, normal assistant replies, interactive dialogs, and explicit errors that need a response in the visible conversation area.
It must remove thinking, complete tool rows and shells, tool images, Pi working activity, and canonically classified Firstmate operational inputs without changing their delivery or model context.
It must redraw loaded transcript rows, preserve tool expansion state, add no replacement status UI, restore stock rendering when disabled, and leave exports and shares complete.
Presentation must remain inactive in RPC, JSON, print, and untrusted contexts.

## Implementation ownership

`.pi/extensions/fm-calm.ts` is the single extension owner for Calm lifecycle, persistence integration, stock-export rendering, and `/calm`.
`.pi/extensions/lib/fm-calm-visibility.ts` owns the allowlist-style transcript policy.
Only `genuine-user-prompt` and `genuine-agent-response` are policy-visible while Calm is active.
`.pi/extensions/lib/fm-calm-assistant-layout.ts` removes thinking blocks from the shallow presentation copy before Pi calculates assistant layout.
`.pi/extensions/lib/fm-calm-tool-layout.ts` returns zero rows from Pi's exported `ToolExecutionComponent` while Calm is active, which removes calls, results, framing, and image children together, and keeps only the width-clamped error text of a row whose result is an error.
`.pi/extensions/lib/fm-calm-operational-user-layout.ts` renders canonically classified text-only Firstmate operational user rows at zero height.
`bin/fm-operational-input.sh` remains the single owner of operational-input construction and parsing.
The seven built-in definitions and `fm_watch_arm_pi` retain per-renderer zero-height behavior as an independent fallback if the complete tool-row adapter is unavailable.

All three class adapters are idempotent and probe their exact Pi export and prototype method before patching.
A missing seam produces one adapter-specific diagnostic and leaves the remaining Calm behavior and unrelated Pi extensions operational.
The adapters consult presentation state at render time, so the patches are inert outside a trusted interactive TUI and while Calm is off.
No input event is intercepted, no message role is rewritten, and no provider context is filtered.

## Current transcript taxonomy

| Policy class | Pi transcript path | Calm result verified through Pi 0.82.1 |
| --- | --- | --- |
| `genuine-user-prompt` | `UserMessageComponent` | Visible, including operational-marker near misses. |
| `genuine-agent-response` | Assistant text in `AssistantMessageComponent` | Visible. |
| `assistant-thinking` | Thinking content in `AssistantMessageComponent` | Zero height whether Pi's thinking display is collapsed or expanded. |
| `assistant-tool-call`, `tool-result`, `tool-image` | `ToolExecutionComponent` | Complete row is zero height for built-in and custom tools while the result is routine. An errored result keeps only its plain error text, capped at six lines with an explicit hidden-line count. |
| `working-status` | Pi working status indicator | Hidden through `ExtensionUIContext.setWorkingVisible(false)`. |
| `synthetic-user` | Firstmate session-start, watcher, turn-end, away-supervisor, from-firstmate, and launch-brief input | Exact user-role content and ordering are retained, while the TUI row is zero height. |
| Legacy Calm operational entries | Registered custom-entry renderer | Retained in session data and rendered at zero height. |
| Interactive dialogs | Extension and built-in focused UI | Visible. |
| Explicit errors and warnings | Pi status, assistant error rendering, and errored tool rows | Visible. Pi routes abort, provider-failure, and tool-failure text through the tool row whenever the turn has a tool call, so Calm surfaces that text as plain lines instead of hiding it. |
| User bash, skill invocation, compaction and branch summaries, command notices, and unrelated custom entries | Their stock Pi components | Unchanged because they are neither internal model work nor Firstmate operational follow-up rows. |

Stock HTML export and share rendering are enabled only around the matching terminal submit action and then presentation is redrawn immediately.
Serialized session entries are never modified by a presentation toggle.

## Compatibility review

Pi 0.81.1 introduced the evidence baseline, Pi 0.82.0 preserved the original assistant and operational-user seams, and Pi 0.82.1 preserves those seams plus the exported `ToolExecutionComponent.render` and `ToolExecutionComponent.updateResult` seams used for complete tool-row suppression and its actionable-error surface, and pi-tui's `visibleWidth`, `truncateToWidth`, and `wrapTextWithAnsi` column helpers used to keep every emitted error line inside the terminal width Pi enforces.
Version strings are evidence rather than compatibility gates.
A future version with a missing method degrades only that adapter.

The other supported primary harnesses do not load `.pi/extensions/`, so this change is not applicable to their transcript rendering.
The tmux, Herdr, Zellij, Orca, and cmux runtime transports continue to deliver the same operational input because Calm changes only Pi component rendering.
Watcher, turn-end, session-start, away-supervisor, and from-firstmate producers remain unchanged.

## Regression coverage

`tests/fm-calm-pi-extension.test.sh` covers the centralized visibility policy, all seven built-ins, custom tool rows, image output, thinking in both Pi display states, working suppression, operational provenance, near misses, persistence, reload and restart redraws, trusted-interactive scoping, Calm-off restoration, exports, shares, and exact captain and assistant conversation preservation.
`tests/fm-pi-primary-types.test.sh` performs strict no-emit checking against the installed Pi declarations when TypeScript is available.
`tests/fm-pi-primary-live-e2e.test.sh` keeps the credentialed provider and watcher integration path opt-in.

## 2026-07-29 Pi 0.82.1 verification

The deterministic suite exercises the real Pi TUI without provider credentials.
The credentialed live suite remains opt-in and was not required for this presentation-only change.

```text
$ pi --version
0.82.1

$ tests/fm-calm-pi-extension.test.sh
ok - Pi calm extension is presentation-only with one persisted visibility choice, no Calm status row, hidden working activity, supported redraw controls, and complete tool-row presentation
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm compatibility evidence never rejects a Pi version for being newer than 0.82.0, and still fails closed on a missing or malformed version
ok - a missing collapsed-thinking presentation API degrades only that Calm adapter with a clear skip reason, while the rest of Calm still registers
ok - missing Pi presentation class exports and error-surface seams reach the independent adapter degradation path
ok - Pi calm centralizes transcript visibility, preserves execution/export data, hides working activity, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:ahoy geometry keeps every thinking and tool block at zero height while preserving history, restart, and Calm-off rendering
ok - Pi calm native E2E hides working activity, keeps captain turns visible, hides exact operational user rows without changing persistence, restores them Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ npm exec --yes --package=typescript -- bash -c 'tests/fm-pi-primary-types.test.sh'
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.82.1

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=56 local_links=153

$ bin/fm-test-run.sh --changed --base origin/main
FM_TEST_SUMMARY total=48 failed=0 skipped_gate=8 duration_ms=417838
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=193 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=31 duration_ms=154446 failed=0
FM_TEST_SUMMARY_FAMILY family=watcher-wake-lock count=10 duration_ms=261558 failed=0
```
