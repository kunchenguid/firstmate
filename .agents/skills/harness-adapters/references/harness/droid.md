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
| Trust | Droid 0.233.0 and 0.237.0 gate fresh folders; `../../../../../bin/fm-droid-trust.sh` registers only the exact isolated worktree in the persistent trust store before launch and removes those paths at teardown. |
| Model | `sessionDefaultSettings.model`; custom models use the user's registry id. |
| Effort | `sessionDefaultSettings.reasoningEffort`; `low`, `medium`, `high`, `xhigh`, `max`, and `dynamic` are retained. |

## Settings and discovery

`../../../../../bin/fm-spawn.sh` owns settings construction, custom-model reference resolution, supported effort omission, atomic publication, rollback, and relaunch replacement.
Only the model registry id is copied from global settings; credentials are never written to task settings.
`../../../../../bin/fm-teardown.sh` removes task settings and exact-worktree trust, including after a harness switch, and the control-plane wiring table retires them during a harness switch.
Model availability depends on the installed CLI and account: inspect `droid --help`, the interactive `/model` catalog, and the user's `~/.factory/settings.json` custom-model registry without exposing credentials.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.
