---
name: refactor-campaign
description: >-
  Agent-only method for large multi-PR refactor or realignment campaigns.
  Load before planning or executing a campaign that will span many pull requests, several waves of crew, and more than one delivery day.
  Owns adversarial planning, authoring fresh at final vocabulary, validate-whole-then-drip delivery, written campaign law with one decision authority, and the operational patterns a stacked campaign needs.
user-invocable: false
metadata:
  internal: true
---

# refactor-campaign

Use this method when one body of work must be restructured across many pull requests, several waves of crew, and more than one delivery day.
It is the single owner of Firstmate's campaign shape; the ordinary task lifecycle in `AGENTS.md` section 7 still owns intake, dispatch, supervision, and merge authority for each individual slice inside the campaign.

## Scope

This skill owns campaign-level orchestration only: how the whole body of work is planned, sliced, proven, and sequenced.
It deliberately owns nothing about how one pull request is shepherded to landing, and nothing about the quality loop a worker runs inside a single task.
Those are separate altitudes with their own owners; compose with whichever ones this fleet has installed and never restate their procedure here.

## When not to use this

A small change, a single-concern fix, or anything that lands in one pull request needs none of this.
The ordinary lifecycle already covers those, and campaign machinery on a one-PR change is pure overhead.
Reach for the campaign shape only when the work genuinely cannot be reviewed, validated, or landed as one unit.

## 1. Plan first, adversarially

Commission exactly one planning investigation before any implementation, on the strongest reasoning class available, and give it the campaign's stated goals as its north star.
Its deliverable is two things.

The first is an abstraction audit.
Every abstraction in the carved surface is either kept or cut, and every verdict carries one sentence of deletion-test evidence: delete it, and name the complexity that reappears.
If nothing reappears, it goes.
Each keep also names which campaign goal it serves; an abstraction that cannot name its goal does not belong in the campaign.
An audit written this way shrinks the work before a single slice is authored, because most cuts remove diff rather than adding it.

The second is a file-level slice map.
Every slice states its one concern, its carve source, its base, its dependencies, its approximate size, and why the configured automated reviewer can approve it alone.
Size the slices to that reviewer's approval capacity rather than to conceptual tidiness, because a slice no reviewer can approve is a slice that does not land.
The map also states a dependency graph and a single linear ordering for the stack, so every branch has exactly one parent and the eventual landing order is already decided.

Choices the captain owns surface in the plan as explicit decision items, each with a stated default the plan proceeds on until overridden.
That keeps planning unblocked while the captain still owns every real choice, and it follows the durable unresolved-decision contract in `decision-hold-lifecycle`.

## 2. Author fresh at final vocabulary

When naming or design decisions supersede work already in flight, do not ship rename or transition pull requests on top of it.
Close the superseded work and carve its validated content into new single-concern slices written directly in the final vocabulary, with the audit's cuts applied at authoring time.
Carving means copy, rename, and apply the listed cuts, not replaying the original commits.

The resubmission is the cheapest simplification moment the code will ever have.
Every cut applied while authoring costs nothing; the same cut applied later costs a migration.
Authoring fresh also removes compatibility shims from existing: a shim exists only because a file with the same name was rewritten in place, and new files from birth never need one.
Old work is closed rather than merged, and closing is a captain-sequenced action like any other.

## 3. Validate whole, then drip

Do not land the campaign incrementally as it is authored.

1. Author the entire stack first as stacked draft pull requests along the planned spine.
   Nothing merges during authoring, and the stack tip assembles the complete result.
2. Prove the assembled tip empirically in the real product before any merge: run the actual end-to-end scenarios a user exercises, in the real runtime, with any paired cross-repository changes in place, and capture evidence.
   Unit tests alone are not proof.
   An empirical gate catches what no unit test can, because unit suites run against the shapes the code was written for while the gate runs against how the product is actually built, installed, and operated.
3. Then land bottom-up, one slice at a time: undraft the lowest slice, let the configured reviewer approve it, merge under the normal authority, rebase its children, repeat.
   These reviews are low-risk precisely because the assembled behavior is already proven.
4. A validation failure freezes the landing sequence: fix the owning slice, re-run the affected scenario, and only then start or resume.
5. If a slice changes materially during its own review, re-check the affected scenario on the rebased stack before landing anything above it.

Record what the gate did not cover as explicitly as what it did, and say which later claims remain unproven until that coverage exists.
A purely mechanical root slice with a compatibility alias may land ahead of the gate when the captain says so, but that is a captain decision, not a default.

## 4. Written law and one decision authority

Campaign constraints, the closed naming table, and the delivery rules live in files, and every brief cites them.
A brief that restates them instead of citing them will drift the moment one copy is edited.
State plainly which decisions are settled and must not be relitigated, so successive crews stop re-deriving them.
Close naming before authoring begins; a partially closed vocabulary produces slices that must be renamed later, which is exactly what section 2 exists to avoid.

Every crew escalates its gate findings upward under the normal ask-user contract, and the implementation worker never answers its own finding.
Firstmate rules against the campaign's recorded intent, using `ask-user-authority`, and obtains the captain's decision whenever the finding would expand the accepted contract.
Rulings are keyed and durable so they can be cited by later slices, and a ruling later found wrong is corrected through the pipeline like any other finding rather than by hand-editing around it.

## 5. Operational patterns

- Stacked branches must skip the delivery pipeline's default-branch rebase step; rebasing a stacked lane onto the default branch drags parent commits into the child's pull request and drifts its base.
- Some stack artifacts are accepted rather than fixed: extra commit counts, merge commits, and base drift on already-run lanes are documented per pull request and dissolve naturally when children rebase during the bottom-up landing.
- Concentrate expected conflicts deliberately: where many slices must touch one shared build or index file, have each slice append one self-contained fenced block so conflicts become append-order trivia.
- Under worker, allocator, or disk pressure, repurpose parked workers that already hold warm build trees instead of allocating fresh ones, and reclaim finished lanes' build artifacts between waves.
- Verify each allocated isolated copy against the recorded runtime state after every spawn rather than trusting the allocation.
- A long external wait during a campaign is a declared pause, not a silent idle, so supervision leaves the waiting worker alone instead of treating it as stuck.
