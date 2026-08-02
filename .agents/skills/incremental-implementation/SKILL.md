---
name: incremental-implementation
description: Delivers multi-file application and tool changes in thin, testable, rollback-friendly slices. Use when implementing a feature, refactoring a subsystem, or changing more than one file.
metadata:
  internal: true
  adapted-from: addyosmani/agent-skills@7829ffd90d973b6325f5f12f1b1226dcace74443
---

# Incremental Implementation

This is a Firstmate-adapted application-engineering skill inspired by Addy Osmani's agent-skills project.

Firstmate's AGENTS.md owns project resolution, isolation, delivery mode, supervision, approval authority, and merge rules.
This skill supplements those rules and never authorizes direct work in a primary checkout, unapproved scope expansion, or bypassing no-mistakes.

## Use when

- Implementing a multi-file feature or refactor.
- Building a new application or tool capability.
- The change is large enough that a single unverified edit would be hard to review.
- A risk-first or contract-first slice can reduce uncertainty.

## Slice cycle

For each slice:

1. Select the smallest complete behavior that can be exercised end to end.
2. Implement only that behavior and its necessary test or contract.
3. Run the repository's focused test, build, type, and lint commands that cover the slice.
4. Confirm the result against the accepted task intent and record evidence through the normal task status path.
5. Commit through the selected Firstmate delivery path before starting the next slice.

Keep each slice working and independently understandable.
Prefer vertical slices that cross the required boundaries over layers that cannot run alone.
Use contract-first slicing when independent producers and consumers need a stable interface.
Use risk-first slicing when an integration, migration, or external dependency is uncertain.

## Scope and design rules

Ask what the simplest correct implementation is before adding an abstraction.
Keep unrelated cleanup, modernization, and speculative features out of the slice.
Prefer a straightforward implementation until a third use case proves an abstraction earns its cost.
Use safe defaults for incomplete or opt-in behavior.
Keep changes additive and rollback-friendly where possible.
Separate deletion or migration from replacement when that makes rollback safer.
Do not restart or replace an active no-mistakes run to accommodate a new requirement.

## Verification

Every slice has a focused executable check before the next slice begins.
The final change passes the repository's full test, build, type, and lint requirements.
The final diff contains no unrelated changes or temporary debugging artifacts.
Each acceptance criterion has a concrete implementation or validation result.
The selected delivery path, not this skill, owns push, PR, CI, and merge mechanics.
