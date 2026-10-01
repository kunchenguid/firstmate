---
name: skill-edit-validation
audience: swarm-plugin
description: Content-assertion sweep after editing SKILL.md files. Triggered when a task changes skill or prompt content that tests assert against. Prevents stale-assertion CI failures.
---

# Skill Edit Validation

## Trigger
After editing ANY `.md` file under `.opencode/skills/`, `.claude/skills/`, or `.agents/skills/` that changes content wording (not just whitespace/formatting).

## Protocol
1. **Extract changed phrases:** Identify old wording vs new wording (e.g., "spec.md does NOT exist" changed to "NO effective spec exists")
2. **Targeted sweep:** For each OLD phrase, grep test files:
   ```
   rg "<old-phrase>" tests/ src/ --type ts -l
   ```
   Focus on: `*-audit*`, `*-security*`, `*-spec-gate*`, `*skill-mirror*`, `*soft-spec*`, `*prompt*`, `*workflow*`
3. **For each match:** Read the assertion context (surrounding 10 lines). Verify:
   - Does the assertion still hold against the new content?
   - Is it checking a substring containing the old phrase?
   - Is it checking for the ABSENCE of a word the new wording introduces? (e.g., `not.toContain('skip')` catches "this check is skipped")
4. **Prefer the semantic registry:** If the assertion is checking skill behavior
   rather than an exact contract string, move it behind
   `tests/helpers/skill-content-registry.ts` (or add a concept there) and assert
   the named concept from the test.
5. **Update stale assertions in the same changeset.** Do NOT defer to CI.
6. **Preserve behavioral intent:** When updating, preserve what the assertion TESTS (e.g., "the plan skill has a spec-absent branch"), not just the string match.

## Constraint
Do NOT rubber-stamp brittle assertions. If an assertion tests implementation detail rather than behavioral intent, flag it for refactoring to a semantic check.

## Root cause
Skill-content tests should assert named semantic concepts where possible. The
registry in `tests/helpers/skill-content-registry.ts` is the preferred safety
net for recurring skill wording checks; use the manual grep sweep for exact
contract strings and any tests not yet migrated.
