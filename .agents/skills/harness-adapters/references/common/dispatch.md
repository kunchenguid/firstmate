# Dispatch and start

Load this with the selected tool reference for dispatch, start, or adapter verification; add `references/common/model-and-effort.md` for either profile axis.

## Resolution

Use the router's detection and safety sections for static crew and secondmate harness resolution and all explicit overrides.
`config/crew-dispatch.json` can override that static default for one crewmate or scout with concrete harness, model, effort, and (for codex) Codex account home axes.
For a profile array, load `quota-array-dispatch` after establishing harness and provider facts here.

`../secondmate-provisioning/SKILL.md` owns inherited local material.
Its harness consequence is that a secondmate's workers receive literal `config/crew-harness` and `config/crew-dispatch.json`, while the primary-only `config/secondmate-harness` is never inherited because secondmates do not spawn secondmates.
A concrete crew value such as `codex` carries that runtime into the secondmate home.
Unset or `default` carries no concrete value, so its workers use that home's own or detected harness rather than the primary's effective crew harness.
The inherited dispatch file applies the same best-fit profiles there.

## Owners

`../../../bin/fm-spawn.sh` owns launch, autonomy, concrete flags, task-kind compatibility, and worker turn-end wiring.
Natural-language rules stay with firstmate, while scripts receive concrete axes.

`../../../bin/fm-busy-lib.sh` owns semantic busy trust.
Composer shapes, glyphs, placeholders, popups, rendered delivery signals, and the `empty` / `pending` / `pending-unproven` / `unknown` decision belong only to `../../../bin/fm-composer-lib.sh`.
Tool references record empirical knowledge for those executable owners.

## Adapter verification

For an approved new adapter check, use the spawn owner's raw-launch escape hatch only for a trivial supervised task.
Verify detection in `../../../bin/fm-harness.sh`, launch in `../../../bin/fm-spawn.sh`, busy state in `../../../bin/fm-busy-lib.sh`, shared composer behavior in `../../../bin/fm-composer-lib.sh`, lifecycle in `../../../bin/fm-control-lib.sh`, and tmux liveness in `../../../bin/backends/tmux.sh` when secondmate use is supported.
Also verify primary integration through `references/common/primary-hooks.md`, model discovery through `references/common/model-and-effort.md`, and one tool record.
A value remains unreachable until its executable owner, portable regression, applicable credentialed live guard, and verification record land together.
`../firstmate-coding-guidelines/SKILL.md` owns harness-dependent proof.
