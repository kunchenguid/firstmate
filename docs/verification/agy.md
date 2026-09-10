# Verification: the agy (Antigravity CLI) crewmate adapter

This record owns the dated empirical evidence for the worker-only `agy` adapter.
The adapter reference at [`.agents/skills/harness-adapters/references/harness/agy.md`](../../.agents/skills/harness-adapters/references/harness/agy.md) owns the operating contract.

## Subject

| Field | Value |
|---|---|
| Version | `Antigravity CLI 1.2.0` from `~/.local/bin/agy`. |
| Verified | 2026-09-10 on Linux. |
| Scope | CREWMATE and SCOUT only. |
| Primary and secondmate | Out of scope, with `--secondmate` refused. |
| Provider | Authenticated real-model session on the local machine. |

## Launch and interactive submission

`agy --help` reported `--prompt-interactive`, `--dangerously-skip-permissions`, `--model`, `--effort low|medium|high`, `--continue`, `--conversation`, `--add-dir`, and text, JSON, and stream formats.
`agy models` listed `gemini-3.8-flash-high`, `gemini-3.8-flash-medium`, `gemini-3.8-flash-low`, `gemini-3.7`, `gemini-3.6`, `gemini-3.1-pro`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, and `gpt-oss-120b-medium` model entries.
The real interactive launch was `agy --dangerously-skip-permissions --effort low --prompt-interactive "Reply with AGY_PROBE_READY, then wait for more input."`.
The trust dialog was accepted with one Enter, the initial brief response began without another Enter, and the TUI remained at its live composer for steering.
The idle capture was a bare `>` composer row followed by `? for shortcuts` and `Gemini 3.8 Flash · low`.
The active-turn capture included `esc to cancel` and an animated `Working...` or `Generating...` row.

## Detection evidence

The live launcher process reported `ps comm=agy` and its tool child environment exported `ANTIGRAVITY_AGENT=1`.
The same child environment also contained `ANTIGRAVITY_AGENTAPI_EXE`, `ANTIGRAVITY_CONVERSATION_ID`, `ANTIGRAVITY_LS_ADDRESS`, `ANTIGRAVITY_LS_VERSION`, `ANTIGRAVITY_PROJECT_ID`, `ANTIGRAVITY_SOURCE_METADATA`, and `ANTIGRAVITY_TRAJECTORY_ID`.
The launcher itself did not export those `ANTIGRAVITY_*` identity values, so `ANTIGRAVITY_AGENT=1` is the verified child marker and exact `agy` ancestry is the launcher signal.
The portable tests exercise marker precedence with inherited `CLAUDECODE`, exact ancestry, `agy-helper` and `agylib` decoys, and exact tmux process-name liveness.

## Hook-backed busy state

The installed hook documentation at `~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md` specifies JSON stdin and JSON stdout with camelCase keys.
The live hook probe used an absolute `--add-dir` workspace containing `.agents/hooks.json` and observed `PreInvocation`, `PreToolUse`, `PostToolUse`, `PostInvocation`, and `Stop` events in the real process.
The adapter writes only `state/<id>.agy-hooks/.agents/hooks.json` and never writes the task worktree's `.agents/hooks.json`.
The portable wiring test drives the generated real hook commands and observes `busy agy-hook` after `PreInvocation` and `idle agy-hook` plus the turn-end marker after `Stop`.
The live Escape probe canceled a real `sleep 60` tool call, returned the TUI to the `>` composer, and produced no delayed `Stop` event for that canceled invocation.
The adapter therefore records `idle fm-interrupt` after its verified Escape delivery path instead of trusting a hook event that agy did not emit.

## Composer and control evidence

The shared classifier accepts `>` as empty only when the independent `? for shortcuts` footer is present below it.
The portable regression proves idle `>` plus footer is `empty`, `> draft` plus footer is `pending`, and bare `>` without the footer is `unknown` in both cursor and cursorless paths.
The real Escape key canceled the active tool call once, required no composer clear, and left the worker alive.
The real `/quit` command exited the TUI and printed the conversation id in its resume hint.
Relaunching with `--conversation=<id>` restored the full prior screen and history.
Relaunching with `--continue` also restored the latest conversation.

## Tests and refresh commands

The portable regressions are `bash tests/fm-gemini-harness.test.sh`, `bash tests/fm-busy-adapter-wiring.test.sh`, `bash tests/fm-composer-lib.test.sh`, `bash tests/fm-control.test.sh`, and `bash tests/fm-tmux-agent-liveness.test.sh`.
The live liveness guard is `FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh`.
The live composer guard is `FM_COMPOSER_MATRIX_LIVE=1 bin/fm-test-run.sh tests/fm-composer-matrix-live-e2e.test.sh`.
The live steering guard was run as `FM_SEND_INBOX_LIVE_E2E=1 FM_SEND_INBOX_LIVE_HARNESSES=agy FM_SEND_INBOX_LIVE_TIMEOUT=120 bash tests/fm-send-inbox-doorbell-live-e2e.test.sh` and the real worker acted on and acknowledged the inbox message.
Both live guards use `fm_live_gate` from `tests/lib.sh` and fail loudly when an installed agy surface cannot be classified.
