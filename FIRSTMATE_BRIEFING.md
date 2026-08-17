# Firstmate deferred instructions: briefing

This agent-runtime bundle is the single conditional owner of the preserved instructions below.
Load it deterministically with `bin/fm-instructions.sh briefing` before the matching action.
The preserved block is copied verbatim from `AGENTS.md` at baseline `a218ebc497af996e04f2aa8d4b8dbd569d4b882a`.
See [prompt-disclosure verification](docs/verification/prompt-disclosure.md) for provenance, measurements, and maintained checks.

<!-- Verbatim preserved baseline block starts on the next line. -->
`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then replace every `{TASK}` placeholder with a clear task description, acceptance criteria, constraints, and necessary context before dispatch or seeding.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.

Every ship brief must retain the worktree-isolation assertion and stop if launched in the primary checkout.
If a ship task touches firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
The generated Herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle action.

Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.
The scaffold is a safety contract, not a suggestion.
