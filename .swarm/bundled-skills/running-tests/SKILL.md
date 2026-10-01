---
name: running-tests
audience: swarm-plugin
description: >
  Safe test execution patterns for opencode-swarm. Covers when to use the test_runner
  tool vs shell bun commands, scope safety rules, per-file isolation loops (bash and
  PowerShell), pre-existing failure verification, CI log reading, and failure
  classification. Load this skill when you need to run tests — not when you need to
  write them (see writing-tests for authoring guidance).
---

# Running Tests for opencode-swarm

This skill is about **executing** tests safely. For **writing** tests, see `writing-tests`.

## Graph-first evidence contract

Use `repo_map` `test_pack` only to discover focused candidate tests; Bun/shell output remains execution authority. Graph evidence is advisory only. If freshness is stale or inconclusive, confidence is low, source is missing, the language is unsupported/dynamic, the graph is absent, or the action fails, select tests from direct source, imports, and repository conventions.

---

## ⛔ The Scope Rule That Prevents Session Kills

`convention` discovery accepts one source file at a time (or explicit direct test
files). `graph` and `impact` discovery accept a bounded normalized source array of
up to `MAX_SAFE_TEST_FILES = 50`. Do not exceed that input cap or respond to
`scope_exceeded` by widening to `scope: 'all'`.

The final unique resolved-test cap still binds for every discovery scope: when
resolution produces more than 50 test files, `test_runner` returns
`scope_exceeded` without executing them. Split a larger graph/impact selection
into intentional bounded batches.

---

## Three-Layer Defense Against Session Blocking

test_runner bounds source selection and resolved test execution before a session can fan out without limit:

### Layer 1 — Scope-specific normalized-input guard
`convention` rejects more than one source file for convention discovery. `graph`
and `impact` reject more than `MAX_SAFE_TEST_FILES = 50` normalized source files
before fan-out. Explicit direct test files remain allowed for convention scope.

### Layer 2 — Advisory resolution estimate
For `graph` and `impact`, `estimateFanOut(sourceFiles, workingDir)` reads the
cached impact map and reports a bounded, advisory count of unique candidate tests
without spawning subprocesses. Resolution metadata preserves whether the estimate
was advisory or unavailable and any cache status; it is not a substitute for the
final cap.

### Layer 3 — Bounded traversal + final unique-test check
Graph and impact traversal are bounded to the safe budget and report
`scope_exceeded` when the budget is exceeded. After fallback, normalization, and
deduplication, the final unique `testFiles.length` is compared with
`MAX_SAFE_TEST_FILES`; an excess returns `scope_exceeded` before execution.

**Result:** When fan-out exceeds the safe threshold, the session gets `outcome: 'scope_exceeded'` instead of hanging.

---

## Decision Tree: test_runner tool vs bun shell command

```
Do you need to run tests?
│
├─ Single test file, targeted validation
│   └─ Either works. Prefer shell: bun --smol test <file> --timeout 30000
│
├─ Multiple test files in the same directory (e.g. all agents tests)
│   └─ Shell only — per-file loop. These are explicit test files, not graph/impact sources.
│
├─ Find tests related to ONE OR MORE changed source files (up to 50 normalized files)
│   └─ test_runner is fine: { scope: 'graph', files: ['src/agents/coder.ts', 'src/tools/test-runner.ts'] }
│      (graph/impact input is bounded; final unique resolved-test cap still applies)
│
├─ Find tests related to MORE THAN 50 changed source files
│   └─ Split into intentional bounded graph/impact batches or use a shell loop.
│      Do not use scope:'all' as a fallback.
│
└─ Validate the entire repo (pre-push)
    └─ Shell only — 5-tier suite from commit-pr skill. Never test_runner scope:'all'.
```

---

## Scope Safety Reference

