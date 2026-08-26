# Scan Gates, Coverage Floor and Resiliency Tier — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four eligibility gates — security/build/plan checks green, a coverage floor, a resiliency-tier ceiling, and a SOC2 rule — taking the ladder from 11 gates to 15.

**Architecture:** Additive. The one structural change is hoisting the head-SHA check-runs fetch above `runGates` so the eligibility gates can read it, then passing those same runs down to the risk evaluator instead of fetching twice. Repository sensitivity comes from a new `GET properties/values` call, lowercased at the boundary.

**Tech Stack:** Node 22, TypeScript, `node:test` + `tsx`, esbuild, container-image Lambda via `finserv-reusable-gha` CI/CD v2.

**Spec:** [`../specs/2026-08-25-scan-gates-and-resiliency-tier-design.md`](../specs/2026-08-25-scan-gates-and-resiliency-tier-design.md)

**Repo:** `bankrate/zapp` at v1.5.0 (Specs A, B and C all shipped). Branch from `main`: `feat/scan-gates-and-resiliency-tier`.

## Global Constraints

- **Shadow-mode invariant.** `src/checks.ts` is not modified. Conclusions stay `neutral`; nothing is approved, merged or blocked.
- **All four new gates fail closed on absent data**, each with a reason a reader can act on. Absent is never treated as permissive.
- **`checksGreen` treats `success`, `neutral` and `skipped` as green.** A skipped Terraform plan on a PR touching no Terraform is not a failure, and our own checks are `neutral` by construction — treating either as red makes every PR ineligible.
- **Tier vocabulary is lowercase everywhere in code.** The property's value is Title Case because humans read it in the GitHub settings UI; `toLowerCase()` once at the read boundary and nowhere else.
- **Tier ranking:** `paper(0) < bronze(1) < silver(2) < gold(3) < platinum(4)`. Higher is more critical, therefore stricter.
- **`freezeOff` stays last** in `GATE_ORDER`, shifting from position 11 to 15.
- **`src/gates.ts` stays pure** — no I/O, no clock, no environment. Everything it needs arrives on `GateInput`.
- **Repo properties are read via `GET /repos/{o}/{r}/properties/values`, never the webhook payload** — the `check_suite` path fetches the PR and gets no custom properties, so a payload-based gate would work on `opened` and silently degrade on every re-evaluation.
- **`newFindings` risk signal is unchanged.** Still six signals.
- **Never log secrets or PR prose.** Repo, PR number, SHAs, gate names, tiers and counts are safe.
- **Node 22**, ESM — every relative import carries a `.js` extension even from `.ts` sources.
- **Conventional Commits** — `release.yml` runs semantic-release on merge to `main`.
- **`docs/superpowers/` is gitignored in zapp.** Spec and plan live in firstmate. `docs/policy.md` is a product doc and does ship.

---

### Task 1: Rules for the four gates

**Files:**
- Modify: `policy-rules.yaml`, `src/rules-types.ts`, `scripts/build-rules.mjs`
- Modify: `tests/build-rules.test.ts`
- Regenerate: `src/generated/rules.ts`

**Interfaces:**
- Consumes: `validatePolicy` from `scripts/build-rules.mjs`
- Produces:
  - `Rules.blockingChecks: string[]`
  - `EnrollmentRecord.blockingChecks?: string[]`
  - `ChangeClass.minCoveragePct: number`, `.maxResiliencyTier: string`, `.soc2Eligible: boolean`

- [ ] **Step 1: Create the branch**

```bash
cd /Users/scrosby/Projects/github/zapp
git checkout main && git pull
git checkout -b feat/scan-gates-and-resiliency-tier
```

- [ ] **Step 2: Write the failing validator tests**

In `tests/build-rules.test.ts`, add to `validDoc()`'s `rules` block:

```ts
      blockingChecks: ['Cycode: SAST'],
```

and to its `changeClasses['dep-patch']`:

```ts
          minCoveragePct: 60, maxResiliencyTier: 'gold', soc2Eligible: false,
```

Then append:

```ts
test('a missing blockingChecks list is rejected', () => {
  const doc = validDoc();
  delete doc.rules.blockingChecks;
  assert.match(validatePolicy(doc)[0], /rules\.blockingChecks/);
});

test('an empty blockingChecks is valid — it means nothing is required to be green', () => {
  const doc = validDoc();
  doc.rules.blockingChecks = [];
  assert.deepEqual(validatePolicy(doc), []);
});

test('a per-repo blockingChecks override is validated when present', () => {
  const doc = validDoc();
  doc.repos[0].blockingChecks = ['ok', 9];
  assert.match(validatePolicy(doc)[0], /repos\[0\]\.blockingChecks/);
});

test('a coverage floor outside 0-100 is rejected', () => {
  for (const bad of [-1, 101]) {
    const doc = validDoc();
    doc.rules.changeClasses['dep-patch'].minCoveragePct = bad;
    assert.match(validatePolicy(doc)[0], /minCoveragePct/, String(bad));
  }
});

test('a Title Case tier in the rules file is rejected — code is lowercase', () => {
  // The PROPERTY is Title Case for humans; the rules file is not. Catching
  // this at build time is the whole point of lowercasing at one boundary.
  const doc = validDoc();
  doc.rules.changeClasses['dep-patch'].maxResiliencyTier = 'Gold';
  assert.match(validatePolicy(doc)[0], /maxResiliencyTier/);
});

test('an unknown tier is rejected', () => {
  const doc = validDoc();
  doc.rules.changeClasses['dep-patch'].maxResiliencyTier = 'titanium';
  assert.match(validatePolicy(doc)[0], /maxResiliencyTier/);
});

test('a non-boolean soc2Eligible is rejected', () => {
  const doc = validDoc();
  doc.rules.changeClasses['dep-patch'].soc2Eligible = 'no';
  assert.match(validatePolicy(doc)[0], /soc2Eligible/);
});

test('the real rules file gives every change class all three new fields', async () => {
  const { POLICY } = await import('../src/generated/rules.js');
  for (const [name, cls] of Object.entries(POLICY.rules.changeClasses)) {
    assert.equal(typeof cls.minCoveragePct, 'number', name);
    assert.equal(typeof cls.soc2Eligible, 'boolean', name);
    assert.match(cls.maxResiliencyTier, /^(paper|bronze|silver|gold|platinum)$/, name);
  }
});

test('the real rules file declares the checks that must be green', async () => {
  const { POLICY } = await import('../src/generated/rules.js');
  for (const name of ['Cycode: SAST', 'Build and scan image', 'Terraform plan (speculative)']) {
    assert.ok(POLICY.rules.blockingChecks.includes(name), name);
  }
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `validatePolicy` accepts a document with no `blockingChecks`

- [ ] **Step 4: Add the rules to `policy-rules.yaml`**

Inside `rules:`, after `signalChecks:`:

```yaml
  # Must be GREEN for a pull request to be a candidate.
  #
  # DISTINCT FROM signalChecks above, which decides when the RISK grade is
  # final. These lists overlap on the Cycode contexts because both care about
  # scanners, not because they are the same question: this one asks "may we
  # automate this at all", the other "have our inputs arrived".
  blockingChecks:
    - "Cycode: SAST"
    - "Cycode: Secrets"
    - "Cycode: Vulnerable Dependencies"
    # The JOB name. Its workflow is named "Wiz Image Scan"; GitHub surfaces the
    # job, and the Wiz scan runs inside it. There is no separate Wiz check.
    - "Build and scan image"
    # TFC speculative plan via Actions. CI/CD v2 has not standardised this name
    # across repos, which is why it is declared and overridable per repo.
    - "Terraform plan (speculative)"
