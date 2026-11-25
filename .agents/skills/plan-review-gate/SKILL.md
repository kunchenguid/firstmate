---
name: plan-review-gate
description: Load before requesting independent plan critics, at intake before writing the ship brief for a big ship task - one that touches several subsystems, data or money semantics, a schema or migration, security, or an irreversible change, or whose captain asks for a plan review - and whenever a plan scout or plan reviewer scout of that gate reports.
user-invocable: false
metadata:
  internal: true
---

# plan-review-gate

The gate puts a written plan in front of fresh reviewers before a big ship is dispatched, so the captain decides on a reviewed plan rather than discovering its holes in the diff.
It reviews the plan only.
It never reviews the diff, never holds work outside the selected delivery path, and adds no rigor to that path.
Skip it for small or well-understood work and whenever the captain declines it; a gate that fires on everything gets ignored.

## Roles and cost

Every participant is an ordinary scout, scaffolded with `bin/fm-brief.sh <id> <repo> --scout` and launched with `bin/fm-dispatch.sh new <id> <project-dir> --scout`.
Every launch gate applies unchanged: the resolver's profile, quota and account choice, lane and project capacity, the load guard, and captain holds.
A refused or deferred launch is handled by that command's own rule and is never bypassed with a raw launch.

- The **plan scout** writes the plan, later merges the reviews into one report, and revises the plan at most once.
  Firstmate drafts neither, per section 1.
- Each **reviewer** is a fresh scout with one lens, given the review packet below and its own worktree of the project.
  It never sees the plan scout's chat, brief, full history, or merged review report.

The default gate is three runs: the plan scout plus the `claims` and `buildable` reviewers.

## 1. Plan scout

Fill the plan scout's `## Firstmate spec` with the following.

- Write the plan to `data/<id>/plan.md`, and amend the brief's rule 2 so that file is the one other write allowed outside the worktree.
- The plan carries, in order: goal; a "Prior art checked" line; numbered steps, each naming every file it touches marked `Create`, `Modify` or `Delete`, the concrete change, and the command that verifies it; interfaces, signatures, and data shapes touched; risks (security, data loss, rollback); low-confidence choices and open questions.
- When the plan is written, append `paused [at=<epoch>]: plan ready at <path>; waiting for reviewer reports` and stay live for the merge and any revision.
- On the merge steer, write the merged report described in step 4 without editing `plan.md`, then append `needs-decision [key=plan-review] [at=<epoch>]: ...` naming `data/<id>/plan-review.md`.
- On a revise answer, revise `plan.md` and append `paused` again for the one re-review.
- When the captain's decision closes the gate, write `report.md` as a short pointer to `plan.md` and `plan-review.md` plus its follow-ups, and report done.

## 2. Reviewers

When `plan.md` exists, dispatch one reviewer per lens in parallel, with task ids `<id>-<lens>` and the plan scout's base branch.

| Lens | File | Run |
|---|---|---|
| Claims versus code, plus risk | [`references/claims.md`](references/claims.md) | always |
| Buildable without guessing | [`references/buildable.md`](references/buildable.md) | always |
| Reuse and simplicity | [`references/reuse.md`](references/reuse.md) | when the plan adds a new module, abstraction, seed, or dependency |
| Cold read | [`references/coldread.md`](references/coldread.md) | when the plan's reader will lack its author's context, or the captain asks |

Each reviewer's `## Captain's intent` is the captain's ask the plan serves.
Its `## Firstmate spec` is the full text of [`references/reviewer-contract.md`](references/reviewer-contract.md) followed by the lens file, with `{PLAN}` replaced by the absolute path of `plan.md`.
Append the review packet paths and scope instruction below to each reviewer's brief.
Pass the prompt text itself, not a skill name, so a reviewer needs no skill loaded.

### Revision-aware review packet

Use this packet contract for every requested independent critic round, including Lavish plan reviews outside this default gate.
It does not change live board chat, the gate's default lenses or round limit, or the captain's requested critic count: a requested four-critic round still has four independent critics.

Before dispatch, the plan author saves a packet for the current revision containing:

- the complete current plan, with its revision identifier;
- a short decision ledger recording decisions, reasons, evidence pointers and superseded decisions;
- only the revision delta since the last requested round, naming its baseline revision, changed sections as "change X to Y", why they changed, and evidence for each changed part, including affected interfaces and risks.

Keep the prior round's baseline stable until the next packet is saved, so no intervening edit disappears from the delta.
Do not attach old conversation transcripts, earlier full plans or unchanged source dumps.
Give each critic the same packet and its own lens, without other critics' findings, and include this scope instruction in its brief:
"Use the current plan and ledger for context; verify the revision delta and its affected dependencies against the cited evidence, reading only changed or affected source sections rather than replaying unchanged history; report any resulting cross-plan inconsistency."
Evidence pointers remain available for targeted reads; if they cannot establish safety, report the gap rather than assume unchanged parts are sound.

The first round is a full-plan review.
Use full-plan review again for major changes (goal, architecture, interfaces, data or security semantics, or assumptions that invalidate earlier review), a missing or unreliable baseline, and whenever the captain asks.
Label the packet `full-plan` or `revision-delta`, state the reason and baseline, and explicitly tell each critic to review the whole current plan in full-plan mode.
Full-plan mode retains the ledger and revision delta; it does not require replaying chat history.

## 3. Not run

A reviewer whose launch is refused, that fails, that is blocked without an answer, or that ends without a report is recorded as `not run: <reason>`.
Never record it as zero findings, and never relaunch it in a loop.

## 4. Merge

When every reviewer is done or not run, steer the plan scout with `fm-send` naming each reviewer's report path or not-run reason.
The merged `data/<id>/plan-review.md` has:

- a status table: lens, task id, `completed` or `not run: <reason>`;
- findings deduplicated across lenses and grouped Blocker, Major, then Nit, each with its lenses, plan section, evidence, and recommendation;
- one note that reviewers read the project's own `AGENTS.md`, so they share its conventions.

Relay the `plan-review` decision to the captain through `captain-hold-lifecycle`, leading with Blockers and Majors; Nits stay in the file.

## 5. Captain decision and the one re-review

The captain proceeds, revises, or drops the ship.
On revise, the plan scout revises `plan.md`, and firstmate runs at most one re-review: fresh reviewers with ids `<id>-<lens>-r2`, only for lenses that raised a Blocker or Major, merged by the plan scout as a second round in `plan-review.md`.
After that round the plan goes to the captain as it stands; there is no further review loop.

## 6. Ship

Once the captain approves the plan, ship it through `scout-completion`: promote the plan scout, or dispatch a fresh ship whose brief names `plan.md` and `plan-review.md`.
Reviewer scouts finish as ordinary scouts and hold no captain decision of their own.

## Attribution

The reviewer contract and lens prompts in `references/` are adapted from [google/elephant-goldfish-model](https://github.com/google/elephant-goldfish-model), licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0).
They were condensed and rewritten for firstmate scouts: the brainstorm modes and harness-specific tool lists were dropped, and the codebase-details lens gained the design-critic risk questions.