| Scope | With `files: [one]` | With `files: [many]` | Notes |
|-------|--------------------|--------------------|-------|
| `'convention'` | ✅ Safe | ❌ Rejected for multiple source files (`scope_exceeded`) | One source file for convention discovery; direct test file paths exempt |
| `'graph'` | ✅ Safe | ✅ Up to 50 normalized source files; >50 rejected | Advisory estimate and bounded traversal; final unique resolved-test cap still applies |
| `'impact'` | ✅ Safe | ✅ Up to 50 normalized source files; >50 rejected | Advisory estimate and bounded traversal; final unique resolved-test cap still applies |
| `'all'` | ❌ Never | ❌ Never | Env-gated (`SWARM_ALLOW_FULL_SUITE=1`); CI mirror only |

**Rule of thumb:** Pass one source file to `convention`; pass a normalized array of
at most 50 source files to `graph` or `impact`. Use a shell loop or intentional
batches when the source selection or final resolved test set exceeds 50.

For one named Go or CTest test, bypass file discovery with an exact native selector:

- Go: `{ scope: "target", native_target: { framework: "go-test", name: "TestName[/Subtest]", path: "relative/package" } }`
- CTest: `{ scope: "target", native_target: { framework: "ctest", name: "ExactTestName", path: "relative/build-dir" } }`

The target name is treated literally, the directory must stay within the project root, and the runner never falls back to a broader package or build-tree sweep.

---

## Per-File Isolation Loops

CI runs agents/tools/services in per-file isolation (one `bun --smol` process per file).
Reproduce this locally with the following loops.

### bash (Linux / macOS)

```bash
# Single directory — per-file isolation
for f in tests/unit/agents/*.test.ts; do
  bun --smol test "$f" --timeout 30000
done

# Multiple directories
for dir in tests/unit/tools tests/unit/services tests/unit/agents; do
  for f in "$dir"/*.test.ts; do
    bun --smol test "$f" --timeout 30000
  done
done

# Stop on first failure (useful for debugging)
for f in tests/unit/agents/*.test.ts; do
  bun --smol test "$f" --timeout 30000 || { echo "FAILED: $f"; break; }
done
```

### PowerShell (Windows)

```powershell
# Single directory — per-file isolation
Get-ChildItem tests/unit/agents/*.test.ts | ForEach-Object {
  bun --smol test $_.FullName --timeout 30000
}

# Multiple directories
@('tests/unit/tools', 'tests/unit/services', 'tests/unit/agents') | ForEach-Object {
  Get-ChildItem "$_/*.test.ts" | ForEach-Object {
    bun --smol test $_.FullName --timeout 30000
  }
}

# Capture output (avoids truncation on large output)
Get-ChildItem tests/unit/agents/*.test.ts | ForEach-Object {
  bun --smol test $_.FullName --timeout 30000
} | Out-File "$env:TEMP\test_out.txt"
Get-Content "$env:TEMP\test_out.txt" | Select-Object -Last 50
```

**Common PowerShell pitfalls:**
- `for f in ...; do` — invalid, use `Get-ChildItem | ForEach-Object`
- `Select-String -Last N` — invalid parameter, use `Select-Object -Last N`
- `2>&1 2>&1` — duplicate redirection, causes parse error; use `2>&1` once
- `&&` — not supported in PowerShell 5.1; use `; if ($?) { cmd2 }` instead
- `bun test --exec bash` — fails on Windows hosts with ENOENT (bash is not available in standard PowerShell). Use `bun test` directly or a PowerShell-based loop instead.
- After `bun install --frozen-lockfile --force`, non-elevated Windows shells can hit `EPERM` while reading refreshed `node_modules` entries. Treat that as a host permission/access issue: rerun the same focused Bun command with approved/elevated access before diagnosing it as a code or test failure.

---

## Batch vs Per-File: Which Directories Need Isolation?