```

Then add three fields to **every** entry under `changeClasses:`:

```yaml
    lockfile-only:
      minCoveragePct: 0
      maxResiliencyTier: platinum    # generated content only; safe anywhere
      soc2Eligible: false
    dep-patch:
      minCoveragePct: 60
      maxResiliencyTier: gold        # everything but the 99.99% tier
      soc2Eligible: false
    dep-minor:
      minCoveragePct: 60
      maxResiliencyTier: silver
      soc2Eligible: false
    dep-major:
      minCoveragePct: 60
      maxResiliencyTier: bronze
      soc2Eligible: false
```

Lowercase here on purpose: the repo property is Title Case for the humans reading it in GitHub's settings UI, and the value is lowercased once when read.

- [ ] **Step 5: Type it in `src/rules-types.ts`**

Add to `ChangeClass`:

```ts
  /** Minimum project coverage percentage this class requires. */
  minCoveragePct: number;
  /** Most critical resiliency tier this class may touch. Lowercase. */
  maxResiliencyTier: string;
  /** Whether this class may be applied to a SOC2-compliant repository. */
  soc2Eligible: boolean;
```

Add to `Rules`:

```ts
  /** Check runs that must be green for a pull request to be a candidate. */
  blockingChecks: string[];
```

Add to `EnrollmentRecord`:

```ts
  /** Replaces `Rules.blockingChecks` for this repo when present. Never merged. */
  blockingChecks?: string[];
```

- [ ] **Step 6: Validate in `scripts/build-rules.mjs`**

Add near the top, beside the other vocabularies:

```js
const TIERS = ['paper', 'bronze', 'silver', 'gold', 'platinum'];
```

After the `rules.signalChecks` check:

```js
  if (!isStrArray(rules.blockingChecks)) bad('rules.blockingChecks', 'must be an array of strings');
```

Inside the `changeClasses` loop, alongside the existing per-class checks:

```js
      if (typeof cls?.minCoveragePct !== 'number' || cls.minCoveragePct < 0 || cls.minCoveragePct > 100) {
        bad(`${p}.minCoveragePct`, 'must be a number between 0 and 100');
      }
      // Lowercase only. The repo property is Title Case for humans and is
      // lowercased on read; a Title Case value here would silently never match.
      if (!TIERS.includes(cls?.maxResiliencyTier)) {
        bad(`${p}.maxResiliencyTier`, `must be one of ${TIERS.join(', ')} (lowercase)`);
      }
      if (typeof cls?.soc2Eligible !== 'boolean') bad(`${p}.soc2Eligible`, 'must be a boolean');
```

And inside the `doc.repos.forEach` loop:

```js
      if (r?.blockingChecks !== undefined && !isStrArray(r.blockingChecks)) {
        bad(`repos[${i}].blockingChecks`, 'must be an array of strings when present');
      }
```

- [ ] **Step 7: Regenerate and run**

```bash
pnpm run build:rules && pnpm test && pnpm run typecheck
```

Expected: PASS. `RULES_SHA` changes because the file changed — correct.

- [ ] **Step 8: Commit**

```bash
git add policy-rules.yaml src/rules-types.ts src/generated/rules.ts scripts/build-rules.mjs tests/build-rules.test.ts
git commit -m "feat: rules for blocking checks, coverage floor, tier ceiling and SOC2"
```

---

### Task 2: Read repository properties

**Files:**
- Create: `src/repo-properties.ts`
- Create: `tests/repo-properties.test.ts`

**Interfaces:**
- Consumes: `githubRequest` from `src/github.ts`
- Produces:
  - `interface RepoProperties { resiliencyTier: string | null; isSoc2Compliant: boolean | null; error?: string }`
  - `fetchRepoProperties(repoFullName: string, request?): Promise<RepoProperties>`
  - `TIER_RANK: Record<string, number>`
  - `tierRank(tier: string | null): number | null`

- [ ] **Step 1: Write the failing test**

Create `tests/repo-properties.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchRepoProperties, tierRank, TIER_RANK } from '../src/repo-properties.js';

// The live shape, captured from bankrate/platform-cicd-v2-demo on 2026-08-25.
const LIVE = [
  { property_name: 'is_poc', value: 'true' },
  { property_name: 'is_soc2_compliant', value: 'false' },
  { property_name: 'resiliency_tier', value: 'Paper' },
];

function fakeRequest(body: any, ok = true, status = 200) {
  const calls: string[] = [];
  const request = async (path: string) => {
    calls.push(path);
    return { ok, status, json: async () => body, text: async () => 'err' };
  };
  return { calls, request: request as any };
}

test('reads the live property shape', async () => {
  const { request, calls } = fakeRequest(LIVE);
  const props = await fetchRepoProperties('bankrate/platform-cicd-v2-demo', request);
  assert.equal(calls[0], '/repos/bankrate/platform-cicd-v2-demo/properties/values');
  assert.equal(props.isSoc2Compliant, false);
  assert.equal(props.error, undefined);
});

test('the Title Case tier is lowercased at the boundary', () => {
  // The property is Title Case because humans read it in GitHub's settings UI.
  // Code sees lowercase, everywhere, from here on.
  return fetchRepoProperties('o/r', fakeRequest(LIVE).request)
    .then((props) => assert.equal(props.resiliencyTier, 'paper'));
});

