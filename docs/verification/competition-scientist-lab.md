# Competition-scientist lab verification

This record verifies the deterministic zero-token smoke for the inert synthetic competition-scientist pilot.
It does not report a model-backed A/B and does not support a competition-performance claim.
The maintained behavior owner is the [example guide](../examples/competition-scientist/README.md), while the command's header and help own exact mechanics.

## Environment

- Date: 2026-09-22.
- Platform: macOS arm64.
- Python: 3.14.7.
- Shell entry point SHA-256: `90c154a18aa7ceeebb11dd2bc60e9d1919b3b86db6ab7d40a739af848d11a3ff`.
- Python engine SHA-256: `e82cad9d64b58892b88c2867d0b9299421226454f43662bdca8a589efdde1fd2`.
- Baseline candidate SHA-256: `8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06`.

## Command

```sh
VERIFY_ROOT=/tmp/fm-competition-scientist-verification-20260922
bin/fm-competition-scientist-lab.sh smoke --output "$VERIFY_ROOT"
```

## Exact output

```text
initialized: /private/tmp/fm-competition-scientist-verification-20260922/grouped-classification-linear
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.100000
attempt: seq=1 verdict=REVERT class=none primary=0.075000
attempt: seq=2 verdict=REVERT class=none primary=0.075000
attempt: seq=3 verdict=REVERT class=none primary=0.075000
attempt: seq=4 verdict=REVERT class=none primary=0.850000
attempt: seq=5 verdict=KEEP class=none primary=0.325000
final: task=grouped-classification controller=linear attempts=6 selected=0c04092840a1 sealed_worst_group=0.300000
replay: PASS task=grouped-classification controller=linear candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260922/grouped-classification-proposed
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.100000
attempt: seq=1 verdict=REVERT class=none primary=0.075000
attempt: seq=2 verdict=REVERT class=none primary=0.075000
attempt: seq=3 verdict=REVERT class=none primary=0.075000
attempt: seq=4 verdict=REVERT class=none primary=0.850000
attempt: seq=5 verdict=KEEP class=none primary=0.325000
final: task=grouped-classification controller=proposed attempts=6 selected=0c04092840a1 sealed_worst_group=0.300000
replay: PASS task=grouped-classification controller=proposed candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260922/nonlinear-regression-linear
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.642310
attempt: seq=1 verdict=REVERT class=none primary=0.553087
attempt: seq=2 verdict=REVERT class=none primary=0.610023
attempt: seq=3 verdict=REVERT class=none primary=0.494248
attempt: seq=4 verdict=KEEP class=none primary=0.906746
attempt: seq=5 verdict=REVERT class=none primary=0.607289
final: task=nonlinear-regression controller=linear attempts=6 selected=3811e5f5288c sealed_worst_group=0.904616
replay: PASS task=nonlinear-regression controller=linear candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260922/nonlinear-regression-proposed
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.642310
attempt: seq=1 verdict=REVERT class=none primary=0.553087
attempt: seq=2 verdict=REVERT class=none primary=0.610023
attempt: seq=3 verdict=REVERT class=none primary=0.494248
attempt: seq=4 verdict=KEEP class=none primary=0.906746
attempt: seq=5 verdict=REVERT class=none primary=0.607289
final: task=nonlinear-regression controller=proposed attempts=6 selected=3811e5f5288c sealed_worst_group=0.904616
replay: PASS task=nonlinear-regression controller=proposed candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260922/noisy-classification-linear
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.650000
attempt: seq=1 verdict=REVERT class=none primary=0.650000
attempt: seq=2 verdict=REVERT class=none primary=0.650000
attempt: seq=3 verdict=REVERT class=none primary=0.650000
attempt: seq=4 verdict=REVERT class=none primary=0.650000
attempt: seq=5 verdict=REVERT class=none primary=0.650000
final: task=noisy-classification controller=linear attempts=6 selected=8fd5cd7ca977 sealed_worst_group=0.700000
replay: PASS task=noisy-classification controller=linear candidates=6 sealed_calls=1
initialized: /private/tmp/fm-competition-scientist-verification-20260922/noisy-classification-proposed
baseline: 8fd5cd7ca977c030d96aa617a43d3fc647d9aefb9b5fb6849b874ec8608b8f06 primary=0.650000
attempt: seq=1 verdict=REVERT class=none primary=0.650000
attempt: seq=2 verdict=REVERT class=none primary=0.650000
attempt: seq=3 verdict=REVERT class=none primary=0.650000
attempt: seq=4 verdict=REVERT class=none primary=0.650000
attempt: seq=5 verdict=REVERT class=none primary=0.650000
final: task=noisy-classification controller=proposed attempts=6 selected=8fd5cd7ca977 sealed_worst_group=0.700000
replay: PASS task=noisy-classification controller=proposed candidates=6 sealed_calls=1
smoke-summary:[{"attempts":6,"controller":"linear","sealed_worst_group":0.3,"selected":"0c04092840a1","task":"grouped-classification"},{"attempts":6,"controller":"proposed","sealed_worst_group":0.3,"selected":"0c04092840a1","task":"grouped-classification"},{"attempts":6,"controller":"linear","sealed_worst_group":0.904616,"selected":"3811e5f5288c","task":"nonlinear-regression"},{"attempts":6,"controller":"proposed","sealed_worst_group":0.904616,"selected":"3811e5f5288c","task":"nonlinear-regression"},{"attempts":6,"controller":"linear","sealed_worst_group":0.7,"selected":"8fd5cd7ca977","task":"noisy-classification"},{"attempts":6,"controller":"proposed","sealed_worst_group":0.7,"selected":"8fd5cd7ca977","task":"noisy-classification"}]
```

The smoke spent zero model tokens because it used the built-in fixture proposal mode.
The run exercised six measured attempts per task/controller search, one post-search sealed call, one proposed-mode falsification call, and visible-candidate replay.
The fixture includes deliberate losing candidates, so a larger printed primary can still revert when it violates the frozen protected-group tolerance.
