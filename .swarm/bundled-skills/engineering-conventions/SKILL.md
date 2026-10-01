---
name: engineering-conventions
audience: swarm-plugin
description: >
  Guidelines and non-negotiable engineering invariants for modifying opencode-swarm.
  Load before architecture, plugin initialization, subprocess, tool registration, plan
  durability, .swarm storage, runtime portability, session/global state, guardrails/retry,
  chat/system message hooks, or release/cache changes. Authoritative source: AGENTS.md
  at the repo root and docs/engineering-invariants.md.
---

# Engineering Conventions for opencode-swarm

**Authoritative source:** [`AGENTS.md`](../../../AGENTS.md) at the repo root and [`docs/engineering-invariants.md`](../../../docs/engineering-invariants.md). This skill is a pointer + summary so the OpenCode agent loads the right invariants before touching dangerous areas. **Read `AGENTS.md` first.** When this skill conflicts with `AGENTS.md`, `AGENTS.md` wins.

## When to load this skill

Before changing shared/exported or runtime-contract code, use `repo_map` `impact_cone` to identify likely consumers, then verify them in direct source. Graph evidence is advisory only. If freshness is stale or inconclusive, confidence is low, source is missing, the language is unsupported/dynamic, the graph is absent, or the action fails, rely on direct source, searches, and executable evidence.

Load this skill **before** beginning implementation work that touches any of:

- `src/index.ts` (plugin entry / `initializeOpenCodeSwarm`)
- `src/hooks/*` (any hook that may run during init or QA review)
- `src/tools/*` (tool registration, working-directory anchoring, test_runner)
- `src/utils/bun-compat.ts` (subprocess shim — every spawn in the repo eventually flows through here)
- `src/utils/timeout.ts` (the `withTimeout` primitive used by every bounded init step)
- `src/utils/gitignore-warning.ts` (Git hygiene; runs on plugin init path)
- `package.json`, build configuration, `dist/`, plugin export shape
- Plan ledger / projection / checkpoint code (`src/plan/*`, `.swarm/plan-*`)
- Session / guardrails / runtime state (`src/state.ts`, `src/hooks/guardrails.ts`)
- Tests involving subprocesses, plugin startup, `mock.module`, or temp directories

If you are not sure whether you are touching one of these, you are touching one of these.

## Highest-risk invariants (the ones that have already shipped regressions)

The full list of 12 invariants is in `AGENTS.md`. The four that have caused the most recent production regressions:

1. **Plugin initialization is bounded and fail-open.** Every awaited operation on the plugin-init path must be wrapped in `withTimeout(...)` and degrade non-fatally on timeout. Issue #704 (v7.0.3) and the v7.3.3 git-hygiene regression both stem from violating this. The OpenCode plugin host silently drops a plugin whose entry never resolves; users see "no agents in TUI / GUI" with no error.
   - **Bounded is not free:** `withTimeout` only prevents an *unbounded* hang — the awaited work's latency still counts toward the ~400 ms repro-704 init deadline. Register non-trivial init I/O in the wrapper-owned post-resolution task queue when nothing downstream needs it before `server()` resolves. Do not use `queueMicrotask` inside the initializer: it can run during a later `await` while `server()` is still unresolved.
2. **Subprocesses are bounded, non-interactive, and killable.** Every `bunSpawn(['<bin>', ...])` call must pass `cwd`, `stdin: 'ignore'` (unless intentionally interactive), `timeout: <ms>`, bounded stdio, and call `proc.kill()` in a `finally`. An outer `withTimeout` is not enough — it lets the awaiter proceed but does not abort the child.
3. **Runtime portability — Node-ESM-loadable + v1 plugin shape.** No top-level `bun:` imports in `dist/index.js`. Default export is `{ id, server }`. All `Bun.*` calls go through `src/utils/bun-compat.ts`. v6.86.8 / v6.86.9 are the cautionary tales.
4. **Test mock isolation.** `mock.module(...)` leaks across files in Bun's shared test-runner process. Prefer, in order: (a) `_test_exports` for pure function testing with zero mocks, (b) `_internals` dependency-injection seam for within-module mocking (see `src/utils/gitignore-warning.ts:_internals` and `src/hooks/diff-scope.ts:_internals`), (c) `mock.module` only when unavoidable. Restore in `afterEach`. The writing-tests skill covers all three tiers in detail; load it before modifying tests.

