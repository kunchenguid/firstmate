---
name: project-management
description: >-
  Load before adding, creating, removing, or initializing a project.
  Cloning or registering a project is add intake and uses the same trigger.
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

## References

Load a reference with `cat` through Bash (for example `cat .agents/skills/project-management/references/remove.md`); shell output is not re-attached after compaction, so read each one at the moment it applies.

| Reference | Read it when |
| --- | --- |
| `references/delivery-posture.md` | Choosing the delivery mode, `+yolo`, `forge=` or `pr=manual` for a project being added or created. |
| `references/add-create-initialize.md` | Cloning, creating, or initializing a project. |
| `references/remove.md` | The captain asks to remove a project. |

## Hard rules that hold without the references

- Creating a remote repository is outward-facing: propose name, owner, visibility, and posture, and obtain the captain's approval first; a local-only create authorizes no remote.
- `+yolo` stays off unless the captain explicitly instructs otherwise.
- Never restart the shared no-mistakes daemon from a project operation.
- Project removal is destructive: obtain the captain's explicit decision, run the preflight in `references/remove.md`, and never issue a raw removal command.
