# portkey: Coverage 5.28% → 60% (clear `coverageFloor`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise `bankrate/portkey` project coverage from **5.28%** to **≥60%** so gate 13 (`coverageFloor`) passes.

**Architecture:** Two phases, and the split is forced rather than chosen. Everything testable under vitest's current `environment: "node"` — `lib/`, `app/api/`, `hooks/` — accounts for only **~42%** of the covered surface. The floor is 60%. So the node-only work **cannot reach it**, and a React component-testing harness (which does not exist in this repo) has to be stood up before the remaining work is even possible.

**Repo:** `bankrate/portkey`

**Related:** Dispatch A ([2026-09-15-portkey-codecov-always-upload.md](2026-09-15-portkey-codecov-always-upload.md)) fixes `codecov/project` reporting. This plan fixes the number it reports. They are independent — A can land first and should.

## The constraint that shapes everything

`vitest.config.mts` sets `environment: "node"`, and **none** of `jsdom`, `happy-dom`, `@testing-library/react`, `@testing-library/dom`, `@testing-library/user-event` or `@vitejs/plugin-react` is a dependency. There is no component test in the repo and no way to write one today.

Surface under the coverage `include` globs, measured from the `main` tree on 2026-09-15 (66 files, 377,719 bytes):

| group | files | bytes | share | testable today? |
|---|---|---|---|---|
| `components/**` | 16 | 198,894 | **53%** | ❌ needs a harness |
| `lib/**` | 15 | 124,580 | **33%** | ✅ node |
| `app/api/**` | 14 | 31,343 | **8%** | ✅ node |
| `app/**` (pages) | 18 | 18,002 | 5% | ❌ needs a harness |
| `hooks/**` | 3 | 4,900 | 1% | ⚠️ mostly needs a harness |

**42% is the ceiling without a component harness. The floor is 60%.** That is the single fact that decides this plan's shape, and it is why Task 5 exists.

Existing tests — four files, and they are the templates to follow:

```
app/api/bastions/[bastionId]/route.test.ts   6,250b
lib/aws-service.test.ts                      7,357b
lib/bastion-provisioning.test.ts             6,962b
lib/rollbar.test.ts                          1,934b
```

## Global Constraints

- **Bytes are a hypothesis, not the plan.** Coverage is measured in statements, not file size. `lib/types.ts` (6KB) is probably almost all type declarations and contributes nearly nothing; `lib/aws-service.ts` (66KB) may be heavy on SDK boilerplate. **Task 1 replaces every byte figure in this plan with real per-file statement counts, and the order is re-derived from those.** Do not skip it.
- **60% is not negotiable per-repo.** `minCoveragePct: 60` lives on each `changeClass` in zapp's `policy-rules.yaml` and applies to every repo. There is no per-repo coverage override in the enrollment record. It is 60% or a fleet-wide policy change.
- **`coverageFloor` reads *project* coverage**, parsed from the `codecov/project` check-run title. Patch coverage does not matter to the gate.
- **Do not change the coverage `include`/`exclude` globs to raise the number.** Narrowing `include` until 60% falls out satisfies the gate and measures nothing. If a path genuinely should not be covered (generated code, config shims), excluding it is legitimate — say which path and why in the PR.
- **Do not restyle the existing four tests.** They pass and they are the house pattern.
- Conventional commits, Jira key in the subject. portkey has no `commitlint.config.js`, so scope-case is unenforced — keep the convention regardless.

---

### Task 1: Measure real coverage per file, and re-derive the order

**Every subsequent task's ordering depends on this.** The byte counts above are a proxy.

- [ ] **Step 1: Get a local baseline**

```bash
cd /tmp && rm -rf portkey-cov && gh repo clone bankrate/portkey portkey-cov -- --depth 1 && cd portkey-cov
pnpm install --frozen-lockfile
pnpm test:coverage
```

`prisma generate` runs via `prebuild`, not via `test:coverage` — if the run fails on a missing Prisma client, run `pnpm db:generate` first.

- [ ] **Step 2: Record the per-file table**

