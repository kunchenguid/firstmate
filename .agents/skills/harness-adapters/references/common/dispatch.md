# Dispatch and start

Load this with the selected tool reference for dispatch, start, or adapter verification; add `references/common/model-and-effort.md` for either profile axis.

## Resolution

Use the router's detection and safety sections for static crew harness resolution and all explicit overrides.
`config/crew-dispatch.json` can override that static default for one crewmate or scout with concrete harness, model, and effort axes.
For a profile array, load `profile-array-dispatch` for task-fit filtering and configured-order choice after establishing harness and provider facts here.

## Owners

`../../../bin/fm-spawn.sh` owns launch, autonomy, concrete flags, task-kind compatibility, and worker turn-end wiring.
Natural-language rules stay with firstmate, while scripts receive concrete axes.

`../../../bin/fm-busy-lib.sh` owns semantic busy trust.
Composer shapes, glyphs, placeholders, popups, rendered input-state signals, and the `empty` / `pending` / `pending-unproven` / `unknown` decision belong only to `../../../bin/fm-composer-lib.sh`.
Tool references record empirical knowledge for those executable owners.

## Adapter verification

For an approved new adapter check, use the spawn owner's raw-launch escape hatch only for a trivial supervised task.
Verify detection in `../../../bin/fm-harness.sh`, launch in `../../../bin/fm-spawn.sh`, busy state in `../../../bin/fm-busy-lib.sh`, shared composer behavior in `../../../bin/fm-composer-lib.sh`, lifecycle in `../../../bin/fm-control-lib.sh`, and Herdr liveness in `../../../bin/backends/herdr.sh`.
Also verify primary integration through `references/common/primary-hooks.md`, model discovery through `references/common/model-and-effort.md`, and one tool record.
A value remains unreachable until its executable owner, portable regression, applicable credentialed live guard, and verification record land together.
`../firstmate-coding-guidelines/SKILL.md` owns harness-dependent proof.
