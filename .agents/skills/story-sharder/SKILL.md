---
name: story-sharder
description: Agent-only planning-to-Linear story sharder for large or ambiguous initiatives during normal Linear-workflow intake. Use when the existing scope assessment says work needs explicit SPEC, milestones, dependencies, and worker-ready story breakdown before execution. Extends the Linear workflow rather than replacing it, keeps SPEC kernels in Linear, and preserves firstmate autonomy for routine in-scope work.
user-invocable: false
metadata:
  internal: true
---

# story-sharder

Load this during normal Linear-workflow intake when a large or ambiguous initiative needs explicit planning before execution.
Do not load it for small, bounded implementation work that can proceed through the ordinary ship or scout lifecycle.
This skill extends the existing Linear workflow scope assessment; it is not a parallel planning or execution pipeline.

## Non-negotiable boundaries

- Routine in-scope work still proceeds without a new captain approval gate.
- SPEC kernels live in Linear, either as a Linear Document or in an issue description.
- Do not put the canonical SPEC kernel in private `data/`, report files, local markdown, or branch-only files.
- Captain decision points are Linear tickets assigned to the captain in the appropriate project.
- Chat approval of the Linear decision ticket is sufficient and final when the captain gives it.
- Execution state remains single-source through Linear plus the normal firstmate backlog.
- Do not create a second status tracker, sprint file, or story-state ledger.
- The sharder never executes stories itself.

## Intake fit

Use the sharder when any of these are true:

- The ask spans multiple milestones or several independent workers.
- Dependencies between deliverables affect safe dispatch order.
- The initiative has ambiguous capabilities, constraints, non-goals, or success signals.
- A scout report, Linear Document, issue, or repo document needs to become several worker-ready tickets.
- The captain asks to shard, break down, plan into Linear stories, or turn a SPEC into buildable tickets.

Do not use the sharder when the work is a contained fix, a single investigation, a small documentation update, or an already clear one-ticket implementation.
In those cases, continue through the existing Linear workflow and firstmate lifecycle.

## Required artifact shape

The proposal has two Linear surfaces.

1. A SPEC kernel in Linear.
2. A Linear decision issue assigned to the captain that links the SPEC/story proposal.

The SPEC kernel contains:

- Why.
- Capabilities with stable `CAP-*` IDs.
- Constraints.
- Non-goals.
- Success signal.
- Companion links to repo docs, research reports, architecture notes, or source tickets.
- Milestones.
- Stories.

Each story contains:

- Stable story id.
- Title.
- Description.
- Acceptance criteria.
- Verification contract.
- Dependencies by story id.
- Milestone.
- Suggested worker kind, `ship` or `scout`.
- Target project.
- Capability IDs it satisfies.

## Proposal procedure

1. Read the source Linear issue, comments, relevant Linear Documents, scout reports, and repo docs.
2. Decide whether sharding is warranted under Intake fit.
3. If not warranted, record no sharder artifact and continue normal Linear workflow.
4. Draft the SPEC kernel and story list in the plan JSON shape owned by `bin/fm-shard.sh --help`.
5. Run `bin/fm-shard.sh validate <plan.json>` before publishing anything.
6. Run `bin/fm-shard.sh render-spec <plan.json>` and use that text for the Linear-resident SPEC kernel.
7. Run `bin/fm-shard.sh propose <plan.json>` to create or update the Linear SPEC surface and the captain decision ticket.
8. Link the decision issue from the source initiative issue.
9. Stop there until the captain approves the decision issue.

A planning scout may draft the plan, but firstmate still owns the Linear decision surface and normal captain authority.
The scout report is evidence, not the canonical SPEC.

## Approval and materialization procedure

After the captain approves the Linear decision ticket, run `bin/fm-shard.sh apply <plan.json>`.
The script creates or updates Linear project milestones, story issues, dependency relations, and matching backlog tasks.
Every generated backlog task must point to the Linear story and the SPEC kernel in its body.
Every generated story issue must include the story id, capability IDs, acceptance criteria, verification contract, dependencies, milestone, suggested worker kind, and target project.

Then dispatch stories through the ordinary lifecycle only when their dependencies and time gates allow it.
Use `fm-brief` as usual, and include the capability IDs, story id, and verification contract in the task-specific instructions.
Do not bypass secondmate routing, delivery mode, no-mistakes, PR approval, or local-only merge authority.

## Completion loop

Completed PRs and scout reports update Linear and docs through the existing completion loop.
If a completed story changes the SPEC, update the Linear-resident SPEC or add a Linear comment there.
Do not fork the canonical SPEC into private files.

## Mechanics owner

`bin/fm-shard.sh` owns the deterministic plan schema, validation, rendering, Linear mutations, and tasks-axi writes.
Its header and `--help` output are the current command reference.
Keep this skill focused on when to use the sharder and what the artifacts mean.
