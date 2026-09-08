---
name: crewmate-briefing
description: Load before creating or materially changing an ordinary ship, scout, or secondmate charter brief.
user-invocable: false
metadata:
  internal: true
---

# Crewmate briefing

`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
For an ordinary ship or scout brief, use its scaffold as the contract, then replace exactly the two standalone `{TASK}` lines under `# Task` and `# Load-bearing contract` with a clear task description, acceptance criteria, constraints, and necessary context.
Do not replace inline prose tokens.
The optional `--evidence-archive` scout variant adds its Reach contract after the evidence-archive section.
A secondmate charter is not an ordinary brief: it uses `# Charter` and `# Routing scope`, carries no load-bearing bookend, and its authoring stays with `secondmate-provisioning`.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.

Every ship brief retains the worktree-isolation assertion and stops if launched in the primary checkout.
If a ship task touches firstmate's shared tracked material, require `firstmate-coding-guidelines` before editing.
If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
The generated Herdr contract uses a named non-`default` isolated lab and its guarded helper for every lifecycle action.

Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.
The scaffold is a safety contract, not a suggestion.
If a performance or scaling oracle is named, point the spec at the selected resource: Read `/Users/pedromuller/dev/firstmate/data/ecc-curated/5064474d4d762dc9640234a41617cccb79185cec/skills/benchmark-optimization-loop/SKILL.md`.
If freshness, streaming, or liveness is named, point the spec at the selected resource: Read `/Users/pedromuller/dev/firstmate/data/ecc-curated/5064474d4d762dc9640234a41617cccb79185cec/skills/latency-critical-systems/SKILL.md`.
If panel or viewer design is named, point the spec at the selected resource: Read `/Users/pedromuller/dev/firstmate/data/ecc-curated/5064474d4d762dc9640234a41617cccb79185cec/skills/dashboard-builder/SKILL.md`.
If two independently named producer and consumer both change, point the spec at the selected resource: Read `/Users/pedromuller/dev/firstmate/data/ecc-curated/5064474d4d762dc9640234a41617cccb79185cec/skills/contract-first/SKILL.md`.
If an independent review intent is named, point the spec at the selected resource: Read `/Users/pedromuller/dev/firstmate/data/ecc-curated/5064474d4d762dc9640234a41617cccb79185cec/lenses/review-evidence.md`.
If a review names a projection, readback, error, or liveness question, point the spec at the selected resource: Read `/Users/pedromuller/dev/firstmate/data/ecc-curated/5064474d4d762dc9640234a41617cccb79185cec/lenses/silent-failure.md`.
If a change touches shell plus request or user input, point the spec at the selected resource: Read `/Users/pedromuller/dev/firstmate/data/ecc-curated/5064474d4d762dc9640234a41617cccb79185cec/lenses/security-boundary.md`.
If the brief is scaffolded with `--visual`, point the spec at the selected resource: Read `/Users/pedromuller/dev/firstmate/data/ecc-curated/5064474d4d762dc9640234a41617cccb79185cec/lenses/a11y-readback.md`.