The `text` reporter prints statement/branch/function/line percentages per file. Capture it:

```bash
pnpm test:coverage 2>&1 | tee /tmp/portkey-coverage-baseline.txt
grep -E "^\s*(All files|app|components|hooks|lib|instrumentation|proxy)" /tmp/portkey-coverage-baseline.txt
```

Confirm the headline figure is ≈5.28%. **If it differs materially from 5.28%, stop and reconcile** — either the codecov number or this run is measuring something different, and building on the wrong baseline wastes the whole plan.

- [ ] **Step 3: Rank by uncovered statements, not by size**

Produce the real attack order — files with the most *uncovered statements*, which is what moves the project percentage:

```bash
node -e '
const fs=require("fs");
// lcov.info: SF=<file>, DA=<line>,<hits>
const recs=fs.readFileSync("coverage/lcov.info","utf8").split("end_of_record");
const rows=recs.map(r=>{
  const f=(r.match(/SF:(.*)/)||[])[1]; if(!f) return null;
  const das=[...r.matchAll(/^DA:\d+,(\d+)$/gm)].map(m=>+m[1]);
  return {f:f.replace(process.cwd()+"/",""), total:das.length, uncovered:das.filter(h=>h===0).length};
}).filter(Boolean).sort((a,b)=>b.uncovered-a.uncovered);
const tot=rows.reduce((s,r)=>s+r.total,0), unc=rows.reduce((s,r)=>s+r.uncovered,0);
console.log("project:", (100*(tot-unc)/tot).toFixed(2)+"%", "| statements:", tot, "| uncovered:", unc);
console.log("to reach 60% you must cover", Math.max(0, Math.ceil(tot*0.6-(tot-unc))), "more statements\n");
rows.slice(0,25).forEach(r=>console.log(String(r.uncovered).padStart(6), "uncovered of", String(r.total).padStart(5), " ", r.f));
'
```

**That printed "you must cover N more statements" figure is this plan's real budget.** Write it into the tracking issue. Every later task reports progress against it.

- [ ] **Step 4: Commit the baseline as a document, not code**

Record the table and the budget in the PR description or the Jira ticket. Do not commit `/tmp` artifacts.

---

### Task 2: Finish `lib/` — the largest node-testable block

33% of the surface, and three of the four existing tests already live here.

**Files:**
- Create/extend: `lib/*.test.ts` alongside each module
- Chief target: `lib/aws-service.ts` (66KB, **17% of the whole surface**, already partially covered by `lib/aws-service.test.ts`)
- Then: `lib/db/index.ts` (23KB), `lib/distributed-cron.ts` (4.7KB), `lib/db/cron-job-leases.ts` (4.1KB)

- [ ] **Step 1: Read the three existing `lib` tests first**

```bash
cd /tmp/portkey-cov
sed -n '1,60p' lib/aws-service.test.ts
sed -n '1,40p' lib/bastion-provisioning.test.ts
```

Match their mocking style exactly — how they stub the AWS SDK, whether they use `vi.mock` at module scope, how `clearMocks`/`restoreMocks` (both `true` in the config) interact with per-test setup. A second, different mocking idiom in the same directory is a review comment waiting to happen.

- [ ] **Step 2: Extend `lib/aws-service.test.ts` first, by uncovered-statement rank**

Take the top entries for `lib/aws-service.ts` from Task 1 Step 3 and cover those branches. This one file is the single biggest lever in the repo.

- [ ] **Step 3: Re-measure after each file, and commit per file**

```bash
pnpm test:coverage 2>&1 | grep "All files"
```

One commit per module keeps the review reviewable and makes a regression bisectable:

```bash
git commit -m "test(lib): cover aws-service error paths (PLAT-xxxx)"
```

- [ ] **Step 4: Report the delta**

Expected after `lib/` is thoroughly covered: **project coverage in the mid-30s.** State the number. If it lands materially below ~30%, Task 1's statement distribution differs from the byte distribution and the remaining task order needs re-deriving before continuing.

---

### Task 3: `app/api` route handlers

8% of the surface across 14 files, uniform shape, and a working template already exists.

