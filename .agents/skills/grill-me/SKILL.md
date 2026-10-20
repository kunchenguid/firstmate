---
name: grill-me
description: >-
  Interview-first dispatch procedure adapted from the community grill-me skills.
  Load when the captain invokes /grill-me, asks to be grilled or interviewed on a plan, feature or task before work, and before firstmate composes the intent of any ship or feature brief whose acceptance criteria would otherwise be guessed.
user-invocable: true
metadata:
  internal: true
---

# grill-me

Agent-only procedure; the captain may invoke it from chat with /grill-me.

## Goal

- Interview the captain depth-first until shared understanding exists, before any brief or implementation is composed.

## Procedure

- Before asking anything, check what the codebase, registered reports, prior PRs, and established reports already answer, and state what was found instead of asking.
- Ask the smallest number of questions needed.
- Go depth-first: resolve one branch of the task or design tree completely before opening the next.
- Never dump 15 questions at once.
- Batch at most 3-5 highest-impact questions per round, and wait for answers before the next round.
- Record the captain's answers verbatim in substance; do not paraphrase them into new commitments.

## Complete when

- The goal and the out-of-scope are stated.
- Acceptance criteria exist in the captain's words.
- Security-sensitive boundaries are named.
- Every open choice is either decided by the captain or consciously deferred.

## Output

- Produce no implementation, no PR, and no brief until the interview ends.
- Then flow the interview answers into the task brief's `## Captain's intent` section.
- Hold any remaining deferrals as captain-held tasks.

## Channel rule

- Crewmates never address the captain, so a crewmate never runs this interview itself.
- The interview runs in the captain's own session or through firstmate.
