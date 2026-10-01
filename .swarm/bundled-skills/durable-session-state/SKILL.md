---
name: durable-session-state
audience: swarm-plugin
description: >
  Persist plans, scope decisions, evidence, and reviewer/critic verdicts to
  durable files during long or multi-phase tasks so work survives context
  compaction, session resumes, and handoffs. Use for swarm-mode tasks, before
  context grows large, when recording approval gates, and when resuming after
  compaction or a session restart.
---

# Durable Session State

Long swarm-mode sessions outlive their context window. Compaction summarizes
history, and summaries lose exactly the things the swarm gates depend on:
which diff a reviewer approved, what evidence was recorded, which decisions
are settled. Without durable artifacts, a resumed session re-litigates settled
decisions or — worse — treats a stale approval as current. Persist state to
files as you go; treat the conversation as cache, not storage.

## Where artifacts live

- Generic swarm tasks: `.claude/session/tasks/<task-slug>/` in the project.
- Issue-tracer work: `.agents/issue-traces/<issue-slug>/` (that skill's own schema
  — `08b-implementation-review.md`, `09-final-critic.md` — wins for its work).
- Never write task artifacts to the repo root, and never under `.swarm/` —
  that directory is the OpenCode plugin's runtime state, not Claude Code's.
- These artifacts are working state, not deliverables: do not commit them
  unless the user asks. Before committing, check `git status` and exclude
  them explicitly.

## What to persist

Keep it to four small files per task; update in place:

1. `plan.md` — task scope, success criteria, files in scope, what must not
   break. Update when scope changes; never fork a second plan file.
2. `decisions.md` — one line per settled decision with a one-line rationale
   ("chose X over Y because Z"). Settled means: do not reopen without new
   evidence or a user request.
3. `evidence.md` — validation commands run and their outcomes (pass/fail plus
   the load-bearing output lines, not full logs).
4. `gates.md` — the approval ledger. One entry per reviewer/critic verdict:

   ```
   ## <gate> — <APPROVE|NEEDS_REVISION|BLOCKED>
   when: <ISO timestamp or turn marker>
   head: <git rev-parse HEAD>
   diff: <git diff --stat summary>
   items: <blocking items, or none>
   ```

## When to write

- At phase boundaries (scope settled, plan built, implementation done, each
  gate verdict received).
- Before ending a turn while background subagents are running.
- Whenever you notice the conversation is long — write ahead of compaction,
  not after it.

## Resume protocol

On resuming (after compaction, a restart, or a handoff), before doing new
work:

1. Re-read the task's artifacts. They are authoritative over your memory of
   the conversation.
2. Do not re-litigate `decisions.md` entries or redo work `evidence.md`
   already proves, absent new evidence or a user request.
3. Check gate staleness: if `git rev-parse HEAD` or the working-tree diff no
   longer matches the latest APPROVE entry in `gates.md`, that approval is
   invalid — re-run the affected reviewer/critic gate on the current diff.
4. If artifacts and the summarized conversation disagree, trust the artifacts
   and say so.

## Relationship to swarm gates

The swarm-mode contract invalidates any approval issued before the latest
edit. The `gates.md` ledger is what makes that rule *checkable* instead of
vibes: record the HEAD and diff summary at approval time, compare on resume
and before final synthesis. If you cannot demonstrate approval-after-last-edit
from the ledger, the gate is not satisfied.