**Files:**
- Template: `app/api/bastions/[bastionId]/route.test.ts`
- Targets: the other 13 route files, largest-uncovered first per Task 1

- [ ] **Step 1: Read the template**

```bash
cat "app/api/bastions/[bastionId]/route.test.ts"
```

It establishes how a Next.js route handler is invoked in a node environment and how auth/db are stubbed. Every new route test should be a near-copy with different assertions.

- [ ] **Step 2: Work the list, one commit per route**

Cover the success path, the auth-rejection path, and the validation-failure path for each handler. Three tests per route across 13 routes is a large but mechanical body of work — well suited to running several in parallel.

- [ ] **Step 3: Report**

Expected cumulative after Tasks 2 and 3: **roughly 40%.** Still below the floor. That is expected and is the whole point of Task 5.

---

### Task 4: `hooks/`

Only 1% of the surface (3 files, 4.9KB) — do it here because `hooks/use-toast.ts` (3.9KB) is plain state logic that may not need a DOM at all.

- [ ] **Step 1: Check what each hook actually needs**

```bash
head -30 hooks/use-toast.ts; ls hooks/
```

If a hook is a reducer plus a module-level store with no React rendering, test it directly in the node environment. If it calls `useEffect`/`useState`, defer it to Task 6 — do not stand up the harness for 1%.

---

### Task 5: Stand up the component-testing harness

**The floor is unreachable without this.** Tasks 2–4 top out near 42%.

**Files:**
- Modify: `package.json` (devDependencies), `vitest.config.mts`
- Create: `vitest.setup.ts`

- [ ] **Step 1: Add the dependencies**

```bash
pnpm add -D @testing-library/react @testing-library/dom @testing-library/jest-dom \
            @testing-library/user-event @vitejs/plugin-react jsdom
```

`jsdom` over `happy-dom` unless there is a reason to prefer otherwise — it is the better-supported default for Next.js component tests. Record the choice in the PR.

- [ ] **Step 2: Keep `lib` and `app/api` in the node environment**

This is the step to get right. Do **not** flip the global `environment` to `jsdom` — the 40-odd node tests from Tasks 2–4 depend on node globals, and switching wholesale risks breaking all of them at once.

Use per-file environments so both coexist:

```ts
// vitest.config.mts
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  resolve: { alias: { "@": path.resolve(import.meta.dirname) } },
  test: {
    // Default stays node so every existing test is untouched.
    environment: "node",
    // Component and page tests opt in by location.
    environmentMatchGlobs: [
      ["components/**", "jsdom"],
      ["app/**/*.test.tsx", "jsdom"],
    ],
    setupFiles: ["./vitest.setup.ts"],
    clearMocks: true,
    restoreMocks: true,
    coverage: { /* unchanged */ },
  },
});
```

`environmentMatchGlobs` is deprecated in newer vitest in favour of `test.projects` — check the installed vitest version and use whichever that version documents. Either is fine; a config that logs a deprecation warning on every run is not.

```ts
// vitest.setup.ts
import "@testing-library/jest-dom/vitest";
```

- [ ] **Step 3: Prove both environments still work**

```bash
pnpm test                     # all four existing tests must still pass
```

Then add one throwaway smoke test for the smallest component, confirm it runs under jsdom, and delete it. **Do not proceed to Task 6 until node and jsdom tests pass in the same run** — discovering the environments conflict after writing twenty component tests is the expensive failure here.

- [ ] **Step 4: Commit the harness on its own**

```bash
git commit -m "test: add jsdom component-testing harness (PLAT-xxxx)"
```

A separate commit, because it is the change most likely to need reverting.

---

### Task 6: Component coverage to clear the floor

53% of the surface. You need roughly **20 points** of it.

**Targets, largest first:**

| file | bytes | share |
|---|---|---|
| `components/bastion/bastion-wizard.tsx` | 52,117 | 14% |
| `components/bastion/bastion-detail-page.tsx` | 26,811 | 7% |
| `components/docs/docs-landing-page.tsx` | 20,529 | 5% |
| `components/bastion/saved-configurations.tsx` | 18,141 | 5% |
| `components/ssh-keys/ssh-keys-manager.tsx` | 15,945 | 4% |
| `components/bastion/bastions-list-page.tsx` | 14,760 | 4% |

