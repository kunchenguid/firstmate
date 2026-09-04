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

Codex 0.153.2 can also show a hooks trust dialog: "Hooks need review" with options to review hooks, trust all and continue, or continue without trusting.
Every interactive Codex launch Firstmate composes includes `--dangerously-bypass-hook-trust`, including crewmate, scout, secondmate, and raw Codex launches.
This keeps effective hooks enabled and accepts their sources for the invocation without persisting a trust decision.
Crewmate and scout turn-end detection retains the independent launch `notify=` signal, while a secondmate uses the tracked project hooks that provide primary SessionStart initialization, pre-tool protection, and Stop-based turn-end supervision.
If an already-parked worker shows this dialog, choose "Continue without trusting" by running these commands in order, then verify that the brief starts processing.
Replace `TASK_ID` with the recorded task ID.

```sh
../../../bin/fm-send.sh TASK_ID --key Down
../../../bin/fm-send.sh TASK_ID --key Down
../../../bin/fm-send.sh TASK_ID --key Enter
```

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
