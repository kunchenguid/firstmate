---
name: project-management
description: >-
  Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project.
  Cloning or registering a project is add intake and uses the same trigger.
  Owns project add, create, clone, remove, initialization, registry, delivery-mode, autonomy, and outward-consent decisions.
user-invocable: false
metadata:
  internal: true
---

# project-management

Use this procedure before adding, creating, removing, or initializing a project.
Cloning or registering a project is add intake and uses the same trigger.
This skill is the single owner of Firstmate's project-management procedure.
It does not replace `secondmate-provisioning`, which owns project clones inside persistent secondmate homes.

## Preconditions and registry

Projects live flat under `projects/`, and `data/projects.md` is the private fleet registry.
Use the registry format and parser contract owned by the header of `bin/fm-project-mode.sh`.
Keep each registry description useful for identifying the project, but keep delivery posture, captain-private state, and detailed project knowledge in their existing designated homes.
Do not turn the registry into project documentation.

Before adding, cloning, creating, or registering any project in the main home, inspect the authoritative `data/secondmates.md` routing table and judge every existing natural-language `scope:` against the proposed project or domain.
Apply `AGENTS.md` section 7's authoritative secondmate routing rules; if an existing scope owns that domain, route the new-project operation or work there instead of creating or registering a duplicate main-home clone.
Absence from the main `data/projects.md` registry is never evidence that no second mate owns the domain.
If the owning second mate cannot accept the route, report that concrete blocker or obtain an explicit captain redirection rather than silently duplicating the project in the main home.

Resolve the project name, destination, delivery posture, and autonomy posture before changing local or remote state.
Keep a newly added clone and its registry entry consistent, and roll back only artifacts created by the incomplete operation when a later initialization step fails and that rollback is safe.
Do not overwrite or repurpose an existing path.

## Delivery posture

The registry records the project's standing posture, which is the captain's default for the work rather than any task's answer; `AGENTS.md` section 7 owns how each task's concrete mode and yolo are resolved at intake and passed explicitly to the brief, the spawn, and any promotion.
Choose that posture when adding or creating the project:

