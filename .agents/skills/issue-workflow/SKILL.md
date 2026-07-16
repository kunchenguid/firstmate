---
name: issue-workflow
description: >-
  Agent-only procedure for the standing issue workflow: pick, grill, scope in a review surface, get approval, then dispatch one crewmate per issue.
  Use when the captain asks to work on an issue in a named repo, asks for the best issue to work on in a named repo, or names a specific issue to take on in a repo.
user-invocable: false
metadata:
  internal: true
---

# issue-workflow

The captain's standing way of turning an open issue into shipped work: pick with a quick confirm, grill out the ambiguity, scope one ticket per review artifact, get explicit approval, then dispatch a single crewmate per issue and hand off to normal supervision.
This skill owns the ordering and the per-step contract only.
It points at existing machinery for every mechanic - `bin/fm-brief.sh` for briefs, `bin/fm-spawn.sh` for launch, the backlog verbs for tracking, and AGENTS.md section 8 for supervision - and never restates lifecycle mechanics.

## (a) Trigger and repo resolution

The trigger is the captain asking to work on an issue, and it always names the repo ("what's the best issue to work on in e-foil?", "let's do #47 in e-foil").
Resolve the project from that name exactly as AGENTS.md section 7 intake requires; route in-scope work to the fitting secondmate rather than the main home.

List the repo's open issues with `gh-axi issue list` and rank them:

1. Unblocked before blocked (nothing depends on unlanded or unstarted work).
2. Dependency-critical next (other issues wait on it).
3. Then best value for effort.

If the captain named the exact issue, skip the pick and confirm and go straight to the grill.
Otherwise reply in chat with your pick, one or two runner-ups, and one line of why for each, in outcome language - the issue and what shipping it gets the captain, never internal mechanics.
Wait for the captain to confirm or redirect before scoping anything.

## (b) Grill protocol

Grill only to resolve ambiguity that would change the plan; skip it entirely when the ticket is already unambiguous.
This protocol is self-contained - do not depend on any external grill skill.

- Ask one question at a time, using the harness's question tool, each with two to four concrete options.
- Explore before you ask: anything the codebase, the issue thread, or the project docs can answer, you answer yourself instead of spending a question on it.
- Every question must be one whose answer changes the scope, the approach, or the success criteria; skip preference-neutral detail.
- Stop as soon as every plan-changing ambiguity is resolved, not after a fixed number of questions.

## (c) Scope contract

Scope the approved issue in a review surface with `lavish-axi` (load the `lavish` skill for its mechanics).
One ticket per artifact, at full depth - never fold multiple issues into one plan.

Each plan artifact must contain, at minimum:

- **Why this issue** - the outcome shipping it delivers.
- **Files table** - each file marked CREATE or MODIFY with its role.
- **What's in each file** - the concrete change per file.
- **Key code** - the load-bearing snippets the implementer will write.
- **Success criteria** - mapped one-to-one to the ticket's acceptance criteria.
- **Risks and gotchas** - what could go wrong and the mitigation.
- **Deviation threshold** - the exact statement from section (e) so the implementer inherits it.
- **Approval control** - the surface the captain uses to approve.

Run planning on the dispatch profile that matches planning and scout work, per AGENTS.md section 4 and the dispatch profiles.

## (d) Approval and dispatch

No implementation crewmate runs before the captain approves the plan in the review surface.
Once approved:

1. Write the approved plan to `data/<id>/plan.md` under the active home.
2. Scaffold the brief with `bin/fm-brief.sh <id> <repo> --plan data/<id>/plan.md`, then replace `{TASK}` with the task description, acceptance criteria, and context per AGENTS.md section 11.
   fm-brief resolves a relative `--plan` path against the current working directory, so the `data/<id>/plan.md` form above is correct only when invoked from the active firstmate home; from any other directory, pass the plan's absolute path.
   The `--plan` block already carries the binding-plan declaration and the deviation threshold, so do not restate them in the task text.
   If the task touches firstmate's own shared tracked material, add the `firstmate-coding-guidelines` load instruction by hand as section 11 requires.
3. Spawn exactly one crewmate for the issue through `bin/fm-spawn.sh` on the execution dispatch profile, after the profile and backend checks in AGENTS.md section 4.
4. Record the work item on the backlog and hand off to normal supervision under AGENTS.md section 8.

## (e) Ship rules

The crewmate follows the project's selected delivery path to a single PR; there is one PR per issue, opened only after the issue is done.

Deviation threshold, carried verbatim into every plan artifact:

- **Minor mechanical deviations** (wording, ordering, naming): adapt, and disclose EVERY one where the delivery path surfaces it - the PR body under "Deviations from approved plan" for a PR-producing mode, or the final ready-branch done summary for local-only.
- **Material deviations** (a different approach, files added or dropped, changed success criteria): STOP, append `needs-decision: plan deviation - {summary}` to the status file, and wait for re-approval.

PR hygiene:

- Body structure: What, Why, Changes, Verification.
- `Closes #N` for the issue so it auto-closes on merge.
- At least one label from the repo's existing taxonomy (`gh-axi label list`); do not invent labels.
- No AI attribution anywhere in the PR body or commits, and no co-author trailer.
- No references to the internal validation pipeline or its step names in the PR or commits.

The captain merges; the `yolo` carve-outs in AGENTS.md section 7 are unchanged, and destructive, irreversible, or security-sensitive choices still escalate.
Teardown and backlog update follow the normal lifecycle in AGENTS.md section 7.
