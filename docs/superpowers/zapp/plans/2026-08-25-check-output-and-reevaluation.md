# Check Output and CI-Finished Re-evaluation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make both merge-policy checks legible — gate and signal tables, a policy doc instead of a Jira link — and make the risk grade complete by re-evaluating as CI reports, saying plainly whether it is finished yet.

**Architecture:** Check runs are updated in place instead of re-created, so re-evaluation costs no extra runs. The worker routes `check_suite: completed` from every app but its own, and a declared `signalChecks` list in `policy-rules.yaml` decides whether each result is provisional or final. Rendering moves from prose to tables built from the gate and signal maps that already exist.

**Tech Stack:** Node 22, TypeScript, `node:test` + `tsx`, esbuild, AWS SDK v3 (DynamoDB), container-image Lambda via `finserv-reusable-gha` CI/CD v2.

**Spec:** [`../specs/2026-08-25-check-output-and-reevaluation-design.md`](../specs/2026-08-25-check-output-and-reevaluation-design.md)

**Repo:** `bankrate/zapp` at v1.4.0. Branch from `main`: `feat/check-output-and-reevaluation`.

## Global Constraints

- **Shadow-mode invariant.** `conclusion: 'neutral'` is a module constant in `src/checks.ts`. This work adds a **second** write path (PATCH alongside POST) — both MUST build their body from one shared private function, and the test asserts `neutral` on whichever verb was used. Never add a parameter that could make a shadow check non-neutral.
- **Our App id is `4702073`**, read at runtime from `getGitHubConfig().app_id` (a **string**; `app.id` from the API is a **number** — compare with `String()`).
- **Drop `check_suite` events from app id `4702073` FIRST, before anything else.** Our check runs live in our own check suite; routing its completion loops forever. This is load-bearing, not defensive.
- **No output may contain `PLAT-1184`.** The policy-doc link replaces it.
- **Policy doc URL, exactly:** `https://github.com/bankrate/zapp/blob/main/docs/policy.md`
- **Icons:** gates — `✅` pass, `❌` fail, `⏭️` skipped, `❓` unknown. Risk grades — `✅` low, `⚠️` medium, `❌` high, `❓` unavailable.
- **All eleven gate rows and all six signal rows render every time**, in `GATE_ORDER` and fixed signal order. No collapsing, no filtering.
- **Eligibility never carries a completeness marker** — all eleven gates read the PR, its diff, enrollment and rules, never another check's result.
- **No timeout promotes provisional to final.** A declared check that never reports leaves a permanently provisional result, naming it.
- **Never log secrets or PR prose.** Repo, PR number, SHAs, gate names, grades and counts are safe. PR title and body are not.
- **Node 22**, ESM — every relative import carries a `.js` extension even from `.ts` sources.
- **Conventional Commits** — `release.yml` runs semantic-release on merge to `main`.
- **`docs/superpowers/` is gitignored in zapp.** Spec and plan live in firstmate. `docs/policy.md` is a *product* doc and does ship.

---

### Task 1: Declare the signal-dependency set

**Files:**
- Modify: `policy-rules.yaml`
- Modify: `src/rules-types.ts`
- Modify: `scripts/build-rules.mjs`
- Modify: `src/enrollment.ts`
- Modify: `tests/build-rules.test.ts`, `tests/enrollment.test.ts`
- Regenerate: `src/generated/rules.ts`

**Interfaces:**
- Consumes: `validatePolicy` from `scripts/build-rules.mjs`; `POLICY` from `src/generated/rules.ts`
- Produces:
  - `Rules.signalChecks: string[]`
  - `EnrollmentRecord.signalChecks?: string[]`
  - `signalChecksFor(repoFullName: string): readonly string[]` in `src/enrollment.ts`

- [ ] **Step 1: Create the branch**

```bash
cd /Users/scrosby/Projects/github/zapp
git checkout main && git pull
git checkout -b feat/check-output-and-reevaluation
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/build-rules.test.ts`. First add `signalChecks: ['Cycode: SAST']` to the `rules` block inside the existing `validDoc()` helper, then:

```ts
test('a missing signalChecks list is rejected', () => {
  const doc = validDoc();
  delete doc.rules.signalChecks;
  assert.match(validatePolicy(doc)[0], /rules\.signalChecks/);
});

test('a non-string entry in signalChecks is rejected', () => {
  const doc = validDoc();
  doc.rules.signalChecks = ['Cycode: SAST', 42];
  assert.match(validatePolicy(doc)[0], /rules\.signalChecks/);
});

test('an empty global signalChecks is valid — it means nothing is waited on', () => {
  const doc = validDoc();
  doc.rules.signalChecks = [];
  assert.deepEqual(validatePolicy(doc), []);
});

test('a per-repo signalChecks override is validated too', () => {
  const doc = validDoc();
  doc.repos[0].signalChecks = ['ok', 7];
  assert.match(validatePolicy(doc)[0], /repos\[0\]\.signalChecks/);
});

test('omitting the per-repo override is valid', () => {
  const doc = validDoc();
  delete doc.repos[0].signalChecks;
  assert.deepEqual(validatePolicy(doc), []);
});

test('the real rules file declares the checks the risk signals read', async () => {
  const { POLICY } = await import('../src/generated/rules.js');
  for (const name of ['Cycode: SAST', 'Cycode: Secrets', 'Cycode: Vulnerable Dependencies', 'codecov/project']) {
    assert.ok(POLICY.rules.signalChecks.includes(name), `${name} declared`);
  }
});
```

Append to `tests/enrollment.test.ts`:

```ts
import { signalChecksFor } from '../src/enrollment.js';

test('an enrolled repo with no override inherits the global list', () => {
  assert.ok(signalChecksFor(DEMO).includes('codecov/project'));
});

test('a per-repo override replaces the global list rather than merging', () => {
  const repos = [{
    repo: 'bankrate/narrow', classification: 'sandbox' as const, ciTrustTier: 2,
    mode: 'shadow' as const, stageEnabled: false, signalChecks: ['Cycode: SAST'],
  }];
  assert.deepEqual(signalChecksFor('bankrate/narrow', repos), ['Cycode: SAST']);
});

test('an empty per-repo override means nothing is waited on', () => {
  const repos = [{
    repo: 'bankrate/nocheck', classification: 'sandbox' as const, ciTrustTier: 2,
    mode: 'shadow' as const, stageEnabled: false, signalChecks: [],
  }];
  assert.deepEqual(signalChecksFor('bankrate/nocheck', repos), []);
});

test('an unenrolled repo falls back to the global list', () => {
  assert.deepEqual(signalChecksFor('bankrate/unknown'), signalChecksFor(DEMO));
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `validatePolicy` accepts a document with no `signalChecks`

- [ ] **Step 4: Add the list to `policy-rules.yaml`**

Inside `rules:`, after `generatedPaths:`:

```yaml
  # Check runs the RISK signals read. An evaluation is final once every one of
  # these has a completed run for the head SHA; until then it is provisional.
  #
  # Declared rather than discovered, because both ways of inferring it are
  # wrong. "Wait for all check suites" never fires — of the fourteen suites on
  # a typical commit here, ten belong to org-installed apps that sit `queued`
  # with zero check runs forever. "Wait for required checks" misses
  # codecov/project, which is not a required context on this repo.
  #
  # Note `codecov/project` comes from the `bankrate-codecov` App (id 370480).
  # The App literally named `codecov` (id 254) is one of the permanently-queued
  # ones — matching on it would wait forever.
  signalChecks:
    - "Cycode: SAST"
    - "Cycode: Secrets"
    - "Cycode: Vulnerable Dependencies"
    - "codecov/project"
```

And on the demo repo's enrollment record, a comment documenting the override without enabling it:

```yaml
    # signalChecks: []   # override to narrow or disable the wait for this repo
```

- [ ] **Step 5: Type it in `src/rules-types.ts`**

Add to `Rules`:

```ts
  /**
   * Check-run names the risk signals depend on. An evaluation is final once
   * every one has completed for the head SHA. Empty means never wait.
   */
  signalChecks: string[];
```

Add to `EnrollmentRecord`:

```ts
  /** Replaces `Rules.signalChecks` for this repo when present. Never merged. */
  signalChecks?: string[];
```

- [ ] **Step 6: Validate in `scripts/build-rules.mjs`**

Inside `validatePolicy`, after the `rules.generatedPaths` check:

```js
  if (!isStrArray(rules.signalChecks)) bad('rules.signalChecks', 'must be an array of strings');
```

And inside the `doc.repos.forEach` loop:

```js
      // Optional. Present-but-wrong is an error; absent means inherit.
      if (r?.signalChecks !== undefined && !isStrArray(r.signalChecks)) {
        bad(`repos[${i}].signalChecks`, 'must be an array of strings when present');
      }
```

- [ ] **Step 7: Add the accessor to `src/enrollment.ts`**

```ts
import { POLICY } from './generated/rules.js';

/**
 * The check runs the risk signals must wait for on this repository.
 *
 * A per-repo list REPLACES the global one rather than extending it — merging
 * would make it impossible to remove a check a repo does not run, which is the
 * main reason to override at all. An empty list means nothing is waited on and
 * every evaluation is immediately final.
 *
 * An unenrolled repo returns the global list; it will fail gate 1 long before
 * this matters, and returning something coherent beats a special case.
 */