## Cross-link: writing tests

For test changes, also load [`.swarm/bundled-skills/writing-tests/SKILL.md`](../writing-tests/SKILL.md). It covers `bun:test` API, mock isolation rules, CI per-file isolation, and cross-platform anti-patterns.

## Hard warning: do NOT use broad `test_runner` for repo validation

The OpenCode `test_runner` tool is for **targeted agent validation** with explicit `files: [...]` or small targeted scopes. It is not the way to validate the full repo from inside an OpenCode session. In this repo:

- `MAX_SAFE_TEST_FILES = 50` (`src/tools/test-runner.ts`). Resolutions exceeding this return `outcome: 'scope_exceeded'` with a SKIP. Do not lean on this — broad scopes can stall or kill OpenCode before that guard fires.
- For repo validation, run the shell commands in `contributing.md` / `TESTING.md` directly (per-file isolation loops + tier orchestration).
- `scope: 'all'` is gated behind the `SWARM_ALLOW_FULL_SUITE=1` env var (intended for opt-in CI mirrors only); there is no `allow_full_suite` arg. Default to `files: [...]` instead.

## Agent prompt strings — escaping pitfalls

Agent prompts in `src/agents/*.ts` are large TypeScript template literals. They frequently contain characters that have special meaning inside template literals and cause silent parse errors if unescaped:

| Character | Inside template literal | Correct escape |
|-----------|------------------------|----------------|
| Backtick `` ` `` | Terminates the literal | `` \` `` (single backslash — renders as `` ` `` in output) |
| `${` | Starts an interpolation | `\${` (single backslash) |
| Literal backslash `\` | Consumed by escape processing | `\\` (double backslash renders as `\` in output) |

**The most common failure pattern:** A coder adds an inline code example containing backticks to an agent prompt string. The unescaped backtick silently terminates the template literal, producing a `SyntaxError: Unexpected identifier` or `Unexpected token` at the character *after* the backtick — which appears unrelated to the actual cause.

```typescript
// WRONG — unescaped backtick terminates the template literal
const PROMPT = `
Use `bun:test` for all tests.   // ← bare backtick before "bun" closes the literal
`;

// CORRECT — single backslash before each backtick; renders as Use `bun:test` in output
const PROMPT = `
Use \`bun:test\` for all tests.
`;

// OVER-ESCAPED (also wrong) — triple backslash produces literal \` in the rendered prompt
const PROMPT = `
Use \\\`bun:test\\\` for all tests.  // renders as: Use \`bun:test\` (backslashes visible)
`;
```

**Detection:** If `bun run build` or `bun --smol test` reports a parse error at a line number that seems far from any recent change, search the surrounding lines for an unescaped backtick inside a template literal.

**Prevention:** After adding any inline code example to an agent prompt, run `bun run build` immediately — the TypeScript compiler catches unescaped backticks as a syntax error before any tests run.

## The invariant-audit gate (PR-time)

Every PR that touches a relevant area must include an `## Invariant audit` section in its description. The format is in `AGENTS.md` ("Invariant audit required in PRs"). The `commit-pr` skill enforces this gate before push/PR — load it before committing.

If you cannot prove a touched invariant from source and test output, **do not push**.

## Evidence file flow (`.swarm/evidence/{taskId}.json`)

**Agents NEVER write these files directly.** The `delegation-gate` hook
writes them automatically after each reviewer/test_engineer Task
delegation returns. The schema is defined in `src/gate-evidence.ts`:

```typescript
export interface GateEvidence {
  sessionId: string;  // actual session ID from the Task delegation
  timestamp: string;  // ISO 8601
  agent: string;     // 'reviewer' | 'test_engineer' | 'sme' | etc.
}

export interface TaskEvidence {
  taskId: string;
  required_gates: string[];
  gates: Record<string, GateEvidence>;
  turbo?: boolean;
}
```

**How to verify the flow is working:**

1. After dispatching a reviewer/test_engineer Task, the `delegation-gate`
   toolAfter hook should automatically write/update
   `.swarm/evidence/{taskId}.json`.
2. When you call `update_task_status(completed)`, the tool reads the
   evidence file and verifies the `required_gates` are all present.