- `no-mistakes` runs the full validation pipeline before a PR.
- `direct-PR` pushes and opens a PR without the no-mistakes pipeline.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.
- `no-mistakes-prod-only` is a conditional policy rather than one flat mode: genuinely internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`.

`no-mistakes-prod-only` is the default for a newly added or created remote-backed project when the captain specifies nothing, and a project with no remote defaults to `local-only`.
State that resolved default while confirming the source, local name, and posture instead of asking the captain to choose from scratch, and record a flat mode instead whenever they ask for one.
Existing registry entries keep the meaning they already have and are never migrated or reinterpreted, so a legacy entry with no bracket stays `no-mistakes`.
Registering a conditional policy is a one-time choice and never requires classifying any change; the per-task surface classification happens at each task's intake, and internal-only is never inferred from file location or project name.

The optional `+yolo` posture changes merge authority only and does not change the delivery mode.
Default it off for every project and every posture, and enable it only on the captain's explicit instruction.
`AGENTS.md` section 7 owns the merge-authority contract.

## Add or clone an existing project

Confirm the source URL, local project name, delivery posture, and autonomy posture, stating the resolved default for each rather than asking the captain to invent one.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
A `no-mistakes` or `no-mistakes-prod-only` project must have an `origin` remote and must complete the initialization procedure below, because a conditional policy's product-facing work runs the pipeline while its internal-only work still takes the direct PR.
A `direct-PR` project needs an `origin` remote but skips no-mistakes initialization.
A `local-only` project may have no remote and skips no-mistakes initialization.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery posture, defaulting visibility to private and the posture to `no-mistakes-prod-only`, then obtain the captain's explicit consent for those exact values; a stated default never replaces that consent.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally, add the registry entry, and initialize it according to its delivery posture.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

## Initialize

Run no-mistakes initialization only for `no-mistakes` and `no-mistakes-prod-only` projects:

```sh
cd projects/<name> && no-mistakes init && no-mistakes doctor
```

Initialization configures the local gate and does not vendor a no-mistakes skill into the project.
Do not create a commit merely because initialization ran.
If doctor reports an environment, authentication, or daemon problem, resolve that blocker before dispatching work and never restart the shared daemon from a project operation.

## Fused Onboarding & Architecture Protocol

Apply this ordered protocol to all future project creation, add, clone, registration, and initialization intake, and verify its completion before dispatching any implementation crewmate for a new project.
Do not retroactively onboard established projects merely because they receive another task.
A clone, registry entry, or successful no-mistakes initialization is not completion of this protocol.
Resume incomplete onboarding from its recorded artifacts and decisions rather than repeating settled interviews.
Tell the captain plainly that alignment takes a real session with them before implementation code is written; do not present this sequence as free setup or invent answers while they are unavailable.
Keep unresolved choices on the configured backlog under the existing captain-hold contract and do not dispatch implementation while they remain open.

Firstmate conducts the captain dialogue and delegates project investigation, design, and artifact writes under `AGENTS.md`'s existing role and project-write boundaries.
Preparation workers may work in isolated copies on the documents and scaffolding below, but must not implement product behavior before this protocol is complete.
For projects entering this protocol, select `no-mistakes` for PR delivery instead of the conditional or direct-PR defaults above; keep purely local projects `local-only` without inventing a remote or PR.
Resolve any conflicting explicit delivery instruction with the captain rather than silently skipping the required review.

### 1. Product Intent (PRD.md)

Read available project documentation before asking questions and distinguish documented facts from choices requiring the captain's answer.
Use `grilling` to interview the captain on product goals, target audience, core user journeys, and functional requirements until shared understanding is confirmed.
Use `to-spec` to synthesize those interview answers into the requirements specification, not to conduct the interview: that skill explicitly performs synthesis without an interview.
Keep its output in root `PRD.md` for this protocol rather than publishing to an unconfigured issue tracker, and commit it through the project's authorized preparation path.
Do not claim a separate docs-grounded grilling variant exists; grounding comes from the preceding document read.

### 2. Domain Dictionary (CONTEXT.md)

Extract domain-specific terminology, acronyms, and jargon during the interview into root `CONTEXT.md`.
Define each term concisely and explicitly, settle ambiguous meanings with the captain, and use the dictionary consistently in all subsequent artifacts and worker instructions.

### 3. Refusal Criteria & Non-Goals (VISION.md)

Mine available repository history and task briefs for prior boundaries, rejected directions, and non-goals; identify absent history rather than inventing it for a new repository.
Stress-test non-goals with hard hypotheticals and obtain explicit answers about what the product strictly refuses to do.
Commit root `VISION.md` as the binding vision boundary, distinguishing refusals from work merely deferred.
Perform this procedure directly through the preparation work rather than invoking a nonexistent vision skill.

### 4. Technical Architecture & Fast Context

Create root `architecture.md` with the full technical design, tech stack, component boundaries, and database schemas.
Create root `architecture-essentials.md` containing only critical architectural decisions and schema outlines for lightweight worker reference, pointing to the full design for detail.
Keep both consistent with `PRD.md`, `CONTEXT.md`, and `VISION.md`; explicitly record when a database or another layer does not apply rather than adding one to satisfy a template.

### 5. Hard-Questions Stress Test

Use `grilling` for one bounded stress-test pass over the proposed requirements and architecture: what will break, what edge cases are missing, and what is overengineered?
Resolve every identified edge case with an explicit accepted behavior or refusal, and update `PRD.md` and `architecture.md` with the answers before proceeding.
Refresh `architecture-essentials.md` when a critical decision or schema changes.
Do not silently assume answers, start an endless new design exercise, or advance while an answer is still missing.

### 6. Unified AGENTS.md & Physical Scaffolding

Have the preparation worker use `bin/fm-ensure-agents-md.sh` to establish one root `AGENTS.md` as the single source of truth for project agent rules, with `CLAUDE.md` importing `@AGENTS.md` rather than duplicating rules.
Point other agent instruction files at that same owner, and retain its self-governance guidance.
Reference the completed onboarding documents from `AGENTS.md` instead of copying them into the always-loaded rules.
Create the complete agreed folder structure, database schemas and types, and empty or draft module shells on disk to establish spatial boundaries before implementation.
For an existing repository newly added to the fleet, reconcile and preserve its existing structure and rules instead of overwriting them with a blank scaffold.
Keep scaffolding within the accepted design, without product behavior or speculative modules, and commit the completed preparation artifacts.

### 7. Backlog Slicing & TDD Implementation

Use `to-tickets` for tracer-bullet vertical slices spanning database, API, UI, and tests wherever those layers apply, with independently verifiable outcomes and explicit blocking dependencies.
Confirm the slice boundaries and public test seams with the captain before dispatch.
Use its slicing method, not an assumed tasks-axi integration or its default per-ticket files and external tracker publication.
Record the approved slices through the configured backlog backend contract in [`docs/configuration.md`](../../../docs/configuration.md#backlog-backend-taskstoml--configbacklog-backend); a manual home hand-edits its backlog file, while a tasks-axi home uses the existing home-scoped wrapper.
Do not invent a per-project tasks-axi ticketing command or migrate the home's backlog backend for onboarding.
Before the first implementation spawn, verify that steps 1 through 6 are committed and available on the implementation base, the approved slices are recorded, and no alignment decision remains open.
Record those completion references with the backlog work so later dispatches can verify them without re-running the sequence.
Only then dispatch implementation crewmates into isolated worktrees under the normal task lifecycle.
Require `tdd` in their instructions for all guardrail and domain logic, with behavior tests at the agreed public seams and Red-Green-Refactor loops.
For this protocol, explicitly require the refactor phase after green while preserving behavior, rather than inheriting `tdd`'s default deferral of refactoring to review.
Pass every completed PR through no-mistakes adversarial review and green checks before presenting it for captain merge approval; onboarding grants no merge authority.

## Remove

Project removal is destructive.
First obtain the captain's explicit removal decision, then inspect the current digest and authoritative repositories for in-flight or queued work, registered secondmate clones, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
If any dependency or unlanded work exists, stop and report it before changing anything.
Never issue a raw removal command from Firstmate.
Once that preflight confirms none of the above and the captain's approval is concrete, AGENTS.md hard rule 1's captain-approved project operation exception authorizes firstmate to remove the clone directly and update its registry entry to match.
When a clone has already been removed through an approved removal, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.