export function signalChecksFor(
  repoFullName: string,
  repos: readonly EnrollmentRecord[] = POLICY.repos,
): readonly string[] {
  return enrollmentFor(repoFullName, repos)?.signalChecks ?? POLICY.rules.signalChecks;
}
```

- [ ] **Step 8: Regenerate and run**

```bash
pnpm run build:rules && pnpm test && pnpm run typecheck
```

Expected: PASS. `RULES_SHA` changes because the file changed — correct.

- [ ] **Step 9: Commit**

```bash
git add policy-rules.yaml src/rules-types.ts src/generated/rules.ts scripts/build-rules.mjs \
        src/enrollment.ts tests/build-rules.test.ts tests/enrollment.test.ts
git commit -m "feat: declare the signal-dependency set in policy-rules.yaml"
```

---

### Task 2: Completeness

**Files:**
- Create: `src/completeness.ts`
- Create: `tests/completeness.test.ts`

**Interfaces:**
- Consumes: `CheckRunSummary` from `src/check-runs.ts` — `{ name, status, conclusion, title }`
- Produces:
  - `interface Completeness { final: boolean; pending: string[] }`
  - `assessCompleteness(runs: readonly CheckRunSummary[], declared: readonly string[]): Completeness`

- [ ] **Step 1: Write the failing test**

Create `tests/completeness.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assessCompleteness } from '../src/completeness.js';
import type { CheckRunSummary } from '../src/check-runs.js';

const DECLARED = ['Cycode: SAST', 'Cycode: Secrets', 'Cycode: Vulnerable Dependencies', 'codecov/project'];

const run = (name: string, status = 'completed'): CheckRunSummary =>
  ({ name, status, conclusion: 'success', title: null });

const allDeclared = () => DECLARED.map((n) => run(n));

test('every declared check completed is final', () => {
  assert.deepEqual(assessCompleteness(allDeclared(), DECLARED), { final: true, pending: [] });
});

test('one missing declared check is provisional and names it', () => {
  const runs = allDeclared().filter((r) => r.name !== 'codecov/project');
  assert.deepEqual(assessCompleteness(runs, DECLARED), { final: false, pending: ['codecov/project'] });
});

test('a declared check present but in progress is still pending', () => {
  const runs = [...allDeclared().slice(0, 3), run('codecov/project', 'in_progress')];
  assert.deepEqual(assessCompleteness(runs, DECLARED), { final: false, pending: ['codecov/project'] });
});

test('pending preserves declared order, not check-run order', () => {
  const result = assessCompleteness([run('codecov/project')], DECLARED);
  assert.deepEqual(result.pending, ['Cycode: SAST', 'Cycode: Secrets', 'Cycode: Vulnerable Dependencies']);
});

test('an empty declared list is final immediately', () => {
  assert.deepEqual(assessCompleteness([], []), { final: true, pending: [] });
});

test('no runs at all with a declared list is provisional on everything', () => {
  assert.deepEqual(assessCompleteness([], DECLARED), { final: false, pending: DECLARED });
});

test('a failing declared check still counts as reported', () => {
  // Completeness asks "has it reported", not "did it pass". The scanner signal
  // grades the verdict; this only decides whether we are still waiting.
  const runs = DECLARED.map((n) => ({ name: n, status: 'completed', conclusion: 'failure', title: null }));
  assert.equal(assessCompleteness(runs, DECLARED).final, true);
});

test('undeclared checks are ignored, however many there are', () => {
  // THE case this whole design exists for: a commit carries suites and runs
  // from org-installed apps that have nothing to do with our signals. None of
  // them may delay `final`.
  const noise = ['Build, test, and lint', 'Commit lint', 'Release', 'Terraform plan (speculative)']
    .map((n) => run(n, 'queued'));
  assert.equal(assessCompleteness([...allDeclared(), ...noise], DECLARED).final, true);
});

