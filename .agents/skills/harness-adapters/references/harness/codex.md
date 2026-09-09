# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'`, verified on codex-cli 0.142.1 whose installed schema contains `model_reasoning_effort`, active config uses it, and bundled catalog advertises only these four values while omitting `max`. |
| Model discovery | Open the current interactive session's `/model` picker. |

A directory trust dialog appears on the first run for a repository root: "Do you trust the contents of this directory?"
Accept it with Enter and verify the instructions begin processing.
The decision persists for the repository, so later worktrees of the same project skip it.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

[`docs/turnend-guard.md`](../../../../../docs/turnend-guard.md#harness-integrations) owns the current Codex Stop-hook boundary, and [`docs/sessionstart-nudge.md`](../../../../../docs/sessionstart-nudge.md#harness-transports) owns the matching SessionStart boundary.
[`docs/verification/supervision.md`](../../../../../docs/verification/supervision.md) records their version-scoped evidence.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
