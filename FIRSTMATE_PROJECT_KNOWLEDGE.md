# Firstmate deferred instructions: project-knowledge

This agent-runtime bundle is the single conditional owner of the preserved instructions below.
Load it deterministically with `bin/fm-instructions.sh project-knowledge` before the matching action.
The preserved block is copied verbatim from `AGENTS.md` at baseline `a218ebc497af996e04f2aa8d4b8dbd569d4b882a`.
See [prompt-disclosure verification](docs/verification/prompt-disclosure.md) for provenance, measurements, and maintained checks.

<!-- Verbatim preserved baseline block starts on the next line. -->
Load `project-management` before adding, creating, removing, or initializing a project.
Cloning or registering a project is add intake and uses the same trigger.
That skill owns registry syntax, delivery-mode selection, outward-facing consent, clone and initialization procedure, safe rollback, and removal preflight.
Project creation never authorizes an unmentioned remote, and project removal never bypasses that preflight or unlanded-work checks; hard rule 1's concrete captain-approved project operation exception remains available when its exact conditions are met.

Load `secondmate-provisioning` before creating, seeding, validating, launching, handing backlog to, recovering, pushing inherited local material into, or retiring a secondmate home, and before editing `data/secondmates.md`.
Its scope field drives routing and its project list is non-exclusive provisioning data, not ownership.
Keep `local-only` work in the main home.

A secondmate is idle by default and acts only on work routed by the main firstmate.
It reconciles its own work under way after restart, then waits silently; an empty queue never authorizes a survey, audit, or self-directed improvement sweep.
Do not reconstruct or supervise a secondmate's child tree from the main home.

Route durable knowledge to its most specific owner:

- Home-domain captain preferences and working style belong in `data/captain.md` after inspect-then-update.
- Captain preferences shared across secondmate domains belong in the primary home's `data/captain-shared.md` under the `secondmate-provisioning` contract.
- Fleet-local operational facts belong in curated, home-local `data/learnings.md`.
- Task-scoped notes belong with the backlog item, and investigation findings belong in the scout report.
- Knowledge useful to almost every contributor to one project belongs in that project's committed `AGENTS.md`.
- Knowledge general to every firstmate user belongs in this repo's shared tracked surface.

Firstmate never writes a project's `AGENTS.md` directly.
A crewmate creates or updates it lazily through the project's selected delivery path, using `bin/fm-ensure-agents-md.sh` and preferring pointers to authoritative sources over copied detail.
Keep fleet delivery posture and captain-private strategy out of project memory.
When the captain invokes `/stow`, load the `stow` skill for its memory curation, knowledge routing, and persistence of the open work records this session is holding; it files and corrects only the open work that session is holding, and never reconciles the backlog against repository or PR reality.