- [ ] **Step 1: Separate cheap lines from real tests, and decide deliberately**

Some of these are static-heavy — `docs-landing-page.tsx` is 20KB and likely mostly literal JSX. A single "renders without crashing" test covers most of its lines for almost no effort. `bastion-wizard.tsx` at 52KB is a multi-step form: its lines are behaviour, and covering them means real interaction tests.

**Name this tension in the PR instead of resolving it silently.** A smoke render satisfies `coverageFloor` — which is what the gate measures — while proving very little. That may be a fine trade for static pages and a bad one for the wizard. The floor exists as a proxy for "this repo is tested"; hitting it with renders that assert nothing satisfies the letter and not the purpose.

Recommended split:
- **Smoke renders** for static-heavy pages (`docs-landing-page`, and any component that is layout with no branching) — cheap, honest about what it proves
- **Real interaction tests** for `bastion-wizard`, `saved-configurations`, `ssh-keys-manager` — these provision production infrastructure; they deserve actual tests regardless of the gate

- [ ] **Step 2: Work the list, re-measuring after each file**

```bash
pnpm test:coverage 2>&1 | grep "All files"
```

Stop when the project figure clears **62–63%**, not 60%. Land with margin: codecov's project number and vitest's local number can differ slightly, and a repo sitting at 60.1% fails the gate on the next uncovered line anyone adds.

- [ ] **Step 3: Confirm the gate, not just the number**

After merge, on the next dependency-bump PR (not on this PR — `.github/**` and test-only changes classify as `unclassified`, so gates 6-15 render `not evaluated`):

```bash
gh api repos/bankrate/portkey/commits/<sha>/check-runs \
  --jq '.check_runs[]|select(.app.slug=="neutral-planet")|.output.summary' | grep -E "coverageFloor|of 18 gates"
```

Expected: `✅ coverageFloor` with a percentage at or above 60.

- [ ] **Step 4: Report what is still blocking**

Clearing `coverageFloor` does not make portkey eligible. State the remainder:

| Gate | Owner |
|---|---|
| `ciBaselineMet` / `checksGreen` — `Terraform plan (speculative)` | [PLAT-1313](https://redventures.atlassian.net/browse/PLAT-1313), or a waiver **plus** a `blockingChecks` override |
| `classificationPermits` — `dep-minor` on `prod-service` | zapp policy: `dep-minor` gains `prod-service` |

---

## Self-review notes

**The blocking finding, stated once more because it is the plan's whole shape.** `vitest.config.mts` sets `environment: "node"` and the repo has **no** component-testing dependency of any kind. Node-testable code (`lib` 33% + `app/api` 8% + `hooks` 1%) is **42%** of the covered surface against a **60%** floor. Tasks 2–4 therefore cannot clear the gate no matter how thoroughly they are done, and Task 5 is a prerequisite rather than a nice-to-have. Anyone who reads this plan as "write more tests" will run out of runway at 42% and not know why.

**Task 1 is not optional and not busywork.** Every ordering in Tasks 2, 3 and 6 is derived from *file size*, which is a proxy for statement count and sometimes a poor one. `lib/types.ts` at 6KB is likely near-zero statements; a 20KB static page may be almost all coverable lines. Task 1 replaces the proxy with the real distribution and prints the actual statement budget.

**Two paths deliberately rejected.** Narrowing the coverage `include` globs until 60% falls out — satisfies the gate, measures nothing. And a per-repo coverage floor — `minCoveragePct` lives on the `changeClass`, so no such override exists; it is 60% or a fleet-wide policy change.

**Sequencing against dispatch A.** Independent. A fixes whether `codecov/project` reports at all (it is at 12/15 because lint failures skip the coverage step); this plan fixes the number it reports. A is days and should go first, so that progress here is visible on every PR rather than three-in-fifteen of them.
