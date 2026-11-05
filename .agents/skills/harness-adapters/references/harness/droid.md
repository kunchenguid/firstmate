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
| Trust | Exact-worktree registration, receipt-only retirement, and pooled-path cleanup transfer are owned by [`fm-droid-trust.sh`](../../../../../bin/fm-droid-trust.sh). |
| Model | `sessionDefaultSettings.model`; custom models use the user's registry id. |
| Effort | `sessionDefaultSettings.reasoningEffort`; `low`, `medium`, `high`, `xhigh`, `max`, and `dynamic` are retained. |
| Background execution | Native tracked Execute jobs (`fireAndForget: true`) notify the primary on completion. |



## Settings and discovery
`../../../../../bin/fm-harness.sh` accepts only an exact `droid` ancestor.
Control uses Escape for interrupt and `/quit` for exit.
`../../../../../bin/fm-session-lock-lib.sh` and `../../../../../bin/fm-agent-process-lib.sh` recognize the same exact process identity.

## Launch settings

`../../../../../bin/fm-spawn.sh` writes `state/<id>.droid-settings.json` before endpoint allocation and launches Droid with that file through `--settings`.
The settings file carries accounting hooks, the crewmate turn-end hook, and optional model and reasoning-effort pins.
It is task-local runtime state and `../../../../../bin/fm-teardown.sh` removes it.
[Task model selection and accounting](../../../../../docs/configuration.md) defines the separate requested and effective fields, catalog resolution, runtime reconciliation, and their consumers.
`../../../../../bin/fm-spawn.sh` owns the folder-trust gate, its bounded wait, and the refusal on backends without verified viewport capture.
Factory's [settings reference](https://docs.factory.com/droid-cli/settings) documents no settings-based folder-trust bypass, so spawn uses the verified control-plane answer instead of writing an undocumented trust store.

## Working style

Droid works programmatically and may use scripts for implementation, analysis, and other task work.
Steering responses and validation-gate decisions remain agent actions on the doorbell plane: read the delivered instruction, reason about it, and respond through the required interface.
Never move those lifecycle decisions into scripts that read an inbox or answer gates autonomously.


`../../../../../bin/fm-spawn.sh` owns settings construction, literal native-model selection, supported effort omission, atomic publication, rollback, and relaunch replacement.
An explicit native catalog id or custom registry id is passed unchanged; an omitted model or `default` leaves the CLI's model default intact, and no provider-facing alias is inferred from global settings.
`../../../../../bin/fm-teardown.sh` removes task settings and retires the trust receipt, including after a harness switch; the control plane retires process-local settings during a harness switch.
`../../../../../bin/fm-droid-trust.sh` owns serialized settings updates, acquired-entry rollback, and cleanup transfer when another recorded task uses the same pooled path.
Model availability depends on the installed CLI and account: inspect `droid --help`, the interactive `/model` catalog, and the user's `~/.factory/settings.json` custom-model registry without exposing credentials.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.
## Primary integration

Tracked `.factory/settings.json` registers SessionStart, Execute PreToolUse, AskUser PreToolUse, and Stop hooks.
SessionStart runs `../../../../../bin/fm-session-start.sh`.
Execute uses the shared primary seatbelt, AskUser defers captain-bound approval questions during away mode, and Stop invokes the Droid turn-end guard.
The `/afk` skill owns the required question binding, and `../../../../../bin/fm-captain-hold.sh` preserves and projects the exact question through its existing owner.
`../../../../../docs/supervision-protocols/droid.md` owns the primary tracked background-cycle procedure and foreground checkpoint fallback.
