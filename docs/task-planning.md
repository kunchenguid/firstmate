# Firstmate task planning

Firstmate's planning family is three agent-only skills under `.agents/skills/`, orchestrated by `task-planning/SKILL.md`.
`task-grill/SKILL.md` runs requirements interrogation ahead of every non-Simple request, `task-design/SKILL.md` builds throwaway prototypes, and `task-planning` owns classification, the wayfinder/spec/ticket artifacts, and dispatch.

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

Every non-Simple level passes through `task-grill` first, which owns the hard gate of frontier exhaustion plus captain confirmation, and may run `task-design` prototypes before any spec exists.
The proposed ticket breakdown goes through an iterative ticket quiz with the captain before approval, and every approved graph ends with a terminal captain-review ticket blocked by all other tickets.
The complexity gate is re-judged at every dispatch: a ticket that has grown multiple meaningful changes or unresolved decisions becomes its own parent feature running the same family pipeline.

## Artifact flow

```text
captain request
      |
      v
task-planning classifies
  /    |     \
Simple Planned Wayfinder-planned
 |       |          |
 |    task-grill <----+   (every non-Simple path)
 |       |
 |    task-design (optional)
 |       |          |
 |    spec.md   wayfinder.md
 |       |          |
 |   tickets/  <----+
 |       |
 +-------+---------->
          |
 ticket-to-code contrast review
          |
 ticket quiz + captain review
          |
          v
 Firstmate brief/spawn (--ticket)
          |
        crews
```

The contrast review sits between decomposition and approval: each ticket is checked mechanically against the actual codebase structure - claimed consumers exist, every real seat of a produced value is listed, touched paths resolve - with the sweep split by feature size (two to three tickets, firstmate sweeps directly; larger or multi-subsystem graphs get a dedicated scout).
At dispatch the approved ticket file itself fills the crew brief's task slot verbatim through `fm-brief.sh --ticket`, so "ticket + common scaffold = brief" holds without firstmate re-elaborating anything.

Planning documents live inside the target project's clone at `projects/<project>/docs/features/<feature-slug>/`, so every planned or running feature is browsable per project instead of mixed into the Firstmate home's `data/`. Firstmate writes them under hard rule 1's enumerated `task-planning` exception and reads them back at intake and dispatch; they stay uncommitted working documents by default, and versioning them happens only through the project's normal delivery path when the captain asks. Runtime state (briefs, metadata, backlog) remains in the Firstmate home.

## Integration boundaries

The planning family composes with existing Firstmate procedures rather than replacing them:

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

- **Discovery.** `.claude/skills` is a symlink to `.agents/skills`, so every harness that scans project skills sees `task-planning`; `metadata.internal: true` keeps it out of installer discovery. The behavioral load path is the AGENTS.md section 13 trigger - a running firstmate loads each skill only at its named trigger, now present in sections 7 and 13.
- **Artifact location and lifecycle.** Feature documents live at `projects/<project>/docs/features/<feature-slug>/` in the primary clone, authorized by hard rule 1's enumerated `task-planning` exception and bounded to that path. Uncommitted documents do not block guarded fleet sync (fast-forward ignores untracked files) and teardown never touches the primary clone. `ls projects/<project>/docs/features/` is the per-project inventory of planned work; progress truth remains the backlog.
- **Parent/child identity.** The parent request is one ordinary task whose backlog note records the `<project>:<feature-slug>` pair. Each ready ticket becomes its own Firstmate task with id `<parent-id>-t<TNN>` (valid per `fm_task_id_creation_valid`: `[A-Za-z0-9._-]`, at most 64 chars); its brief embeds the ticket content and points at `projects/<project>/docs/features/<feature-slug>/spec.md`.
- **Dependency-aware dispatch.** Each ready ticket is filed as its own Queued backlog item with an explicit blocked-by note; the ordinary backlog re-evaluation after each teardown and heartbeat unlocks dependents. No new dispatch machinery is introduced.
- **Risk-based verification.** A ticket's routine/elevated/critical level shapes evidence expectations inside the selected delivery path but never lowers a project's standing delivery posture; `no-mistakes-prod-only` classification still wins for product-facing work.