| Directory | Mode | Reason |
|-----------|------|--------|
| `tests/unit/tools/` | Per-file loop | Heavy `mock.module` usage; cache poisoning risk |
| `tests/unit/services/` | Per-file loop | Same |
| `tests/unit/agents/` | Per-file loop | Same |
| `tests/unit/hooks/` | Per-file loop | Same |
| `tests/unit/cli/` | Batch OK | Fewer mock conflicts |
| `tests/unit/commands/` | Batch OK | Fewer mock conflicts |
| `tests/unit/config/` | Batch OK | Fewer mock conflicts |
| `tests/integration/` | Batch OK | Integration fixtures, not mock-heavy |
| `tests/security/` | Batch OK | Adversarial inputs, no module mocks |
| `tests/smoke/` | Batch OK | Built-package tests |

---

## Truncated Output Recovery

When `bun test` output exceeds the bash tool's buffer, it is saved to a file with an ID
like `tool_dff778...`. This ID format is **not** accepted by `retrieve_summary` (which only
reads `S1`, `S2` etc. format IDs). The output is effectively lost.

**Prevention — pipe to a file explicitly:**

```powershell
# PowerShell
bun --smol test tests/unit/agents --timeout 60000 |
  Out-File "$env:TEMP\test_out.txt"
Get-Content "$env:TEMP\test_out.txt" | Select-Object -Last 50
```

```bash
# bash
bun --smol test tests/unit/agents --timeout 60000 2>&1 | tee /tmp/test_out.txt
tail -50 /tmp/test_out.txt
```

**To get a clean pass/fail summary only**, filter immediately:

```powershell
# PowerShell — show only summary lines
bun --smol test tests/unit/agents --timeout 60000 |
  Select-String "pass|fail|error" |
  Select-Object -Last 10
```

```bash
# bash
bun --smol test tests/unit/agents --timeout 60000 2>&1 | grep -E "pass|fail|error" | tail -10
```

---

## Verifying Pre-Existing Failures

Before documenting a failure as "pre-existing," prove it exists on `main` without affecting
your working tree. Use a Git worktree — safer than `git stash` (stash can drop untracked
files, fail on locked files on Windows, and leave you in an inconsistent state).

```bash
# bash — create a throwaway checkout of main
git worktree add /tmp/repro-check origin/main
bun --smol test /tmp/repro-check/tests/unit/agents/architect-workflow-security.test.ts --timeout 30000
git worktree remove /tmp/repro-check
```

```powershell
# PowerShell — same pattern (use Join-Path for robust separator handling)
git worktree add "$env:TEMP\repro-check" origin/main
$testPath = Join-Path "$env:TEMP\repro-check" "tests\unit\agents\architect-workflow-security.test.ts"
bun --smol test $testPath --timeout 30000
git worktree remove "$env:TEMP\repro-check"
```

**Decision after checking:**
- Fails on `main` too → pre-existing. Document under `## Pre-existing failures` in PR body. Continue.
- Fails only on your branch → you introduced it. Fix before pushing.

**⚠️ Check your own session history first.** Before documenting anything as pre-existing, confirm you did not fix or update this test earlier in the current session. A test you fixed 20 messages ago is not pre-existing — listing it as such in the table or PR body is incorrect and will be caught in review.

---

## Placeholder Scans Without Diff Line Numbers

`placeholder_scan` is diff-aware: when you can supply `added_lines` (a map of workspace-relative file path → added line numbers from the task/PR diff), its verdict covers only the added lines, so a pre-existing TODO/FIXME on an unchanged line inside a changed file no longer fails the gate. When you CANNOT map a file's added lines (new/untracked file, no diff access) — or the computed added-line set is EMPTY — omit that file from `added_lines` entirely: the tool scans it unfiltered, fail-closed, and you manually cross-check that file's findings against the changed lines before treating a finding as introduced by the change. NEVER pass an empty line array for a file (an empty array suppresses every finding in it) and NEVER hand-enumerate guessed line numbers: a wrong `added_lines` map silently suppresses findings.

---

## Failure Classification

Not all failures are equal. Before deciding what to do, classify the failure:

