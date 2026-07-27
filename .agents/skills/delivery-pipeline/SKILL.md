---
name: delivery-pipeline
description: >-
  Agent-only procedure for the universal delivery pipeline: every intake shape enters the same five stages - classify, grill, plan for approval, approve and hold and dispatch, then ship one PR (or deliver a report for research).
  Use when work arrives in any shape for a named repo: an open issue, a reported bug, a research or design question, or a feature request.
user-invocable: false
metadata:
  internal: true
---

# delivery-pipeline

The captain's standing way of turning any incoming work into a shipped change or a delivered report.
Every intake shape - an open issue, a reported bug, a research or design question, or a feature request - enters the same five stages; only the ending differs, because implementation work ends at a merged PR and research ends at a report the captain reads.
This skill owns the stage ordering and the per-stage contract only.
It points at existing machinery for every mechanic - `bin/fm-brief.sh` for briefs, `bin/fm-spawn.sh` for launch, `lavish-axi` for the review surface, the backlog verbs for tracking, and AGENTS.md section 8 for supervision - and never restates lifecycle mechanics.

The plan gate is a hard rule and it is universal: no implementation crewmate is ever spawned, for any intake shape, before the captain approves a plan on record.
Research reaches the same gate; its approved plan governs a scout whose report is the deliverable, never a PR.

## Stage 1 - Intake and classify

Resolve the project exactly as AGENTS.md section 7 intake requires; route in-scope work to the fitting secondmate rather than the main home.
Classify the intake shape so the ending is unambiguous:

- **issue**, **bug**, and **feature** are implementation work and end at a merged PR, or at a clean ready branch the captain approves for a repo with no remote.
- **research** is a knowledge deliverable and ends at a report in `data/<scout-id>/report.md`, never a PR.

When the captain asks for the best issue to work on in a named repo, list the repo's open issues with `gh-axi issue list` and rank them:

1. Unblocked before blocked (nothing depends on unlanded or unstarted work).
2. Dependency-critical next (other issues wait on it).
3. Then best value for effort.

If the captain named the exact work - a specific issue, a reported bug, a research question, or a feature - skip the pick and confirm and go straight to the grill.
Otherwise reply in chat with your pick, one or two runner-ups, and one line of why for each, in outcome language - the work and what shipping it gets the captain, never internal mechanics.
Wait for the captain to confirm or redirect before planning anything.

## Stage 2 - Grill

Grill only to resolve ambiguity that would change the plan; skip it entirely when the work is already unambiguous.
This protocol is self-contained - do not depend on any external grill skill.

- Ask one question at a time, in the terminal, using the harness's question tool, each with two to four concrete options.
- Explore before you ask: anything the codebase, the issue thread, or the project docs can answer, you answer yourself instead of spending a question on it.
- Every question must be one whose answer changes the scope, the approach, or the success criteria; skip preference-neutral detail.
- Stop as soon as every plan-changing ambiguity is resolved, not after a fixed number of questions.

## Stage 3 - Plan for approval

Spawn a planner crewmate that reads the repo and drafts the plan.
Planners only read code, so the same-repo serialization rule in stage 4 does not bind them: planners are uncapped, and several plans drafted for one repo at once is what keeps the review queue full while code work serializes.
Run planning on the dispatch profile that matches planning and scout work, per AGENTS.md section 4 and the dispatch profiles.

A planner is a scout, scaffolded with `bin/fm-brief.sh <planner-id> <repo> --scout`.
`--plan` applies only to ship briefs, so a planner or scout brief names any plan path in its task text instead of passing the flag.
The generated scout definition of done is unchanged, so brief the planner for both artifacts: the plan at `<this-firstmate-home>/data/<planner-id>/plan.html`, and the `data/<planner-id>/report.md` the generated brief already names, standing alone with what it read, what it recommends, and the plan's path.
Name the plan path in absolute form every time you hand it to a planner: its worktree is scratch that teardown discards, and the generated brief absolutizes only the report, so a relative plan path lands in the discarded worktree and leaves stage 4 nothing to copy.
Without that report, `bin/fm-teardown.sh` refuses the planner's teardown and the decision-hold completion gate never passes.

The plan is one live artifact per task at `<this-firstmate-home>/data/<planner-id>/plan.html`, presented for review with `lavish-axi` (load the `lavish` skill for its mechanics).
It is overwritten in place across revisions, with a rev counter incremented on each revision; no revision history is kept.
One task per artifact, at full depth - never fold multiple work items into one plan.

Every plan artifact, whatever the intake shape, must contain at minimum:

- **Why this work** - the outcome shipping it delivers.
- **Success criteria** - mapped one-to-one to the acceptance criteria.
- **Risks and gotchas** - what could go wrong and the mitigation.
- **Approval control** - the surface the captain uses to approve.

An implementation plan must also contain:

- **Files table** - each file marked CREATE or MODIFY with its role.
- **What's in each file** - the concrete change per file.
- **Key code** - the load-bearing snippets the implementer will write.
- **Deviation threshold** - the exact statement from stage 5 so the implementer inherits it.

A research or design plan writes no code and never reaches stage 5, so it omits those four as inapplicable and must instead contain:

- **Question** - the exact question the report has to answer.
- **Sources and method** - what the scout reads, runs, and reproduces to answer it.
- **Report outline** - the sections `data/<scout-id>/report.md` must carry.

On the captain's verdict:

- **Annotates** - the same planner revises, the rev counter increments, and the artifact goes back for review.
- **Approves** - the plan is on record; proceed to stage 4.

