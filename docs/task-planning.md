# Firstmate task planning

Firstmate's planning layer is `.agents/skills/task-planning/SKILL.md`.

It is a Firstmate-native adaptation of three ideas from Matt Pocock's engineering skills:

- **Wayfinder:** map unresolved decisions before implementation is planned.
- **to-spec:** graduate resolved decisions into an implementation contract.
- **to-tickets:** turn the contract into independently executable vertical slices with explicit dependencies.

It intentionally does **not** import Wayfinder's implementation workflow. Firstmate remains the owner of briefs, worktrees, crew spawning, supervision, delivery modes, validation, and merge authority.

## Planning levels

| Level | Use when | Artifacts | Execution |
| --- | --- | --- | --- |
| Simple | narrow, obvious, one crew | none | existing Firstmate lifecycle |
| Planned | clear request, multiple meaningful changes or crews | `spec.md`, `tickets/` | existing Firstmate lifecycle after plan approval |
| Wayfinder-planned | destination or load-bearing decisions are unclear | `wayfinder.md`, `spec.md`, `tickets/` | existing Firstmate lifecycle after plan approval |

The gate is deliberately not mandatory for every task. This keeps small fixes from paying the token and latency cost of full planning.

## Artifact flow

```text
captain request
      |
      v
planning level
  /    |     \
Simple Planned Wayfinder-planned
 |       |          |
 |    spec.md   wayfinder.md
 |       |          |
 |   tickets/  <----+
 |       |
 +-------+---------->
         |
   captain review
         |
         v
 Firstmate brief/spawn
         |
       crews
```

Planning documents live inside the target project's clone at `projects/<project>/docs/features/<feature-slug>/`, so every planned or running feature is browsable per project instead of mixed into the Firstmate home's `data/`. Firstmate writes them under hard rule 1's enumerated `task-planning` exception and reads them back at intake and dispatch; they stay uncommitted working documents by default, and versioning them happens only through the project's normal delivery path when the captain asks. Runtime state (briefs, metadata, backlog) remains in the Firstmate home.

## Integration boundaries

The planning skill composes with existing Firstmate procedures rather than replacing them:

- `diagnostic-reasoning` remains authoritative for bug causality and reproduction.
- `captain-hold-lifecycle` remains authoritative for unresolved decisions and approval.
- `project-management` remains authoritative for project intake and delivery posture.
- `harness-adapters` and `quota-array-dispatch` remain authoritative for crew runtime/model selection.
- `fm-brief.sh` and `fm-spawn.sh` remain authoritative for implementation execution.

A planning ticket is not a Wayfinder decision ticket. Decision questions are resolved through scout work or captain decisions before they graduate into implementation tickets.

## Token-efficiency rule

Do not invoke the full Wayfinder-style workflow merely because a task exists. Prefer the cheapest workflow that preserves correctness:

1. direct crew for simple work;
2. spec + tickets for clear multi-part work;
3. Wayfinder + spec + tickets only when unresolved decisions can materially change the implementation.

Likewise, ticket existence does not imply a separate review-agent call. Verification is specified per ticket and escalated according to the project's existing delivery mode and risk.

## Verified integration points

Source-audited against this repository:

- **Discovery.** `.claude/skills` is a symlink to `.agents/skills`, so every harness that scans project skills sees `task-planning`; `metadata.internal: true` keeps it out of installer discovery. The behavioral load path is the AGENTS.md section 13 trigger - a running firstmate loads the skill only at that named trigger, now present in sections 7 and 13.
- **Artifact location and lifecycle.** Feature documents live at `projects/<project>/docs/features/<feature-slug>/` in the primary clone, authorized by hard rule 1's enumerated `task-planning` exception and bounded to that path. Uncommitted documents do not block guarded fleet sync (fast-forward ignores untracked files) and teardown never touches the primary clone. `ls projects/<project>/docs/features/` is the per-project inventory of planned work; progress truth remains the backlog.
- **Parent/child identity.** The parent request is one ordinary task whose backlog note records the `<project>:<feature-slug>` pair. Each ready ticket becomes its own Firstmate task with id `<parent-id>-t<TNN>` (valid per `fm_task_id_creation_valid`: `[A-Za-z0-9._-]`, at most 64 chars); its brief embeds the ticket content and points at `projects/<project>/docs/features/<feature-slug>/spec.md`.
- **Dependency-aware dispatch.** Each ready ticket is filed as its own Queued backlog item with an explicit blocked-by note; the ordinary backlog re-evaluation after each teardown and heartbeat unlocks dependents. No new dispatch machinery is introduced.
- **Risk-based verification.** A ticket's routine/elevated/critical level shapes evidence expectations inside the selected delivery path but never lowers a project's standing delivery posture; `no-mistakes-prod-only` classification still wins for product-facing work.

Live intake tests (simple / planned / wayfinder-planned) against a real firstmate session remain the outstanding validation step before this PR leaves draft.