| Class | Definition | Example | What to do |
|-------|-----------|---------|------------|
| **Stale assertion** | Test checks for text/value that was deliberately removed | `expect(prompt).toContain('CONSTRAINT: [what NOT to do]')` — template removed in refactor | Update the assertion to match current state |
| **Soft regression indicator** | Test checks a threshold the codebase has since exceeded | `expect(tokenCount).toBeLessThan(35000)` — prompt grew past limit | Fix the threshold or reduce the prompt; do not just document and ignore |
| **Genuine pre-existing** | Failure exists on `main` unrelated to any recent change | See the quarantine ledgers (`scripts/ci/quarantined-tests*.txt`) | Document in PR body; do not fix unless scoped |
| **New regression** | Failure introduced by your changes | Tests for prompt text you removed without updating tests | Fix before pushing |

**Stale assertions and soft regression indicators are actionable** — they signal drift between
tests and code. Genuine pre-existing failures are not your responsibility to fix in this PR,
but they must be documented.

---

## Reading CI Failure Logs

When a CI job fails, the GitHub Actions log shows the exact `file:line` of the failure.
Do not guess — read the log.

```bash
# Get the failing job URL from the PR
gh pr view <number> --json statusCheckRollup --jq '.statusCheckRollup[] | select(.conclusion=="FAILURE") | .detailsUrl'

# Fetch and search the log (if gh CLI available)
gh run view --log <run-id> | grep -E "FAIL|error" | head -20
```

Or open the `detailsUrl` directly in a browser / via WebFetch and search for:
- `(fail)` — Bun test failure marker
- `error:` — parse or runtime error
- `at <anonymous>` — stack frame pointing to the test file and line

Once you have `tests/unit/agents/some-file.test.ts:354`, reproduce locally:
```bash
bun --smol test tests/unit/agents/some-file.test.ts --timeout 30000
```

---

## Quick Reference: Common Failures and Causes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `scope_exceeded` returned from test_runner | Convention received multiple source files, graph/impact received >50 normalized sources, or final resolution exceeded 50 unique tests | Split graph/impact inputs into bounded batches or reduce the source scope; never widen to `scope:'all'` |
| Session killed during test_runner | Pre-fix: unbounded fan-out on multiple files | Now returns `scope_exceeded` instead — no more session kills |
| `mock.module` breaks unrelated tests | Missing spread of real module exports | Add `...realModule` spread |
| Windows tests fail with EBUSY | `mock.restore()` called while child process holds lock | Add `test.skipIf(process.platform === 'win32')` |
| Test output truncated, ID unreadable | Bash tool buffer exceeded | Pipe to `Out-File`/`tee` explicitly |
| `for f in ...; do` parse error | Bash syntax in PowerShell | Use `Get-ChildItem | ForEach-Object` |
| `Select-String -Last N` error | Invalid PowerShell parameter | Use `Select-Object -Last N` |
| Token budget test failure | Prompt grew past hardcoded threshold | Treat as soft regression; update threshold |
| CONSTRAINT assertion fails after refactor | Test checks for removed format template | Update assertion to match current prompt |
| `package-check` CI failure | `package-check` validates the npm tarball (`npm pack` + tarball contents) — a source/build/package-manifest problem, not generated-file drift | `dist/` is generated and NOT committed — do not stage it; run `bun run build` locally only when you need the bundle. There is no longer a committed-dist drift check. |

## Tree-sitter / WASM test timeouts

Tests that exercise tree-sitter (any test calling `extractFileSymbols` or loading a `web-tree-sitter` grammar) may take several seconds on **first WASM module load**. Depending on the code path, tree-sitter is reached via the dynamic symbol-graph import or the externalized runtime import; either way, the first `Parser.init` / grammar load in a process is slow.

- Use `--timeout 60000` (not 30000) for test files that load tree-sitter grammars.
- If the `test_engineer` agent gets stuck (no output for extended time), run the test file directly via bash with a longer timeout (`--timeout 120000`) to determine whether it's a WASM first-load delay or a genuine code failure.
- **Classify the timeout** before returning the test_engineer to the coder — a WASM-load timeout is infrastructure, not a code bug.
- Each test process loads WASM independently (no cross-process cache), so every file's first grammar load is slow.