3. If `update_task_status` fails with "required QA gates not yet satisfied"
   or "Evidence file is corrupt or unreadable," inspect the evidence
   file with `cat .swarm/evidence/{taskId}.json` to diagnose.

**Do NOT manually write or fabricate evidence files.** This bypasses the
gate enforcement and can cause downstream tool failures when the real
session IDs are looked up.

**When to suspect the flow is broken:**

- The evidence file doesn't exist after a reviewer/test_engineer Task
  delegation returns
- The evidence file exists but has wrong `agent` or `sessionId` values
- The plan has newly-added task IDs that the hook may not recognize

**Workaround for broken flow:** If the hook consistently fails to write
the evidence file, escalate to the user — do NOT silently fabricate
evidence with placeholder session IDs. The gate check exists to enforce
that a real review/test run happened.

See [`.opencode/skills/writing-tests/SKILL.md`](../writing-tests/SKILL.md)
§ Cross-Platform Requirements → "macOS rename-visibility race" for the
ENOENT retry pattern that this gate flow triggers on macOS CI.

## Init-path-safe imports (invariant 1 deep-dive)

The most expensive invariant-1 violations come from **transitive import chains** that silently load heavy modules (WASM, tree-sitter) at plugin init time. A single `import { X } from '../../lang'` in a tool-time module can transitively load `runtime.ts` → `web-tree-sitter` (heavy WASM), spiking init latency well past the repro-704 T1 deadline (observed during issue #1471 development).

### The lang barrel trap

`src/lang/index.ts` re-exports from `./runtime`, which statically imports `web-tree-sitter`. Importing **anything** from the barrel (`from '../../lang'`) transitively loads WASM at module-eval time.

**Wrong:** `import { LANGUAGE_REGISTRY } from '../../lang'` — loads runtime → web-tree-sitter.
**Right:** `import { LANGUAGE_REGISTRY } from '../../lang/profiles'` — loads only profiles (string data, no WASM).

### Type-only vs value imports

- `import type { Query } from 'web-tree-sitter'` — **safe** (erased at compile time, no module load).
- `import { Query } from 'web-tree-sitter'` — **unsafe** on the init path (loads the WASM module).
- For value dependencies on heavy modules in init-reachable code, use dynamic `import()` inside an async function (deferred to first call, not module load).

### The `--external` build flag

Dynamic `import('web-tree-sitter')` only defers loading at runtime if `--external web-tree-sitter` is set in the bun build config. Without it, bun bundles web-tree-sitter inline and the dynamic import resolves from the bundle (no deferral). Check `package.json` build scripts for the flag.

### Verification checklist

For any import-chain change touching `src/lang/`, `runtime`, or `web-tree-sitter`:
1. Trace the transitive chain from `src/index.ts` to verify no heavy module loads at init.
2. Rebuild dist: `bun run build` (stale dist gives false regressions).
3. Run `node scripts/repro-704.mjs` — T1 must be under 400ms.
4. Run `bun --smol test tests/unit/lang/symbol-graph-init-purity.test.ts` — init-path purity tests must pass.

## Tool version parity (local vs CI)

**Tool versions must match CI.** When `package.json` pins a tool version (e.g., `@biomejs/biome@2.3.14`, `@biomejs/biome@^2`, or any other versioned dev dependency), invoke it **with the pinned version** during local validation. Unversioned `bunx biome` resolves to a different version than the CI gate uses, and a CI-blocking failure can be invisible to local pre-commit validation.

Examples:
- Pinned biome: `bunx @biomejs/biome@<version> ci .` (substitute `<version>` from `package.json`).
- Unversioned `bunx biome ci .` resolves to whatever Bun's `bunx` registry returns at run time — historically 0.3.x vs the pinned 2.x.

The `commit-pr` skill Tier 1 - quality section pins the biome command to the package.json version; this is the canonical pattern for any tool where local and CI versions could diverge. Apply the same discipline to ESLint, Prettier, TypeScript, and any other versioned dev dependency.

**Why this matters:** PR #1503 (telemetry rotation fix) had a biome 2.3.14 `organizeImports` failure on the `./telemetry` import block that was invisible to local `bunx biome` (which resolved to 0.3.3 with no equivalent rule). The reviewer caught it from CI logs, not local validation. Pin tool versions to close the local/CI parity gap.

## Skill mirror contract

The cross-tree skill mirror contract is the authoritative registry at `src/config/skill-mirrors.ts`. If your PR modifies `.opencode/skills/<X>/SKILL.md` or `.claude/skills/<X>/SKILL.md`, consult that file to determine the contract kind for skill `<X>`:

- **`identical`:** `.opencode` and `.claude` SKILL.md must be byte-identical (the `canonical` field records which side wins when they drift). Update both trees byte-for-byte in the same commit. Verify with `bun run drift:check`. PR #1512 (lane-dispatch) introduced drift in council/deep-dive by only updating `.opencode` — a contract violation.
- **`divergent`:** both must exist but content intentionally differs per runtime. Examples: `engineering-conventions` is divergent (different frontmatter, different conventions per Claude Code vs OpenCode). `writing-tests` is classified divergent because the additional-contract model does not yet have an adapter kind, but operationally `.opencode/skills/writing-tests/SKILL.md` is canonical and `.claude/skills/writing-tests/SKILL.md` delegates to it.
- **`opencode-only`:** `.opencode` exists; no `.claude` mirror expected. Examples: `loop` (would shadow Claude Code's built-in `/loop`), `running-tests` (OpenCode-runtime guidance).
- **Adapter shim pattern:** for architect MODE skills like `swarm-pr-review` and `swarm-pr-feedback`, the `.claude` and `.agents` files are thin adapter shims that delegate to the canonical `.opencode` file via `expectedCanonicalRef`. When updating these, the canonical content goes in `.opencode`; the adapter shim typically needs no change unless the cross-tree delegation interface changes.

**If your PR modifies a `.opencode/skills/<X>/SKILL.md` file:** check `src/config/skill-mirrors.ts` for the contract, then run `bun run drift:check --enforce` locally before pushing. CI invokes drift-check with `--enforce`, so blocking mirror drift fails the job while the report is also surfaced as an issue comment; a drift between canonical and mirror means Claude Code agents reading the mirror get stale instructions.

## Sandbox env overrides (subprocess-safety deep-dive)

When a sandbox executor (`src/sandbox/{linux,macos,win32}/*.ts`) interpolates environment variables into a sandbox profile, a bwrap rule, or a PowerShell `-EnvironmentVariables` block, the following rules apply — they exist because a future shell-injection regression in any new sandbox path would be a security vulnerability, not just a bug:

- **Keys must match POSIX env-var name syntax.** Every env key must be validated against the regex `/^[A-Za-z_][A-Za-z0-9_]*$/` (a leading letter or underscore, then letters/digits/underscores) before being interpolated. Define or reuse a single `isValidEnvKey(key: string): boolean` helper colocated with the `SandboxExecutor` interface in `src/sandbox/executor.ts` (around line 24+); do not duplicate the regex inline at every call site. Keys that fail validation must be silently dropped (not raised) so that one bad caller cannot wedge the sandbox path — but the drop must be observable in the advisory/observability layer (`pendingAdvisoryMessages` or structured log), never silent.
- **Values must be shell-quoted or treated as opaque single tokens.** On POSIX, prepend a leading single quote, escape any embedded single quotes by replacing `'` with `'\''`, and append a trailing single quote. On Windows PowerShell, **prefer single-quoted literal contexts (e.g. `'$env:NAME'`) and run values through a `psStringEscape`-style helper that escapes backtick, `$`, `"`, and `` ` ``** (the special characters in double-quoted PowerShell strings). Single-quoted PowerShell strings are literal — only `'` needs escaping, doubling it to `''`. If a context requires double-quoted PS values, escape embedded `"` as `` ` ``, backtick as `` `` ``, and `$` as `` ` `` (backtick is the PS escape character in double-quoted strings; `$` must be escaped to prevent variable expansion). On bwrap, always pass values as separate argv tokens after the `--setenv` flag (`--setenv KEY VALUE`, two tokens), never as a single concatenated `KEY=VALUE` token that an intermediate shell would interpret.
- **Use the array-form argv for every sandbox subprocess.** Never `shell:`-interpolate. The same invariant-3 rules (`array-form spawn`, `stdin: 'ignore'`, `cwd`, `timeout`, `proc.kill()` in `finally`) apply to sandbox spawns as to any other subprocess; opencode-swarm repository contributors can also consult the repo's subprocess-safety developer skill.

## Sandbox fallback parity (Windows and Linux)

`sandbox/{linux,macos,win32}/*.ts` has primary executors plus legacy fallbacks (Windows `NativeWindowsSandboxExecutor` + `RestrictedEnvironmentExecutor` / PowerShell wrapper, Linux `BubblewrapSandboxExecutor` + no-sandbox fallback). When you modify any of the following on the primary executor, you MUST update the fallback path in the same change to keep behavior parity and add a parity test:

- `getEnvOverrides` signature or merge semantics.
- `wrapCommand` scoping rules (allowed roots, read-only mounts, temp-dir allocation).
- `isAvailable()` / capability probe logic.
- Failure-mode handling (does a missing sandbox envelope hard-fail or soft-fail to env-only isolation?).
- Scope-materialization for lane-scoped resources.

A divergence between primary and fallback that is not exercised by a parity test is a regression. The existing per-OS test files `tests/unit/sandbox/{linux,macos,win32}.test.ts` must continue to cover both the primary and fallback paths after every env-affecting change — extend these tests rather than relying on dedicated sandbox-envoverride test files that may or may not exist in your branch.

## SAST baseline capturing (differential scanning)

The `sast_scan` tool supports `capture_baseline: true` with a `phase` parameter
to snapshot pre-existing findings. Subsequent scans with the same `phase` value
perform differential checking — they only fail on **new** findings, not
pre-existing ones.

### When to capture a baseline

- **Before Phase 1 code changes.** The baseline must reflect the state of the
  codebase *before* any new work is done. This ensures the differential scan
  catches findings introduced by the current session's changes.

### Critical safety guard

**NEVER capture a baseline after code changes have been made in a phase.**
A baseline captured post-edit silently encodes the very bugs the scan is meant
to catch as "pre-existing," suppressing them indefinitely. This turns the SAST
gate into theater.

Baseline capture also requires at least one supported, existing file to be
successfully scanned. Omitted, empty, or entirely unscannable `changed_files`
returns `capture_baseline requires changed_files to produce a non-empty baseline`
instead of reporting a successful no-op capture.

### Moved findings and audited absorption (#2302)

Every baseline fingerprint carries a position-independent reflow identity
(file + rule + flagged-line content). A pre-existing finding whose neighbor
lines were edited, or that moved to a new line, is reported as a
`moved_findings` entry on the next diff scan — it never gates. Only findings
matching neither the baseline fingerprints nor its reflow identities are NEW.

Re-capturing into an existing baseline with findings that were not in it is
**BLOCKED** unless the capture passes `baseline_refresh_rationale` — for
already-indexed AND first-time-indexed files alike, because the tool cannot
distinguish a pre-delegation capture from a failure-response recapture; every
absorbed finding then records a who/when/rationale entry in the baseline
triage log. This is the audited path for genuinely pre-existing findings
(routine per-task captures of first-time files, or findings discovered late
after a file rename) — it is NOT a way to make a failed gate go green:
recapturing with a rationale after a gate failure means accepting findings
that may be coder-introduced. First writes (baseline creation) are snapshots,
not absorptions, and stay free.

### How to use it

1. Identify the files to scan. In a phase, use the union of declared task-scope
   files plus files the coder is expected to touch. Derive the list from
   `declare_scope` outputs, `git diff --name-only`, or the phase's task specs.
2. Before any coder delegation in Phase 1, capture the baseline:
   ```
   sast_scan(directory, changed_files=[...], capture_baseline=true, phase=1)
   ```
3. After coder work, scan the same file set:
   ```
   sast_scan(directory, changed_files=[...], phase=1)
   ```
   This returns only NEW findings (absent from the baseline).
4. If a pre-existing finding is legitimately fixed, the baseline can be
   re-captured at the start of the next phase with the updated file list.

### Why this matters

During PR #1704 review, SAST flagged `RegExp.prototype.exec()` as
"command injection via child_process.exec()" — a false positive that blocked
the gate. With a baseline captured before the phase, this pre-existing false
positive would have been suppressed, and only genuinely new findings would
surface.
