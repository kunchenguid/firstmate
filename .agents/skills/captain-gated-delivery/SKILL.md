---
name: captain-gated-delivery
description: >-
  Agent-only procedure for the default two-gate ship workflow: a plan gate and a deliverable gate, with full validation deferred until the captain accepts the result.
  Load at ship intake to choose the plan path, before building or refreshing a deliverable review package, before deciding validation timing, and before applying simple-ship acceleration to a fix round.
user-invocable: false
metadata:
  internal: true
---

# captain-gated-delivery

This skill is the single owner of the captain-gated delivery workflow: its default sequence, the review-lens definitions, validation timing, and the simple-ship acceleration this workflow nests inside it.
`AGENTS.md` section 7 carries only the always-loaded one-paragraph summary and this skill's trigger; every procedural detail lives here.
Origin and rationale: `data/fm-simple-ship-velocity/captain-gated-delivery-and-simple-ship-2026-08-11.md` and `data/bp-wireframe-speed-postmortem/` - historical record, not a second copy of the current contract.

The goal is captain judgment without captain supervision: firstmate owns routing, implementation, routine decisions, evidence production, and validation, while the captain participates at exactly two judgment gates.

## Default workflow

1. **Request.** The captain describes the desired outcome.
2. **Choose the plan path.** Decide whether captain review of a Big Plan would materially improve the outcome.
   Use a Big Plan when the work involves meaningful product concepts, UX direction, architecture, scope, migration, security, irreversibility, or consequential tradeoffs.
   Skip the plan gate when the intended behavior, remedy, and acceptance criteria are already clear and the work is routine or localized.
   Record the choice on the captain dashboard; when skipping, include a brief reason.
3. **Review the plan when applicable.** Prepare it and wait for explicit captain acceptance before implementation begins.
   Incorporate feedback until accepted; implementation begins from the accepted plan source.
4. **Implement and reach review readiness.** Before implementation, identify every applicable review lens (below) and capture any before-state evidence that would be hard to recreate later.
   Complete the work autonomously, running only the targeted builds, regressions, and smoke tests needed to make the result safe and credible to review.
   Defer the full validation pipeline unless risk requires it earlier (see "Validation timing" below).
5. **Run the deliverable review loop.** Build a task-owned review package under the task's `data/<id>/` evidence path using every applicable lens, and surface openable links on the captain dashboard.
   The package shows the result and how to exercise it, the evidence each applicable lens requires, decisions or tradeoffs discovered during implementation, and known limitations relevant to acceptance.
   The captain reviews the product experience, concepts, architecture, and corrected behavior - not merely whether the code passes its checks.
   Coordinate each feedback round, rerun targeted validation, and refresh the package. Continue until the captain explicitly accepts the deliverable.
6. **Reach ship readiness by selected mode.** Normally after deliverable acceptance, complete the selected delivery path's full readiness stage.
   For `no-mistakes`, run the complete pipeline: review, tests, documentation, lint, push, PR, and CI.
   For `direct-PR`, push the branch, open the PR, and reach CI green; the deliverable gate normally runs at review readiness before push, but risk may require opening the PR early just as it may require validating early.
   For `local-only`, run the project's full local checks once on the final branch - the full test suite and lint, or the project's documented equivalent - and treat those checks being green as ship readiness before the existing guarded local merge under the configured merge authority.
   Fix findings autonomously when they remain within accepted intent and existing authority (`ask-user-authority`).
   If a fix materially changes the accepted experience, behavior, or architecture, refresh the evidence and reopen the deliverable gate (step 5) before continuing.
7. **Ship.** Once the deliverable is accepted and the selected mode's ship-readiness stage is green, proceed under the existing merge authority (AGENTS.md section 7's selected delivery path and approval authority; this workflow never invents a second one).

## Review lenses

Use every lens that applies - a feature may need both product-concept and architecture review; a bug fix may also change the UI.
Store review artifacts under the task's `data/<id>/` evidence path and surface openable links on the captain dashboard; evidence belongs to the task, never parked only inside another lane's plan or review document.

