---
name: review-round
description: >-
  Sweep every open pull request the captain is a requested reviewer on or the author of, review each one, and bring back one consolidated per-project decision surface.
  Use when the captain invokes /review-round or asks for a pull-request review round, a review sweep, "what needs my review", or "review my open PRs".
user-invocable: true
metadata:
  internal: true
---

# review-round

A review round produces verdicts, never fixes, and it is a distinct deliverable from a ship or a scout: reviewing his own or someone else's pull request is evidence for a decision, not authorization to change code.
The one standing exception is stated below under Self pull requests.
This skill is the single owner of that procedure.

## Build the inventory

Discover both classes with `gh-axi search prs`, scoped to the requested-reviewer and authored-by facets for the captain's handle, state open.
They are handled differently:

- **Incoming** - someone else wrote it, the captain is the requested reviewer.
  The verdict becomes the review he posts under his own name, so firstmate must get it right before it reaches him.
- **Self** - the captain wrote it.
  He wants defects found, not reassurance.

The authored-by search reaches back years and surfaces old contributions to repositories that are not part of the fleet.
Scope the round to projects registered in `data/projects.md` plus anything the captain names in the request, and report what was excluded rather than silently dropping it.

Before dispatching a reviewer, check whether the pull request already has a report from an earlier round and an existing review decision under the captain's account.
A pull request already reviewed and still waiting on someone else is not re-reviewed.
Re-asking a question already answered is the specific failure this skill exists to prevent.

## Dispatch one reviewer per pull request

Each reviewer is a scout: it produces a report, never a pull request, per `AGENTS.md` section 7.
Effort follows consequence, not diff size.
Raise it where a mistake would cause an outage, data loss, a security hole, or a change that is hard to reverse.
Keep it low where the change is documentation or is fully covered by a gate that actually runs.
A two-line change to an account-lockout policy deserves more thought than a hundred lines of docs.

Require every reviewer's brief to enforce:

1. **Diff against the pull request's own base branch, never `main`.**
   A stacked pull request reviewed against `main` shows its parent's changes as its own and produces findings that are not about the change under review at all.
2. **Treat a passing check as evidence only about what it actually ran.**
   Establish which workflow produced the check and whether that workflow exercises the changed files at all - a job defined in one workflow says nothing about a change to a workflow that fires only on a tag push or a comment trigger.
   The reviewer's verdict must say explicitly whether the change was genuinely exercised, and say so plainly when it was not, rather than letting a green tick imply confidence it does not carry.
3. **Never speak to GitHub.**
   No comment, no review, no approval, no push, no merge.
   The reviewer's only output is its report; firstmate delivers the verdict after the captain decides, which keeps his name off anything he has not seen.

## Consolidate into one decision surface

Build one Lavish page per project, grouped by project, and never publish a second competing page for a repository already covered by an open one - check `lavish-axi`'s session list first.
The page must be self-contained: he decides from it alone, with no need to open a pull request or ask what a change was about, and every explanation assumes no prior knowledge of the change.
Open with a status summary that separates what is already done and needs nothing from him from what needs his input.
Every option set names exactly one `(Recommended)` choice with a one-line reason, and always leaves a free-text way to answer in his own words or ask for more explanation first.

Load `decision-hold-lifecycle` before treating the round as complete: each verdict that needs the captain's word is an unresolved decision from a structured review under that skill's own definition, and it owns the hold-and-resolve mechanics.

## Self pull requests

Standing arrangement: real defects found in the captain's own pull requests may be fixed afterward through the project's normal delivery path, at the project's registered delivery posture.
The merge always needs his explicit word regardless of that project's `yolo` posture - this is a standing exception to the ordinary routine-gate authority in `AGENTS.md` section 7, scoped to review-round merges only.

## Drive the round to landing, not back to him

Approved means merge it.
Rejected means the fix is made and the review is re-requested.
The round is not finished when the verdicts are delivered - it is finished when every pull request in it has either landed or is genuinely waiting on a named other person.
State that name; a pull request left waiting on an unnamed human stalls invisibly.
A pull request opened without a reviewer stalls the same way, so assign one at delivery.

Two merge-mechanics traps cost real time:

- A repository whose code-owner rule names the captain as its only owner cannot merge normally, because the code-owner gate refuses every merge where the only possible approver is the author.
  Point at the project's existing merge helper first (`bin/fm-pr-merge.sh` for a task-owned pull request, `gh-axi pr merge` otherwise); an administrative override is the exception for this specific trap, taken only with the captain's explicit word, never the default path.
- Where a ruleset requires branches to be up to date, merging one pull request invalidates every other open pull request's up-to-date status.
  Plan a batch as update-branch-then-wait, once per pull request (`gh-axi pr update-branch`), never as a single merge-them-all step.

## Report staleness as its own finding

Report pull requests that have been open a long time as a finding in their own right, stating what each is waiting on, distinct from any defect in the change itself.
Ten stale pull requests are a problem about the process, not about any one change, and that pattern only surfaces if every round looks at the whole inventory rather than only what changed since the last one.
