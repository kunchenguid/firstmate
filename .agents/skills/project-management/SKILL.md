---
name: project-management
description: >-
  Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project.
  Owns project add, create, clone, remove, initialization, registry, delivery-mode, autonomy, and outward-consent decisions.
user-invocable: false
metadata:
  internal: true
---

# project-management

Use this procedure before adding, creating, removing, or initializing a project.
This skill is the single owner of Firstmate's project-management procedure.
It does not replace `secondmate-provisioning`, which owns project clones inside persistent secondmate homes.

## Preconditions and registry

Projects live flat under `projects/`, and `data/projects.md` is the private fleet registry.
Use the registry format and parser contract owned by the header of `bin/fm-project-mode.sh`.
Keep each registry description useful for identifying the project, but keep delivery posture, captain-private state, and detailed project knowledge in their existing designated homes.
Do not turn the registry into project documentation.

Resolve the project name, destination, delivery mode, and autonomy posture before changing local or remote state.
Keep a newly added clone and its registry entry consistent, and roll back only artifacts created by the incomplete operation when a later initialization step fails and that rollback is safe.
Do not overwrite or repurpose an existing path.

## Delivery posture

Choose the delivery mode when adding or creating the project:

- `direct-PR` pushes and opens a PR without the no-mistakes pipeline and is the default when the captain does not specify a mode.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.
- `no-mistakes` runs the full validation pipeline before a PR and is preserved as a legacy opt-in only for the one bounded Firstmate/OMX cutover PR. Do not default new projects to no-mistakes.

The optional `+yolo` posture changes routine approval authority but does not change the delivery mode.
Default it on for newly registered projects only when the captain does not specify; otherwise follow the captain's instruction.
Destructive, irreversible, and security-sensitive decisions still require captain approval when it is on.

A ship task is complete only when a validated delivery receipt exists at `data/<id>/delivery-receipt.json`, regardless of delivery mode.

## Add or clone an existing project

Confirm the source URL, local project name, delivery mode, and autonomy posture.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
A `direct-PR` project needs an `origin` remote.
A `local-only` project may have no remote.
A `no-mistakes` project must have an `origin` remote and must complete the initialization procedure below. Only opt in to no-mistakes for the bounded Firstmate/OMX cutover or when explicitly requested.

Record the registry line as `- <name> [<mode> +yolo] - <desc> (added <date>)` unless the captain overrides.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery mode, defaulting visibility to private and delivery mode to `direct-PR +yolo`, then obtain the captain's explicit consent for those values.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally, add the registry entry, and initialize it according to its delivery mode.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

## Initialize

Run no-mistakes initialization only for `no-mistakes` projects:

```sh
cd projects/<name> && no-mistakes init && no-mistakes doctor
```

Initialization configures the local gate and does not vendor a no-mistakes skill into the project.
Do not create a commit merely because initialization ran.
If doctor reports an environment, authentication, or daemon problem, resolve that blocker before dispatching work and never restart the shared daemon from a project operation.

## Remove

Project removal is destructive and is not one of Firstmate's current direct-write exceptions under `projects/`.
Never issue a raw removal command from Firstmate.
First obtain the captain's explicit removal decision, then inspect the current digest and authoritative repositories for in-flight or queued work, registered secondmate clones, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
If any dependency or unlanded work exists, stop and report it before changing the registry.
Until a guarded removal helper and corresponding prime-directive exception exist, report that implementation gap instead of bypassing the project-write boundary.
When a clone has already been removed through an approved guarded path, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.
