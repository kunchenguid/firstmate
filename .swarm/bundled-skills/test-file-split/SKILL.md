---
name: test-file-split
audience: swarm-plugin
description: Protocol for splitting test files that approach or exceed the FR-006 500-line limit (enforced in CI by scripts/check-test-file-cap.ts as a diff-scoped ratchet). Covers describe-block extraction, shared helper management, pure-function extraction, mock isolation verification, and cascading-split detection. Load when a test file approaches or exceeds 500 lines.
---

# Test File Split Protocol (FR-006)

`scripts/check-test-file-cap.ts` enforces the **500-line cap** per test file (FR-006 / SC-006.1) as a **diff-scoped ratchet**: new test files over 500 lines and existing over-cap files that grew fail the quality gate and block PR merge. Pre-existing over-cap files not touched by the PR are non-blocking. Escape hatch: `TEST_CAP_ENFORCE=0` soft-warns. This skill covers the complete splitting protocol.

Read first: `.opencode/skills/writing-tests/SKILL.md` (or `.claude/skills/writing-tests/SKILL.md`) for bun:test framework rules, mock isolation patterns, and file placement conventions.

## When to use this skill

- A test file exceeds or approaches 500 lines
- CI fails with an FR-006 file-size violation
- You are adding tests to a file that is already above 400 lines (proactive split)

## Step 1 — Measure and identify split boundaries

```bash
# Check the file
wc -l tests/unit/scripts/my-module.test.ts

# Find all test files exceeding 400 lines (early warning)
find tests/ -name "*.test.ts" -exec wc -l {} \; | sort -rn | awk '$1 > 400'
```

Identify natural `describe()` block boundaries. Group blocks by functional area:
- Each `describe()` block should belong to exactly one split file
- Shared `beforeEach`/`afterEach` hooks determine which blocks must stay together

## Step 2 — Choose a suffix for the new file

| Pattern | Example | When to use |
|---------|---------|-------------|
| `<module>-<area>.test.ts` | `release-notes-fragments-sha.test.ts` | Split by functional area (SHA resolution, validation, merge logic) |
| `<module>-<area>.adversarial.test.ts` | `auth-login.adversarial.test.ts` | Split adversarial tests into their own file |

## Step 3 — Manage shared imports and helpers

Three options, in order of preference:

1. **Extract to shared utility (preferred for complex shared setup):**
   Create `tests/helpers/<module>-shared.ts` with shared fixtures, mock factories, and setup functions. Import from both split files.

2. **Duplicate simple imports (for small overlap):**
   If only `bun:test` imports and 1-2 source imports are shared, duplicate them in both files. Simpler than a utility module for trivial cases.

3. **Extract pure functions from source (for testability):**
   If the source module has inline validation logic, extract them as exported pure functions (e.g., `isValidPrNumber`, `resolveAllCandidates`) so both test files can target them independently. See the PR #1762 example below. See `.opencode/skills/generated/safe-extraction/SKILL.md` for the source extraction pattern.

## Step 4 — Extract and move describe blocks

1. Cut the selected `describe()` blocks from the original file.
2. Paste them into the new file.
3. Add all necessary imports to the new file.
4. Remove now-unused imports from the original file.

## Step 5 — Verify both files

### Line count check
```bash
wc -l tests/unit/scripts/my-module.test.ts tests/unit/scripts/my-module-sha.test.ts
# Both must be under 500 lines
```

### Isolated run
```bash
bun --smol test tests/unit/scripts/my-module.test.ts --timeout 60000
bun --smol test tests/unit/scripts/my-module-sha.test.ts --timeout 60000
```

### Co-run (mock isolation verification)
```bash
# Critical: Bun shares a single process across test files.
# mock.module leaks can cause co-run failures even when isolated runs pass.
bun --smol test tests/unit/scripts/my-module*.test.ts --timeout 60000
```

If the co-run fails but isolated runs pass, check for `mock.module()` leakage. See `.opencode/skills/writing-tests/SKILL.md` → "Mock Isolation Rules" and the `_internals` DI seam pattern.

## Step 6 — Evaluate `_test_exports` opportunity

After splitting, evaluate whether internal utility functions in the source module can be exported via `_test_exports` for zero-mock testing. This is a natural cleanup moment — the split already forces you to review test coverage boundaries.

## Cascading split warning

If a previously split file exceeds 500 lines **again**, the test suite is structurally too large for a single module. Do not split a third time — reorganize the tests by source module boundaries instead. Repeated splitting produces fragmented test suites that are hard to navigate and maintain.

## Real-world example (PR #1762)

`tests/unit/scripts/release-notes-fragments.test.ts` exceeded 500 lines. It was split into:

| File | Lines | Content |
|------|-------|---------|
| `release-notes-fragments.test.ts` | 379 | Fragment collection, deduplication, output formatting |
| `release-notes-fragments-sha.test.ts` | 261 | `extractCommitShasFromBody`, `mergeCandidateLists`, `resolveAllCandidates`, `isValidPrNumber`, `stripCustomReleaseNotesBlock` |

The split also extracted `isValidPrNumber` and `resolveAllCandidates` as pure exported functions from the source module, enabling independent testing.
