---
name: comment-audit
description: >-
  Agent-only adversarial comment-audit pass over an implementation's diff.
  Load before treating an implementation as review-ready.
  Owns the read-only comment-rot findings contract (narration, commented-out code, stale claims, workaround sermons, lint-suppression abuse), the small keep-list, and the worker's root-cause fix procedure.
user-invocable: false
metadata:
  internal: true
---

# comment-audit

Run this pass before treating an implementation as review-ready, on the project whose delivery path is about to receive the work.
This skill is the single owner of the comment-audit contract.
It exists because comments rot faster than code: narration duplicates what the code says, commented-out code becomes an archaeology trap, claims drift from behavior, workaround justifications fossilize bugs, and lint suppressions silently widen into blanket exemptions.

## Scope

Audit the task's diff: the files the implementation changed, or the current diff against the task's base branch including the working tree when no file list is at hand.
Never audit files the task did not touch.
If the task scope is unclear, resolve it from the brief before spawning anything.

## Spawn the auditor

Spawn one fresh-context read-only reviewer subagent (the fleet's standard read-only review delegation, per the project's delegation policy) and pass it this scope.
Do not restate this skill's rules in the spawn prompt; the subagent loads this skill itself.
The auditor reads and reports only: it never edits files, never runs state-changing commands, and never answers questions outside the comment-audit scope.

## What the auditor flags

Flag only comments and comment-adjacent rot, each with file, line, the quoted comment, the reason it rots, and a proposed root-cause fix:

- **Narration** - comments that restate what the adjacent code already says.
- **Commented-out code** - dead code kept as prose instead of deleted; history tools own recovery.
- **Stale claims** - comments that contradict current behavior, name moved symbols, or document limits the code no longer has.
- **Workaround sermons** - comments justifying a local workaround ("needed because X breaks", "do not remove") where the underlying cause may be fixable.
- **Suppression abuse** - lint, type, or test suppressions that exceed the exact hazard: blanket disables, suppressions carried from copied code, or suppressions hiding a correctness or safety concern.

## The keep-list

Never flag, and never accept a flag against: license and legal headers, public-API contract comments that bind external callers, and external-behavior gotchas about things the code cannot change (upstream bugs with a reference, platform quirks, wire-format constraints).
A constraint keep survives only with proof the constraint is real and outside the task's control.

## Adjudicate

The implementation worker that invoked the audit adjudicates: inspect each flag against the code before accepting it.
Reject flags that treat keep-listed comments as guilty, misstate why a suppression exists, or propose restoring prose where structure belongs.
A stale-claim flag stays actionable even when the fix is deleting the comment; a suppression flag stays actionable when it hides a correctness or safety concern.
If a flag is ambiguous, resolve it from the code, not from the comment's self-description.

## Fix at root cause

The invoking implementation worker fixes every accepted finding inside its own task scope - never a firstmate supervisor and never the auditor subagent, which stays read-only throughout.
Fix in this order of preference:

1. Delete: dead paths, dead parameters, comments whose content is already in the code.
2. Encode: replace a prose constraint with structure - a type, an assertion, a test, a lint rule - so the code enforces what the comment claimed.
3. Root-cause: remove the workaround the sermon was justifying when its cause is in scope.
4. Bound: shrink a suppression to the narrowest span that covers the real hazard, with a reason naming that hazard.

Never bolt on a symptom guard, never widen the task's scope to chase a root cause outside it, and never fix an instance the diff does not contain.
When the root cause is out of scope, land the smallest in-scope fix, keep the narrowed comment only if a keep-list exception holds, and report the remainder as open work.

## Verify and report

Run the project's checks after fixing, exactly as the selected delivery path requires.
Report the deletion count, encodings added, suppressions narrowed or removed, keeps preserved with their proof, and open out-of-scope findings.
Carry open findings into the task report instead of leaving them only in chat.
