---
name: merge-conflict-arbitration
description: >-
  Agent-only protocol for reconciling a merge conflict between two parallel lanes that touched the same file.
  Use when two concurrently dispatched tasks conflict on the same file and a merge or rebase conflict needs reconciliation.
  Owns the third-party arbiter, the verbatim-intent inputs, the three-class per-hunk taxonomy, the conflict-regions-only impartiality contract, the decision summary, and the repeated-conflict hotspot signal.
user-invocable: false
metadata:
  internal: true
---

# merge-conflict-arbitration

Load this when two parallel lanes have touched the same file and a merge or rebase conflict between their branches needs reconciliation.
It does not change who may merge: section 7's delivery paths and merge authority remain in force, and the arbiter only prepares a resolution for that existing authority.

## Why a third party

A lane's own worker must never resolve a conflict against a peer lane's work.
It lacks the peer's context and carries a structural bias for its own side, so it either overwrites the peer or abandons its own change.
Dispatch the reconciliation to a third-party agent that authored neither side.

## Inputs the arbiter must receive

Give the arbiter both diffs and both intents verbatim.
Intent means the declared purpose of each side in its authors' own words: the task briefs, the PR bodies, and failing those, the commit messages.
A resolution made from diffs alone is guessing at intent and is not arbitration.

## Per-hunk taxonomy

The arbiter classifies every conflicted hunk into exactly one of three classes:

- **disjoint-intent** - the two sides answer different questions in the same region; combine both changes.
- **same-question-different-answer** - the two sides answer the same question differently; pick ONE side's answer based on the stated intents, never synthesize an unrequested hybrid, and expose the choice to veto in the summary.
- **superseded** - one side's change makes the other's obsolete; keep the survivor.

## Impartiality contract

The arbiter touches only the regions in conflict.
It does not refactor, restyle, or improve either side's non-conflicting code, however tempting the adjacency.

## Deliverable

The arbiter returns a summary enumerating every hunk decision: the class assigned, the choice made, and the intent evidence behind it.
Every same-question-different-answer choice in that summary is exposed to veto by the authority that owns the merge, so route the summary there before the resolution lands.

## Hotspot signal

Repeated conflicts on the SAME file across dispatches are a signal that the file is a hotspot to decompose, not routine reconciliation.
Surface that signal as its own finding instead of silently arbitrating the same file again.