test('our own check runs never count toward completeness', () => {
  const ours = [run('merge-policy/eligibility'), run('merge-policy/risk')];
  assert.equal(assessCompleteness([...allDeclared(), ...ours], DECLARED).final, true);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/completeness.js'`

- [ ] **Step 3: Write the implementation**

Create `src/completeness.ts`:

```ts
// Decides whether a risk evaluation saw everything it was waiting for.
//
// The declared set comes from policy-rules.yaml, not from inspecting the
// commit, because neither obvious inference works:
//
//   - "all check suites completed" never fires. A commit here carries ~14
//     check suites and only ~4 ever produce a check run; the rest belong to
//     org-installed apps and sit `queued` with zero runs forever.
//   - "all required checks completed" misses codecov/project, which is not a
//     required context on the repo whose coverage signal needs it.
//
// So: we say what we depend on, and check for exactly that.
import type { CheckRunSummary } from './check-runs.js';

/** Whether the evaluation is finished, and what it is still waiting for. */
export interface Completeness {
  final: boolean;
  /** Declared checks with no completed run yet, in declared order. */
  pending: string[];
}

/**
 * Compare the commit's check runs against the declared dependency set.
 *
 * "Reported" means `status === 'completed'`, regardless of conclusion — a
 * failing scanner has reported, and the scanner signal grades that verdict
 * separately. This function only answers whether we are still waiting.
 *
 * Args:
 *   runs: Every check run on the head SHA.
 *   declared: Check-run names this repo's risk signals depend on.
 */
export function assessCompleteness(
  runs: readonly CheckRunSummary[],
  declared: readonly string[],
): Completeness {
  const reported = new Set(
    runs.filter((run) => run.status === 'completed').map((run) => run.name),
  );

  // Iterate `declared`, not `runs`, so the pending list is in a stable,
  // human-meaningful order and undeclared noise cannot leak into it.
  const pending = declared.filter((name) => !reported.has(name));

  return { final: pending.length === 0, pending };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 9 tests

- [ ] **Step 5: Commit**

```bash
git add src/completeness.ts tests/completeness.test.ts
git commit -m "feat: decide provisional vs final from the declared check set"
```

---

### Task 3: Update check runs in place

**Files:**
- Modify: `src/checks.ts`
- Modify: `tests/checks.test.ts`

**Interfaces:**
- Consumes: `githubRequest` from `src/github.ts`; `getGitHubConfig` from `src/secrets.ts`
- Produces:
  - `upsertShadowCheck(repoFullName: string, headSha: string, name: string, output: CheckOutput, externalId?: string, request?, getConfig?): Promise<void>`
  - `findOurCheckRun(repoFullName: string, headSha: string, name: string, request?, getConfig?): Promise<{ id: number; externalId: string | null } | null>`
  - `postShadowCheck` is REMOVED — every caller moves to `upsertShadowCheck`

- [ ] **Step 1: Write the failing tests**

Replace `tests/checks.test.ts` entirely:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { upsertShadowCheck, findOurCheckRun } from '../src/checks.js';

const OUR_APP = 4702073;
const REPO = 'bankrate/platform-cicd-v2-demo';
const SHA = 'f00d42';
const output = { title: 't', summary: 's' };

const getConfig = async () => ({ app_id: String(OUR_APP), private_key: 'k', installation_id: '1' });

/** Records every request; `lookup` is the body the GET resolves with. */
function harness(lookup: any, lookupOk = true) {
  const calls: { path: string; method: string; body: any }[] = [];
  const request = async (path: string, options: any = {}) => {
    calls.push({ path, method: options.method ?? 'GET', body: options.body ? JSON.parse(options.body) : null });
    if ((options.method ?? 'GET') === 'GET') {
      return { ok: lookupOk, status: lookupOk ? 200 : 500, json: async () => lookup, text: async () => 'err' };
    }
    return { ok: true, status: 200, json: async () => ({}), text: async () => '' };
  };
  return { calls, request: request as any };
}

const ourRun = (id: number, externalId: string | null = null) => ({
  check_runs: [{ id, name: 'merge-policy/risk', app: { id: OUR_APP }, external_id: externalId }],
});

test('no existing run creates one with POST', async () => {
  const { request, calls } = harness({ check_runs: [] });
  await upsertShadowCheck(REPO, SHA, 'merge-policy/risk', output, undefined, request, getConfig);
  const write = calls.find((c) => c.method === 'POST')!;
  assert.equal(write.path, `/repos/${REPO}/check-runs`);
  assert.equal(write.body.head_sha, SHA);
});

test('an existing run of ours is updated with PATCH to its id', async () => {
  const { request, calls } = harness(ourRun(99));
  await upsertShadowCheck(REPO, SHA, 'merge-policy/risk', output, undefined, request, getConfig);
  const write = calls.find((c) => c.method === 'PATCH')!;
  assert.equal(write.path, `/repos/${REPO}/check-runs/99`);
  assert.equal(calls.some((c) => c.method === 'POST'), false, 'no duplicate created');
});

test('the lookup is scoped to the check name', async () => {
  const { request, calls } = harness({ check_runs: [] });
  await upsertShadowCheck(REPO, SHA, 'merge-policy/risk', output, undefined, request, getConfig);
  assert.match(calls[0]!.path, /\/commits\/f00d42\/check-runs\?check_name=merge-policy%2Frisk/);
});

test('a same-named run from a DIFFERENT app is ignored', async () => {
  const other = { check_runs: [{ id: 5, name: 'merge-policy/risk', app: { id: 999 }, external_id: null }] };
  const { request, calls } = harness(other);
  await upsertShadowCheck(REPO, SHA, 'merge-policy/risk', output, undefined, request, getConfig);
  assert.equal(calls.some((c) => c.method === 'POST'), true, 'creates our own rather than hijacking theirs');
});

test('a failed lookup falls back to POST rather than losing the check', async () => {
  const { request, calls } = harness(null, false);
  await upsertShadowCheck(REPO, SHA, 'merge-policy/risk', output, undefined, request, getConfig);
  assert.equal(calls.some((c) => c.method === 'POST'), true);
});

test('BOTH write paths carry conclusion neutral', async () => {
  // The shadow invariant now has two write paths. This is the test that keeps
  // it structural rather than letting one drift.
  for (const lookup of [{ check_runs: [] }, ourRun(99)]) {
    const { request, calls } = harness(lookup);
    await upsertShadowCheck(REPO, SHA, 'merge-policy/risk', output, undefined, request, getConfig);
    const write = calls.find((c) => c.method !== 'GET')!;
    assert.equal(write.body.conclusion, 'neutral', `${write.method} body`);
    assert.equal(write.body.status, 'completed');
  }
});

test('upsertShadowCheck exposes no way to ask for another conclusion', () => {
  // Arity: (repo, headSha, name, output) required; externalId, request and
  // getConfig all default. None of them is a conclusion.
  assert.equal(upsertShadowCheck.length, 4);
});

test('external_id is written when given, and omitted when not', async () => {
  const withId = harness({ check_runs: [] });
  await upsertShadowCheck(REPO, SHA, 'merge-policy/risk', output, 'final', withId.request, getConfig);
  assert.equal(withId.calls.find((c) => c.method === 'POST')!.body.external_id, 'final');

  const without = harness({ check_runs: [] });
  await upsertShadowCheck(REPO, SHA, 'merge-policy/eligibility', output, undefined, without.request, getConfig);
  assert.equal('external_id' in without.calls.find((c) => c.method === 'POST')!.body, false);
});

test('a failed write throws so the delivery retries', async () => {
  const request = (async (_p: string, o: any = {}) =>
    (o.method ?? 'GET') === 'GET'
      ? { ok: true, status: 200, json: async () => ({ check_runs: [] }) }
      : { ok: false, status: 422, text: async () => 'No commit found for SHA' }) as any;
  await assert.rejects(
    () => upsertShadowCheck(REPO, SHA, 'merge-policy/risk', output, undefined, request, getConfig),
    /check-run write failed .*422/,
  );
});

test('findOurCheckRun returns our run id and external id', async () => {
  const { request } = harness(ourRun(99, 'final'));
  assert.deepEqual(await findOurCheckRun(REPO, SHA, 'merge-policy/risk', request, getConfig), { id: 99, externalId: 'final' });
});

test('findOurCheckRun returns null when we have not posted one', async () => {
  const { request } = harness({ check_runs: [] });
  assert.equal(await findOurCheckRun(REPO, SHA, 'merge-policy/risk', request, getConfig), null);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `upsertShadowCheck` is not exported

- [ ] **Step 3: Rewrite `src/checks.ts`**

```ts
// Posts the shadow-mode check runs.
//
// SHADOW-MODE INVARIANT: this is the only code path in the repo permitted to
// write to the check-runs API, and neither entry point takes a conclusion —
// the value is the constant below, applied in ONE place that both the create
// and the update path go through. There is no argument a future caller can
// pass to make a shadow check non-neutral.
//
// Two write paths exist because re-evaluation updates a check rather than
// creating a second one. Keep the shared body builder: splitting it is how the
// invariant would quietly decay into a convention.
import { githubRequest } from './github.js';
import { getGitHubConfig } from './secrets.js';
import { log } from './log.js';

const SHADOW_CONCLUSION = 'neutral';

/** The rendered body of a check run, as GitHub's `output` object. */
export interface CheckOutput {
  title: string;
  summary: string;
}

/** Our own existing check run for a name and commit. */
export interface ExistingCheckRun {
  id: number;
  /** `final` / `provisional` for the risk check; null when never set. */
  externalId: string | null;
}

/** The one place a shadow check's request body is built. */
function shadowBody(name: string, headSha: string, output: CheckOutput, externalId?: string) {
  return {
    name,
    head_sha: headSha,
    status: 'completed',
    conclusion: SHADOW_CONCLUSION,
    completed_at: new Date().toISOString(),
    output,
    ...(externalId !== undefined ? { external_id: externalId } : {}),
  };
}

/**
 * Find our own check run of this name on this commit.
 *
 * Filters on `app.id` because another App could legitimately post a check with
 * the same name, and hijacking it would be both wrong and confusing. Returns
 * null when we have not posted one, or when the lookup fails — the caller
 * treats both as "create a new one", which is the safe direction.
 */
export async function findOurCheckRun(
  repoFullName: string,
  headSha: string,
  name: string,
  request: typeof githubRequest = githubRequest,
  getConfig: typeof getGitHubConfig = getGitHubConfig,
): Promise<ExistingCheckRun | null> {
  try {
    const res = await request(
      `/repos/${repoFullName}/commits/${headSha}/check-runs?check_name=${encodeURIComponent(name)}`,
    );
    if (!res.ok) {
      log('warn', 'check_run_lookup_failed', { repo: repoFullName, head_sha: headSha, name, status: res.status });
      return null;
    }

    const { app_id } = await getConfig();
    const body = (await res.json()) as {
      check_runs?: { id: number; app?: { id?: number }; external_id?: string | null }[];
    };

    // app_id from Secrets Manager is a string; app.id from the API is a number.
    const ours = (body.check_runs ?? []).find((run) => String(run.app?.id) === String(app_id));
    return ours ? { id: ours.id, externalId: ours.external_id ?? null } : null;
  } catch (err) {
    log('warn', 'check_run_lookup_failed', {
      repo: repoFullName, head_sha: headSha, name,
      error: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}

/**
 * Create or update a completed, neutral check run on a pull request's head commit.
 *
 * Updating in place is what keeps re-evaluation from stacking a fresh pair of
 * check runs on the commit every time a CI system finishes.
 *
 * Args:
 *   repoFullName: `owner/repo`.
 *   headSha: The PR head SHA the check is pinned to.
 *   name: The check run name.
 *   output: The check's title and markdown summary.
 *   externalId: Machine-readable state carried on the run itself — `final` or
 *     `provisional` for the risk check. Read back by the worker so completeness
 *     is re-derived from GitHub rather than remembered locally.
 *   request: Injectable GitHub request client.
 *   getConfig: Injectable App config source.
 * Raises:
 *   Error: On a non-2xx write, so the worker releases its claim and SQS retries.
 */
export async function upsertShadowCheck(
  repoFullName: string,
  headSha: string,
  name: string,
  output: CheckOutput,
  externalId?: string,
  request: typeof githubRequest = githubRequest,
  getConfig: typeof getGitHubConfig = getGitHubConfig,
): Promise<void> {
  const existing = await findOurCheckRun(repoFullName, headSha, name, request, getConfig);

  const [path, method] = existing
    ? [`/repos/${repoFullName}/check-runs/${existing.id}`, 'PATCH']
    : [`/repos/${repoFullName}/check-runs`, 'POST'];

  const res = await request(path, {
    method,
    body: JSON.stringify(shadowBody(name, headSha, output, externalId)),
  });

  if (!res.ok) {
    throw new Error(`check-run write failed for ${name}: ${res.status} ${await res.text()}`);
  }
}
```

- [ ] **Step 4: Point the worker at the new name**

In `src/worker.ts`, change the import from `postShadowCheck` to `upsertShadowCheck`, rename the `WorkerDeps` field, and update the call site. Task 8 rewrites the surrounding block; this step only keeps the build green.

In `src/index.ts`, update the `createWorker({ ... })` wiring to pass `upsertShadowCheck`.

In `tests/worker.test.ts`, rename the stub field from `postShadowCheck` to `upsertShadowCheck`.

- [ ] **Step 5: Run the suite**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/checks.ts src/worker.ts src/index.ts tests/checks.test.ts tests/worker.test.ts
git commit -m "feat: update check runs in place instead of creating duplicates"
```

---

### Task 4: The eligibility table

**Files:**
- Modify: `src/render.ts`
- Modify: `tests/render.test.ts`

**Interfaces:**
- Consumes: `EligibilityResult`, `GATE_ORDER`, `GateName`, `GateVerdict` from `src/gates.ts`; `ClassificationResult` from `src/classify.ts`
- Produces: `renderEligibility(result, classification): CheckOutput` — same signature, new body

**Gate value shapes** (from the shipped `src/gates.ts`, needed to render the Result column):

| Gate | `value` |
|---|---|
| `enrolled` | `{ present: boolean, mode: string \| null }` |
| `botAllowlisted` | the author login, a string |
| `ticketLinked` | `{ required: boolean, found: boolean }` |
| `conventionalTitle` | `undefined` |
| `changeClass` | `{ class: string, reason: string \| null }` |
| `pathsAllowed` | `string[]` of offending filenames |
| `size` | `{ files, lines, maxFiles, maxLines }` |
| `semverCap` | `{ delta: string, cap: string }` |
| `classificationPermits` | `{ repo: string \| null, permitted: string[] }` |
| `tierFloor` | `{ have: number \| null, need: number }` |
| `freezeOff` | `{ freeze: boolean }` |

- [ ] **Step 1: Write the failing tests**

Replace the eligibility tests in `tests/render.test.ts` with:

```ts
test('renders every gate as a table row, in GATE_ORDER', () => {
  const out = render(27);
  const rows = out.summary.split('\n').filter((l) => /^\| [✅❌⏭️❓] \|/.test(l));
  assert.equal(rows.length, GATE_ORDER.length);
  const namesInOrder = rows.map((r) => r.split('|')[2]!.trim());
  assert.deepEqual(namesInOrder, [...GATE_ORDER]);
});

test('a passing gate is marked and carries what it observed', () => {
  const out = render(27);
  assert.match(out.summary, /\| ✅ \| botAllowlisted \| `dependabot\[bot\]` \|/);
  assert.match(out.summary, /\| ✅ \| tierFloor \| tier 2 ≥ 2 \|/);
  assert.match(out.summary, /\| ✅ \| size \| \d+ files?, \d+ lines \(max \d+ \/ \d+\) \|/);
});

test('a failing gate is marked and says why', () => {
  const out = render(32);
  assert.match(out.summary, /\| ❌ \| classificationPermits \|/);
  assert.match(out.summary, /\| ❌ \| tierFloor \| tier 2 < 3 \|/);
});

test('skipped gates render as skipped, not failed', () => {
  const out = render(37);
  assert.match(out.summary, /\| ⏭️ \| semverCap \|/);
  assert.doesNotMatch(out.summary, /\| ❌ \| semverCap \|/);
});

test('a gate with nothing to report renders an em dash', () => {
  const out = render(27);
  assert.match(out.summary, /\| ✅ \| conventionalTitle \| — \|/);
});

test('the lead line still names the verdict and class', () => {
  assert.match(render(27).title, /would have been a candidate — dep-minor/i);
  assert.match(render(32).title, /not a candidate — dep-major/i);
});

test('the tally appears below the table', () => {
  assert.match(render(27).summary, /11 of 11 gates passed/);
  assert.match(render(32).summary, /9 of 11/);
});

test('no eligibility output mentions the epic ticket', () => {
  for (const n of [27, 32, 37]) assert.doesNotMatch(render(n).summary, /PLAT-1184/);
});

test('every eligibility output links the policy doc', () => {
  for (const n of [27, 32, 37]) {
    assert.match(render(n).summary, /https:\/\/github\.com\/bankrate\/zapp\/blob\/main\/docs\/policy\.md/);
  }
});

test('eligibility carries no completeness marker — it never waits', () => {
  for (const n of [27, 32, 37]) {
    assert.doesNotMatch(render(n).title, /provisional|final/i);
  }
});
```

Add `import { GATE_ORDER } from '../src/gates.js';` at the top.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — the summary has no table rows

- [ ] **Step 3: Rewrite the eligibility half of `src/render.ts`**

Delete `candidateSummary` and `tally`; keep `rejectionDetail` and `largestBump`. Replace the `EPIC` constant:

```ts
const POLICY_DOC = 'https://github.com/bankrate/zapp/blob/main/docs/policy.md';
const LEARN_MORE = `[What is this, and how do I suggest a check? →](${POLICY_DOC})`;
```

Then add:

```ts
const GATE_ICON: Record<GateVerdict, string> = {
  pass: '✅', fail: '❌', skipped: '⏭️', unknown: '❓',
};

/**
 * What a gate observed, as one table cell.
 *
 * Renders the VALUE, not a restatement of the rule — `tier 2 ≥ 2` rather than
 * "tier floor met". A gate with nothing meaningful to show gets an em dash
 * rather than invented text.
 */
function gateCell(name: GateName, result: GateResult): string {
  const v = result.value as any;

  switch (name) {
    case 'enrolled':
      return v?.present ? `${v.mode}` : 'not enrolled';
    case 'botAllowlisted':
      return v ? `\`${v}\`` : '—';
    case 'ticketLinked':
      if (!v?.required) return 'not required for this author';
      return v.found ? 'Jira key found' : 'no Jira key found';
    case 'changeClass':
      return v?.reason ? `\`${v.class}\` — ${v.reason}` : `\`${v?.class}\``;
    case 'pathsAllowed':
      return Array.isArray(v) && v.length > 0 ? v.map((f: string) => `\`${f}\``).join(', ') : '—';
    case 'size':
      return `${v.files} file${v.files === 1 ? '' : 's'}, ${v.lines} lines (max ${v.maxFiles} / ${v.maxLines})`;
    case 'semverCap':
      return `${v.delta} ${result.verdict === 'pass' ? '≤' : '>'} ${v.cap}`;
    case 'classificationPermits':
      return result.verdict === 'pass' ? `\`${v.repo}\`` : `\`${v.repo}\` not permitted`;
    case 'tierFloor':
      return `tier ${v.have} ${result.verdict === 'pass' ? '≥' : '<'} ${v.need}`;
    case 'freezeOff':
      return v?.freeze ? 'automation frozen' : '—';
    default:
      return '—';
  }
}

/** The eleven gates as a markdown table, always all of them, always in order. */
function gateTable(result: EligibilityResult): string {
  const rows = GATE_ORDER.map((name) => {
    const gate = result.gates[name];
    return `| ${GATE_ICON[gate.verdict]} | ${name} | ${gate.verdict === 'skipped' ? 'not evaluated' : gateCell(name, gate)} |`;
  });
  return ['| | Gate | Result |', '|---|---|---|', ...rows].join('\n');
}
```

And rewrite `renderEligibility`:

```ts
export function renderEligibility(
  result: EligibilityResult,
  classification: ClassificationResult,
): CheckOutput {
  const passed = GATE_ORDER.filter((n) => result.gates[n].verdict === 'pass').length;
  const candidate = result.verdict === 'candidate';
  const bump = largestBump(classification);

  const lead = candidate
    ? `Would have been a candidate — ${result.changeClass}`
    : result.failedGate === 'botAllowlisted'
      ? 'Not a candidate — author is not an automation account'
      : `Not a candidate — ${result.changeClass}`;

  const context = bump
    ? `${classification.bumps.length} dependency update${classification.bumps.length === 1 ? '' : 's'}, largest jump **${bump.level}** (\`${bump.name}\` ${bump.from} → ${bump.to}).`
    : rejectionDetail(result, classification);

  const verdictLine = candidate
    ? `**${passed} of ${GATE_ORDER.length} gates passed.** Nothing was approved or merged — this service runs in shadow mode.`
    : `**${passed} of ${GATE_ORDER.length} gates passed.** First failure: \`${result.failedGate}\` — ${rejectionDetail(result, classification)}`;

  return {
    title: lead.slice(0, 255),
    summary: [
      `**${lead}**`, '',
      context, '',
      gateTable(result), '',
      verdictLine, '',
      NEVER_BLOCKS, '',
      LEARN_MORE,
    ].join('\n'),
  };
}
```

Import `GateName`, `GateResult`, `GateVerdict` and `GATE_ORDER` from `./gates.js`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/render.ts tests/render.test.ts
git commit -m "feat: render eligibility gates as a table, link the policy doc"
```

---

### Task 5: The risk table and the completeness marker

**Files:**
- Modify: `src/render.ts`
- Modify: `tests/render.test.ts`

**Interfaces:**
- Consumes: `RiskResult` from `src/risk.ts`; `Completeness` from Task 2
- Produces:
  - `renderRisk(risk: RiskResult, classification: ClassificationResult, completeness: Completeness): CheckOutput` — **signature gains a third parameter**
  - `renderRiskNotEvaluated(): CheckOutput` — unchanged signature, new body

- [ ] **Step 1: Write the failing tests**

Replace the risk tests in `tests/render.test.ts`:

```ts
const FINAL = { final: true, pending: [] };
const PROVISIONAL = { final: false, pending: ['Cycode: SAST', 'codecov/project'] };

test('renders every signal as a table row, in fixed order', () => {
  const out = renderRisk(riskResult(), classification, FINAL);
  const rows = out.summary.split('\n').filter((l) => /^\| [✅⚠️❌❓] \|/.test(l));
  assert.equal(rows.length, 6);
  assert.deepEqual(rows.map((r) => r.split('|')[2]!.trim()), [
    'Version distance', 'Publish age', 'Closes a known finding',
    'New scanner findings', 'Coverage change', 'Dependency type',
  ]);
});

test('grade maps onto the icon vocabulary and the legend is inline', () => {
  const out = renderRisk(riskResult(), classification, FINAL);
  assert.match(out.summary, /\| ⚠️ \| Version distance \|/);
  assert.match(out.summary, /\| ✅ \| Coverage change \|/);
  assert.match(out.summary, /Legend: ✅ low · ⚠️ medium · ❌ high · ❓ not available/);
});

test('an unavailable signal is a row with its reason, not a separate block', () => {
  const out = renderRisk(riskResult(), classification, FINAL);
  assert.match(out.summary, /\| ❓ \| Closes a known finding \| Dependabot alerts are disabled for this repository \|/);
  assert.doesNotMatch(out.summary, /Not available for this evaluation/);
});

test('a final result says final, in the title and once only', () => {
  const out = renderRisk(riskResult(), classification, FINAL);
  assert.match(out.title, /graded on 5 of 6 signals · final/);
  assert.doesNotMatch(out.summary, /waiting on/i);
});

test('a provisional result names every outstanding check', () => {
  const out = renderRisk(riskResult(), classification, PROVISIONAL);
  assert.match(out.title, /· provisional/);
  assert.match(out.summary, /`Cycode: SAST`/);
  assert.match(out.summary, /`codecov\/project`/);
  assert.match(out.summary, /will update as they report/i);
});

test('no risk output mentions the epic ticket', () => {
  for (const c of [FINAL, PROVISIONAL]) {
    assert.doesNotMatch(renderRisk(riskResult(), classification, c).summary, /PLAT-1184/);
  }
  assert.doesNotMatch(renderRiskNotEvaluated().summary, /PLAT-1184/);
});

test('every risk output links the policy doc', () => {
  const link = /https:\/\/github\.com\/bankrate\/zapp\/blob\/main\/docs\/policy\.md/;
  assert.match(renderRisk(riskResult(), classification, FINAL).summary, link);
  assert.match(renderRiskNotEvaluated().summary, link);
});

test('the not-evaluated variant points at the eligibility check', () => {
  const out = renderRiskNotEvaluated();
  assert.match(out.title, /not evaluated/i);
  assert.match(out.summary, /merge-policy\/eligibility/);
});

test('titles stay inside GitHub check-run limits', () => {
  assert.ok(renderRisk(riskResult(), classification, PROVISIONAL).title.length <= 255);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `renderRisk` takes two arguments

- [ ] **Step 3: Rewrite the risk half of `src/render.ts`**

Delete `signalSentences`, `unavailableLines` and `GRADE_TITLE`. Add:

```ts
const RISK_ICON: Record<SignalGrade, string> = {
  low: '✅', medium: '⚠️', high: '❌', unknown: '❓',
};

const RISK_TITLE: Record<SignalGrade, string> = {
  low: 'Risk: low', medium: 'Risk: medium', high: 'Risk: high',
  unknown: 'Risk could not be graded',
};

/** Signal rows, in a fixed order that does not follow object key order. */
const SIGNAL_ROWS: { key: keyof RiskSignals; label: string }[] = [
  { key: 'semverDistance', label: 'Version distance' },
  { key: 'publishAge', label: 'Publish age' },
  { key: 'closesFinding', label: 'Closes a known finding' },
  { key: 'newFindings', label: 'New scanner findings' },
  { key: 'coverageDelta', label: 'Coverage change' },
  { key: 'depType', label: 'Dependency type' },
];

/** What one signal observed, as a table cell. Unknown shows its reason. */
function signalCell(key: keyof RiskSignals, risk: RiskResult, classification: ClassificationResult): string {
  const signal = risk.signals[key];
  if (signal.grade === 'unknown') return signal.reason ?? 'not available';

  const v = signal.value as any;
  switch (key) {
    case 'semverDistance': {
      const bump = largestBump(classification);
      return bump ? `${v} — \`${bump.name}\` ${bump.from} → ${bump.to}` : String(v);
    }
    case 'publishAge':
      return `youngest ${v.youngestDays} day${v.youngestDays === 1 ? '' : 's'} (\`${v.package}\`)`;
    case 'closesFinding':
      return v.ghsaIds.length > 0 ? v.ghsaIds.join(', ') : 'none open for these packages';
    case 'newFindings':
      return `${v.failed} of ${v.checked} checks failing`;
    case 'coverageDelta':
      return v.deltaPct === 0
        ? `unchanged at ${v.currentPct}%`
        : `${v.deltaPct > 0 ? '+' : ''}${v.deltaPct} points, now ${v.currentPct}%`;
    case 'depType':
      return `${v.production} production, ${v.development} development`;
    default:
      return '—';
  }
}

function signalTable(risk: RiskResult, classification: ClassificationResult): string {
  const rows = SIGNAL_ROWS.map(({ key, label }) =>
    `| ${RISK_ICON[risk.signals[key].grade]} | ${label} | ${signalCell(key, risk, classification)} |`);
  return ['| | Signal | Observed |', '|---|---|---|', ...rows].join('\n');
}
```

Rewrite `renderRisk`:

```ts
/**
 * Render the `merge-policy/risk` check body.
 *
 * `completeness` decides the provisional/final marker. Naming the outstanding
 * checks matters more than the word itself: a reader seeing a half-graded
 * result needs to know whether it is mid-flight or permanently stuck.
 */
export function renderRisk(
  risk: RiskResult,
  classification: ClassificationResult,
  completeness: Completeness,
): CheckOutput {
  const marker = completeness.final ? 'final' : 'provisional';
  const headline = `${RISK_TITLE[risk.grade]} — graded on ${risk.signalsGraded} of 6 signals · ${marker}`;

  const waiting = completeness.final
    ? []
    : [
        `_Still waiting on: ${completeness.pending.map((n) => `\`${n}\``).join(', ')}. ` +
          'This check will update as they report._',
        '',
      ];

  return {
    title: headline.slice(0, 255),
    summary: [
      `**${headline}**`, '',
      signalTable(risk, classification), '',
      'Legend: ✅ low · ⚠️ medium · ❌ high · ❓ not available', '',
      ...waiting,
      NEVER_BLOCKS, '',
      LEARN_MORE,
    ].join('\n'),
  };
}
```

Rewrite `renderRiskNotEvaluated`'s body to end with `NEVER_BLOCKS` and `LEARN_MORE` instead of the epic link, keeping its existing wording otherwise.

Import `Completeness` from `./completeness.js`, `RiskSignals` from `./risk.js`, and `SignalGrade` from `./signals/types.js`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

- [ ] **Step 5: Read all four renderings as a stranger would**

```bash
node --import tsx -e "
import {readFileSync} from 'fs';
import {renderEligibility, renderRisk, renderRiskNotEvaluated} from './src/render.ts';
import {runGates} from './src/gates.ts'; import {classify} from './src/classify.ts';
import {rules} from './src/rules.ts'; import {enrollmentFor} from './src/enrollment.ts';
const D='bankrate/platform-cicd-v2-demo';
const s=(g,v=null,r)=>({grade:g,value:v,...(r?{reason:r}:{})});
const risk={grade:'medium',signalsGraded:5,signals:{
  semverDistance:s('medium','minor'), publishAge:s('low',{youngestDays:7,package:'@types/pg'}),
  closesFinding:s('unknown',null,'Dependabot alerts are disabled for this repository'),
  newFindings:s('low',{failed:0,checked:3}), coverageDelta:s('low',{deltaPct:0,currentPct:62.99}),
  depType:s('medium',{production:6,development:1})}};
for (const n of [27,32,37]) {
  const pr=JSON.parse(readFileSync(\`tests/fixtures/pr-\${n}-payload.json\`,'utf8'));
  const f=JSON.parse(readFileSync(\`tests/fixtures/pr-\${n}-files.json\`,'utf8'));
  const c=classify(f,rules().generatedPaths);
  const r=runGates({repoFullName:D,title:pr.title,body:pr.body??'',authorLogin:pr.user.login,files:f,enrollment:enrollmentFor(D),rules:rules(),classification:c});
  const o=renderEligibility(r,c);
  console.log('='.repeat(72)); console.log('PR '+n+' ELIGIBILITY: '+o.title); console.log(); console.log(o.summary); console.log();
}
const c27=classify(JSON.parse(readFileSync('tests/fixtures/pr-27-files.json','utf8')),rules().generatedPaths);
for (const [label,comp] of [['FINAL',{final:true,pending:[]}],['PROVISIONAL',{final:false,pending:['Cycode: SAST','codecov/project']}]]) {
  const o=renderRisk(risk,c27,comp);
  console.log('='.repeat(72)); console.log('RISK '+label+': '+o.title); console.log(); console.log(o.summary); console.log();
}
const ne=renderRiskNotEvaluated();
console.log('='.repeat(72)); console.log('RISK NOT EVALUATED: '+ne.title); console.log(); console.log(ne.summary);
"
```

Read all six. Check the tables would render as tables in GitHub — every row the same column count, pipes escaped inside cells. If anything reads awkwardly, fix the wording now; no test can judge it.

- [ ] **Step 6: Commit**

```bash
git add src/render.ts tests/render.test.ts
git commit -m "feat: render risk signals as a table with a provisional/final marker"
```

---

### Task 6: Build an eval context from either trigger

**Files:**
- Create: `src/pr-context.ts`
- Create: `tests/pr-context.test.ts`
- Modify: `src/evaluate.ts` (add `trigger` to `EvalContext`)

**Interfaces:**
- Consumes: `githubRequest`; `EvalContext` from `src/evaluate.ts`
- Produces:
  - `contextFromPullRequestEvent(payload: any): EvalContext`
  - `fetchPrContext(repoFullName: string, prNumber: number, request?): Promise<EvalContext>`
  - `EvalContext` gains `trigger: 'pull_request' | 'check_suite'`

- [ ] **Step 1: Write the failing test**

Create `tests/pr-context.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { contextFromPullRequestEvent, fetchPrContext } from '../src/pr-context.js';

const DEMO = 'bankrate/platform-cicd-v2-demo';
const pr27 = JSON.parse(readFileSync('tests/fixtures/pr-27-payload.json', 'utf8'));

test('builds a context from a pull_request webhook payload', () => {
  const ctx = contextFromPullRequestEvent({
    action: 'opened', repository: { full_name: DEMO }, pull_request: pr27,
  });
  assert.equal(ctx.repoFullName, DEMO);
  assert.equal(ctx.prNumber, pr27.number);
  assert.equal(ctx.headSha, pr27.head.sha);
  assert.equal(ctx.authorLogin, 'dependabot[bot]');
  assert.equal(ctx.trigger, 'pull_request');
});

test('a fetched context is field-for-field identical apart from the trigger', async () => {
  // This is what keeps the two entry paths from drifting: a check_suite
  // re-evaluation must see exactly what the pull_request path saw.
  const request = (async () => ({ ok: true, status: 200, json: async () => pr27 })) as any;
  const fromEvent = contextFromPullRequestEvent({ repository: { full_name: DEMO }, pull_request: pr27 });
  const fetched = await fetchPrContext(DEMO, pr27.number, request);

  assert.deepEqual({ ...fetched, trigger: 'pull_request' }, fromEvent);
  assert.equal(fetched.trigger, 'check_suite');
});

test('the fetch targets the pull request endpoint', async () => {
  const calls: string[] = [];
  const request = (async (p: string) => { calls.push(p); return { ok: true, status: 200, json: async () => pr27 }; }) as any;
  await fetchPrContext(DEMO, 27, request);
  assert.equal(calls[0], `/repos/${DEMO}/pulls/27`);
});

test('a failed fetch throws so the delivery retries', async () => {
  const request = (async () => ({ ok: false, status: 404, text: async () => 'Not Found' })) as any;
  await assert.rejects(() => fetchPrContext(DEMO, 27, request), /pull request GET failed .*404/);
});

test('a null body renders as an empty string, never the literal "null"', () => {
  const ctx = contextFromPullRequestEvent({
    repository: { full_name: DEMO },
    pull_request: { ...pr27, body: null },
  });
  assert.equal(ctx.body, '');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/pr-context.js'`

- [ ] **Step 3: Add `trigger` to `EvalContext` in `src/evaluate.ts`**

```ts
  /** Which event produced this evaluation. Recorded on the eval record. */
  trigger: 'pull_request' | 'check_suite';
```

- [ ] **Step 4: Write `src/pr-context.ts`**

```ts
// Builds the evaluator's input from either trigger.
//
// The pull_request event carries title, body and author inline. A check_suite
// event does not — its `pull_requests[]` entries hold only number, head and
// base — so that path fetches the pull request. Both converge here so
// `evaluate()` cannot tell which event it is serving, and so the two paths
// cannot drift apart.
import { githubRequest } from './github.js';
import type { EvalContext } from './evaluate.js';

/** Shape both paths reduce to. */
function toContext(
  repoFullName: string,
  pr: any,
  trigger: EvalContext['trigger'],
): EvalContext {
  return {
    repoFullName,
    prNumber: pr?.number,
    headSha: pr?.head?.sha,
    title: pr?.title ?? '',
    // `body` is null on a PR opened with no description; `?? ''` keeps the
    // Jira-key matcher from searching the string "null".
    body: pr?.body ?? '',
    authorLogin: pr?.user?.login ?? '',
    trigger,
  };
}

/** Build a context from a `pull_request` webhook payload. */
export function contextFromPullRequestEvent(payload: any): EvalContext {
  return toContext(payload?.repository?.full_name, payload?.pull_request, 'pull_request');
}

/**
 * Fetch a pull request and build a context from it.
 *
 * Used by the check_suite path, whose payload lacks the fields gates 2, 3 and 4
 * read.
 *
 * Raises:
 *   Error: On a non-2xx response, so the worker releases its claim and retries.
 */
export async function fetchPrContext(
  repoFullName: string,
  prNumber: number,
  request: typeof githubRequest = githubRequest,
): Promise<EvalContext> {
  const res = await request(`/repos/${repoFullName}/pulls/${prNumber}`);
  if (!res.ok) {
    throw new Error(`pull request GET failed for ${repoFullName}#${prNumber}: ${res.status} ${await res.text()}`);
  }
  return toContext(repoFullName, await res.json(), 'check_suite');
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: FAIL on typecheck — `src/worker.ts` builds a context without `trigger`. Add `trigger: 'pull_request'` to the object literal it passes to `deps.evaluate`, and add it to the context objects in `tests/evaluate.test.ts`. Then re-run: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/pr-context.ts src/evaluate.ts src/worker.ts tests/pr-context.test.ts tests/evaluate.test.ts
git commit -m "feat: build the eval context from either trigger"
```

---

### Task 7: Thread completeness through the evaluator and the ledger

**Files:**
- Modify: `src/evaluate.ts`
- Modify: `src/ledger.ts`
- Modify: `tests/evaluate.test.ts`, `tests/ledger.test.ts`

**Interfaces:**
- Consumes: `assessCompleteness` (Task 2), `signalChecksFor` (Task 1), `renderRisk` (Task 5)
- Produces:
  - `ShadowVerdict` gains `externalId?: string`
  - `EvalRecord` gains `trigger`, `final: boolean`, `pendingChecks: string[]`

- [ ] **Step 1: Write the failing tests**

Append to `tests/evaluate.test.ts`:

```ts
test('a candidate whose declared checks have all completed is final', async () => {
  const [, risk] = await evaluate(ctx(27), riskDeps(27) as any);
  assert.match(risk!.output.title, /· final/);
  assert.equal(risk!.externalId, 'final');
});

test('a candidate missing a declared check is provisional and says which', async () => {
  const thin = riskDeps(27, { fetchCheckRuns: async () => [
    { name: 'Cycode: SAST', status: 'completed', conclusion: 'success', title: null },
  ] });
  const [, risk] = await evaluate(ctx(27), thin as any);
  assert.match(risk!.output.title, /· provisional/);
  assert.equal(risk!.externalId, 'provisional');
  assert.match(risk!.output.summary, /codecov\/project/);
});

test('the eligibility verdict carries no externalId', async () => {
  const [eligibility] = await evaluate(ctx(27), riskDeps(27) as any);
  assert.equal(eligibility!.externalId, undefined);
});

test('a non-candidate is neither final nor provisional', async () => {
  const [, risk] = await evaluate(ctx(37), riskDeps(37) as any);
  assert.match(risk!.output.title, /not evaluated/i);
  assert.equal(risk!.externalId, undefined);
});

test('the eval record carries trigger, final and pendingChecks', async () => {
  const recorded: any[] = [];
  await evaluate(ctx(27), riskDeps(27, { recordEvaluation: async (r: any) => { recorded.push(r); } }) as any);
  assert.equal(recorded[0].trigger, 'pull_request');
  assert.equal(recorded[0].final, true);
  assert.deepEqual(recorded[0].pendingChecks, []);
});

test('a non-candidate record is final — nothing was waited on', async () => {
  const recorded: any[] = [];
  await evaluate(ctx(37), riskDeps(37, { recordEvaluation: async (r: any) => { recorded.push(r); } }) as any);
  assert.equal(recorded[0].final, true);
});
```

Append to `tests/ledger.test.ts`:

```ts
test('trigger, final and pendingChecks are stored as queryable attributes', async () => {
  const { send, calls } = fakeSend();
  await recordEvaluation({
    ...record(), trigger: 'check_suite', final: false, pendingChecks: ['codecov/project'],
  } as any, send);
  const item = calls[0].input.Item;
  assert.equal(item.trigger.S, 'check_suite');
  assert.equal(item.final.BOOL, false);
  assert.deepEqual(item.pendingChecks.SS, ['codecov/project']);
});

test('an empty pendingChecks stores a NULL, not an empty string set', async () => {
  // DynamoDB rejects an empty string set outright — this is a real write
  // failure, not a style preference.
  const { send, calls } = fakeSend();
  await recordEvaluation({ ...record(), trigger: 'pull_request', final: true, pendingChecks: [] } as any, send);
  assert.deepEqual(calls[0].input.Item.pendingChecks, { NULL: true });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `externalId` is not on `ShadowVerdict`

- [ ] **Step 3: Extend `src/evaluate.ts`**

Add to `ShadowVerdict`:

```ts
  /**
   * Machine-readable state written onto the check run itself. `final` or
   * `provisional` for risk; absent for eligibility, which never waits.
   */
  externalId?: string;
```

Change `assessRisk` to return completeness alongside the grade. It already fetches `runs`; surface them:

```ts
): Promise<{ risk: RiskResult; completeness: Completeness }> {
```

…and at the end of that function, replace the bare `return combine({...})` with:

```ts
  // The combine({ semverDistance, publishAge, closesFinding, newFindings,
  // coverageDelta, depType }) call already at the end of assessRisk is
  // UNCHANGED — bind its result to a name instead of returning it directly,
  // then pair it with completeness computed from the `runs` this function
  // already fetched.
  const risk = combine({ /* …the six signal arguments exactly as they are today… */ });
  return { risk, completeness: assessCompleteness(runs, signalChecksFor(ctx.repoFullName)) };
```

`runs` is the local already produced by `safely('check_runs', …)` at the top of `assessRisk`; no
extra fetch is needed. Add `import { assessCompleteness } from './completeness.js';`,
`import type { Completeness } from './completeness.js';` and `signalChecksFor` to the
`./enrollment.js` import.

In `evaluate`, replace the risk block:

```ts
  const assessed = eligibility.verdict === 'candidate'
    ? await assessRisk(ctx, classification, policy.risk, deps)
    : undefined;

  // A non-candidate waited on nothing, so it is trivially final. Recording it
  // as provisional would pollute any query that filters on `final`.
  const completeness = assessed?.completeness ?? { final: true, pending: [] };
```

Pass `trigger`, `final` and `pendingChecks` to `recordEvaluation`:

```ts
      trigger: ctx.trigger,
      final: completeness.final,
      pendingChecks: completeness.pending,
      risk: assessed?.risk,
```

And return:

```ts
  return [
    { name: ELIGIBILITY_CHECK, output: renderEligibility(eligibility, classification) },
    assessed
      ? {
          name: RISK_CHECK,
          output: renderRisk(assessed.risk, classification, assessed.completeness),
          externalId: assessed.completeness.final ? 'final' : 'provisional',
        }
      : { name: RISK_CHECK, output: renderRiskNotEvaluated() },
  ];
```

Extend the `evaluated` log line with `final: completeness.final` and `pending: completeness.pending.length`.

- [ ] **Step 4: Extend `src/ledger.ts`**

Add to `EvalRecord`:

```ts
  trigger: 'pull_request' | 'check_suite';
  /** Whether every declared signal check had reported. Filter Phase 1 analysis on this. */
  final: boolean;
  /** Declared checks that had not reported. Empty when final. */
  pendingChecks: string[];
```

Add to the `Item`:

```ts
      trigger: { S: record.trigger },
      final: { BOOL: record.final },
      // DynamoDB rejects an empty string set, so an empty list must be NULL.
      pendingChecks: record.pendingChecks.length > 0
        ? { SS: record.pendingChecks }
        : { NULL: true },
```

- [ ] **Step 5: Run the suite**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/evaluate.ts src/ledger.ts tests/evaluate.test.ts tests/ledger.test.ts
git commit -m "feat: mark evaluations provisional or final and record it"
```

---

### Task 8: Route check_suite completions

**Files:**
- Modify: `src/worker.ts`
- Modify: `src/index.ts`
- Modify: `tests/worker.test.ts`

**Interfaces:**
- Consumes: `contextFromPullRequestEvent`, `fetchPrContext` (Task 6); `findOurCheckRun`, `upsertShadowCheck` (Task 3)
- Produces: `WorkerDeps` gains `fetchPrContext` and `findOurCheckRun`

- [ ] **Step 1: Write the failing tests**

Append to `tests/worker.test.ts`:

```ts
const OUR_APP_ID = 4702073;

function checkSuiteEvent({ appId = 39308, action = 'completed', prs = [{ number: 7 }], sha = 'f00d42' } = {}) {
  return sqsEvent(JSON.stringify({
    action,
    check_suite: { app: { id: appId }, head_sha: sha, pull_requests: prs },
    repository: { full_name: DEMO },
  }), { event: 'check_suite', deliveryId: 'cs-1' });
}

function csHarness(over: any = {}) {
  const state = { posts: [] as any[], evaluated: [] as any[] };
  const worker = createWorker({
    claimDelivery: async () => true,
    confirmDelivery: async () => {},
    releaseDelivery: async () => {},
    isEnrolled: () => true,
    // The loop guard reads our App id from here. Without this stub every
    // check_suite test throws on `deps.getGitHubConfig is not a function`.
    getGitHubConfig: async () => ({ app_id: String(OUR_APP_ID), private_key: 'k', installation_id: '1' }),
    upsertShadowCheck: async (repo: string, sha: string, name: string, out: any, ext?: string) => {
      state.posts.push({ repo, sha, name, ext });
    },
    findOurCheckRun: async () => null,
    fetchPrContext: async (repo: string, n: number) => {
      state.evaluated.push({ repo, n });
      return { repoFullName: repo, prNumber: n, headSha: 'f00d42', title: 't', body: '', authorLogin: 'dependabot[bot]', trigger: 'check_suite' };
    },
    evaluate: async () => ([
      { name: 'merge-policy/eligibility', output: { title: 't', summary: 's' } },
      { name: 'merge-policy/risk', output: { title: 't', summary: 's' }, externalId: 'final' },
    ]),
    ...over,
  } as any);
  return { worker, state };
}

test('a completed check suite from another app triggers re-evaluation', async () => {
  const { worker, state } = csHarness();
  await worker(checkSuiteEvent());
  assert.deepEqual(state.evaluated, [{ repo: DEMO, n: 7 }]);
  assert.equal(state.posts.length, 2);
});

test('OUR OWN completed check suite is ignored — this is the infinite loop guard', async () => {
  const { worker, state } = csHarness();
  await worker(checkSuiteEvent({ appId: OUR_APP_ID }));
  assert.deepEqual(state.evaluated, [], 'the evaluator must not be called');
  assert.deepEqual(state.posts, []);
});

test('a non-completed check_suite action is dropped', async () => {
  const { worker, state } = csHarness();
  await worker(checkSuiteEvent({ action: 'requested' }));
  assert.deepEqual(state.evaluated, []);
});

test('a check suite with no pull requests is dropped', async () => {
  const { worker, state } = csHarness();
  await worker(checkSuiteEvent({ prs: [] }));
  assert.deepEqual(state.evaluated, []);
});

test('an already-final head sha is not re-evaluated', async () => {
  const { worker, state } = csHarness({ findOurCheckRun: async () => ({ id: 1, externalId: 'final' }) });
  await worker(checkSuiteEvent());
  assert.deepEqual(state.evaluated, []);
});

test('a provisional head sha IS re-evaluated', async () => {
  const { worker, state } = csHarness({ findOurCheckRun: async () => ({ id: 1, externalId: 'provisional' }) });
  await worker(checkSuiteEvent());
  assert.equal(state.evaluated.length, 1);
});

test('the externalId from the verdict is passed through to the check run', async () => {
  const { worker, state } = csHarness();
  await worker(checkSuiteEvent());
  assert.equal(state.posts.find((p) => p.name === 'merge-policy/risk')!.ext, 'final');
  assert.equal(state.posts.find((p) => p.name === 'merge-policy/eligibility')!.ext, undefined);
});

test('multiple pull requests on one suite are all evaluated', async () => {
  const { worker, state } = csHarness();
  await worker(checkSuiteEvent({ prs: [{ number: 7 }, { number: 9 }] }));
  assert.deepEqual(state.evaluated.map((e) => e.n), [7, 9]);
});

test('an unenrolled repo is dropped before any fetch', async () => {
  const { worker, state } = csHarness({ isEnrolled: () => false });
  await worker(checkSuiteEvent());
  assert.deepEqual(state.evaluated, []);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `check_suite` is still in `KNOWN_UNROUTED` and drops

- [ ] **Step 3: Rewrite the routing in `src/worker.ts`**

Remove `check_suite` from `KNOWN_UNROUTED`, add the deps, and split `handleDelivery`:

```ts
// Our own GitHub App. A check_suite event carrying this id is OUR OWN check
// runs completing — routing it would re-evaluate, upsert, complete our suite
// again, and loop forever. Read from config rather than hard-coded so it
// cannot drift from the App the service actually authenticates as.
async function isOurApp(appId: unknown, getConfig: typeof getGitHubConfig): Promise<boolean> {
  const { app_id } = await getConfig();
  return String(appId) === String(app_id);
}
```

```ts
async function handleCheckSuite(deps: WorkerDeps, deliveryId: string, payload: any): Promise<void> {
  const suite = payload?.check_suite;

  // FIRST, before anything else. See isOurApp.
  if (await isOurApp(suite?.app?.id, deps.getGitHubConfig)) {
    log('info', 'self_check_suite_ignored', { delivery: deliveryId, head_sha: suite?.head_sha });
    return;
  }

  if (payload?.action !== 'completed') {
    log('info', 'action_not_routed', { event: 'check_suite', action: payload?.action, delivery: deliveryId });
    return;
  }

  const repoFullName: string | undefined = payload?.repository?.full_name;
  const headSha: string | undefined = suite?.head_sha;
  if (!repoFullName || !headSha) {
    throw new Error('malformed check_suite payload: missing repository.full_name or check_suite.head_sha');
  }

  if (!deps.isEnrolled(repoFullName)) {
    log('info', 'repo_not_enrolled', { repo: repoFullName, delivery: deliveryId });
    return;
  }

  const prs: { number: number }[] = suite?.pull_requests ?? [];
  if (prs.length === 0) {
    // Happens for fork-originated pull requests, which carry no linked PR here.
    log('info', 'check_suite_no_pull_requests', { repo: repoFullName, head_sha: headSha, delivery: deliveryId });
    return;
  }

  // Re-derived from GitHub's own state rather than remembered locally, so a
  // restart or a dropped delivery cannot strand this.
  const existing = await deps.findOurCheckRun(repoFullName, headSha, RISK_CHECK);
  if (existing?.externalId === 'final') {
    log('info', 'already_final', { repo: repoFullName, head_sha: headSha, delivery: deliveryId });
    return;
  }

  for (const pr of prs) {
    const ctx = await deps.fetchPrContext(repoFullName, pr.number);
    await postVerdicts(deps, ctx, deliveryId);
  }
}
```

```ts
/** Evaluate one pull request and write both check runs. */
async function postVerdicts(deps: WorkerDeps, ctx: EvalContext, deliveryId: string): Promise<void> {
  const verdicts = await deps.evaluate(ctx);
  for (const verdict of verdicts) {
    await deps.upsertShadowCheck(ctx.repoFullName, ctx.headSha, verdict.name, verdict.output, verdict.externalId);
  }
  log('info', 'shadow_checks_posted', {
    repo: ctx.repoFullName, pr: ctx.prNumber, head_sha: ctx.headSha,
    trigger: ctx.trigger, delivery: deliveryId,
  });
}
```

Rewrite the `pull_request` branch of `handleDelivery` to build its context with `contextFromPullRequestEvent(payload)` and call `postVerdicts`, and dispatch `check_suite` to `handleCheckSuite`.

Add three fields to `WorkerDeps` and wire all three in `src/index.ts`:

```ts
  fetchPrContext: typeof fetchPrContext;
  findOurCheckRun: typeof findOurCheckRun;
  /** Injected so the loop guard's App id is stubbable in tests. */
  getGitHubConfig: typeof getGitHubConfig;
```

Imports `src/worker.ts` needs: `contextFromPullRequestEvent`, `fetchPrContext` from `./pr-context.js`;
`findOurCheckRun`, `upsertShadowCheck` from `./checks.js`; `getGitHubConfig` from `./secrets.js`;
`RISK_CHECK` and the `EvalContext` type from `./evaluate.js`.

- [ ] **Step 4: Run the suite**

Run: `pnpm test && pnpm run typecheck && pnpm run build`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/worker.ts src/index.ts tests/worker.test.ts
git commit -m "feat: re-evaluate on check_suite completion, ignoring our own"
```

---

### Task 9: `docs/policy.md`

**Files:**
- Create: `docs/policy.md`
- Modify: `README.md` (link it from the Documentation section)

**Interfaces:**
- Consumes: the gate names in `GATE_ORDER`, the signal labels in `SIGNAL_ROWS`, the values in `policy-rules.yaml`
- Produces: the page both check runs link

- [ ] **Step 1: Write the page**

Create `docs/policy.md`. Its audience is **someone whose pull request just got a check from a service they have never heard of** — not someone working on zapp, which is what `README.md`, `docs/architecture.md` and `docs/call-flows.md` already serve. Write for that reader throughout.

Cover, in this order:

1. **What this is** — three sentences. A service that watches pull requests and records what an automated merge policy *would* have decided. It holds no permission to approve or merge anything. Its checks never block.
2. **The two checks** — `merge-policy/eligibility` answers "could this be automated?", `merge-policy/risk` answers "how risky is it?". Risk is only computed for pull requests eligibility admits.
3. **The eleven gates** — a table of gate name (exactly as it appears in the check and in `policy-rules.yaml`), what it checks, and why it exists. Read the current `src/gates.ts` for the authoritative behaviour of each.
4. **The six risk signals** — what each measures, what makes it low / medium / high, and what makes it unavailable. Note that the grade is the worst signal, and that closing a known security advisory lowers it by one step and can never raise it.
5. **Change classes** — `lockfile-only`, `dep-patch`, `dep-minor`, `dep-major`, their current thresholds, and the **max-delta-governs** rule for grouped bumps: one major among eleven patches makes the whole pull request `dep-major`. That is the rule most likely to surprise someone.
6. **Repository classification and CI-trust tier** — what `sandbox`, `internal-tool` and `prod-service` mean, what a tier is, and that both come from the repo's entry in `policy-rules.yaml`.
7. **Why risk sometimes says "provisional"** — the risk signals read other checks' results; the service waits for a declared list of them; a check stuck on provisional means one of those never reported, and it names which.
8. **Suggesting a check, or arguing one is wrong** — open a pull request against `policy-rules.yaml`. It is reviewed like any other change and its git SHA is stamped on every decision, so any verdict traces back to the exact rules that produced it. **This is the section the page exists for** — make it the easiest thing to find.

Keep the values consistent with `policy-rules.yaml` as committed. Where a number appears, say it is the current value and that the check run always shows what it actually compared against.

- [ ] **Step 2: Link it from `README.md`**

In the Documentation section, add a line marking `docs/policy.md` as the reader-facing page, distinct from the internal architecture docs — so a future maintainer does not "helpfully" merge them.

- [ ] **Step 3: Verify the link the checks emit actually resolves**

```bash
test -f docs/policy.md && echo "exists locally"
```

The URL `https://github.com/bankrate/zapp/blob/main/docs/policy.md` 404s until this branch merges. Confirm it resolves after Task 11 Step 2, not before.

- [ ] **Step 4: Commit**

```bash
git add docs/policy.md README.md
git commit -m "docs: add the reader-facing merge-policy explainer"
```

---

### Task 10: Internal documentation

**Files:**
- Modify: `AGENTS.md`, `docs/architecture.md`, `docs/call-flows.md`

**Interfaces:**
- Consumes: everything
- Produces: nothing code-facing

- [ ] **Step 1: Append to `AGENTS.md`**

Concise, pointing at authoritative files rather than restating them:

- `check_suite` events from our own App id must be dropped first — our check runs live in our own suite, and routing its completion loops forever. `src/worker.ts` reads the id from `getGitHubConfig()`; do not hard-code it.
- Check runs are **upserted**, not created. `src/checks.ts` owns both write paths and they share one body builder — that is what keeps `conclusion: 'neutral'` structural now that there are two verbs.
- Completeness is **declared** in `rules.signalChecks`, not inferred. "Wait for all check suites" never fires: a typical commit here carries ~14 suites of which ~10 belong to org-installed apps that sit `queued` with zero runs forever. And the App named `codecov` (id 254) is one of those — the real `codecov/project` comes from `bankrate-codecov` (id 370480).
- `final` / `provisional` is carried on the check run's `external_id`, so the worker re-derives it from GitHub rather than keeping local state.
- The ledger is now a time series per head SHA. Filter analysis on `final`; the latest record per SHA saw the most data.
- `docs/policy.md` is reader-facing, for people whose PR got a check. `docs/architecture.md` and `docs/call-flows.md` are for people working on zapp. Do not merge them.

- [ ] **Step 2: Update `docs/architecture.md` and `docs/call-flows.md`**

Read both first. Add the second trigger path (`check_suite: completed` → self-filter → already-final check → `fetchPrContext` → `evaluate` → upsert), and note that the `pull_request` path is unchanged apart from building its context through `src/pr-context.ts`.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md docs/architecture.md docs/call-flows.md
git commit -m "docs: record the second trigger path and the upsert invariant"
```

---

### Task 11: Deploy to QA and validate live

**Files:** none — verification only.

- [ ] **Step 1: Open the pull request**

```bash
gh pr create --repo bankrate/zapp --base main --head feat/check-output-and-reevaluation \
  --title "feat: check-run tables, policy doc, and CI-finished re-evaluation" \
  --body "Spec lives in firstmate: docs/superpowers/zapp/specs/2026-08-25-check-output-and-reevaluation-design.md"
```

Confirm CI passes, including the rules drift check and the Docker build.

- [ ] **Step 2: Merge and cut a QA pre-release**

Merge, then publish a pre-release tag (e.g. `v1.5.0-rc.1`) so `deploy-v2.yml` stops after QA.

Confirm the policy-doc URL now resolves:

```bash
gh api repos/bankrate/zapp/contents/docs/policy.md?ref=main --jq .name
```

- [ ] **Step 3: Trigger a fresh evaluation and WATCH it, do not just read the end state**

```bash
gh pr checkout 27 --repo bankrate/platform-cicd-v2-demo
git commit --allow-empty -m "chore: re-trigger merge-policy evaluation"
git push
```

Then poll every 30 seconds while CI runs:

```bash
SHA=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/27 --jq .head.sha)
gh api "repos/bankrate/platform-cicd-v2-demo/commits/$SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.name|startswith("merge-policy/")) | "\(.name) ext=\(.external_id) :: \(.output.title)"'
```

**Expect to see `provisional` at least once before it settles to `final`.** A marker that only ever reads `final` would pass a naive end-state check while being broken — this is the observation the whole feature turns on.

- [ ] **Step 4: Confirm exactly one check run per name**

```bash
SHA=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/27 --jq .head.sha)
gh api "repos/bankrate/platform-cicd-v2-demo/commits/$SHA/check-runs?per_page=100&filter=all" \
  --jq '[.check_runs[] | select(.name|startswith("merge-policy/")) | .name] | group_by(.) | map({name: .[0], count: length})'
```

Expected: `count: 1` for each. **A count above 1 means the upsert is not working** and every CI completion stacked a new run.

- [ ] **Step 5: Confirm the loop guard fired**

```bash
AWS_PROFILE=bankrate-qa aws logs filter-log-events --region us-east-1 \
  --log-group-name /aws/lambda/zapp-qa \
  --filter-pattern '{ $.msg = "self_check_suite_ignored" }' \
  --start-time $(( ($(date +%s) - 1800) * 1000 )) --query 'length(events)'
```

Expected: **at least 1.** Zero means either the guard never ran or our own suite never completed — both worth understanding before trusting it. Also confirm the count is not growing without bound, which would indicate a loop the guard is failing to break.

- [ ] **Step 6: Read the rendered checks in a browser**

Open the PR's Checks tab. Confirm the tables render as tables, the icons display, the legend is legible, and the policy link resolves. This is the acceptance criterion no test can judge.

- [ ] **Step 7: Confirm neither output mentions the epic**

```bash
SHA=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/27 --jq .head.sha)
gh api "repos/bankrate/platform-cicd-v2-demo/commits/$SHA/check-runs?per_page=100" \
  --jq '[.check_runs[] | select(.name|startswith("merge-policy/")) | .output.summary] | join(" ") | test("PLAT-1184")'
```

Expected: `false`.

- [ ] **Step 8: Confirm the ledger time series**

```bash
AWS_PROFILE=bankrate-qa aws dynamodb query --region us-east-1 \
  --table-name zapp-evaluations \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"repo#bankrate/platform-cicd-v2-demo#pr#27"}}' \
  --scan-index-forward false --max-items 6 \
  --query 'Items[].{sk:sk.S,trigger:trigger.S,final:final.BOOL,riskGrade:riskGrade.S}'
```

Expected: several records — the earliest `trigger=pull_request`, later ones `trigger=check_suite`, and **exactly one with `final=true`**, which is the most recent.

- [ ] **Step 9: Confirm the risk grade actually improved**

Expected: **5 of 6 signals · final**, up from the 4 of 6 the service shows today. The sixth stays `❓` while Dependabot alerts remain disabled on the repository — that row now names that reason in the table.

- [ ] **Step 10: Confirm the checks are still on no required-checks configuration**

```bash
gh api repos/bankrate/platform-cicd-v2-demo/branches/main/protection --jq '.required_status_checks.contexts'
```

Expected: only the three `Cycode:` contexts.

- [ ] **Step 11: Record the evidence**

Post the outputs of Steps 3, 4, 5, 8 and 9 on the zapp PR. These are the acceptance criteria; a claim without its output is not evidence.

---

## Post-implementation

- **PLAT-1192 (T8)** — the required-checks snapshot and the ten-minute reconcile sweep. `signalChecks` answers "are *our* inputs ready?"; T8 answers "is this PR's own required-check state green?". They overlap on the Cycode contexts here only by coincidence of this repo's configuration — do not merge them.
- **Enabling Dependabot alerts** on enrolled repos turns the sixth signal from `❓` into real data.
- **Enrolling more repos** is a one-line PR against `policy-rules.yaml`; each new repo may need its own `signalChecks` override if it does not run Codecov.
- **The SNS alerts topic still has no subscribers** — carried since PLAT-1233. Both alarms are visible in CloudWatch and page nobody.