test('a SOC2-compliant repo parses as true', async () => {
  const { request } = fakeRequest([{ property_name: 'is_soc2_compliant', value: 'true' }]);
  assert.equal((await fetchRepoProperties('o/r', request)).isSoc2Compliant, true);
});

test('unset properties are absent from the response and read as null', async () => {
  // GitHub OMITS unset properties rather than returning them null — verified
  // live. Absent and unset are therefore the same observation.
  const { request } = fakeRequest([{ property_name: 'is_poc', value: 'true' }]);
  const props = await fetchRepoProperties('o/r', request);
  assert.equal(props.resiliencyTier, null);
  assert.equal(props.isSoc2Compliant, null);
});

test('a failed fetch returns nulls AND an error, never a permissive default', async () => {
  const { request } = fakeRequest(null, false, 403);
  const props = await fetchRepoProperties('o/r', request);
  assert.equal(props.resiliencyTier, null);
  assert.equal(props.isSoc2Compliant, null);
  assert.match(props.error!, /403/);
});

test('a thrown request is caught and reported, not propagated', async () => {
  const request = (async () => { throw new Error('socket hang up'); }) as any;
  const props = await fetchRepoProperties('o/r', request);
  assert.match(props.error!, /socket hang up/);
});

test('no source file reads custom_properties from a webhook payload', async () => {
  // The guard for the asymmetry the spec names: `repository.custom_properties`
  // exists on a pull_request payload and NOT on `GET /pulls/{n}`, which the
  // check_suite re-evaluation path uses. A future "optimisation" that reads the
  // payload to save this fetch would work on `opened` and silently degrade on
  // every re-evaluation — the worst kind of bug, because the first evaluation
  // looks correct. This test is what makes that regression loud.
  const { readdir, readFile } = await import('node:fs/promises');
  const roots = ['src', 'src/signals'];
  const offenders: string[] = [];

  for (const dir of roots) {
    for (const name of await readdir(dir)) {
      if (!name.endsWith('.ts')) continue;
      const path = `${dir}/${name}`;
      if ((await readFile(path, 'utf8')).includes('custom_properties')) offenders.push(path);
    }
  }

  assert.deepEqual(offenders, [], 'read properties via fetchRepoProperties instead');
});

test('tier ranking is ordinal, least to most critical', () => {
  assert.deepEqual(
    ['paper', 'bronze', 'silver', 'gold', 'platinum'].map((t) => TIER_RANK[t]),
    [0, 1, 2, 3, 4],
  );
});

