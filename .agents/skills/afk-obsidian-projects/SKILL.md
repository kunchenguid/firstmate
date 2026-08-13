---
name: afk-obsidian-projects
description: >-
  Work an explicitly authorized set of AI Project Manager tasks while the captain is away, when they invoke /afk-obsidian-projects or hand firstmate a specific list of vault tasks to progress.
  Readiness is never permission: only the exact frozen task list runs, all seven readiness gates are re-checked at dispatch, and firstmate alone writes the vault.
user-invocable: true
metadata:
  internal: true
---

# afk-obsidian-projects

**Load `autonomous-run-engine` first.**
It owns the shared intake-to-report procedure.
This file owns only what is specific to the AI Project Manager vault.

```text
/afk-obsidian-projects --tasks <exact note paths> | --manifest <file> | --base-query <id>
                       [--budget <wall>]
```

## Readiness is not authority

`ai_goal: ready` means a task is technically ready to be worked.
It has never meant the captain authorized working it.

Authority comes from `#autonomous-execution` on the note, or from the captain naming that task for this run.
A ready task with neither is skipped with that reason, not worked.

Scope is a list of exact note paths, a reviewed manifest, or a stable Base query **whose current members are frozen into the manifest before execution**.
Freeze the members, never the query: a note that starts matching at 3am must not be able to join a run that is already going.

## Re-check the seven gates at dispatch, not just at intake

Hours pass between intake and a task's turn, and the vault changes in that time.
Immediately before dispatching each task, re-check all seven: autonomy, access, ambiguity, risk, reversibility, external communication, and missing inputs.

Unknown is not eligible.
A gate that cannot be answered is a skip with a reason, not a judgement call in the run's favor.

Each task resolves its own project, repo, and closest rules independently.
One task's authorization never extends to another, and a project's rules never transfer sideways because two tasks look similar.

## Firstmate alone writes the vault

Workers return evidence.
Firstmate translates it into the concise `State / Evidence / Next` block on the matching `type: task` note, following the vault's own `PM_AGENT.md` contract: minimal properties, one replaceable three-bullet `## AI Update`.

Preflight refuses a manifest that names anything but `firstmate-only` as the vault writer.

Never create a PM note per worker, a session log, a chat log, or a duplicate of evidence that already lives in the repo.
Write plain human language: the note is read by the captain, not by an agent.

## Boundaries

- Personal Apps (Recipe, Inventory, Workout Pro, and any other) stay excluded unless the captain explicitly reverses it for that exact app.
- Finished work that needs the captain's acceptance waits for it. Away mode batches the notification; it does not approve the work.
- Dependency order, mutable-lane collisions, the single browser lease, machine health, and account routing decide what may run at the same time.

## Deliverable

Per task: what moved, what proves it, what is next, and, for anything skipped, the exact gate that stopped it.
A run where most tasks were skipped for good reasons is a successful run, and the skip reasons are the useful part of the report.
