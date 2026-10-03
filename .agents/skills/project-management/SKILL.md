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

## Preconditions and registry

Projects live flat under `projects/`, and `data/projects.md` is the private fleet registry.
Use the registry format and parser contract owned by the header of `bin/fm-project-mode.sh`.
Keep each registry description useful for identifying the project, but keep delivery posture, captain-private state, and detailed project knowledge in their existing designated homes.
Do not turn the registry into project documentation.


Resolve the project name, destination, delivery posture, and autonomy posture before changing local or remote state.
Keep a newly added clone and its registry entry consistent, and roll back only artifacts created by the incomplete operation when a later initialization step fails and that rollback is safe.
Do not overwrite or repurpose an existing path.

## Delivery posture

The registry records the project's standing posture, which is the captain's default for the work rather than any task's answer; `AGENTS.md` section 7 owns how each task's concrete mode and yolo are resolved at intake and passed explicitly to the brief, the spawn, and any promotion.
Choose that posture when adding or creating the project:

- `review-PR` runs intent-aware native review plus relevant tests and lint before a PR.
- `direct-PR` pushes and opens a PR without the native-review requirement.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.
- `review-prod-only` is a conditional policy rather than one flat mode: genuinely internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `review-PR`.

Regardless of registry posture, `AGENTS.md` resolves a deployable ByteDance-internal BITS/PPE task to concrete mode `review-PR` and routes its conditional lifecycle to `bits-development`; the registry entry itself does not change.

`review-prod-only` is the default for a newly added or created remote-backed project when the captain specifies nothing, and a project with no remote defaults to `local-only`.
State that resolved default while confirming the source, local name, and posture instead of asking the captain to choose from scratch, and record a flat mode instead whenever they ask for one.
Legacy `no-mistakes` and `no-mistakes-prod-only` entries are accepted only for compatibility and resolve to `review-PR` and `review-prod-only`; new registry writes use only current names.
Registering a conditional policy is a one-time choice and never requires classifying any change; the per-task surface classification happens at each task's intake, and internal-only is never inferred from file location or project name.

The optional `+yolo` posture changes merge authority only and does not change the delivery mode.
Default it off for every project and every posture, and enable it only on the captain's explicit instruction.
`AGENTS.md` section 7 owns the merge-authority contract.

## Add or clone an existing project

Confirm the source URL, local project name, delivery posture, and autonomy posture, stating the resolved default for each rather than asking the captain to invent one.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
A `review-PR`, `review-prod-only`, or `direct-PR` project needs an `origin` remote.
A `local-only` project may have no remote.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery posture, defaulting visibility to private and the posture to `review-prod-only`, then obtain the captain's explicit consent for those exact values; a stated default never replaces that consent.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally, add the registry entry, and initialize it according to its delivery posture.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

## Initialize

Verify the selected harness and runtime backend required by the standing posture, but do not install a project-local review pipeline.
For `review-PR`, a task may dispatch only to a harness with a verified native review command; `bin/fm-native-review.sh` provides the exact failure when the selected harness lacks that capability.
Do not create a commit merely because project intake ran.

## Remove

Project removal is destructive.
First obtain the captain's explicit removal decision, then inspect the current digest and authoritative repositories for in-flight or queued work, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
If any dependency or unlanded work exists, stop and report it before changing anything.
Never issue a raw removal command from Firstmate.
Once that preflight confirms none of the above and the captain's approval is concrete, AGENTS.md hard rule 1's captain-approved project operation exception authorizes firstmate to remove the clone directly and update its registry entry to match.
When a clone has already been removed through an approved removal, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.
