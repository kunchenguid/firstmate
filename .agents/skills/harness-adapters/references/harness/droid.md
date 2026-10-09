# Droid

Verified for crewmate and scout work only.
Droid primary and secondmate supervision are unsupported; `../../../../../bin/fm-spawn.sh` and `../../../../../bin/fm-control-lib.sh` refuse secondmate launches and replacements.
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

## Settings and discovery

`../../../../../bin/fm-spawn.sh` owns settings construction, literal native-model selection, supported effort omission, atomic publication, rollback, and relaunch replacement.
The requested native catalog id or custom registry id is passed unchanged; no provider-facing alias is inferred from global settings.
`../../../../../bin/fm-teardown.sh` removes task settings and retires the trust receipt, including after a harness switch; the control plane retires process-local settings during a harness switch.
`../../../../../bin/fm-droid-trust.sh` owns serialized settings updates, acquired-entry rollback, and cleanup transfer when another recorded task uses the same pooled path.
Model availability depends on the installed CLI and account: inspect `droid --help`, the interactive `/model` catalog, and the user's `~/.factory/settings.json` custom-model registry without exposing credentials.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.
