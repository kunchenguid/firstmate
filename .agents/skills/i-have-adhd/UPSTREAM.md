# i-have-adhd vendored upstream

`SKILL.md` and `LICENSE` in this directory are verbatim copies vendored from <https://github.com/ayghri/i-have-adhd>, pinned at upstream commit `839872f9d1cd634fed642b4589ce7226199cc15f` on `main` (2026-09-19), under the MIT license.
They pin the exact upstream text behind the always-on captain-facing answer-shape contract in `AGENTS.md` section 9, so that contract's source cannot drift.
This directory is a pinned reference, not a load-triggered firstmate skill: the binding contract is the distilled block in section 9, which applies unconditionally to every captain-facing answer.
It is deliberately absent from `skills-lock.json`, which is the external skill installer's own record of what it installed.

## Deliberately left out of the section 9 distillation

- The persistence clause and the `/i-have-adhd` / "stop adhd mode" toggle: the style is always on, so the vendored toggle is not adopted; section 9's precedence clause states explicitly that those phrases and the invocation path never disable the contract.
- The "What ADHD changes about reading" rationale section: motivating context, not output rules.
- All bad/good example pairs: the distilled rules carry only the operative change.
- The "When to break the rules" overrides: explaining fully on request, confirming destructive actions, stopping a debug spiral, and asking one clarifying question are already owned by existing firstmate contracts and skills, and upstream-vs-local rule conflicts are covered by the precedence clause in the distilled block.
- The "Pre-send check" procedure: its substance lands inside the distilled bullets rather than a separate checklist.
- Harness and task-tool guidance: firstmate has its own harness and task-tracking conventions.
