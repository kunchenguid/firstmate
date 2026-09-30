---
name: selective-parallelism
description: >-
  Agent-only policy for how much delegated help one task gets and in what shape.
  Use before splitting a single task across more than one worker, before running a multi-hypothesis race, and before dispatching a nontrivial change.
  Owns the one-coordinator ceiling, the per-task Code-Crew and Butler-Crew roles, the 2-3 worker hypothesis race, and the pre-change scope and impact preflight.
user-invocable: false
metadata:
  internal: true
---

# selective-parallelism

Use this skill before splitting one task across more than one worker and before dispatching a nontrivial change.
It is the single owner of Firstmate's policy on the size and shape of delegated help for a single task.
`AGENTS.md` section 7 keeps the always-loaded ceiling and the safety-critical rules; everything else lives here.
Firstmate applies it at intake, while briefing, and while choosing between dispatch shapes.
It creates no agent type, no standing process, and no runtime mechanism.

## One coordinator, narrow help on demand

The default shape is one crewmate, and that default holds for a long task, a many-step task, a many-file task, and a task the coordinator finds tedious.

A second worker is a decision that costs the captain supervision, quota, and reconciliation, so it needs a named reason from the closed list below.
Never add one because a task looks large, because a similar task once needed one, or because two workers sound faster.
Set no crew-count target: the right number for a task is a judgment from the reason, never a quota to fill.

Reasons that justify a second worker:

- **Distinct concerns inside one task.** The brief carries unrelated work whose own context would rot a shared window, such as a data migration plus an unrelated documentation rewrite.
  Split by concern rather than by project, and name the concern in each brief.
- **Independent audit or review.** A second worker checks a delivered result against its actual diff and verification evidence, with no stake in the approach that produced it.
- **A genuinely uncertain design or a hard bug.** Use the hypothesis race below rather than splitting an implementation nobody has designed yet.

Anything else stays at one worker.
Section 7's concurrency rule is the separate axis: several independent tasks may run at once with no cap, and this skill does not restrict that.
The failure this policy prevents is workers exchanging partial, unverified results that nobody reconciles, which leaves the coordinator, and then the human, managing the mess instead of the work.

## Per-task crew roles

A crew role is briefing vocabulary for a narrow concern, not a persistent agent.
It is scaffolded and dispatched through the ordinary `bin/fm-brief.sh` then `bin/fm-spawn.sh` path, so it gets the same worktree isolation, durable state, supervision, and delivery contract as any other task.
Each role runs in its own isolated session with a fresh brief, which reduces context bleed from earlier work without promising any particular context quality.
Close a completed role session only through the ordinary task lifecycle after its deliverable exists and delivery and landed-work gates permit teardown; never discard unlanded work or tear down a task whose required work remains.

Two roles cover routine splitting:

- **`Code-Crew`** carries code implementation, bug fixes, and feature development for one task.
  For code behavior changes, begin with a failing behavioral test and implement against it; follow the target repository's test commands and safety constraints, and when it has no executable contract verify the real surface directly instead of claiming a check passed.
  Running a PR verification pass is input to review and never replaces the coordinator's final review, which the rules below state.
- **`Butler-Crew`** carries the recurring non-engineering chores for one task: Notion and knowledge-wiki capture, journal and ledger upkeep, and Discord or other automation runs.
  Any write to an external system, any message it sends, and any merge it proposes still obey the existing approval and safety rules unchanged, so a specialist never gains a capability the coordinator lacks.

Independent audit and review is the third shape, and it is read-only: it produces findings against someone else's delivered work rather than a change of its own.

Rules that hold for every crew role:

- A role name is never bound to a provider or a model.
  Harness, model, and effort come from the dispatch profile resolution `AGENTS.md` section 4 owns, so retuning a profile changes who does the work without rewriting any role.
- A role reports to Firstmate through the ordinary status and report path, and never absorbs captain communication, delivery posture, or merge authority; those stay with Firstmate.
- A role never replaces the coordinator's final review of every delegated result, which `AGENTS.md` section 7 already requires and which also covers a result produced by an external tool rather than by a worker.
- Two roles never hold write access to the same change.
  A role that needs another's output waits for it, or the dependency is serialized under section 7's concurrency rule.
- A role is never a standing process kept warm between tasks, and a role never becomes a secondmate.
  Secondmate scope and provisioning belong to `secondmate-provisioning`, and this skill does not change them.

## Multi-hypothesis race

Run a race only when a design is genuinely uncertain or a bug is hard, and only when the answer would change what gets built or fixed.
Section 7 already refuses a parallel design exercise that is not expected to change the answer, so a race has to clear that bar before it starts, and routine code changes never race at all.

A race is 2 to 3 contenders, never more, because a wider field costs more than it decides.
Give every contender a distinct specific hypothesis about the cause or the approach so the reports are genuinely different evidence rather than three variations of one guess.
State each hypothesis in the brief so the contender investigates it rather than restating the task.
Scaffold each contender with `bin/fm-brief.sh <task-id> <repo> --scout` and dispatch it the ordinary way, so each runs read-only in its own isolated scratch worktree and delivers a report at `data/<task-id>/report.md`.

The coordinator does the comparing, never the contenders: read each report, weigh the evidence against the reproduction or the requirement, then state the selected approach and why the others lost.
The reports are evidence, not authorization: promote a selected scout or brief a ship task only after implementation is separately authorized under `AGENTS.md` section 7.
Once authorized, assign exactly one implementation owner, promoting the matching scout through `bin/fm-promote.sh` when its report is selected, or briefing one ship task when none is.
Never let two contenders carry the implementation forward, never blend hypotheses, and never let a race outlive its decision.

A race is not the way to handle an undiagnosed bug.
Load `diagnostic-reasoning` first when the fault is not yet understood, because a race over an unexplained symptom compares guesses instead of evidence.

## Pre-change scope and impact preflight

Run this for nontrivial work before implementation starts, and put the result in the brief rather than leaving it in conversation.
Skip it for a routine well-understood change whose affected surface is obvious.

Name four things before choosing the shape:

- **Affected callers and consumers.** Every place that reads, calls, imports, documents, or tests what changes, including callers outside the obvious directory, and the blast radius each one gives it.
- **Assumptions that change.** The invariants the rest of the code relies on, plus any documented or implied promise the change would break.
- **The minimum in-scope change.** The smallest change that satisfies the accepted intent, with what stays out of scope named explicitly; a generalization, consistency sweep, or extra hardening the ask did not request is follow-up work, not scope.
- **Verification.** What proves the change works against the real surface rather than against intent, and which of those checks already exist.

Keep prose cleanup a separate writing request, never a step inside a code change.
A request to cut filler, hedging, or AI tells from a PR description, a document, or a report is about that prose; applying the same treatment to code is a refactor with its own scope and risk, and the two must not ride in one instruction.

## What this skill does not change

It does not touch hard rule 1's project-write boundary, hard rule 2's merge authority, section 7's delivery paths, the secondmate policy, or the coordinator's final review.
It adds no configuration, no script, and no state file.
When a shape seems to need new machinery, take the simplest direct end-to-end path until a concrete blocker or repeated need proves the machinery is warranted.
