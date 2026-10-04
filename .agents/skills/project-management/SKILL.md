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

The registry records the project's standing delivery posture and optional ship-branch prefix, which are the captain's defaults rather than any task's answer.
`AGENTS.md` section 7 owns how each task's concrete mode, yolo, and branch prefix are resolved at intake and passed explicitly to the brief, the spawn, and any promotion.
Choose that posture when adding or creating the project:

- `direct-PR` uses repository-owned risk-based validation, pushes and opens a PR.
- `local-only` uses the same validation principle, has no required remote or PR, and lands only through the approved local fast-forward path.

`direct-PR` is the default for a newly added or created remote-backed project when the captain specifies nothing, and a project with no remote defaults to `local-only`.
State that resolved default while confirming the source, local name, and posture.
A legacy registry entry with no bracket resolves to `direct-PR`; retired delivery modes are invalid and must be migrated without changing the project's other settings.

The optional `+yolo` posture changes merge authority only and does not change the delivery mode.
Default it off for every project and every posture, and enable it only on the captain's explicit instruction.
`AGENTS.md` section 7 owns the merge-authority contract.

The optional `forge=` token records which forge the project's remote actually is; its one value is `forge=gerrit`.
It is orthogonal to the mode and to `+yolo`, so it is never derived from either, and it is never inferred at use time from a remote name, host, port, or push target.
At add or create intake, run `bin/fm-forge-detect.sh projects/<name>` once the clone exists and propose its answer alongside the posture; the captain's confirmation is what binds it, and the registry token is the durable record of that confirmation.
Never register the binding from detection alone, and never re-derive it later from the clone.
A forge composes with `direct-PR`, and the registry refuses it on `local-only`, which publishes nothing; a Gerrit-hosted project kept local registers `local-only` with no forge token.
`yolo` is inactive on a `forge=gerrit` project, so never propose `+yolo` alongside it.
`bin/fm-project-mode.sh`'s header owns the binding and `bin/fm-dod-lib.sh` owns what it changes for a worker.

## Add or clone an existing project

Confirm the source URL, local project name, delivery posture, and autonomy posture, stating the resolved default for each rather than asking the captain to invent one.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
A `direct-PR` project needs an `origin` remote.
A `local-only` project may have no remote.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery posture, defaulting visibility to private and the posture to `direct-PR`, then obtain the captain's explicit consent for those exact values; a stated default never replaces that consent.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally, add the registry entry, and inspect its existing native validation path.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

## Initialize

Use the repository's existing native setup and validation commands.
Registration and cloning do not install a delivery tool or initialize a separate gate.
If the repository has no usable validation path, make only the smallest risk-appropriate native correction required by the authorized task.

## Remove

Project removal is destructive.
First obtain the captain's explicit removal decision, then inspect the current digest and authoritative repositories for in-flight or queued work, registered secondmate clones, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
If any dependency or unlanded work exists, stop and report it before changing anything.
Never issue a raw removal command from Firstmate.
Once that preflight confirms none of the above and the captain's approval is concrete, AGENTS.md hard rule 1's captain-approved project operation exception authorizes firstmate to remove the clone directly and update its registry entry to match.
When a clone has already been removed through an approved removal, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.
