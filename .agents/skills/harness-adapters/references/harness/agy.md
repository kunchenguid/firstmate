# Antigravity CLI

Antigravity CLI `agy` 1.2.0 was verified end to end on 2026-09-10 on Linux.
The adapter is verified for CREWMATE and SCOUT tasks only.
`bin/fm-spawn.sh` refuses `--secondmate` on `agy` because no primary supervision protocol is verified.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `agy` resolved from `PATH`, refused if absent. |
| Launch | `agy --dangerously-skip-permissions [--model <model>] [--effort <level>] --add-dir <absolute-firstmate-hook-root> --prompt-interactive <brief>`. |
| Brief submission | The `--prompt-interactive` brief submitted itself and required no separate Enter. |
| Autonomy | `--dangerously-skip-permissions` removed the real tool-permission gate in the authenticated 1.2.0 session. |
| Busy state | Firstmate-owned `PreInvocation` and `Stop` hooks write semantic `agy-hook` events. |
| Rendered busy tail | `esc to cancel` is a delivery-only signal and never replaces the hook-backed worker state. |
| Interrupt | One `Escape` cancels a tool call and leaves the TUI alive without repolluting the composer. |
| Exit | `/quit` followed by Enter exits the TUI. |
| Resume | `--conversation=<id>` restored the verified conversation, and `--continue` also restored the latest conversation after a real exit and relaunch. |
| Marker | Child and tool processes export `ANTIGRAVITY_AGENT=1`; the `agy` launcher process itself exports no `ANTIGRAVITY_*` identity marker. |
| Process name | The live launcher and TUI process report the exact command name `agy`. |
| Composer | The idle composer is a bare `>` row followed by `? for shortcuts` and the model footer. |
| Model | `agy models` lists available models, and `--model <model>` selects one. |
| Effort | `low`, `medium`, and `high` map directly to `--effort`; `xhigh` and `max` cap at `high`, while explicit `ultra` is refused by the shared native-effort gate. |

## Detection

`ANTIGRAVITY_AGENT=1` is checked before `CLAUDECODE` so an agy worker launched under Claude is not misread as Claude.
The marker was observed in the child environment while the launcher itself had no such marker.
The spawn clears inherited `ANTIGRAVITY_*` and foreign harness markers before starting a fresh agy worker.
The ancestry detector and tmux liveness classifier match the exact command name `agy` and reject names such as `agy-helper`.

## Busy state and firstmate-owned hooks

The canonical adapter creates `state/<id>.agy-hooks/.agents/hooks.json` and passes that absolute directory through `--add-dir`.
The task worktree's own `.agents/hooks.json` is never written or removed by the adapter.
The `PreInvocation` hook records `busy` with source `agy-hook` and the `Stop` hook records `idle` and touches `state/<id>.turn-ended`.
The live probe showed that Escape canceled a long-running tool call without emitting `Stop`, so `fm-control.sh` and the `fm-send.sh --key` path record `idle` with source `fm-interrupt` after delivering Escape.
Hook commands consume the JSON stdin contract and return `{}` on stdout so the worker's lifecycle is not broken by firstmate state handling.
Raw launch commands remain unwired and classify unknown, matching the other adapter escape hatches.

## Composer safety

The shared classifier accepts the agy prompt only when the same capture also contains the independent `? for shortcuts` footer below it.
An idle `>` plus that footer is `empty`, text after `>` plus that footer is `pending`, and a bare `>` without the footer is `unknown`.
The global shell-glyph rule remains intact, so a dead shell showing only `>` is never an injection target.

## Control and recovery

The verified interrupt sequence is one `Escape` with no composer-clear key and no rendered cancellation acknowledgement.
`/quit` is the verified exit command.
The deterministic Firstmate control verb remains `relaunch`, while `--conversation=<id>` is the preferred native identity resume and `--continue` is the verified latest-conversation fallback.

## Verification boundaries

`references/common/primary-hooks.md` is intentionally out of scope for this worker-only adapter.
The real-binary evidence came from `agy --help`, `agy models`, isolated tmux launches, child-environment capture, the documented hook contract, a real hook event probe, Escape interruption, and both native resume forms.
The portable regression is in `tests/fm-gemini-harness.test.sh`, `tests/fm-busy-adapter-wiring.test.sh`, `tests/fm-composer-lib.test.sh`, `tests/fm-control.test.sh`, and `tests/fm-tmux-agent-liveness.test.sh`.
