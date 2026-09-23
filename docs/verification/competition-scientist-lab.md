# Competition-scientist lab verification

This record verifies the deterministic zero-token smoke for the inert synthetic competition-scientist pilot.
It does not report a model-backed A/B and does not support a competition-performance claim.
The maintained behavior owner is the [example guide](../examples/competition-scientist/README.md), while the command's header and help own exact mechanics.

## Environment

- Date: 2026-09-23.
- Platform: macOS arm64.
- Python: 3.14.7.
- Shell entry point SHA-256: `adbf438cc45b1e1d019e3544b712059738a5881602b2becaebf090e6668502ca`.
- Python engine SHA-256: `bb50e375b68f3ee1bc8c3088b04f9d308c72e5dd41e19c19dbff2f0bfda91b19`.
- Baseline candidate SHA-256: `8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06`.

## Command

```sh
VERIFY_ROOT=/tmp/fm-competition-scientist-verification-20260923
bin/fm-competition-scientist-lab.sh smoke --output "$VERIFY_ROOT"
```

## Exact output

```text
initialized: /private/tmp/fm-competition-scientist-verification-20260923/grouped-classification-linear
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.100000
attempt: seq=1 verdict=REVERT class=none primary=0.075000
attempt: seq=2 verdict=REVERT class=none primary=0.075000
attempt: seq=3 verdict=REVERT class=none primary=0.075000
attempt: seq=4 verdict=KEEP class=none primary=0.850000
attempt: seq=5 verdict=KEEP class=none primary=0.850000
final: task=grouped-classification controller=linear attempts=6 selected=6c74127e5424 sealed_worst_group=0.875000
replay: PASS task=grouped-classification controller=linear candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260923/grouped-classification-proposed
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.100000
attempt: seq=1 verdict=REVERT class=none primary=0.075000
attempt: seq=2 verdict=REVERT class=none primary=0.075000
attempt: seq=3 verdict=REVERT class=none primary=0.075000
attempt: seq=4 verdict=KEEP class=none primary=0.850000
attempt: seq=5 verdict=KEEP class=none primary=0.850000
final: task=grouped-classification controller=proposed attempts=6 selected=6c74127e5424 sealed_worst_group=0.875000
replay: PASS task=grouped-classification controller=proposed candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260923/nonlinear-regression-linear
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.642310
attempt: seq=1 verdict=REVERT class=none primary=0.553087
attempt: seq=2 verdict=REVERT class=none primary=0.610023
attempt: seq=3 verdict=REVERT class=none primary=0.494248
attempt: seq=4 verdict=KEEP class=none primary=0.906746
attempt: seq=5 verdict=REVERT class=none primary=0.607289
final: task=nonlinear-regression controller=linear attempts=6 selected=3811e5f5288c sealed_worst_group=0.904616
replay: PASS task=nonlinear-regression controller=linear candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260923/nonlinear-regression-proposed
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.642310
attempt: seq=1 verdict=REVERT class=none primary=0.553087
attempt: seq=2 verdict=REVERT class=none primary=0.610023
attempt: seq=3 verdict=REVERT class=none primary=0.494248
attempt: seq=4 verdict=KEEP class=none primary=0.906746
attempt: seq=5 verdict=REVERT class=none primary=0.607289
final: task=nonlinear-regression controller=proposed attempts=6 selected=3811e5f5288c sealed_worst_group=0.904616
replay: PASS task=nonlinear-regression controller=proposed candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260923/noisy-classification-linear
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.650000
attempt: seq=1 verdict=REVERT class=none primary=0.650000
attempt: seq=2 verdict=REVERT class=none primary=0.650000
attempt: seq=3 verdict=REVERT class=none primary=0.650000
attempt: seq=4 verdict=REVERT class=none primary=0.650000
attempt: seq=5 verdict=REVERT class=none primary=0.650000
final: task=noisy-classification controller=linear attempts=6 selected=8fd5cd7ca977 sealed_worst_group=0.700000
replay: PASS task=noisy-classification controller=linear candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260923/noisy-classification-proposed
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.650000
attempt: seq=1 verdict=REVERT class=none primary=0.650000
attempt: seq=2 verdict=REVERT class=none primary=0.650000
attempt: seq=3 verdict=REVERT class=none primary=0.650000
attempt: seq=4 verdict=REVERT class=none primary=0.650000
attempt: seq=5 verdict=REVERT class=none primary=0.650000
final: task=noisy-classification controller=proposed attempts=6 selected=8fd5cd7ca977 sealed_worst_group=0.700000
replay: PASS task=noisy-classification controller=proposed candidates=6 sealed_calls=1
smoke-summary:[{"attempts":6,"controller":"linear","sealed_worst_group":0.875,"selected":"6c74127e5424","task":"grouped-classification"},{"attempts":6,"controller":"proposed","sealed_worst_group":0.875,"selected":"6c74127e5424","task":"grouped-classification"},{"attempts":6,"controller":"linear","sealed_worst_group":0.904616,"selected":"3811e5f5288c","task":"nonlinear-regression"},{"attempts":6,"controller":"proposed","sealed_worst_group":0.904616,"selected":"3811e5f5288c","task":"nonlinear-regression"},{"attempts":6,"controller":"linear","sealed_worst_group":0.7,"selected":"8fd5cd7ca977","task":"noisy-classification"},{"attempts":6,"controller":"proposed","sealed_worst_group":0.7,"selected":"8fd5cd7ca977","task":"noisy-classification"}]
```

The smoke spent zero model tokens because it used the built-in fixture proposal mode.
The run exercised six measured attempts per task/controller search, one post-search sealed call, one proposed-mode falsification call, and visible-candidate replay.
The fixture includes deliberate losing candidates, so a candidate can still revert when it sinks a group below the incumbent worst-group floor by more than the frozen protected-group tolerance.
On grouped-classification the search keeps the candidate that removes the feature whose relationship flips in the stress groups, which is the robustness trade the worst-group objective exists to reward.
