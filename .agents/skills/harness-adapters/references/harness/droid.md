# Droid

Verified for primary, secondmate, crewmate, and scout work.
Current empirical evidence lives in [`docs/verification/runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#droid).

## Operating facts

| Fact | Value |
|---|---|
| Binary and identity | `droid`, matched by exact process ancestry; no verified environment identity marker. |
| Launch | Positional instructions with `--settings state/<id>.droid-settings.json --auto high`. |
| Autonomy | `--auto high` allows commands; a raw launch retains its caller's autonomy choice. |
| Busy state | Adapter-scoped working spinner row or `Press ESC to stop`; no semantic busy writer is armed. |
| Turn end | A process-local `Stop` command hook touches the task's turn-ended file; interrupt does not promise a Stop hook. |
| Interrupt and exit | One Escape and `/quit`, delivered through `../../../../../bin/fm-control.sh`. |
| Recovery | Deterministic relaunch through the control plane; native resume is not part of this adapter's recovery contract. |
| Skills | `/<skill>`. |
| Trust | Exact worktree or safely seeded secondmate-home registration, receipt retirement, and cleanup transfer are owned by [`fm-droid-trust.sh`](../../../../../bin/fm-droid-trust.sh). |
| Model | `sessionDefaultSettings.model`; custom models use the user's registry id. |
| Effort | `sessionDefaultSettings.reasoningEffort`; `low`, `medium`, `high`, `xhigh`, `max`, and `dynamic` are retained. |
| Background execution | Native tracked Execute jobs (`fireAndForget: true`) notify the primary on completion. |

## Identity

[`fm-harness.sh`](../../../../../bin/fm-harness.sh), [`fm-session-lock-lib.sh`](../../../../../bin/fm-session-lock-lib.sh), and [`fm-agent-process-lib.sh`](../../../../../bin/fm-agent-process-lib.sh) share the exact process identity above.

## Launch settings

`../../../../../bin/fm-spawn.sh` writes `state/<id>.droid-settings.json` before endpoint allocation and launches Droid with that file through `--settings`.
The settings file carries accounting hooks, the crewmate turn-end hook, and optional model and reasoning-effort pins.
It is task-local runtime state and `../../../../../bin/fm-teardown.sh` removes it.
[Task model selection and accounting](../../../../../docs/configuration.md) defines the separate requested and effective fields, catalog resolution, runtime reconciliation, and their consumers.
`../../../../../bin/fm-spawn.sh` owns the folder-trust gate, generation-bound relaunch confirmation, its bounded wait, and the refusal on backends without verified viewport capture.
Exact-path pre-registration remains the normal trust path; the bounded viewport gate handles a remaining interactive trust prompt and verifies that launch has continued.

## Working style

Droid works programmatically and may use scripts for implementation, analysis, and other task work.
Steering responses and validation-gate decisions remain agent actions on the doorbell plane: read the delivered instruction, reason about it, and respond through the required interface.
Never move those lifecycle decisions into scripts that read an inbox or answer gates autonomously.
Model availability depends on the installed CLI and account: inspect `droid --help`, the interactive `/model` catalog, and the user's `~/.factory/settings.json` custom-model registry without exposing credentials.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Primary integration

Tracked `.factory/settings.json` registers SessionStart, Execute PreToolUse, AskUser PreToolUse, and Stop hooks.
SessionStart runs `../../../../../bin/fm-session-start.sh`.
Execute uses the shared primary seatbelt, and Stop invokes the Droid turn-end guard.
While away, the AskUser guard denies the call, directs the agent not to retry or ask in plain text, and directs decision recording through a captain hold; after return it is inert.
The `/afk` skill owns the away-mode decision procedure.
`../../../../../docs/supervision-protocols/droid.md` owns the primary tracked background-cycle procedure and foreground checkpoint fallback.