## Stage 4 - Approve, hold, dispatch

No implementation crewmate runs before the captain approves the plan; this gate is universal and has no exception for any intake shape.
Once approved, branch on the deliverable:

- **research** - dispatch exactly one scout crewmate to execute the approved plan; its report is the deliverable and there is no PR.
  1. Scaffold the brief with `bin/fm-brief.sh <scout-id> <repo> --scout`, then replace `{TASK}` with the question, the approved plan's absolute path, the acceptance criteria, and context per AGENTS.md section 11.
  2. Spawn through `bin/fm-spawn.sh` on the planning and scout dispatch profile, after the profile and backend checks in AGENTS.md section 4.
  3. Record the work item on the backlog and hand off to normal supervision under AGENTS.md section 8.
  Scouts read only, so they neither take the repo's implementation slot nor wait behind one.
  The scout writes `data/<scout-id>/report.md`; deliver that report to the captain and stop, because research never enters stage 5.
- **implementation** - check the repo's implementation slot before dispatching.

Two implementation tasks never run in the same repo at once.
That is the mechanical default, not a judgement call: it prevents real branch and merge conflicts, because freeing the slot only at merge means every task starts from a base containing everything before it.
The single exception is a task the captain has explicitly flagged P0, which may dispatch into a busy repo concurrently on the captain's stated acceptance of the merge-conflict and rebase cost; record that acceptance on the work item.
Firstmate never opens that exception from its own read of urgency, so absent an explicit P0 flag the default stands.
Everything else - how many repos run in parallel, research alongside code - stays firstmate's contextual call.

- **Slot busy** - the task is held with its approval already banked, so it is not re-approved when it starts.
  Every hold states its reason naming the blocking task, in the shape `held - waiting on <repo> #<n> to merge`.
  File the work item on the backlog first and hold it only then, the order `bin/fm-decision-hold.sh` uses, because `tasks-axi hold` fails `NOT_FOUND` on an id the backlog does not carry yet.
  Record the hold durably with `tasks-axi hold <ship-id> --reason "held - waiting on <repo> #<n> to merge" --kind load`, the capacity kind for a slot wait; `--kind captain` belongs to the decision-hold lifecycle and would misread as a pending captain decision.
  No hold sits silently, and no agent has to remember elapsed time: the durable re-evaluation of queued work after every teardown and heartbeat enforces the bound, and when it finds a held item older than 24 hours it surfaces it to the captain with the blocking PR's full URL and asks for a merge, a re-scope, or an explicit P0 override.
- **Slot free** - dispatch exactly one implementation crewmate:
  1. Copy the approved plan from the planner's `<this-firstmate-home>/data/<planner-id>/plan.html` to the ship task's `data/<ship-id>/plan.html` under the active home, creating that directory first if it does not exist.
     `fm-brief.sh` fails hard with `--plan file not found` when the copy is skipped, so it happens before the brief is scaffolded.
  2. Scaffold the brief with `bin/fm-brief.sh <ship-id> <repo> --plan data/<ship-id>/plan.html`, then replace `{TASK}` with the task description, acceptance criteria, and context per AGENTS.md section 11.
     fm-brief resolves a relative `--plan` path against the current working directory, so pass the plan's absolute path when invoking from any directory other than the active firstmate home.
     The `--plan` block already carries the binding-plan declaration and the deviation threshold, so do not restate them in the task text.
     If the task touches firstmate's own shared tracked material, add the `firstmate-coding-guidelines` load instruction by hand as section 11 requires.
  3. Spawn through `bin/fm-spawn.sh` on the execution dispatch profile, after the profile and backend checks in AGENTS.md section 4.
  4. Record the work item on the backlog and hand off to normal supervision under AGENTS.md section 8.

When the blocking PR merges, the repo's slot frees; a held task auto-starts from its banked approval and the captain is told after, not asked again.
Re-validate the banked plan against the new base before that auto-start: if the merged work touched the plan's files or invalidated its success criteria, escalate it as a plan deviation for re-approval rather than starting silently on a stale plan.

## Stage 5 - Ship

Stage 5 is implementation-only; a research task already ended at its report in stage 4 and never reaches here.
The crewmate follows the project's selected delivery path to a single PR; there is one PR per work item, opened only after the work is done.
A repo with no remote ends instead at a clean ready branch the captain approves; the plan gate, the grill, and the trust rules all still apply, only the PR ending differs.

Deviation threshold, carried verbatim into every plan artifact:

- **Minor mechanical deviations** (wording, ordering, naming): adapt, and disclose EVERY one where the delivery path surfaces it - the PR body under "Deviations from approved plan" for a PR-producing mode, or the final ready-branch done summary for local-only.
- **Material deviations** (a different approach, files added or dropped, changed success criteria): STOP, append `needs-decision: plan deviation - {summary}` to the status file, and wait for re-approval.

PR hygiene:

- Body structure: What, Why, Changes, Verification.
- `Closes #N` for an issue so it auto-closes on merge.
- At least one label from the repo's existing taxonomy (`gh-axi label list`); do not invent labels.
- No AI attribution anywhere in the PR body or commits, and no co-author trailer.
- No references to the internal validation pipeline or its step names in the PR or commits.

The captain merges; the `yolo` carve-outs in AGENTS.md section 7 are unchanged, and destructive, irreversible, or security-sensitive choices still escalate.
Teardown and backlog update follow the normal lifecycle in AGENTS.md section 7.