**Feature or product-concept review** - show the working experience through an openable preview, representative walkthrough, screenshots, or recording.
Explain the product model introduced or changed: new concepts, categories, and vocabulary; relationships among those concepts; important states, transitions, and rules; how those ideas appear in the experience; and consequential choices, alternatives, or limitations.
The captain should be able to judge both how the feature feels and whether its conceptual model is coherent.

**Architecture review** - provide a before/after summary of the affected architecture: modules, layers, and ownership boundaries; dependencies, data flow, and important seams; responsibilities that moved or changed; rationale for the chosen structure; tradeoffs and rejected alternatives; and known limitations or follow-up pressure.
Use diagrams, file trees, code links, or annotated diffs when they make the change easier to understand.
The captain should be able to judge the structure without reconstructing it from the patch.

**Bug-fix review** - demonstrate the same reproducible scenario before and after the fix.
For user-observable bugs, paired short recordings are the default: one reproducing the bug, one repeating the same scenario showing the corrected behavior, with equivalent inputs and environment so the difference is clear.
When recording is not meaningful or practical, provide the closest paired evidence instead - failing and passing tests, command transcripts, logs, traces, or request/response captures - and state why recordings were omitted.

**Other work** - use the artifact that exposes the meaningful result: rendered pages for documentation; transcripts or runnable examples for CLI and API changes; measurements and traces for performance work; or behavioral tests and before/after dependency evidence for internal changes.

Skip the deliverable gate only when no meaningful human judgment can be exercised over the result, and record the reason on the captain dashboard.
A change being technical is not sufficient by itself to skip review: if its behavior or structure can be demonstrated, demonstrate it.

## Validation timing

Validation has two stages:

- **Review readiness** - fast, targeted checks that make the deliverable credible and safe to review (step 4).
- **Ship readiness** - the selected delivery mode's full readiness stage, normally run after the captain accepts the deliverable (step 6).

This ordering avoids repeatedly paying for full validation while product feedback is still changing the work.
It does not weaken safety requirements, CI, external review, or merge authority: the bars that stay untouched are full review for product-facing UI, browser or equivalent regressions with evidence for visual changes, never merging red, and captain ownership of the merge.
Start the selected readiness stage earlier than step 6 when risk warrants it - this ordering is a default, not a rule that overrides judgment about genuine risk.

## Simple-ship acceleration

The captain-gated delivery workflow applies to every ship; this section only accelerates routine parity findings and fix rounds inside it.

A simple ship is small, localized, behavior-preserving work that completes an accepted parity, fill, or alignment remedy family.
If classification is uncertain, use the normal authority and validation path - ordinary ships remain non-yolo, and this is the only autonomous exception.

**Autonomous parity fixes** - load `ask-user-authority` before deciding any ask-user finding; it owns the exact four-condition test and the mandatory dashboard-plus-chat callout for exercising this authority.
This workflow is what makes that authority standing rather than a per-project opt-in.

**Light-touch fix verification** - for each simple-ship review round:

1. Collect the review's findings into one fix batch.
2. Apply the batch in one fix pass.
3. Run the named regressions for the fixes in that batch.
4. After the final fix batch, run the full suite once.
5. Re-review the fix commits or fix range, not the entire branch.

CI and external review remain independent backstops.
Use this operating pattern before adding deeper no-mistakes automation; change the pipeline only when repeated use demonstrates a specific gap.

**Decision-key grammar** - workers open decisions as `needs-decision [key=<slug>]: <summary>` and close them as `resolved [key=<slug>]: <how>`, key before the colon.
`bin/fm-brief.sh` emits this form and `bin/fm-classify-lib.sh` owns extraction (including tolerating a mis-ordered legacy key found in the note); this skill only points at that contract, it does not restate it.

**Scan-complete briefs** - parity briefs define the remedy family with a scan instruction instead of treating an enumerated site list as the scope boundary: what pattern or language to search for, what treatment to apply, and the exhaustive done condition.
Known sites may be included as examples, but they do not limit the scan.
A missed member of the defined family remains in-scope parity work, not new product scope.
`bin/fm-brief.sh`'s generated "Completeness for parity-style work" section is the current text; this skill does not duplicate it.