test('tierRank returns null for unset and unrecognised tiers', () => {
  assert.equal(tierRank(null), null);
  assert.equal(tierRank('titanium'), null);
  assert.equal(tierRank('Gold'), null, 'already-lowercased input is expected here');
  assert.equal(tierRank('gold'), 3);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/repo-properties.js'`

- [ ] **Step 3: Write the implementation**

Create `src/repo-properties.ts`:

```ts
// Reads the repository custom properties the sensitivity gates depend on.
//
// NOT from the webhook payload. `repository.custom_properties` is present on a
// pull_request event and absent from `GET /pulls/{n}`, which is what the
// check_suite re-evaluation path uses — so a payload-based gate would work on
// `opened` and silently degrade on every re-evaluation. One explicit call,
// identical on both paths, is worth more than the saved request.
import { githubRequest } from './github.js';
import { log } from './log.js';

/**
 * Resiliency tiers, least to most critical.
 *
 * Lowercase. The `resiliency_tier` property's values are Title Case because
 * humans read them in GitHub's settings UI; that is the right choice for the
 * property and the wrong one to carry into code, so it is lowercased once at
 * the boundary below and nowhere else.
 */
export const TIER_RANK: Record<string, number> = {
  paper: 0, bronze: 1, silver: 2, gold: 3, platinum: 4,
};

/**
 * Rank a tier, or null when it is unset or unrecognised.
 *
 * Null rather than 0: an unrecognised tier must fail its gate, not rank as the
 * least critical value and quietly pass everything.
 */
export function tierRank(tier: string | null): number | null {
  if (tier === null) return null;
  return TIER_RANK[tier] ?? null;
}

/** The repository properties the eligibility gates read. */
export interface RepoProperties {
  /** Lowercased production resiliency tier, or null when unset. */
  resiliencyTier: string | null;
  /** null when unset — the property is org-required, so null means misconfigured. */
  isSoc2Compliant: boolean | null;
  /** Why the values are null. Present only when the fetch itself failed. */
  error?: string;
}

const EMPTY = (error: string): RepoProperties =>
  ({ resiliencyTier: null, isSoc2Compliant: null, error });

/**
 * Fetch a repository's custom properties.
 *
 * Never throws: a failure returns nulls plus an error string, and the gates
 * fail closed with that string as their reason. Returning a permissive default
 * on a failed fetch would let an outage grant automation.
 *
 * GitHub omits unset properties from the response rather than returning them
 * null, so absent and unset are indistinguishable here — and both fail closed,
 * which makes the distinction moot.
 */
export async function fetchRepoProperties(
  repoFullName: string,
  request: typeof githubRequest = githubRequest,
): Promise<RepoProperties> {
  try {
    const res = await request(`/repos/${repoFullName}/properties/values`);
    if (!res.ok) {
      log('warn', 'repo_properties_fetch_failed', { repo: repoFullName, status: res.status });
      return EMPTY(`repository properties could not be read (HTTP ${res.status})`);
    }

    const body = (await res.json()) as { property_name?: string; value?: string | null }[];
    const value = (name: string): string | null =>
      body.find((p) => p.property_name === name)?.value ?? null;

    const tier = value('resiliency_tier');
    const soc2 = value('is_soc2_compliant');

    return {
      resiliencyTier: tier === null ? null : tier.toLowerCase(),
      isSoc2Compliant: soc2 === null ? null : soc2 === 'true',
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    log('warn', 'repo_properties_fetch_failed', { repo: repoFullName, error: message });
    return EMPTY(`repository properties could not be read (${message})`);
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS, 8 tests

- [ ] **Step 5: Verify against the real repository once**

```bash
node --import tsx -e "
import { fetchRepoProperties } from './src/repo-properties.ts';
const res = await fetch('https://api.github.com/repos/bankrate/platform-cicd-v2-demo/properties/values', {
  headers: { Authorization: 'Bearer ' + process.env.GH_TOKEN, Accept: 'application/vnd.github+json' },
});
console.log(JSON.stringify(await res.json(), null, 2));
" 2>/dev/null || gh api repos/bankrate/platform-cicd-v2-demo/properties/values
```

Expected: `is_poc=true`, `is_soc2_compliant=false`, `resiliency_tier=Paper`. Confirm the fixture in
Step 1 still matches the live shape; if GitHub has changed it, fix the fixture rather than the test.

- [ ] **Step 6: Commit**

```bash
git add src/repo-properties.ts tests/repo-properties.test.ts
git commit -m "feat: read repo custom properties, lowercasing the tier at the boundary"
```

---

### Task 3: Give the gates the data they need

The structural change. `evaluate.ts` currently fetches check runs at line 99, **inside** `assessRisk`,
which runs at line 159 — after `runGates` at 145. Gates 11 and 12 read check runs, so the fetch moves
above the gates and the result is passed down rather than fetched twice.

**Files:**
- Modify: `src/gates.ts` (`GateInput` only — no gate logic yet)
- Modify: `src/evaluate.ts`
- Modify: `tests/gates.test.ts`, `tests/evaluate.test.ts`

**Interfaces:**
- Consumes: `CheckRunSummary` from `src/check-runs.ts`; `RepoProperties` from Task 2
- Produces: `GateInput` gains `runs: CheckRunSummary[]` and `properties: RepoProperties`; `EvaluateDeps` gains `fetchRepoProperties`

- [ ] **Step 1: Write the failing test**

Append to `tests/evaluate.test.ts`:

```ts
test('check runs are fetched once and shared by gates and risk', async () => {
  let fetches = 0;
  const d = riskDeps(27, {
    fetchCheckRuns: async () => { fetches++; return []; },
    fetchRepoProperties: async () => ({ resiliencyTier: 'paper', isSoc2Compliant: false }),
  });
  await evaluate(ctx(27), d as any);
  assert.equal(fetches, 1, 'hoisted above runGates, not fetched again for risk');
});

test('repository properties are fetched for every evaluation', async () => {
  const seen: string[] = [];
  const d = riskDeps(27, {
    fetchRepoProperties: async (repo: string) => {
      seen.push(repo);
      return { resiliencyTier: 'paper', isSoc2Compliant: false };
    },
  });
  await evaluate(ctx(27), d as any);
  assert.deepEqual(seen, ['bankrate/platform-cicd-v2-demo']);
});

test('an unenrolled repo costs no property fetch', async () => {
  let called = false;
  const d = riskDeps(27, {
    fetchRepoProperties: async () => { called = true; return { resiliencyTier: null, isSoc2Compliant: null }; },
  });
  await evaluate(ctx(27, 'bankrate/not-enrolled'), d as any);
  assert.equal(called, false);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `fetchRepoProperties` is not on `EvaluateDeps`

- [ ] **Step 3: Extend `GateInput` in `src/gates.ts`**

```ts
  /** Check runs on the head SHA. Gates 11 and 12 read these. */
  runs: CheckRunSummary[];
  /** Repository custom properties. Gates 13 and 14 read these. */
  properties: RepoProperties;
```

with `import type { CheckRunSummary } from './check-runs.js';` and
`import type { RepoProperties } from './repo-properties.js';`.

- [ ] **Step 4: Hoist the fetches in `src/evaluate.ts`**

Add `fetchRepoProperties: typeof fetchRepoProperties;` to `EvaluateDeps` and to `defaultDeps`, with
its import.

Change `assessRisk`'s signature to accept the already-fetched runs instead of fetching them:

```ts
async function assessRisk(
  ctx: EvalContext,
  classification: ClassificationResult,
  thresholds: RiskThresholds,
  runs: CheckRunSummary[],
  deps: EvaluateDeps,
): Promise<{ risk: RiskResult; completeness: Completeness }> {
```

and **delete** the `safely('check_runs', …)` entry from its `Promise.all`, destructuring the
remaining three results accordingly. The `runs` parameter replaces it.

In `evaluate`, after the `files` fetch and **before** `runGates`:

```ts
  // Hoisted above runGates: gates 11 and 12 read check runs, and gates 13 and
  // 14 read repository properties. Both were previously fetched only inside
  // assessRisk, which runs after the gates and only for candidates.
  //
  // Skipped entirely for a repo we do not evaluate, exactly as the files fetch
  // is — gate 1 fails regardless and an unenrolled repo should cost us nothing.
  const skipFetches = enrollment === undefined || enrollment.mode === 'off';

  const [runs, properties] = skipFetches
    ? [[] as CheckRunSummary[], { resiliencyTier: null, isSoc2Compliant: null } as RepoProperties]
    : await Promise.all([
        deps.fetchCheckRuns(ctx.repoFullName, ctx.headSha),
        deps.fetchRepoProperties(ctx.repoFullName),
      ]);
```

Add `runs` and `properties` to the `runGates({ … })` call, and pass `runs` to `assessRisk`.

- [ ] **Step 5: Update the gate test harness**

`tests/gates.test.ts`'s `fromFixture` helper builds `GateInput`. Add the two new fields to its
defaults so existing tests keep compiling:

```ts
    runs: [],
    properties: { resiliencyTier: 'paper', isSoc2Compliant: false },
```

Existing gate tests assert on gates 1–10 and `freezeOff`, all unaffected by these fields.

- [ ] **Step 6: Run the suite**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS. Gates 11–14 do not exist yet; this task only moves data.

- [ ] **Step 7: Commit**

```bash
git add src/gates.ts src/evaluate.ts tests/gates.test.ts tests/evaluate.test.ts
git commit -m "refactor: fetch check runs and repo properties before running the gates"
```

---

### Task 4: The four gates

**Files:**
- Modify: `src/gates.ts`
- Modify: `src/signals/coverage.ts` (export the title parser)
- Modify: `tests/gates.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 1–3
- Produces: `GATE_ORDER` gains `checksGreen`, `coverageFloor`, `resiliencyTierPermits`, `soc2Permits` before `freezeOff`; `parseCoverageTitle` exported from `src/signals/coverage.ts`

- [ ] **Step 1: Write the failing tests**

Append to `tests/gates.test.ts`:

```ts
const green = (name: string) => ({ name, status: 'completed', conclusion: 'success', title: null });
const BLOCKING = ['Cycode: SAST', 'Cycode: Secrets', 'Cycode: Vulnerable Dependencies',
                  'Build and scan image', 'Terraform plan (speculative)'];
const allGreen = () => BLOCKING.map(green);
const coverage = (pct: number) => ({
  name: 'codecov/project', status: 'completed', conclusion: 'success',
  title: `${pct}% (+0.00%) compared to abc1234`,
});

test('the ladder is 15 gates with freezeOff last', () => {
  assert.equal(GATE_ORDER.length, 15);
  assert.equal(GATE_ORDER[GATE_ORDER.length - 1], 'freezeOff');
  assert.deepEqual(GATE_ORDER.slice(10, 14),
    ['checksGreen', 'coverageFloor', 'resiliencyTierPermits', 'soc2Permits']);
});

test('all blocking checks green passes gate 11', () => {
  const r = runGates(fromFixture(27, { runs: [...allGreen(), coverage(80)] }));
  assert.equal(r.gates.checksGreen.verdict, 'pass');
});

test('a failing blocking check fails gate 11 and names it', () => {
  const runs = [{ ...green('Cycode: SAST'), conclusion: 'failure' }, ...allGreen().slice(1), coverage(80)];
  const r = runGates(fromFixture(27, { runs }));
  assert.equal(r.gates.checksGreen.verdict, 'fail');
  assert.match(JSON.stringify(r.gates.checksGreen.value), /Cycode: SAST/);
});

test('a MISSING blocking check fails gate 11 — absence is not green', () => {
  const r = runGates(fromFixture(27, { runs: [...allGreen().slice(1), coverage(80)] }));
  assert.equal(r.gates.checksGreen.verdict, 'fail');
  assert.match(JSON.stringify(r.gates.checksGreen.value), /Cycode: SAST/);
});

test('an in-progress blocking check fails gate 11', () => {
  const runs = [{ ...green('Cycode: SAST'), status: 'in_progress', conclusion: null }, ...allGreen().slice(1), coverage(80)];
  assert.equal(runGates(fromFixture(27, { runs })).gates.checksGreen.verdict, 'fail');
});

test('neutral and skipped both count as green', () => {
  const runs = [
    { ...green('Cycode: SAST'), conclusion: 'neutral' },
    { ...green('Cycode: Secrets'), conclusion: 'skipped' },
    ...allGreen().slice(2), coverage(80),
  ];
  assert.equal(runGates(fromFixture(27, { runs })).gates.checksGreen.verdict, 'pass');
});

test('an undeclared failing check is ignored by gate 11', () => {
  const runs = [...allGreen(), coverage(80), { ...green('Commit lint'), conclusion: 'failure' }];
  assert.equal(runGates(fromFixture(27, { runs })).gates.checksGreen.verdict, 'pass');
});

test('a per-repo blockingChecks override replaces the global list', () => {
  const enrollment = { ...enrollmentFor(DEMO)!, blockingChecks: ['Cycode: SAST'] };
  const r = runGates(fromFixture(27, { enrollment, runs: [green('Cycode: SAST'), coverage(80)] }));
  assert.equal(r.gates.checksGreen.verdict, 'pass', 'the other four are not required here');
});

test('coverage above the floor passes gate 12', () => {
  const r = runGates(fromFixture(27, { runs: [...allGreen(), coverage(62.99)] }));
  assert.equal(r.gates.coverageFloor.verdict, 'pass');
  assert.match(JSON.stringify(r.gates.coverageFloor.value), /62.99/);
});

test('coverage below the floor fails gate 12', () => {
  const tight = { ...rules(), changeClasses: { ...rules().changeClasses,
    'dep-minor': { ...rules().changeClasses['dep-minor']!, minCoveragePct: 80 } } };
  const r = runGates(fromFixture(27, { rules: tight, runs: [...allGreen(), coverage(62.99)] }));
  assert.equal(r.gates.coverageFloor.verdict, 'fail');
});

test('absent coverage FAILS gate 12 — it does not skip', () => {
  const r = runGates(fromFixture(27, { runs: allGreen() }));
  assert.equal(r.gates.coverageFloor.verdict, 'fail');
  assert.match(JSON.stringify(r.gates.coverageFloor.value), /codecov\/project/);
});

test('the demo repo Paper tier passes gate 13 under every configured ceiling', () => {
  const runs = [...allGreen(), coverage(80)];
  const props = { resiliencyTier: 'paper', isSoc2Compliant: false };

  // paper is rank 0, so it clears every ceiling the rules file declares. Assert
  // that against each class's real configured value rather than trusting one.
  for (const name of Object.keys(rules().changeClasses)) {
    const forced = {
      ...rules(),
      changeClasses: {
        ...rules().changeClasses,
        'dep-minor': { ...rules().changeClasses['dep-minor']!,
                       maxResiliencyTier: rules().changeClasses[name]!.maxResiliencyTier },
      },
    };
    const r = runGates(fromFixture(27, { rules: forced, runs, properties: props }));
    assert.equal(r.gates.resiliencyTierPermits.verdict, 'pass',
      `paper should clear ${name}'s ceiling (${rules().changeClasses[name]!.maxResiliencyTier})`);
  }
});

test('a tier above the ceiling fails gate 13', () => {
  const r = runGates(fromFixture(27, {
    runs: [...allGreen(), coverage(80)],
    properties: { resiliencyTier: 'platinum', isSoc2Compliant: false },
  }));
  assert.equal(r.gates.resiliencyTierPermits.verdict, 'fail');
  assert.match(JSON.stringify(r.gates.resiliencyTierPermits.value), /platinum/);
});

test('an unset tier fails gate 13 — unknown criticality is maximum criticality', () => {
  const r = runGates(fromFixture(27, {
    runs: [...allGreen(), coverage(80)],
    properties: { resiliencyTier: null, isSoc2Compliant: false },
  }));
  assert.equal(r.gates.resiliencyTierPermits.verdict, 'fail');
});

test('an unrecognised tier fails rather than ranking lowest', () => {
  const r = runGates(fromFixture(27, {
    runs: [...allGreen(), coverage(80)],
    properties: { resiliencyTier: 'titanium', isSoc2Compliant: false },
  }));
  assert.equal(r.gates.resiliencyTierPermits.verdict, 'fail');
});

test('a failed property fetch fails gates 13 and 14 with its reason', () => {
  const props = { resiliencyTier: null, isSoc2Compliant: null, error: 'repository properties could not be read (HTTP 403)' };
  const r = runGates(fromFixture(27, { runs: [...allGreen(), coverage(80)], properties: props }));
  assert.equal(r.gates.resiliencyTierPermits.verdict, 'fail');
  assert.equal(r.gates.soc2Permits.verdict, 'fail');
  assert.match(JSON.stringify(r.gates.soc2Permits.value), /403/);
});

test('a non-SOC2 repo passes gate 14 regardless of soc2Eligible', () => {
  const r = runGates(fromFixture(27, {
    runs: [...allGreen(), coverage(80)],
    properties: { resiliencyTier: 'paper', isSoc2Compliant: false },
  }));
  assert.equal(r.gates.soc2Permits.verdict, 'pass');
});

test('a SOC2 repo fails gate 14 unless the class is soc2Eligible', () => {
  const props = { resiliencyTier: 'paper', isSoc2Compliant: true };
  const runs = [...allGreen(), coverage(80)];
  assert.equal(runGates(fromFixture(27, { runs, properties: props })).gates.soc2Permits.verdict, 'fail');

  const eligible = { ...rules(), changeClasses: { ...rules().changeClasses,
    'dep-minor': { ...rules().changeClasses['dep-minor']!, soc2Eligible: true } } };
  assert.equal(runGates(fromFixture(27, { rules: eligible, runs, properties: props })).gates.soc2Permits.verdict, 'pass');
});

test('an unset is_soc2_compliant fails gate 14 — the property is org-required', () => {
  const r = runGates(fromFixture(27, {
    runs: [...allGreen(), coverage(80)],
    properties: { resiliencyTier: 'paper', isSoc2Compliant: null },
  }));
  assert.equal(r.gates.soc2Permits.verdict, 'fail');
});

test('an unclassified change skips gates 11-14, never fails them', () => {
  const r = runGates(fromFixture(37));
  for (const g of ['checksGreen', 'coverageFloor', 'resiliencyTierPermits', 'soc2Permits'] as const) {
    assert.equal(r.gates[g].verdict, 'skipped', g);
  }
});

test('PR #27 is still a candidate at 15 of 15', () => {
  const r = runGates(fromFixture(27, {
    runs: [...allGreen(), coverage(62.99)],
    properties: { resiliencyTier: 'paper', isSoc2Compliant: false },
  }));
  assert.equal(r.verdict, 'candidate');
  assert.equal(r.failedGate, null);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `GATE_ORDER` has 11 entries

- [ ] **Step 3: Export the coverage title parser**

In `src/signals/coverage.ts`, extract the existing regex parse into an exported function so gate 12
and the risk signal cannot drift apart:

```ts
/** Parsed `codecov/project` title, e.g. `62.99% (+0.00%) compared to 62d5a6a`. */
export interface ParsedCoverage {
  currentPct: number;
  deltaPct: number;
}

/**
 * Parse a Codecov project title, or null when it does not match.
 *
 * Exported so the coverage FLOOR gate reads the same string the coverage DELTA
 * signal does — two regexes over one upstream format would drift.
 */
export function parseCoverageTitle(title: string | null): ParsedCoverage | null {
  if (!title) return null;
  const match = TITLE.exec(title);
  if (!match) return null;
  const currentPct = Number(match[1]);
  const deltaPct = Number(match[2]);
  if (!Number.isFinite(currentPct) || !Number.isFinite(deltaPct)) return null;
  return { currentPct, deltaPct };
}
```

Then rewrite `coverageDelta`'s body to call it, keeping its existing unknown-reason strings unchanged
so `tests/signals-coverage.test.ts` still passes.

- [ ] **Step 4: Add the four gates to `src/gates.ts`**

Extend `GATE_ORDER`, inserting before `freezeOff`:

```ts
  'tierFloor',
  'checksGreen',
  'coverageFloor',
  'resiliencyTierPermits',
  'soc2Permits',
  'freezeOff',
```

Add near the other constants:

```ts
// `neutral` and `skipped` are green: a skipped Terraform plan on a pull request
// touching no Terraform is not a failure, and our own checks are neutral by
// construction. Treating either as red would make every PR ineligible.
const GREEN = new Set(['success', 'neutral', 'skipped']);
const COVERAGE_CHECK = 'codecov/project';
```

with `import { parseCoverageTitle } from './signals/coverage.js';` and
`import { tierRank } from './repo-properties.js';`.

Inside the `else` branch where gates 6–10 are computed (the branch that runs when the change class is
known), append:

```ts
    // 11 — every declared blocking check must be green. A per-repo list
    // REPLACES the global one; read from GateInput rather than a helper so this
    // module stays pure.
    const blocking = input.enrollment?.blockingChecks ?? input.rules.blockingChecks;
    const notGreen = blocking.filter((name) => {
      const run = input.runs.find((r) => r.name === name);
      // Absent is NOT green: a scanner that has not reported must never read as
      // a clean scan.
      return run === undefined || run.status !== 'completed' || !GREEN.has(run.conclusion ?? '');
    });
    gates.checksGreen = gate(notGreen.length === 0, { notGreen, checked: blocking.length });

    // 12 — coverage floor. Absent FAILS rather than skips: "no coverage at all"
    // must not be treated better than "low coverage".
    const coverageRun = input.runs.find((r) => r.name === COVERAGE_CHECK);
    const parsed = parseCoverageTitle(coverageRun?.title ?? null);
    gates.coverageFloor = parsed === null
      ? fail({ reason: `${COVERAGE_CHECK} has not reported a coverage percentage`, floor: cls.minCoveragePct })
      : gate(parsed.currentPct >= cls.minCoveragePct, { currentPct: parsed.currentPct, floor: cls.minCoveragePct });

    // 13 — resiliency tier ceiling. Unset or unrecognised FAILS: unknown
    // criticality is treated as maximum criticality.
    const have = tierRank(input.properties.resiliencyTier);
    const ceiling = tierRank(cls.maxResiliencyTier);
    gates.resiliencyTierPermits = have === null || ceiling === null
      ? fail({
          tier: input.properties.resiliencyTier,
          ceiling: cls.maxResiliencyTier,
          reason: input.properties.error ?? 'resiliency_tier is not set on this repository',
        })
      : gate(have <= ceiling, { tier: input.properties.resiliencyTier, ceiling: cls.maxResiliencyTier });

    // 14 — SOC2. Unset fails: the property is org-required, so its absence
    // means the repository is misconfigured rather than that the rule is moot.
    const soc2 = input.properties.isSoc2Compliant;
    gates.soc2Permits = soc2 === null
      ? fail({ reason: input.properties.error ?? 'is_soc2_compliant is not set on this repository' })
      : gate(!soc2 || cls.soc2Eligible, { soc2, classEligible: cls.soc2Eligible });
```

And in the `if (!classified …)` branch that skips gates 6–10, add the four new skips:

```ts
    gates.checksGreen = skip();
    gates.coverageFloor = skip();
    gates.resiliencyTierPermits = skip();
    gates.soc2Permits = skip();
```

- [ ] **Step 5: Run the suite**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/gates.ts src/signals/coverage.ts tests/gates.test.ts
git commit -m "feat: gates for blocking checks, coverage floor, resiliency tier and SOC2"
```

---

### Task 5: Render the four new rows

**Files:**
- Modify: `src/render.ts`
- Modify: `tests/render.test.ts`

**Interfaces:**
- Consumes: the gate value shapes from Task 4
- Produces: `gateCell` handles the four new gate names; `rejectionDetail` explains each

- [ ] **Step 1: Write the failing tests**

Append to `tests/render.test.ts`:

```ts
test('the gate table now has 15 rows', () => {
  const rows = render(27).summary.split('\n').filter((l) => /^\| [✅❌⏭️❓] \|/.test(l));
  assert.equal(rows.length, 15);
});

test('each new gate renders what it observed', () => {
  const out = render(27);
  assert.match(out.summary, /\| .. \| checksGreen \| \d+ of \d+ green \|/);
  assert.match(out.summary, /\| .. \| coverageFloor \| [\d.]+% \(floor \d+%\) \|/);
  assert.match(out.summary, /\| .. \| resiliencyTierPermits \| `paper` ≤ `\w+` \|/);
  assert.match(out.summary, /\| .. \| soc2Permits \| not SOC2-scoped \|/);
});

test('a failing blocking check names it in the row', () => {
  const out = renderFailing('checksGreen', { notGreen: ['Cycode: SAST'], checked: 5 });
  assert.match(out.summary, /Cycode: SAST/);
});

test('an unset tier explains itself rather than showing null', () => {
  const out = renderFailing('resiliencyTierPermits', {
    tier: null, ceiling: 'gold', reason: 'resiliency_tier is not set on this repository',
  });
  assert.match(out.summary, /not set on this repository/);
  assert.doesNotMatch(out.summary, /null/);
});

test('the rejection lead line explains each new gate in plain language', () => {
  assert.match(renderFailing('coverageFloor', { reason: 'codecov/project has not reported a coverage percentage', floor: 60 }).summary, /coverage/i);
  assert.match(renderFailing('soc2Permits', { soc2: true, classEligible: false }).summary, /SOC ?2/i);
});
```

Add this helper beside the existing `render`:

```ts
/** Build a rendering whose first failure is `name`, to exercise one row. */
function renderFailing(name: string, value: unknown) {
  const pr = payload(27); const f = files(27);
  const classification = classify(f, rules().generatedPaths);
  const result = runGates({
    repoFullName: DEMO, title: pr.title, body: pr.body ?? '', authorLogin: pr.user.login,
    files: f, enrollment: enrollmentFor(DEMO), rules: rules(), classification,
    runs: [], properties: { resiliencyTier: 'paper', isSoc2Compliant: false },
  });
  // Override the one gate under test so the row and lead line are exercised
  // without hand-building a whole EligibilityResult.
  const gates = { ...result.gates, [name]: { verdict: 'fail' as const, value } };
  return renderEligibility({ ...result, gates, verdict: 'not-candidate', failedGate: name as any }, classification);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — the table has 11 rows and the new cells render `—`

- [ ] **Step 3: Add the cases to `gateCell` in `src/render.ts`**

```ts
    case 'checksGreen': {
      const v2 = v as { notGreen: string[]; checked: number };
      return v2.notGreen.length === 0
        ? `${v2.checked} of ${v2.checked} green`
        : v2.notGreen.map((n: string) => `\`${n}\``).join(', ');
    }
    case 'coverageFloor':
      return v?.currentPct === undefined
        ? String(v?.reason ?? 'no coverage reported')
        : `${v.currentPct}% (floor ${v.floor}%)`;
    case 'resiliencyTierPermits':
      return v?.tier
        ? `\`${v.tier}\` ${result.verdict === 'pass' ? '≤' : '>'} \`${v.ceiling}\``
        : String(v?.reason ?? 'tier not set');
    case 'soc2Permits':
      if (v?.soc2 === undefined || v?.soc2 === null) return String(v?.reason ?? 'SOC2 status unknown');
      return v.soc2
        ? (v.classEligible ? 'SOC2-scoped, class permitted' : 'SOC2-scoped, class not permitted')
        : 'not SOC2-scoped';
```

- [ ] **Step 4: Add the cases to `rejectionDetail` in `src/render.ts`**

```ts
    case 'checksGreen': {
      const names = (value as { notGreen: string[] }).notGreen.map((n) => `\`${n}\``).join(', ');
      return `These required checks are not green on this commit: ${names}. A check that has not reported yet counts as not green.`;
    }
    case 'coverageFloor': {
      const v = value as { currentPct?: number; floor: number; reason?: string };
      return v.currentPct === undefined
        ? `Project coverage could not be read, and \`${result.changeClass}\` requires at least ${v.floor}%. ${v.reason ?? ''}`.trim()
        : `Project coverage is ${v.currentPct}%, below the ${v.floor}% floor for \`${result.changeClass}\`.`;
    }
    case 'resiliencyTierPermits': {
      const v = value as { tier: string | null; ceiling: string; reason?: string };
      return v.tier
        ? `This repository's production resiliency tier is \`${v.tier}\`, above the \`${v.ceiling}\` ceiling for \`${result.changeClass}\`.`
        : `This repository's production resiliency tier could not be determined — ${v.reason}. Automation is withheld until it is set.`;
    }
    case 'soc2Permits': {
      const v = value as { soc2?: boolean | null; reason?: string };
      return v.soc2 === true
        ? `This repository is in scope for SOC 2, and \`${result.changeClass}\` changes are not eligible for automation on SOC 2 repositories.`
        : `This repository's SOC 2 status could not be determined — ${v.reason}.`;
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

- [ ] **Step 6: Read the rendered table as a stranger would**

```bash
node --import tsx -e "
import {readFileSync} from 'fs';
import {renderEligibility} from './src/render.ts';
import {runGates} from './src/gates.ts'; import {classify} from './src/classify.ts';
import {rules} from './src/rules.ts'; import {enrollmentFor} from './src/enrollment.ts';
const D='bankrate/platform-cicd-v2-demo';
const g=(n)=>({name:n,status:'completed',conclusion:'success',title:null});
const runs=[...['Cycode: SAST','Cycode: Secrets','Cycode: Vulnerable Dependencies','Build and scan image','Terraform plan (speculative)'].map(g),
  {name:'codecov/project',status:'completed',conclusion:'success',title:'62.99% (+0.00%) compared to abc1234'}];
for (const n of [27,32,37]) {
  const pr=JSON.parse(readFileSync(\`tests/fixtures/pr-\${n}-payload.json\`,'utf8'));
  const f=JSON.parse(readFileSync(\`tests/fixtures/pr-\${n}-files.json\`,'utf8'));
  const c=classify(f,rules().generatedPaths);
  const r=runGates({repoFullName:D,title:pr.title,body:pr.body??'',authorLogin:pr.user.login,files:f,
    enrollment:enrollmentFor(D),rules:rules(),classification:c,runs,
    properties:{resiliencyTier:'paper',isSoc2Compliant:false}});
  const o=renderEligibility(r,c);
  console.log('='.repeat(74)); console.log('PR '+n+': '+o.title); console.log(); console.log(o.summary); console.log();
}"
```

Check all 15 rows are present and aligned, and that no cell shows `null`, `undefined` or `[object Object]`.

- [ ] **Step 7: Commit**

```bash
git add src/render.ts tests/render.test.ts
git commit -m "feat: render the four new gate rows"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/policy.md`, `AGENTS.md`

- [ ] **Step 1: Extend `docs/policy.md`**

It is the reader-facing page both checks link. Add the four gates to its gate table, using the same
names the check run shows, and explain each in the terms its audience cares about:

- `checksGreen` — security scanners, the image scan and the Terraform plan must be green; a check
  that has not reported yet counts as not green.
- `coverageFloor` — the repository's project coverage must clear a minimum, which is separate from
  the risk signal that measures whether this PR *changed* coverage.
- `resiliencyTierPermits` — what the production resiliency tier means, that it comes from the
  `resiliency_tier` repository property, that a repo admin sets it in repository Settings → Custom
  properties, and that an unset tier withholds automation.
- `soc2Permits` — SOC 2-scoped repositories are held to a stricter set of change classes.

Add the current thresholds per change class, noting they are the current values and the check run
always shows what it actually compared against.

- [ ] **Step 2: Append to `AGENTS.md`**

Concise, pointing at authoritative files:

- Repo properties are read with `GET /repos/{o}/{r}/properties/values`, never the webhook payload —
  `repository.custom_properties` is absent from `GET /pulls/{n}`, which the `check_suite`
  re-evaluation path uses, so a payload-based gate works on `opened` and silently degrades after.
- `resiliency_tier` values are Title Case (`Paper`) because humans read them in GitHub's settings
  UI. `src/repo-properties.ts` lowercases once at the boundary; the rules file, the ranking and every
  comparison are lowercase. The build rejects a Title Case tier in `policy-rules.yaml`.
- The property is `values_editable_by: org_and_repo_actors`, so a repo admin can set their own tier.
  Gate 13 is self-attestation, not enforcement.
- `blockingChecks` (must be green to be a candidate) and `signalChecks` (when the risk grade is
  final) are different questions that happen to overlap on Cycode. Do not merge them.
- Check runs and repo properties are fetched **before** `runGates` and passed down to the risk
  evaluator; do not reintroduce a second fetch inside `assessRisk`.

- [ ] **Step 3: Commit**

```bash
git add docs/policy.md AGENTS.md
git commit -m "docs: explain the scan, coverage and sensitivity gates"
```

---

### Task 7: Deploy to QA and validate live

**Files:** none — verification only.

- [ ] **Step 1: Open the pull request**

```bash
gh pr create --repo bankrate/zapp --base main --head feat/scan-gates-and-resiliency-tier \
  --title "feat: scan gates, coverage floor and resiliency-tier eligibility" \
  --body "Spec lives in firstmate: docs/superpowers/zapp/specs/2026-08-25-scan-gates-and-resiliency-tier-design.md"
```

Confirm CI passes, including the rules drift check and the Docker build.

- [ ] **Step 2: Merge and cut a QA pre-release**

Merge, then publish a pre-release tag (e.g. `v1.6.0-rc.1`) so `deploy-v2.yml` stops after QA.

- [ ] **Step 3: Confirm the demo repo still reads as expected**

```bash
gh api repos/bankrate/platform-cicd-v2-demo/properties/values --jq '.[] | "\(.property_name)=\(.value)"'
```

Expected: `resiliency_tier=Paper`, `is_soc2_compliant=false`.

- [ ] **Step 4: Trigger an evaluation and let CI finish**

```bash
gh pr checkout 27 --repo bankrate/platform-cicd-v2-demo
git commit --allow-empty -m "chore: re-trigger merge-policy evaluation"
git push
```

Wait for all checks green — gates 11 and 12 read them, so an early read will show a legitimate
failure rather than a bug.

- [ ] **Step 5: Confirm 15 of 15**

```bash
SHA=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/27 --jq .head.sha)
gh api "repos/bankrate/platform-cicd-v2-demo/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name=="merge-policy/eligibility") | .output.summary' | head -30
```

Expected: `Would have been a candidate — dep-minor`, a 15-row table, `15 of 15 gates passed`, and
`resiliencyTierPermits` showing `` `paper` ≤ `silver` ``.

- [ ] **Step 6: Prove the tier gate actually bites**

The deliberate negative. In repository Settings → Custom properties, set the demo repo's
`resiliency_tier` to **`Platinum`**, push another empty commit, and confirm the PR becomes a
non-candidate with `resiliencyTierPermits` named as the first failure:

```bash
SHA=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/27 --jq .head.sha)
gh api "repos/bankrate/platform-cicd-v2-demo/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name=="merge-policy/eligibility") | .output.title'
```

Expected: `Not a candidate — dep-minor`.

**Then set it back to `Paper`** and confirm the next evaluation returns to candidate. A gate that
only ever passes has not been tested.

- [ ] **Step 7: Read the rendered table in a browser**

Open the PR's Checks tab. Confirm 15 rows render as a table, the new cells are legible, and nothing
shows `null` or `[object Object]`.

- [ ] **Step 8: Record the evidence**

Post the outputs of Steps 5 and 6 on the zapp PR. Those two are the acceptance criteria; a claim
without its output is not evidence.

---

## Post-implementation

- **Narrow `values_editable_by` to `org_actors`** if gate 13 ever becomes load-bearing outside shadow
  mode. Today a repo admin can set their own tier, which makes it self-attestation.
- **Every future enrolled repo needs `resiliency_tier` set before enrolment.** The property is
  optional org-wide, so an unset repo fails gate 13 and none of its PRs is a candidate — correct, but
  it will read as a regression to whoever forgets.
- **PLAT-1192 (T8)** — the required-checks snapshot. `blockingChecks` is a list *we* require;
  T8 enumerates what the *repository* requires. They overlap and must not be merged.
- **The SNS alerts topic still has no subscribers** — carried since PLAT-1233.
