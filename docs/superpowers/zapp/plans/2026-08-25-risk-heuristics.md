# Risk Heuristics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grade the risk of every gate-passing pull request from six deterministic signals, and replace `merge-policy/risk`'s placeholder with a real rationale.

**Architecture:** Six independent signal modules, each degrading to `unknown` on its own terms rather than failing the evaluation. One shared head-SHA check-runs fetch feeds two of them. `src/risk.ts` combines them worst-known-wins, with `closesFinding` acting only as a one-step reducer. Thresholds live in `policy-rules.yaml` and are validated at build time like everything else.

**Tech Stack:** Node 22, TypeScript, `node:test` + `tsx`, esbuild, AWS SDK v3 (DynamoDB), Terraform, container-image Lambda via `finserv-reusable-gha` CI/CD v2. External: `api.deps.dev` (publish timestamps).

**Spec:** [`../specs/2026-08-25-risk-heuristics-design.md`](../specs/2026-08-25-risk-heuristics-design.md)

**Jira:** [PLAT-1191](https://redventures.atlassian.net/browse/PLAT-1191) (T7). Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184).

**Repo:** `bankrate/zapp`. Branch from `main`: `feat/plat-1191-risk-heuristics`.

> **HARD PREREQUISITE — Spec A must be merged first.** This plan consumes `classify()`, `rules()`, `fetchPrFiles()`, `recordEvaluation()`, `runGates()` and `renderEligibility()`, all of which land in [`2026-08-25-policy-rules-and-eligibility.md`](./2026-08-25-policy-rules-and-eligibility.md). Do not start Task 2 until `main` carries them. Task 1 is deliberately independent and can run at any time.

## Global Constraints

- **Shadow-mode invariant.** `src/checks.ts` is NOT modified. `postShadowCheck` takes no conclusion parameter and remains the only path to the check-runs API. The risk grade is never acted on.
- **`unknown` is a value, not an error.** Every signal degrades to `unknown` with a recorded reason. No signal failure may fail a delivery or lose a check run. This inverts the worker's usual throw-and-retry posture and does so knowingly — retrying will not make a disabled API start answering.
- **Absence is never zero.** A missing or incomplete Cycode check reads `unknown`, never "clean scan". A missing Codecov check reads `unknown`, never "no change".
- **Worst known signal wins.** `unknown` signals are excluded from the comparison but counted, and every rendering states the coverage as "graded on N of 6 signals".
- **`closesFinding` only ever lowers.** `high` → `medium`, `medium` → `low`, `low` → `low`. It never participates in the worst-of comparison and can never raise a grade.
- **Risk is evaluated only for candidates.** A non-candidate gets a "not evaluated" check, and no signal fetch is made at all.
- **Semver deltas come from Spec A's `classify()`** — already read from the manifest diff. This plan never re-derives them.
- **Thresholds live in `policy-rules.yaml`**, validated at build time by `scripts/build-rules.mjs`. The signal-to-grade mapping lives in code, where it is tested.
- **Never log secrets or PR prose.** Package names, versions, grades and counts are safe. No signal in this plan reads PR title or body.
- **Node 22**, ESM (`"type": "module"`), so every relative import carries a `.js` extension even from `.ts` sources.
- **Conventional Commits** — `release.yml` runs semantic-release on merge to `main`.
- **`docs/superpowers/` is gitignored in the zapp repo.** The spec and this plan live in firstmate. Do not add design docs to zapp.

---

### Task 1: Request the GitHub App permission

First, and out of band, because it needs a human org owner and the approval latency is unknown. Everything else proceeds while it is pending; only Task 7 consumes it.

**Files:** none — a GitHub settings change plus a recorded verification.

**Interfaces:**
- Consumes: nothing
- Produces: `vulnerability_alerts: read` on the `neutral-planet` App

- [ ] **Step 1: Record the current permission set as a baseline**

```bash
gh api /orgs/bankrate/installations --paginate \
  --jq '.installations[] | select(.app_slug=="neutral-planet") | {permissions, repository_selection}'
```

Save this output. It is the before-picture for Step 4, which checks that nothing crept in alongside the intended change.

- [ ] **Step 2: Add the permission**

At <https://github.com/organizations/bankrate/settings/apps/neutral-planet/permissions>, set **Dependabot alerts** to **Read-only**. Change nothing else.

This is a manual step — the App-settings API cannot alter an App's own permission set. Adding a permission puts the installation into pending approval; an org owner must accept it before it takes effect.

- [ ] **Step 3: Accept the pending request as an org owner**

At <https://github.com/organizations/bankrate/settings/installations>, open the `neutral-planet` installation and approve the new permission.

- [ ] **Step 4: Verify the live scope, and that nothing else changed**

```bash
gh api /orgs/bankrate/installations --paginate \
  --jq '.installations[] | select(.app_slug=="neutral-planet") | {permissions, repository_selection}'
```

Expected: the Step 1 output plus `"vulnerability_alerts": "read"`, and nothing else different.

**`checks` must still be the ONLY `write` permission.** If any other write appears, stop — the Phase 0 invariant that the service cannot approve, merge, or enable auto-merge is broken, and that matters more than this ticket.

- [ ] **Step 5: Decide on the repo setting, separately**

`GET /repos/bankrate/platform-cicd-v2-demo/dependabot/alerts` returns 403 *"Dependabot alerts are disabled for this repository"* — a **repository setting**, which the App permission does not affect.

```bash
gh api "repos/bankrate/platform-cicd-v2-demo/dependabot/alerts?state=open&per_page=1" 2>&1 | head -3
```

If it still says *disabled*, that is fine and expected: signal 3 records `unknown` and the risk grade is computed from five signals. Enabling Dependabot alerts on the demo repo is a repo-owner decision and explicitly out of this plan's scope. Note which way it went — Task 14's expected output depends on it.

No commit for this task.

---

### Task 2: Risk thresholds in the rules file

Independent of every other task except the build wiring Spec A created.

**Files:**
- Modify: `policy-rules.yaml` (add the `risk` section)
- Modify: `scripts/build-rules.mjs` (validate it)
- Modify: `src/rules-types.ts` (type it)
- Modify: `tests/build-rules.test.ts` (extend the validator tests)
- Regenerate: `src/generated/rules.ts`

**Interfaces:**
- Consumes: `validatePolicy`, `gitBlobSha` from Spec A's `scripts/build-rules.mjs`
- Produces: `interface RiskThresholds { cooldownDays: number; maxNewFindings: number; maxCoverageDropPct: number }` on `Rules.risk`

- [ ] **Step 1: Create the branch**

```bash
cd /Users/scrosby/Projects/github/zapp
git checkout main && git pull
git checkout -b feat/plat-1191-risk-heuristics
```

- [ ] **Step 2: Write the failing validator tests**

Append to `tests/build-rules.test.ts`. The `validDoc()` helper there must gain a `risk` block, so update it first:

```ts
// In validDoc(), inside `rules:`, alongside freeze/bots/generatedPaths:
      risk: { cooldownDays: 3, maxNewFindings: 0, maxCoverageDropPct: 0 },
```

Then append these tests:

```ts
test('a missing risk section is rejected', () => {
  const doc = validDoc();
  delete doc.rules.risk;
  assert.match(validatePolicy(doc)[0], /rules\.risk/);
});

test('a negative cooldown is rejected', () => {
  const doc = validDoc();
  doc.rules.risk.cooldownDays = -1;
  assert.match(validatePolicy(doc)[0], /rules\.risk\.cooldownDays/);
});

test('a non-integer maxNewFindings is rejected', () => {
  const doc = validDoc();
  doc.rules.risk.maxNewFindings = 1.5;
  assert.match(validatePolicy(doc)[0], /rules\.risk\.maxNewFindings/);
});

test('a negative coverage tolerance is rejected — the field is a magnitude', () => {
  const doc = validDoc();
  doc.rules.risk.maxCoverageDropPct = -2;
  assert.match(validatePolicy(doc)[0], /rules\.risk\.maxCoverageDropPct/);
});

test('the real rules file carries usable risk thresholds', async () => {
  const { POLICY } = await import('../src/generated/rules.js');
  assert.equal(typeof POLICY.rules.risk.cooldownDays, 'number');
  assert.ok(POLICY.rules.risk.cooldownDays > 0);
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `validatePolicy` accepts a document with no `risk` section

- [ ] **Step 4: Add the section to `policy-rules.yaml`**

Inside `rules:`, after `freeze:`:

```yaml
  # Risk-heuristic thresholds (PLAT-1191). Only NUMBERS live here — the
  # signal-to-grade mapping is in src/risk.ts, where it is tested. This file
  # holds what a human would tune after reading the shadow data.
  risk:
    # A version published fewer than this many days ago is inside the
    # supply-chain window: not yet exposed to the world's scrutiny.
    cooldownDays: 3
    # Failing scanner checks tolerated before the grade goes high.
    maxNewFindings: 0
    # Coverage drop tolerated, in percentage points, before the grade rises.
    maxCoverageDropPct: 0
```

- [ ] **Step 5: Validate it in `scripts/build-rules.mjs`**

Inside `validatePolicy`, after the `rules.generatedPaths` check:

```js
  const risk = rules.risk;
  if (!risk || typeof risk !== 'object') {
    bad('rules.risk', 'must be an object');
  } else {
    // Non-negative: each of these is a magnitude, not a direction. A negative
    // coverage tolerance would silently invert the comparison in src/risk.ts.
    if (!isInt(risk.cooldownDays) || risk.cooldownDays < 0) bad('rules.risk.cooldownDays', 'must be a non-negative integer');
    if (!isInt(risk.maxNewFindings) || risk.maxNewFindings < 0) bad('rules.risk.maxNewFindings', 'must be a non-negative integer');
    if (typeof risk.maxCoverageDropPct !== 'number' || risk.maxCoverageDropPct < 0) bad('rules.risk.maxCoverageDropPct', 'must be a non-negative number');
  }
```

- [ ] **Step 6: Type it in `src/rules-types.ts`**

```ts
/** Tunable thresholds for the risk heuristics (PLAT-1191). */
export interface RiskThresholds {
  /** Below this age in days, a published version is still in the supply-chain window. */
  cooldownDays: number;
  /** Failing scanner checks tolerated before the grade goes high. */
  maxNewFindings: number;
  /** Coverage drop tolerated, in percentage points. */
  maxCoverageDropPct: number;
}
```

And add `risk: RiskThresholds;` to the `Rules` interface.

- [ ] **Step 7: Regenerate, then run the tests**

```bash
pnpm run build:rules
pnpm test && pnpm run typecheck
```

Expected: PASS. `src/generated/rules.ts` now has a different `RULES_SHA` — that is correct, the file changed.

- [ ] **Step 8: Commit**

```bash
git add policy-rules.yaml scripts/build-rules.mjs src/rules-types.ts src/generated/rules.ts tests/build-rules.test.ts
git commit -m "feat: risk thresholds in policy-rules.yaml (PLAT-1191)"
```

---

### Task 3: Capture the risk fixtures

Signals 2, 3, 4 and 5 all read external responses. Capturing them first makes the whole suite offline and reproducible, and pins the response shapes this plan was written against.

**Files:**
- Create: `tests/fixtures/deps-dev-fastify-5.12.0.json`, `tests/fixtures/deps-dev-fastify-jwt-10.2.2.json`
- Create: `tests/fixtures/pr-27-check-runs.json`, `tests/fixtures/pr-32-check-runs.json`
- Create: `tests/fixtures/dependabot-alerts.json`
- Create: `tests/fixtures/dependabot-alerts-403-disabled.json`, `tests/fixtures/dependabot-alerts-403-permission.json`
- Create: `tests/fixtures/pr-27-manifest.json`
- Modify: `tests/fixtures/README.md`

**Interfaces:**
- Consumes: nothing
- Produces: JSON fixtures for every external response this plan parses

- [ ] **Step 1: Capture deps.dev publish timestamps**

```bash
curl -s "https://api.deps.dev/v3/systems/npm/packages/fastify/versions/5.12.0" \
  > tests/fixtures/deps-dev-fastify-5.12.0.json
curl -s "https://api.deps.dev/v3/systems/npm/packages/%40fastify%2Fjwt/versions/10.2.2" \
  > tests/fixtures/deps-dev-fastify-jwt-10.2.2.json
```

Note the scoped-package encoding: `@fastify/jwt` becomes `%40fastify%2Fjwt`. Both `@` and `/` must be encoded, which `encodeURIComponent` does.

Verify:

```bash
jq -r '"\(.versionKey.name)@\(.versionKey.version) published \(.publishedAt)"' \
  tests/fixtures/deps-dev-*.json
```

Expected: `fastify@5.12.0 published 2026-08-13T15:59:58Z` and `@fastify/jwt@10.2.2 published 2026-08-14T23:39:13Z`.

- [ ] **Step 2: Capture the head-SHA check runs**

```bash
for n in 27 32; do
  sha=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/$n --jq .head.sha)
  gh api "repos/bankrate/platform-cicd-v2-demo/commits/$sha/check-runs?per_page=100" \
    > tests/fixtures/pr-$n-check-runs.json
done
jq -r '.check_runs[] | select(.name|test("Cycode|codecov")) | "\(.name) [\(.conclusion)] \(.output.title)"' \
  tests/fixtures/pr-27-check-runs.json
```

Expected: three `Cycode: *` lines and two `codecov/*` lines. `codecov/project`'s title looks like `62.99% (+0.00%) compared to 62d5a6a` — that string is what Task 6 parses.

**If the Cycode or codecov checks are absent**, CI had not finished for that SHA. Push a commit to the PR, wait for CI, and re-capture. A fixture with no scanner checks tests only the `unknown` path.

- [ ] **Step 3: Capture a real Dependabot alerts response**

The demo repo has alerts disabled, so borrow the shape from a repo that does not:

```bash
gh api "repos/bankrate/conductor-api/dependabot/alerts?state=open&per_page=5" \
  > tests/fixtures/dependabot-alerts.json
gh api "repos/bankrate/conductor-api/dependabot/alerts?state=open&per_page=1" \
  --jq '.[0] | {scope: .dependency.scope, pkg: .dependency.package.name, ecosystem: .dependency.package.ecosystem, ghsa: .security_advisory.ghsa_id, patched: .security_vulnerability.first_patched_version.identifier}'
```

Expected shape, confirmed live: `{"ecosystem":"npm","ghsa":"GHSA-5p4m-2wfm-xmqj","patched":"4.3.1","pkg":"js-yaml","scope":"development"}`.

Use `gh api --jq` rather than piping to `jq`: advisory descriptions contain characters that break the pipe. The saved file itself is valid JSON and `JSON.parse` handles it — verified.

- [ ] **Step 4: Capture both 403 bodies**

The two causes are different and Task 7 must tell them apart.

```bash
gh api "repos/bankrate/platform-cicd-v2-demo/dependabot/alerts" 2>&1 \
  | grep -o '{.*}' > tests/fixtures/dependabot-alerts-403-disabled.json
cat tests/fixtures/dependabot-alerts-403-disabled.json
```

Expected: a body whose `message` contains *"Dependabot alerts are disabled for this repository."*

The permission-denied body is not reproducible on demand once Task 1 is approved, so write it from GitHub's documented form:

```bash
cat > tests/fixtures/dependabot-alerts-403-permission.json <<'JSON'
{
  "message": "Resource not accessible by integration",
  "documentation_url": "https://docs.github.com/rest/dependabot/alerts#list-dependabot-alerts-for-a-repository",
  "status": "403"
}
JSON
```

- [ ] **Step 5: Capture the head manifest**

```bash
sha=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/27 --jq .head.sha)
gh api "repos/bankrate/platform-cicd-v2-demo/contents/package.json?ref=$sha" \
  -H 'Accept: application/vnd.github.raw' > tests/fixtures/pr-27-manifest.json
jq -r 'to_entries[] | select(.key|test("ependencies")) | "\(.key): \(.value|length)"' tests/fixtures/pr-27-manifest.json
```

Expected: `dependencies: 22` and `devDependencies: 15`.

- [ ] **Step 6: Extend the fixtures README**

Append to `tests/fixtures/README.md`:

```markdown
## Risk-heuristic fixtures (PLAT-1191)

| Fixture | Source | Exercises |
|---|---|---|
| `deps-dev-*.json` | `api.deps.dev` version endpoint | Publish-age parsing, including a scoped package name |
| `pr-{27,32}-check-runs.json` | `GET /commits/{sha}/check-runs` | Cycode verdicts and the `codecov/project` title format |
| `dependabot-alerts.json` | `bankrate/conductor-api` | Alert shape — the demo repo has alerts DISABLED |
| `dependabot-alerts-403-disabled.json` | The demo repo | The "alerts are disabled" 403 |
| `dependabot-alerts-403-permission.json` | Hand-written from GitHub's docs | The "not accessible by integration" 403 |
| `pr-27-manifest.json` | `GET /contents/package.json?ref={headSha}` | dependencies vs devDependencies lookup |

The two 403 fixtures matter: the causes are different (a repository setting
versus a missing App permission) and the code must report which, or the first
person to debug a permanently-`unknown` signal has nothing to go on.
```

- [ ] **Step 7: Commit**

```bash
git add tests/fixtures/
git commit -m "test: capture risk-signal fixtures (PLAT-1191)"
```

---

### Task 4: Shared signal types and the check-runs fetch

Signals 4 and 5 read the same response. Fetching it twice would double the latency for no reason.

**Files:**
- Create: `src/signals/types.ts`
- Create: `src/check-runs.ts`
- Create: `tests/check-runs.test.ts`

**Interfaces:**
- Consumes: `githubRequest` from `src/github.ts`
- Produces:
  - `type SignalGrade = 'low' | 'medium' | 'high' | 'unknown'`
  - `interface Signal<T> { grade: SignalGrade; value: T | null; reason?: string }`
  - `unknownSignal<T>(reason: string): Signal<T>`
  - `interface CheckRunSummary { name: string; status: string; conclusion: string | null; title: string | null }`
  - `fetchCheckRuns(repoFullName: string, headSha: string, request?): Promise<CheckRunSummary[]>`

- [ ] **Step 1: Write the failing test**

Create `tests/check-runs.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fetchCheckRuns } from '../src/check-runs.js';

const pr27 = JSON.parse(readFileSync('tests/fixtures/pr-27-check-runs.json', 'utf8'));

function fakeRequest(body: any, ok = true, status = 200) {
  const calls: string[] = [];
  const request = async (path: string) => {
    calls.push(path);
    return { ok, status, json: async () => body, text: async () => 'err' };
  };
  return { calls, request: request as any };
}

test('flattens the check runs to name, status, conclusion and title', async () => {
  const { request, calls } = fakeRequest(pr27);
  const runs = await fetchCheckRuns('bankrate/platform-cicd-v2-demo', 'f00d42', request);
  assert.ok(runs.length > 0);
  assert.match(calls[0], /^\/repos\/bankrate\/platform-cicd-v2-demo\/commits\/f00d42\/check-runs\?/);
  const cycode = runs.find((r) => r.name === 'Cycode: SAST');
  assert.equal(cycode?.conclusion, 'success');
  assert.equal(cycode?.status, 'completed');
});

test('carries the codecov title the coverage signal parses', async () => {
  const { request } = fakeRequest(pr27);
  const runs = await fetchCheckRuns('o/r', 'sha', request);
  const project = runs.find((r) => r.name === 'codecov/project');
  assert.match(project!.title!, /%/);
});

test('a run with no output title becomes null, not undefined', async () => {
  const { request } = fakeRequest({ check_runs: [{ name: 'x', status: 'completed', conclusion: 'success', output: {} }] });
  const runs = await fetchCheckRuns('o/r', 'sha', request);
  assert.equal(runs[0]!.title, null);
});

test('a failed request returns an empty list rather than throwing', async () => {
  // Signals must degrade to `unknown`, not fail the delivery. An empty list is
  // indistinguishable from "no checks yet", which both read as `unknown`
  // downstream — the correct outcome either way.
  const { request } = fakeRequest(null, false, 502);
  const runs = await fetchCheckRuns('o/r', 'sha', request);
  assert.deepEqual(runs, []);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/check-runs.js'`

- [ ] **Step 3: Write `src/signals/types.ts`**

```ts
// Shared vocabulary for the risk signals (PLAT-1191).
//
// `unknown` is a first-class value here, not an error. T7 requires that missing
// data is recorded as unknown and never guessed, so every signal returns this
// shape whether it succeeded or not, and no signal failure ever propagates.

/** How one signal grades the change. */
export type SignalGrade = 'low' | 'medium' | 'high' | 'unknown';

/** One signal's grade plus the raw value behind it. */
export interface Signal<T> {
  grade: SignalGrade;
  /** The observed value, or null when unknown. Persisted for threshold tuning. */
  value: T | null;
  /** Why the signal is unknown. Present only when it is. */
  reason?: string;
}

/**
 * Build an unknown signal with its cause recorded.
 *
 * The reason is not decoration: a permanently-unknown signal is otherwise
 * indistinguishable from a bug, and the check-run text names it to the reader.
 */
export function unknownSignal<T>(reason: string): Signal<T> {
  return { grade: 'unknown', value: null, reason };
}
```

- [ ] **Step 4: Write `src/check-runs.ts`**

```ts
// One fetch of a commit's check runs, shared by the scanner-findings and
// coverage signals. Fetching twice would double this evaluation's latency for
// identical data.
import { githubRequest } from './github.js';
import { log } from './log.js';

/** The fields the risk signals read from a check run. */
export interface CheckRunSummary {
  name: string;
  /** `queued`, `in_progress`, or `completed`. */
  status: string;
  /** `success`, `failure`, `neutral`, … or null while incomplete. */
  conclusion: string | null;
  /** `output.title`, or null when the check posted none. */
  title: string | null;
}

/**
 * List the check runs for a commit.
 *
 * Returns an EMPTY LIST on failure rather than throwing. Every consumer treats
 * an absent check as `unknown`, and a fetch failure is exactly that — an
 * absence. Throwing would fail the whole delivery over a signal that is
 * explicitly allowed to be missing.
 *
 * Args:
 *   repoFullName: `owner/repo`.
 *   headSha: The commit to read checks for.
 *   request: Injectable GitHub request client.
 */
export async function fetchCheckRuns(
  repoFullName: string,
  headSha: string,
  request: typeof githubRequest = githubRequest,
): Promise<CheckRunSummary[]> {
  try {
    const res = await request(`/repos/${repoFullName}/commits/${headSha}/check-runs?per_page=100`);
    if (!res.ok) {
      log('warn', 'check_runs_fetch_failed', { repo: repoFullName, head_sha: headSha, status: res.status });
      return [];
    }

    const body = (await res.json()) as {
      check_runs?: { name: string; status: string; conclusion: string | null; output?: { title?: string | null } }[];
    };

    return (body.check_runs ?? []).map((run) => ({
      name: run.name,
      status: run.status,
      conclusion: run.conclusion,
      title: run.output?.title ?? null,
    }));
  } catch (err) {
    log('warn', 'check_runs_fetch_failed', {
      repo: repoFullName, head_sha: headSha,
      error: err instanceof Error ? err.message : String(err),
    });
    return [];
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/signals/types.ts src/check-runs.ts tests/check-runs.test.ts
git commit -m "feat: shared signal types and a single head-SHA check-runs fetch (PLAT-1191)"
```

---

### Task 5: Signal 4 — new scanner findings

**Files:**
- Create: `src/signals/scan-findings.ts`
- Create: `tests/signals-scan-findings.test.ts`

**Interfaces:**
- Consumes: `CheckRunSummary` (Task 4), `Signal`, `unknownSignal` (Task 4)
- Produces: `scanFindings(runs: CheckRunSummary[], maxNewFindings: number): Signal<{ failed: number; checked: number }>`

- [ ] **Step 1: Write the failing test**

Create `tests/signals-scan-findings.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { scanFindings } from '../src/signals/scan-findings.js';
import { fetchCheckRuns } from '../src/check-runs.js';
import type { CheckRunSummary } from '../src/check-runs.js';

const raw = JSON.parse(readFileSync('tests/fixtures/pr-27-check-runs.json', 'utf8'));
const fromFixture = async (): Promise<CheckRunSummary[]> =>
  fetchCheckRuns('o/r', 'sha', (async () => ({ ok: true, status: 200, json: async () => raw })) as any);

const run = (name: string, conclusion: string | null, status = 'completed'): CheckRunSummary =>
  ({ name, status, conclusion, title: null });

const ALL_GREEN: CheckRunSummary[] = [
  run('Cycode: SAST', 'success'),
  run('Cycode: Secrets', 'success'),
  run('Cycode: Vulnerable Dependencies', 'success'),
];

test('all scanners green grades low', () => {
  const s = scanFindings(ALL_GREEN, 0);
  assert.equal(s.grade, 'low');
  assert.deepEqual(s.value, { failed: 0, checked: 3 });
});

test('the real PR #27 fixture grades low', async () => {
  const s = scanFindings(await fromFixture(), 0);
  assert.equal(s.grade, 'low');
  assert.equal(s.value!.checked, 3);
});

test('a failing scanner above the threshold grades high', () => {
  const s = scanFindings([run('Cycode: SAST', 'failure'), ...ALL_GREEN.slice(1)], 0);
  assert.equal(s.grade, 'high');
  assert.equal(s.value!.failed, 1);
});

test('failures within the threshold stay low', () => {
  const s = scanFindings([run('Cycode: SAST', 'failure'), ...ALL_GREEN.slice(1)], 1);
  assert.equal(s.grade, 'low');
});

test('a MISSING scanner is unknown, never a clean scan', () => {
  const s = scanFindings(ALL_GREEN.slice(0, 2), 0);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /Cycode: Vulnerable Dependencies/);
});

test('an INCOMPLETE scanner is unknown, never a clean scan', () => {
  const s = scanFindings([run('Cycode: SAST', null, 'in_progress'), ...ALL_GREEN.slice(1)], 0);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /not finished|in_progress/i);
});

test('no checks at all is unknown — the usual case on a freshly opened PR', () => {
  const s = scanFindings([], 0);
  assert.equal(s.grade, 'unknown');
});

test('unrelated checks are ignored', () => {
  const s = scanFindings([...ALL_GREEN, run('Build, test, and lint', 'failure')], 0);
  assert.equal(s.grade, 'low', 'a failing build is not a scanner finding');
});

test('a skipped scanner counts as reported, not missing', () => {
  const s = scanFindings([run('Cycode: SAST', 'skipped'), ...ALL_GREEN.slice(1)], 0);
  assert.equal(s.grade, 'low');
  assert.equal(s.value!.failed, 0);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/signals/scan-findings.js'`

- [ ] **Step 3: Write the implementation**

Create `src/signals/scan-findings.ts`:

```ts
// Signal 4: new scanner findings on the head commit.
//
// A precise finding COUNT would need the Cycode API, for which this service has
// no credentials. "Which scanners are red on this commit" is the honest
// available signal and satisfies T7's requirement that new findings be zero.
//
// ABSENCE IS UNKNOWN, NEVER ZERO. This is the epic's fail-closed rule for the
// required-checks snapshot, applied early: a scanner that has not reported yet
// must never read as a clean scan. Getting this backwards would grade an
// unscanned commit as low risk, which is the single most dangerous thing this
// module could do.
import type { CheckRunSummary } from '../check-runs.js';
import type { Signal } from './types.js';
import { unknownSignal } from './types.js';

/** The scanners expected on every commit in this org. */
const EXPECTED = ['Cycode: SAST', 'Cycode: Secrets', 'Cycode: Vulnerable Dependencies'] as const;

/** What the signal observed. */
export interface ScanFindings {
  failed: number;
  checked: number;
}

/**
 * Grade the scanner verdicts for a commit.
 *
 * Args:
 *   runs: All check runs for the head SHA.
 *   maxNewFindings: Failing scanners tolerated before grading high.
 * Returns:
 *   `low` when failures are within tolerance, `high` when above, and `unknown`
 *   when any expected scanner is missing or has not finished.
 */
export function scanFindings(
  runs: CheckRunSummary[],
  maxNewFindings: number,
): Signal<ScanFindings> {
  const missing = EXPECTED.filter((name) => !runs.some((run) => run.name === name));
  if (missing.length > 0) {
    return unknownSignal(`scanner check(s) not present for this commit: ${missing.join(', ')}`);
  }

  const found = EXPECTED.map((name) => runs.find((run) => run.name === name)!);

  const unfinished = found.filter((run) => run.status !== 'completed');
  if (unfinished.length > 0) {
    return unknownSignal(
      `scanner check(s) not finished: ${unfinished.map((r) => `${r.name} (${r.status})`).join(', ')}`,
    );
  }

  // `skipped`, `neutral` and `success` all mean "reported, nothing wrong".
  // Only an outright failure counts as a finding.
  const failed = found.filter((run) => run.conclusion === 'failure').length;

  return {
    grade: failed > maxNewFindings ? 'high' : 'low',
    value: { failed, checked: found.length },
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 9 tests

- [ ] **Step 5: Commit**

```bash
git add src/signals/scan-findings.ts tests/signals-scan-findings.test.ts
git commit -m "feat: scanner-findings risk signal, absence reads unknown (PLAT-1191)"
```

---

### Task 6: Signal 5 — coverage versus base

**Files:**
- Create: `src/signals/coverage.ts`
- Create: `tests/signals-coverage.test.ts`

**Interfaces:**
- Consumes: `CheckRunSummary` (Task 4), `Signal`, `unknownSignal` (Task 4)
- Produces: `coverageDelta(runs: CheckRunSummary[], maxDropPct: number): Signal<{ deltaPct: number; currentPct: number }>`

- [ ] **Step 1: Write the failing test**

Create `tests/signals-coverage.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { coverageDelta } from '../src/signals/coverage.js';
import type { CheckRunSummary } from '../src/check-runs.js';

const project = (title: string | null, status = 'completed'): CheckRunSummary =>
  ({ name: 'codecov/project', status, conclusion: 'success', title });

test('parses the real codecov title format', () => {
  const s = coverageDelta([project('62.99% (+0.00%) compared to 62d5a6a')], 0);
  assert.equal(s.grade, 'low');
  assert.deepEqual(s.value, { deltaPct: 0, currentPct: 62.99 });
});

test('a coverage increase grades low', () => {
  const s = coverageDelta([project('71.20% (+2.50%) compared to abc1234')], 0);
  assert.equal(s.grade, 'low');
  assert.equal(s.value!.deltaPct, 2.5);
});

test('a drop beyond tolerance grades medium', () => {
  const s = coverageDelta([project('58.00% (-4.99%) compared to abc1234')], 0);
  assert.equal(s.grade, 'medium');
  assert.equal(s.value!.deltaPct, -4.99);
});

test('a drop within tolerance stays low', () => {
  const s = coverageDelta([project('61.99% (-1.00%) compared to abc1234')], 2);
  assert.equal(s.grade, 'low');
});

test('tolerance is a magnitude — a 1pp drop against a 2pp tolerance passes', () => {
  const s = coverageDelta([project('61.99% (-1.00%) compared to abc1234')], 2);
  assert.equal(s.grade, 'low');
  const worse = coverageDelta([project('58.99% (-4.00%) compared to abc1234')], 2);
  assert.equal(worse.grade, 'medium');
});

test('a missing codecov check is unknown', () => {
  const s = coverageDelta([], 0);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /codecov\/project/);
});

test('an unfinished codecov check is unknown', () => {
  const s = coverageDelta([project('...', 'in_progress')], 0);
  assert.equal(s.grade, 'unknown');
});

test('an unparseable title is unknown, not zero', () => {
  const s = coverageDelta([project('Coverage report unavailable')], 0);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /could not parse/i);
});

test('a null title is unknown', () => {
  const s = coverageDelta([project(null)], 0);
  assert.equal(s.grade, 'unknown');
});

test('codecov/patch is not used — only codecov/project measures the whole project', () => {
  const patch: CheckRunSummary = { name: 'codecov/patch', status: 'completed', conclusion: 'success', title: '90.00% (+1.00%) compared to abc' };
  assert.equal(coverageDelta([patch], 0).grade, 'unknown');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/signals/coverage.js'`

- [ ] **Step 3: Write the implementation**

Create `src/signals/coverage.ts`:

```ts
// Signal 5: project coverage change versus the base commit.
//
// Read from the `codecov/project` check run's output title, which on this org's
// repos reads e.g. `62.99% (+0.00%) compared to 62d5a6a`. Both the current
// percentage and the signed delta are in that string.
//
// `codecov/patch` is deliberately NOT used: it measures only the lines this PR
// touched, which is a different question. A dependency bump touching no source
// has a meaningless patch coverage and a meaningful project coverage.
//
// Dependency bumps rarely move coverage, so this signal is usually a quiet
// `low`. It earns its place by catching a bump that silently drops instrumented
// code.
import type { CheckRunSummary } from '../check-runs.js';
import type { Signal } from './types.js';
import { unknownSignal } from './types.js';

const CHECK_NAME = 'codecov/project';

// `62.99% (+0.00%) compared to 62d5a6a`
const TITLE = /^([\d.]+)%\s*\(([+-][\d.]+)%\)/;

/** What the signal observed. */
export interface CoverageDelta {
  /** Signed change in percentage points. Negative is a drop. */
  deltaPct: number;
  currentPct: number;
}

/**
 * Grade the project coverage change.
 *
 * Args:
 *   runs: All check runs for the head SHA.
 *   maxDropPct: Drop tolerated in percentage points, as a magnitude.
 * Returns:
 *   `low` when coverage rose or fell within tolerance, `medium` when it fell
 *   further, `unknown` when Codecov has not reported or the title did not parse.
 */
export function coverageDelta(
  runs: CheckRunSummary[],
  maxDropPct: number,
): Signal<CoverageDelta> {
  const run = runs.find((r) => r.name === CHECK_NAME);
  if (!run) return unknownSignal(`${CHECK_NAME} has not reported for this commit`);
  if (run.status !== 'completed') return unknownSignal(`${CHECK_NAME} is ${run.status}`);
  if (!run.title) return unknownSignal(`${CHECK_NAME} posted no output title`);

  const match = TITLE.exec(run.title);
  if (!match) return unknownSignal(`could not parse coverage from "${run.title}"`);

  const currentPct = Number(match[1]);
  const deltaPct = Number(match[2]);
  if (!Number.isFinite(currentPct) || !Number.isFinite(deltaPct)) {
    return unknownSignal(`could not parse coverage from "${run.title}"`);
  }

  // deltaPct is signed; maxDropPct is a magnitude. A drop of 4.99 against a
  // tolerance of 2 is a fail: -4.99 < -2.
  return {
    grade: deltaPct < -Math.abs(maxDropPct) ? 'medium' : 'low',
    value: { deltaPct, currentPct },
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 10 tests

- [ ] **Step 5: Commit**

```bash
git add src/signals/coverage.ts tests/signals-coverage.test.ts
git commit -m "feat: coverage-delta risk signal from the codecov check (PLAT-1191)"
```

---

### Task 7: Signal 2 — publish age

The only signal that reaches outside GitHub and AWS, and the only one with a concurrency budget.

**Files:**
- Create: `src/signals/publish-age.ts`
- Create: `tests/signals-publish-age.test.ts`

**Interfaces:**
- Consumes: `DependencyBump` from Spec A's `src/classify.ts`; `Signal`, `unknownSignal` (Task 4)
- Produces:
  - `publishAge(bumps: DependencyBump[], cooldownDays: number, deps?: PublishAgeDeps): Promise<Signal<{ youngestDays: number; package: string }>>`
  - `interface PublishAgeDeps { fetchPublishedAt: (name: string, version: string) => Promise<string | null>; now: () => number }`
  - `fetchPublishedAt(name: string, version: string, fetchImpl?: typeof fetch): Promise<string | null>`
  - `mapWithConcurrency<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]>`

- [ ] **Step 1: Write the failing test**

Create `tests/signals-publish-age.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { publishAge, mapWithConcurrency } from '../src/signals/publish-age.js';
import type { DependencyBump } from '../src/classify.js';

const fastify = JSON.parse(readFileSync('tests/fixtures/deps-dev-fastify-5.12.0.json', 'utf8'));
const jwt = JSON.parse(readFileSync('tests/fixtures/deps-dev-fastify-jwt-10.2.2.json', 'utf8'));

// 2026-08-25T12:00:00Z — fastify@5.12.0 is 11.x days old, @fastify/jwt@10.2.2 is 10.x
const NOW = Date.parse('2026-08-25T12:00:00Z');

const bump = (name: string, to: string): DependencyBump =>
  ({ name, from: '0.0.0', to, level: 'patch' });

function deps(times: Record<string, string | null>) {
  const asked: string[] = [];
  return {
    asked,
    deps: {
      fetchPublishedAt: async (name: string) => { asked.push(name); return times[name] ?? null; },
      now: () => NOW,
    },
  };
}

test('grades low when every package is older than the cooldown', async () => {
  const { deps: d } = deps({ fastify: fastify.publishedAt, '@fastify/jwt': jwt.publishedAt });
  const s = await publishAge([bump('fastify', '^5.12.0'), bump('@fastify/jwt', '^10.2.2')], 3, d);
  assert.equal(s.grade, 'low');
  assert.equal(s.value!.package, '@fastify/jwt', 'the youngest package is reported');
  assert.equal(s.value!.youngestDays, 10);
});

test('grades medium when any package is inside the cooldown window', async () => {
  const fresh = new Date(NOW - 12 * 60 * 60 * 1000).toISOString();
  const { deps: d } = deps({ fastify: fastify.publishedAt, 'brand-new': fresh });
  const s = await publishAge([bump('fastify', '^5.12.0'), bump('brand-new', '^1.0.0')], 3, d);
  assert.equal(s.grade, 'medium');
  assert.equal(s.value!.package, 'brand-new');
  assert.equal(s.value!.youngestDays, 0);
});

test('one failed lookup does not sink the signal', async () => {
  const { deps: d } = deps({ fastify: fastify.publishedAt, unknownpkg: null });
  const s = await publishAge([bump('fastify', '^5.12.0'), bump('unknownpkg', '^1.0.0')], 3, d);
  assert.equal(s.grade, 'low');
  assert.match(s.reason!, /unknownpkg/, 'the failure is named');
});

test('all lookups failing makes the signal unknown', async () => {
  const { deps: d } = deps({});
  const s = await publishAge([bump('a', '^1.0.0'), bump('b', '^2.0.0')], 3, d);
  assert.equal(s.grade, 'unknown');
});

test('no bumps at all is unknown, not low', async () => {
  const { deps: d } = deps({});
  const s = await publishAge([], 3, d);
  assert.equal(s.grade, 'unknown');
});

test('range prefixes are stripped before lookup', async () => {
  const { deps: d, asked } = deps({ fastify: fastify.publishedAt });
  await publishAge([bump('fastify', '^5.12.0')], 3, d);
  assert.deepEqual(asked, ['fastify']);
});

test('mapWithConcurrency never exceeds its limit', async () => {
  let inFlight = 0;
  let peak = 0;
  const items = Array.from({ length: 11 }, (_, i) => i);
  const results = await mapWithConcurrency(items, 8, async (i) => {
    inFlight++; peak = Math.max(peak, inFlight);
    await new Promise((r) => setTimeout(r, 5));
    inFlight--;
    return i * 2;
  });
  assert.equal(peak <= 8, true, `peak concurrency was ${peak}`);
  assert.deepEqual(results, items.map((i) => i * 2));
});

test('mapWithConcurrency preserves input order despite parallelism', async () => {
  const results = await mapWithConcurrency([30, 10, 20], 3, async (ms) => {
    await new Promise((r) => setTimeout(r, ms));
    return ms;
  });
  assert.deepEqual(results, [30, 10, 20]);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/signals/publish-age.js'`

- [ ] **Step 3: Write the implementation**

Create `src/signals/publish-age.ts`:

```ts
// Signal 2: how long the new version has been public.
//
// A version published hours ago is the supply-chain attack window; one
// published weeks ago has been under the world's scrutiny.
//
// SOURCE: api.deps.dev, NOT registry.npmjs.org. npm exposes publish timestamps
// only in the full packument (`GET /{pkg}`) — the per-version endpoint has no
// time field at all — and a popular package's packument is enormous
// (fastify's is 1,780,110 bytes). Eleven of those per evaluation would pull
// ~20 MB into a 256 MB Lambda to read eleven dates. deps.dev returns the same
// timestamp in 834 bytes.
//
// The cost is a dependency on a third party neither Bankrate nor GitHub
// operates. It is acceptable ONLY because the failure mode was already
// designed: a slow, down, or reshaped deps.dev records `unknown`, which is what
// T7 specifies. No evaluation fails and no check run is lost.
import type { DependencyBump } from '../classify.js';
import type { Signal } from './types.js';
import { unknownSignal } from './types.js';
import { log } from '../log.js';

const DEPS_DEV = 'https://api.deps.dev/v3/systems/npm/packages';

// Bounds outbound fan-out: a grouped bump can carry a dozen packages, and this
// runs inside a Lambda with a 30s budget shared with several GitHub calls.
const CONCURRENCY = 8;
const REQUEST_TIMEOUT_MS = 3_000;

const MS_PER_DAY = 24 * 60 * 60 * 1000;

// Strips range operators: `^5.12.0` -> `5.12.0`.
const VERSION = /(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)/;

/** What the signal observed. */
export interface PublishAge {
  /** Age in whole days of the youngest package in the change. */
  youngestDays: number;
  /** Which package that was. */
  package: string;
}

/** Injectable collaborators (real implementations by default). */
export interface PublishAgeDeps {
  fetchPublishedAt: (name: string, version: string) => Promise<string | null>;
  now: () => number;
}

/**
 * Run `fn` over `items` with at most `limit` in flight, preserving input order.
 *
 * Written here rather than pulled from npm: it is fifteen lines, and the
 * alternative is a runtime dependency in the Lambda bundle for one call site.
 */
export async function mapWithConcurrency<T, R>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;

  const worker = async (): Promise<void> => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index]!);
    }
  };

  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

/**
 * Look up when a specific npm version was published.
 *
 * Args:
 *   name: Package name. Scoped names are URL-encoded (`@fastify/jwt` becomes
 *     `%40fastify%2Fjwt`), which `encodeURIComponent` handles.
 *   version: A bare semver, already stripped of range operators.
 *   fetchImpl: Injectable fetch.
 * Returns:
 *   An ISO-8601 timestamp, or null on any failure — a 404, a timeout, a
 *   reshaped response. Null becomes `unknown`, never a guess.
 */
export async function fetchPublishedAt(
  name: string,
  version: string,
  fetchImpl: typeof fetch = fetch,
): Promise<string | null> {
  try {
    const url = `${DEPS_DEV}/${encodeURIComponent(name)}/versions/${encodeURIComponent(version)}`;
    const res = await fetchImpl(url, { signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    if (!res.ok) return null;

    const body = (await res.json()) as { publishedAt?: string };
    return body.publishedAt ?? null;
  } catch {
    // Timeout, DNS failure, malformed JSON — all the same outcome: unknown.
    return null;
  }
}

const defaultDeps: PublishAgeDeps = { fetchPublishedAt, now: () => Date.now() };

/**
 * Grade the change by the age of its youngest package.
 *
 * The YOUNGEST, not the governing bump: a single fresh package among ten mature
 * ones is the actual supply-chain exposure, and grading on the package that
 * happened to set the semver class would miss it.
 *
 * Args:
 *   bumps: Every dependency bump in the change, from `classify()`.
 *   cooldownDays: Below this age, a version is still in the exposure window.
 *   deps: Injected lookup and clock.
 */
export async function publishAge(
  bumps: DependencyBump[],
  cooldownDays: number,
  deps: PublishAgeDeps = defaultDeps,
): Promise<Signal<PublishAge>> {
  if (bumps.length === 0) return unknownSignal('no dependency bumps to age');

  const now = deps.now();

  const ages = await mapWithConcurrency(bumps, CONCURRENCY, async (bump) => {
    const version = VERSION.exec(bump.to)?.[1];
    if (!version) return { name: bump.name, days: null };

    const publishedAt = await deps.fetchPublishedAt(bump.name, version);
    if (!publishedAt) return { name: bump.name, days: null };

    const published = Date.parse(publishedAt);
    if (!Number.isFinite(published)) return { name: bump.name, days: null };

    return { name: bump.name, days: Math.floor((now - published) / MS_PER_DAY) };
  });

  const known = ages.filter((a): a is { name: string; days: number } => a.days !== null);
  const failed = ages.filter((a) => a.days === null).map((a) => a.name);

  if (known.length === 0) {
    log('warn', 'publish_age_all_unknown', { packages: bumps.length });
    return unknownSignal(`no publish date available for any of ${bumps.length} package(s)`);
  }

  const youngest = known.reduce((min, a) => (a.days < min.days ? a : min));

  return {
    grade: youngest.days < cooldownDays ? 'medium' : 'low',
    value: { youngestDays: youngest.days, package: youngest.name },
    // Partial failures are recorded but do not sink the signal: the packages we
    // did age still say something true.
    ...(failed.length > 0 ? { reason: `no publish date for ${failed.join(', ')}` } : {}),
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 8 tests

- [ ] **Step 5: Verify the real endpoint once, by hand**

```bash
node --import tsx -e "
import { fetchPublishedAt } from './src/signals/publish-age.ts';
console.log('fastify@5.12.0     ', await fetchPublishedAt('fastify', '5.12.0'));
console.log('@fastify/jwt@10.2.2', await fetchPublishedAt('@fastify/jwt', '10.2.2'));
console.log('nonexistent        ', await fetchPublishedAt('this-package-does-not-exist-xyz', '1.0.0'));
"
```

Expected: two ISO timestamps and a `null`. This confirms scoped-name encoding and the not-found path against the live service — the fixtures cannot.

- [ ] **Step 6: Commit**

```bash
git add src/signals/publish-age.ts tests/signals-publish-age.test.ts
git commit -m "feat: publish-age risk signal via deps.dev (PLAT-1191)"
```

---

### Task 8: Signal 3 — closes a known finding

**Files:**
- Create: `src/signals/advisories.ts`
- Create: `tests/signals-advisories.test.ts`

**Interfaces:**
- Consumes: `githubRequest`; `DependencyBump` from `src/classify.ts`; `Signal`, `unknownSignal` (Task 4)
- Produces:
  - `fetchOpenAlerts(repoFullName: string, request?): Promise<AlertsResult>`
  - `type AlertsResult = { ok: true; alerts: DependabotAlert[] } | { ok: false; reason: 'permission' | 'disabled' | 'error' }`
  - `interface DependabotAlert { packageName: string; ecosystem: string; ghsaId: string; firstPatched: string | null }`
  - `closesFinding(result: AlertsResult, bumps: DependencyBump[]): Signal<{ ghsaIds: string[] }>`

- [ ] **Step 1: Write the failing test**

Create `tests/signals-advisories.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fetchOpenAlerts, closesFinding } from '../src/signals/advisories.js';
import type { AlertsResult } from '../src/signals/advisories.js';
import type { DependencyBump } from '../src/classify.js';

const alertsBody = JSON.parse(readFileSync('tests/fixtures/dependabot-alerts.json', 'utf8'));
const disabled403 = JSON.parse(readFileSync('tests/fixtures/dependabot-alerts-403-disabled.json', 'utf8'));
const permission403 = JSON.parse(readFileSync('tests/fixtures/dependabot-alerts-403-permission.json', 'utf8'));

const bump = (name: string, to: string): DependencyBump =>
  ({ name, from: '0.0.0', to, level: 'patch' });

function fakeRequest(body: any, ok = true, status = 200) {
  return (async () => ({ ok, status, json: async () => body, text: async () => JSON.stringify(body) })) as any;
}

const ok = (alerts: any[]): AlertsResult => ({ ok: true, alerts });

test('parses the live alert shape', async () => {
  const result = await fetchOpenAlerts('o/r', fakeRequest(alertsBody));
  assert.equal(result.ok, true);
  const alert = (result as any).alerts[0];
  assert.equal(typeof alert.packageName, 'string');
  assert.equal(alert.ecosystem, 'npm');
  assert.match(alert.ghsaId, /^GHSA-/);
});

test('a 403 for a disabled repo is reported as disabled', async () => {
  const result = await fetchOpenAlerts('o/r', fakeRequest(disabled403, false, 403));
  assert.deepEqual(result, { ok: false, reason: 'disabled' });
});

test('a 403 for a missing permission is reported as permission', async () => {
  const result = await fetchOpenAlerts('o/r', fakeRequest(permission403, false, 403));
  assert.deepEqual(result, { ok: false, reason: 'permission' });
});

test('any other failure is reported as error', async () => {
  const result = await fetchOpenAlerts('o/r', fakeRequest({}, false, 502));
  assert.deepEqual(result, { ok: false, reason: 'error' });
});

test('a bump to at-or-above the patched version closes the finding', () => {
  const s = closesFinding(
    ok([{ packageName: 'js-yaml', ecosystem: 'npm', ghsaId: 'GHSA-5p4m-2wfm-xmqj', firstPatched: '4.3.1' }]),
    [bump('js-yaml', '^4.3.1')],
  );
  assert.equal(s.grade, 'low');
  assert.deepEqual(s.value, { ghsaIds: ['GHSA-5p4m-2wfm-xmqj'] });
});

test('a bump above the patched version also closes it', () => {
  const s = closesFinding(
    ok([{ packageName: 'js-yaml', ecosystem: 'npm', ghsaId: 'G-1', firstPatched: '4.3.1' }]),
    [bump('js-yaml', '^4.9.0')],
  );
  assert.deepEqual(s.value, { ghsaIds: ['G-1'] });
});

test('a bump below the patched version closes nothing', () => {
  const s = closesFinding(
    ok([{ packageName: 'js-yaml', ecosystem: 'npm', ghsaId: 'G-1', firstPatched: '4.3.1' }]),
    [bump('js-yaml', '^4.2.0')],
  );
  assert.deepEqual(s.value, { ghsaIds: [] });
});

test('an alert for a package this PR does not touch is ignored', () => {
  const s = closesFinding(
    ok([{ packageName: 'lodash', ecosystem: 'npm', ghsaId: 'G-1', firstPatched: '1.0.0' }]),
    [bump('js-yaml', '^4.3.1')],
  );
  assert.deepEqual(s.value, { ghsaIds: [] });
});

test('a non-npm alert is ignored', () => {
  const s = closesFinding(
    ok([{ packageName: 'js-yaml', ecosystem: 'rubygems', ghsaId: 'G-1', firstPatched: '4.3.1' }]),
    [bump('js-yaml', '^4.3.1')],
  );
  assert.deepEqual(s.value, { ghsaIds: [] });
});

test('an alert with no patched version cannot be closed by any bump', () => {
  const s = closesFinding(
    ok([{ packageName: 'js-yaml', ecosystem: 'npm', ghsaId: 'G-1', firstPatched: null }]),
    [bump('js-yaml', '^9.9.9')],
  );
  assert.deepEqual(s.value, { ghsaIds: [] });
});

test('no open alerts means the signal is known and empty, not unknown', () => {
  const s = closesFinding(ok([]), [bump('js-yaml', '^4.3.1')]);
  assert.equal(s.grade, 'low');
  assert.deepEqual(s.value, { ghsaIds: [] });
});

test('a failed fetch is unknown, and names which 403 it was', () => {
  const s = closesFinding({ ok: false, reason: 'disabled' }, [bump('a', '^1.0.0')]);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /disabled/);

  const perm = closesFinding({ ok: false, reason: 'permission' }, [bump('a', '^1.0.0')]);
  assert.match(perm.reason!, /permission/);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/signals/advisories.js'`

- [ ] **Step 3: Write the implementation**

Create `src/signals/advisories.ts`:

```ts
// Signal 3: does this change close a known open security advisory?
//
// A security remediation is LESS risky to merge than an equivalent routine
// bump, and this is the signal that says so. It is the only signal that acts as
// a reducer rather than a contributor — see src/risk.ts.
//
// Two different 403s reach this code and they mean different things:
//   - "Dependabot alerts are disabled for this repository" is a REPOSITORY
//     SETTING. No App permission grant will fix it.
//   - "Resource not accessible by integration" is a MISSING APP PERMISSION
//     (`vulnerability_alerts: read`), or one still pending org approval.
// Telling them apart is the whole reason this module distinguishes the cases:
// otherwise the first person to debug a permanently-unknown signal has nothing
// to go on.
import { githubRequest } from '../github.js';
import type { DependencyBump } from '../classify.js';
import type { Signal } from './types.js';
import { unknownSignal } from './types.js';
import { log } from '../log.js';

/** The fields this signal reads from a Dependabot alert. */
export interface DependabotAlert {
  packageName: string;
  /** `npm`, `rubygems`, `pip`, … Only npm is matched here. */
  ecosystem: string;
  ghsaId: string;
  /** Lowest version that resolves the advisory, or null when none exists yet. */
  firstPatched: string | null;
}

/** Either the alerts, or why they could not be read. */
export type AlertsResult =
  | { ok: true; alerts: DependabotAlert[] }
  | { ok: false; reason: 'permission' | 'disabled' | 'error' };

const VERSION = /(\d+)\.(\d+)\.(\d+)/;

/** Is `a` at or above `b`? Both are bare semvers. */
function atOrAbove(a: string, b: string): boolean {
  const x = VERSION.exec(a);
  const y = VERSION.exec(b);
  if (!x || !y) return false;

  for (let i = 1; i <= 3; i++) {
    const left = Number(x[i]);
    const right = Number(y[i]);
    if (left !== right) return left > right;
  }
  return true;
}

/**
 * Fetch the repository's open Dependabot alerts.
 *
 * Never throws: every failure is a reason code, because this signal is allowed
 * to be unknown and a delivery must not fail over it.
 */
export async function fetchOpenAlerts(
  repoFullName: string,
  request: typeof githubRequest = githubRequest,
): Promise<AlertsResult> {
  try {
    const res = await request(`/repos/${repoFullName}/dependabot/alerts?state=open&per_page=100`);

    if (!res.ok) {
      const body = await res.text();
      const reason: 'permission' | 'disabled' | 'error' =
        res.status !== 403 ? 'error' : /disabled/i.test(body) ? 'disabled' : 'permission';
      log('warn', 'advisories_forbidden', { repo: repoFullName, status: res.status, reason });
      return { ok: false, reason };
    }

    const body = (await res.json()) as {
      dependency?: { package?: { name?: string; ecosystem?: string } };
      security_advisory?: { ghsa_id?: string };
      security_vulnerability?: { first_patched_version?: { identifier?: string } | null };
    }[];

    return {
      ok: true,
      alerts: body.map((alert) => ({
        packageName: alert.dependency?.package?.name ?? '',
        ecosystem: alert.dependency?.package?.ecosystem ?? '',
        ghsaId: alert.security_advisory?.ghsa_id ?? '',
        firstPatched: alert.security_vulnerability?.first_patched_version?.identifier ?? null,
      })),
    };
  } catch (err) {
    log('warn', 'advisories_fetch_failed', {
      repo: repoFullName,
      error: err instanceof Error ? err.message : String(err),
    });
    return { ok: false, reason: 'error' };
  }
}

/** What the signal observed. */
export interface ClosesFinding {
  /** Advisories this change resolves. Empty is a valid, known answer. */
  ghsaIds: string[];
}

const REASONS: Record<'permission' | 'disabled' | 'error', string> = {
  disabled: 'Dependabot alerts are disabled for this repository',
  permission: 'the app lacks permission to read Dependabot alerts (or approval is pending)',
  error: 'the Dependabot alerts API could not be reached',
};

/**
 * Which open advisories this change resolves.
 *
 * An empty list is a KNOWN answer, not an unknown one: "we checked and this
 * closes nothing" is different from "we could not check", and only the latter
 * is `unknown`.
 *
 * The grade is always `low` when known — this signal never raises risk. It acts
 * as a one-step reducer in src/risk.ts, and the grade here exists only so the
 * shape matches every other signal.
 */
export function closesFinding(
  result: AlertsResult,
  bumps: DependencyBump[],
): Signal<ClosesFinding> {
  if (!result.ok) return unknownSignal(REASONS[result.reason]);

  const ghsaIds = result.alerts
    .filter((alert) => {
      if (alert.ecosystem !== 'npm' || !alert.firstPatched) return false;
      const bump = bumps.find((b) => b.name === alert.packageName);
      return bump !== undefined && atOrAbove(bump.to, alert.firstPatched);
    })
    .map((alert) => alert.ghsaId);

  return { grade: 'low', value: { ghsaIds } };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 12 tests

- [ ] **Step 5: Commit**

```bash
git add src/signals/advisories.ts tests/signals-advisories.test.ts
git commit -m "feat: closes-known-finding risk signal (PLAT-1191)"
```

---

### Task 9: Signal 6 — development versus production dependency

**Files:**
- Create: `src/signals/dep-type.ts`
- Create: `tests/signals-dep-type.test.ts`

**Interfaces:**
- Consumes: `githubRequest`; `DependencyBump`; `Signal`, `unknownSignal` (Task 4)
- Produces:
  - `fetchManifestSections(repoFullName: string, headSha: string, request?): Promise<Record<string, 'production' | 'development'> | null>`
  - `depType(sections: Record<string, 'production' | 'development'> | null, bumps: DependencyBump[]): Signal<{ production: number; development: number }>`

- [ ] **Step 1: Write the failing test**

Create `tests/signals-dep-type.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fetchManifestSections, depType } from '../src/signals/dep-type.js';
import type { DependencyBump } from '../src/classify.js';

const manifest = readFileSync('tests/fixtures/pr-27-manifest.json', 'utf8');

const bump = (name: string): DependencyBump => ({ name, from: '1.0.0', to: '1.0.1', level: 'patch' });

function fakeRequest(body: string, ok = true, status = 200) {
  const calls: string[] = [];
  const request = async (path: string) => {
    calls.push(path);
    return { ok, status, text: async () => body };
  };
  return { calls, request: request as any };
}

test('builds a name-to-section map from the head manifest', async () => {
  const { request, calls } = fakeRequest(manifest);
  const sections = await fetchManifestSections('o/r', 'f00d42', request);
  assert.equal(sections!['fastify'], 'production');
  assert.equal(sections!['typescript'], 'development');
  assert.match(calls[0], /\/repos\/o\/r\/contents\/package\.json\?ref=f00d42/);
});

test('an unreadable manifest returns null rather than throwing', async () => {
  const { request } = fakeRequest('', false, 404);
  assert.equal(await fetchManifestSections('o/r', 'sha', request), null);
});

test('unparseable manifest content returns null', async () => {
  const { request } = fakeRequest('not json at all');
  assert.equal(await fetchManifestSections('o/r', 'sha', request), null);
});

test('any production dependency grades medium', () => {
  const s = depType({ fastify: 'production', typescript: 'development' }, [bump('fastify'), bump('typescript')]);
  assert.equal(s.grade, 'medium');
  assert.deepEqual(s.value, { production: 1, development: 1 });
});

test('development-only grades low', () => {
  const s = depType({ typescript: 'development', vitest: 'development' }, [bump('typescript'), bump('vitest')]);
  assert.equal(s.grade, 'low');
  assert.deepEqual(s.value, { production: 0, development: 2 });
});

test('PR #27 shape: mostly production, grades medium', () => {
  const sections = { fastify: 'production' as const, jose: 'production' as const, '@types/pg': 'development' as const };
  const s = depType(sections, [bump('fastify'), bump('jose'), bump('@types/pg')]);
  assert.equal(s.grade, 'medium');
  assert.deepEqual(s.value, { production: 2, development: 1 });
});

test('a null section map is unknown', () => {
  const s = depType(null, [bump('fastify')]);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /manifest/i);
});

test('a bump absent from the manifest is unknown, not assumed development', () => {
  // Assuming "not in the manifest means devDependency" would grade a runtime
  // dependency as low risk on a rename or a workspace layout this code does not
  // understand. Fail loud instead.
  const s = depType({ fastify: 'production' }, [bump('fastify'), bump('mystery-package')]);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /mystery-package/);
});

test('no bumps is unknown', () => {
  assert.equal(depType({}, []).grade, 'unknown');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/signals/dep-type.js'`

- [ ] **Step 3: Write the implementation**

Create `src/signals/dep-type.ts`:

```ts
// Signal 6: are the bumped packages runtime or development dependencies?
//
// A devDependency bump cannot reach production; a runtime dependency can.
//
// READ FROM THE HEAD MANIFEST, NOT THE PATCH. Patch hunks do not reliably carry
// the section header: PR #27's first hunk starts at line 43 and does include
// `"dependencies": {`, but PR #32's single hunk starts at line 65 and never
// shows `"devDependencies": {` even though every changed line is one. Parsing
// section context out of a hunk therefore works on some pull requests and
// silently guesses on the rest, which is worse than not having the signal.
import { githubRequest } from '../github.js';
import type { DependencyBump } from '../classify.js';
import type { Signal } from './types.js';
import { unknownSignal } from './types.js';
import { log } from '../log.js';

/** Which manifest section a package sits in. */
export type DepSection = 'production' | 'development';

/** Manifest keys that put a package in production at runtime. */
const PRODUCTION_KEYS = ['dependencies', 'optionalDependencies', 'peerDependencies'];
const DEVELOPMENT_KEYS = ['devDependencies'];

/** What the signal observed. */
export interface DepTypeCounts {
  production: number;
  development: number;
}

/**
 * Fetch the head commit's package.json and index every dependency by section.
 *
 * Returns null on any failure — the signal reads that as `unknown`. Never
 * throws: a delivery must not fail over a signal allowed to be missing.
 */
export async function fetchManifestSections(
  repoFullName: string,
  headSha: string,
  request: typeof githubRequest = githubRequest,
): Promise<Record<string, DepSection> | null> {
  try {
    const res = await request(
      `/repos/${repoFullName}/contents/package.json?ref=${headSha}`,
      { headers: { Accept: 'application/vnd.github.raw' } },
    );
    if (!res.ok) {
      log('warn', 'manifest_fetch_failed', { repo: repoFullName, head_sha: headSha, status: res.status });
      return null;
    }

    const manifest = JSON.parse(await res.text()) as Record<string, unknown>;
    const sections: Record<string, DepSection> = {};

    for (const [keys, section] of [[PRODUCTION_KEYS, 'production'], [DEVELOPMENT_KEYS, 'development']] as const) {
      for (const key of keys) {
        const block = manifest[key];
        if (block && typeof block === 'object') {
          for (const name of Object.keys(block)) sections[name] = section;
        }
      }
    }

    return sections;
  } catch (err) {
    log('warn', 'manifest_fetch_failed', {
      repo: repoFullName, head_sha: headSha,
      error: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}

/**
 * Grade the change by whether it touches runtime dependencies.
 *
 * A bump absent from the manifest makes the whole signal `unknown` rather than
 * being assumed development. Assuming would grade a runtime dependency as low
 * risk whenever this code meets a layout it does not understand — a rename, a
 * workspace, a monorepo path — which is exactly when a guess is least safe.
 */
export function depType(
  sections: Record<string, DepSection> | null,
  bumps: DependencyBump[],
): Signal<DepTypeCounts> {
  if (sections === null) return unknownSignal('head package.json could not be read');
  if (bumps.length === 0) return unknownSignal('no dependency bumps to classify');

  const unlisted = bumps.filter((bump) => sections[bump.name] === undefined).map((b) => b.name);
  if (unlisted.length > 0) {
    return unknownSignal(`bumped package(s) not found in the head manifest: ${unlisted.join(', ')}`);
  }

  const production = bumps.filter((bump) => sections[bump.name] === 'production').length;

  return {
    grade: production > 0 ? 'medium' : 'low',
    value: { production, development: bumps.length - production },
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 9 tests

- [ ] **Step 5: Commit**

```bash
git add src/signals/dep-type.ts tests/signals-dep-type.test.ts
git commit -m "feat: dev-vs-prod dependency risk signal from the head manifest (PLAT-1191)"
```

---

### Task 10: Grading

**Files:**
- Create: `src/risk.ts`
- Create: `tests/risk.test.ts`

**Interfaces:**
- Consumes: `Signal`, `SignalGrade` (Task 4); the five signal value types (Tasks 5–9); `SemverLevel` from `src/rules-types.ts`
- Produces:
  - `gradeSemverDistance(maxDelta: SemverLevel): Signal<string>`
  - `combine(signals: RiskSignals): RiskResult`
  - `interface RiskSignals { semverDistance; publishAge; closesFinding; newFindings; coverageDelta; depType }`
  - `interface RiskResult { grade: SignalGrade; signalsGraded: number; signals: RiskSignals }`

- [ ] **Step 1: Write the failing test**

Create `tests/risk.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { combine, gradeSemverDistance } from '../src/risk.js';
import type { RiskSignals } from '../src/risk.js';
import type { Signal, SignalGrade } from '../src/signals/types.js';

const sig = <T>(grade: SignalGrade, value: T | null = null): Signal<T> => ({ grade, value });

function signals(over: Partial<RiskSignals> = {}): RiskSignals {
  return {
    semverDistance: sig('low', 'patch'),
    publishAge: sig('low', { youngestDays: 30, package: 'a' }),
    closesFinding: sig('low', { ghsaIds: [] }),
    newFindings: sig('low', { failed: 0, checked: 3 }),
    coverageDelta: sig('low', { deltaPct: 0, currentPct: 60 }),
    depType: sig('low', { production: 0, development: 2 }),
    ...over,
  } as RiskSignals;
}

test('semver distance maps by level', () => {
  assert.equal(gradeSemverDistance('none').grade, 'low');
  assert.equal(gradeSemverDistance('patch').grade, 'low');
  assert.equal(gradeSemverDistance('minor').grade, 'medium');
  assert.equal(gradeSemverDistance('major').grade, 'high');
});

test('all low grades low, on all six signals', () => {
  const r = combine(signals());
  assert.equal(r.grade, 'low');
  assert.equal(r.signalsGraded, 6);
});

test('worst signal wins', () => {
  assert.equal(combine(signals({ depType: sig('medium', { production: 1, development: 0 }) })).grade, 'medium');
  assert.equal(combine(signals({ newFindings: sig('high', { failed: 2, checked: 3 }) })).grade, 'high');
});

test('one high beats several lows — worst-of is not an average', () => {
  const r = combine(signals({ semverDistance: sig('high', 'major') }));
  assert.equal(r.grade, 'high');
});

test('the PR #27 shape grades medium, not low', () => {
  // minor bump + production dependencies. Three low signals do not average it
  // down; this is the case the worst-of rule exists for.
  const r = combine(signals({
    semverDistance: sig('medium', 'minor'),
    depType: sig('medium', { production: 6, development: 1 }),
    closesFinding: sig('unknown'),
  }));
  assert.equal(r.grade, 'medium');
  assert.equal(r.signalsGraded, 5);
});

test('unknown signals are excluded from the comparison but counted', () => {
  const r = combine(signals({ newFindings: sig('unknown'), coverageDelta: sig('unknown') }));
  assert.equal(r.grade, 'low');
  assert.equal(r.signalsGraded, 4);
});

test('every signal unknown grades unknown', () => {
  const r = combine(signals({
    semverDistance: sig('unknown'), publishAge: sig('unknown'), closesFinding: sig('unknown'),
    newFindings: sig('unknown'), coverageDelta: sig('unknown'), depType: sig('unknown'),
  }));
  assert.equal(r.grade, 'unknown');
  assert.equal(r.signalsGraded, 0);
});

test('closesFinding lowers the grade by exactly one step', () => {
  const closes = sig('low', { ghsaIds: ['GHSA-1'] });
  assert.equal(combine(signals({ semverDistance: sig('high', 'major'), closesFinding: closes })).grade, 'medium');
  assert.equal(combine(signals({ depType: sig('medium', { production: 1, development: 0 }), closesFinding: closes })).grade, 'low');
  assert.equal(combine(signals({ closesFinding: closes })).grade, 'low', 'low cannot go lower');
});

test('closesFinding with an empty ghsa list changes nothing', () => {
  const r = combine(signals({ semverDistance: sig('high', 'major'), closesFinding: sig('low', { ghsaIds: [] }) }));
  assert.equal(r.grade, 'high');
});

test('closesFinding can never RAISE a grade', () => {
  for (const grade of ['low', 'medium', 'high'] as const) {
    const withClose = combine(signals({ semverDistance: sig(grade, 'x'), closesFinding: sig('low', { ghsaIds: ['G'] }) }));
    const without = combine(signals({ semverDistance: sig(grade, 'x'), closesFinding: sig('low', { ghsaIds: [] }) }));
    const rank = { low: 0, medium: 1, high: 2, unknown: -1 } as const;
    assert.ok(rank[withClose.grade] <= rank[without.grade], `${grade}: reducer must not raise`);
  }
});

test('closesFinding does not participate in the worst-of comparison', () => {
  // Its own grade is always `low` when known; it must not drag a high down by
  // being counted as a low.
  const r = combine(signals({ newFindings: sig('high', { failed: 1, checked: 3 }), closesFinding: sig('low', { ghsaIds: [] }) }));
  assert.equal(r.grade, 'high');
});

test('an all-unknown-but-one set grades on the one', () => {
  const r = combine(signals({
    semverDistance: sig('high', 'major'), publishAge: sig('unknown'), closesFinding: sig('unknown'),
    newFindings: sig('unknown'), coverageDelta: sig('unknown'), depType: sig('unknown'),
  }));
  assert.equal(r.grade, 'high');
  assert.equal(r.signalsGraded, 1);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/risk.js'`

- [ ] **Step 3: Write the implementation**

Create `src/risk.ts`:

```ts
// Combines the six signals into one risk grade (PLAT-1191).
//
// WORST KNOWN SIGNAL WINS. Not an average, not a score: the shadow phase exists
// to learn which signal drives which outcome, and a score obscures exactly
// that. Signals grading `unknown` are excluded from the comparison but counted,
// so a grade built from one `low` and four `unknown`s cannot render as a
// confident green.
import type { SemverLevel } from './rules-types.js';
import type { Signal, SignalGrade } from './signals/types.js';
import type { ScanFindings } from './signals/scan-findings.js';
import type { CoverageDelta } from './signals/coverage.js';
import type { PublishAge } from './signals/publish-age.js';
import type { ClosesFinding } from './signals/advisories.js';
import type { DepTypeCounts } from './signals/dep-type.js';

/** All six signals for one evaluation. */
export interface RiskSignals {
  semverDistance: Signal<string>;
  publishAge: Signal<PublishAge>;
  closesFinding: Signal<ClosesFinding>;
  newFindings: Signal<ScanFindings>;
  coverageDelta: Signal<CoverageDelta>;
  depType: Signal<DepTypeCounts>;
}

export interface RiskResult {
  grade: SignalGrade;
  /** How many of the six produced a value. Reported to the reader. */
  signalsGraded: number;
  signals: RiskSignals;
}

const RANK: Record<Exclude<SignalGrade, 'unknown'>, number> = { low: 0, medium: 1, high: 2 };
const BY_RANK = ['low', 'medium', 'high'] as const;

const SEMVER_GRADE: Record<SemverLevel, SignalGrade> = {
  none: 'low',
  patch: 'low',
  minor: 'medium',
  major: 'high',
};

/**
 * Grade the semver distance.
 *
 * Takes the max delta already computed by `classify()` from the manifest diff —
 * this never re-derives it, and never reads a title or a summary table.
 */
export function gradeSemverDistance(maxDelta: SemverLevel): Signal<string> {
  return { grade: SEMVER_GRADE[maxDelta], value: maxDelta };
}

/**
 * Combine the signals into a grade.
 *
 * `closesFinding` is deliberately NOT in the comparison set. Its own grade is
 * always `low` when known, so including it would drag nothing down but would
 * imply it contributes. Instead it acts as a one-step reducer at the end: a
 * patch that closes a known vulnerability is safer to take than the same patch
 * arriving routinely, and the grade should say so — but a bump that closes
 * nothing is not thereby riskier.
 */
export function combine(signals: RiskSignals): RiskResult {
  const comparable = [
    signals.semverDistance,
    signals.publishAge,
    signals.newFindings,
    signals.coverageDelta,
    signals.depType,
  ];

  const known = comparable.filter(
    (s): s is Signal<unknown> & { grade: Exclude<SignalGrade, 'unknown'> } => s.grade !== 'unknown',
  );

  // Counted across all SIX, including closesFinding, because the reader is told
  // "graded on N of 6" and closesFinding being available is real information.
  const signalsGraded = [...comparable, signals.closesFinding].filter((s) => s.grade !== 'unknown').length;

  if (known.length === 0) {
    return { grade: 'unknown', signalsGraded, signals };
  }

  const worstRank = known.reduce((worst, s) => Math.max(worst, RANK[s.grade]), 0);

  // The reducer: only when the signal is known AND actually closed something.
  const closes = signals.closesFinding.grade !== 'unknown'
    && (signals.closesFinding.value?.ghsaIds.length ?? 0) > 0;

  const finalRank = closes ? Math.max(0, worstRank - 1) : worstRank;

  return { grade: BY_RANK[finalRank]!, signalsGraded, signals };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS, 12 tests

- [ ] **Step 5: Commit**

```bash
git add src/risk.ts tests/risk.test.ts
git commit -m "feat: worst-known-signal risk grading with a security reducer (PLAT-1191)"
```

---

### Task 11: Render the risk check

**Files:**
- Modify: `src/render.ts` (replace `renderRiskPlaceholder` with `renderRisk` + `renderRiskNotEvaluated`)
- Modify: `tests/render.test.ts` (replace the placeholder test)

**Interfaces:**
- Consumes: `RiskResult` (Task 10); `ClassificationResult` from `src/classify.ts`; `CheckOutput` from `src/checks.ts`
- Produces:
  - `renderRisk(risk: RiskResult, classification: ClassificationResult): CheckOutput`
  - `renderRiskNotEvaluated(): CheckOutput`

- [ ] **Step 1: Write the failing tests**

In `tests/render.test.ts`, delete the existing `renderRiskPlaceholder` test and its import, then append:

```ts
import { renderRisk, renderRiskNotEvaluated } from '../src/render.js';
import type { RiskResult, RiskSignals } from '../src/risk.js';
import type { Signal, SignalGrade } from '../src/signals/types.js';

const s = <T>(grade: SignalGrade, value: T | null = null, reason?: string): Signal<T> =>
  ({ grade, value, ...(reason ? { reason } : {}) });

function riskResult(over: Partial<RiskSignals> = {}, grade: SignalGrade = 'medium', signalsGraded = 5): RiskResult {
  return {
    grade,
    signalsGraded,
    signals: {
      semverDistance: s('medium', 'minor'),
      publishAge: s('low', { youngestDays: 11, package: '@fastify/jwt' }),
      closesFinding: s('unknown', null, 'Dependabot alerts are disabled for this repository'),
      newFindings: s('low', { failed: 0, checked: 3 }),
      coverageDelta: s('low', { deltaPct: 0, currentPct: 62.99 }),
      depType: s('medium', { production: 6, development: 1 }),
      ...over,
    } as RiskSignals,
  };
}

const classification = {
  changeClass: 'dep-minor',
  maxDelta: 'minor' as const,
  bumps: [
    { name: '@fastify/jwt', from: '^10.2.1', to: '^10.2.2', level: 'patch' as const },
    { name: 'fastify', from: '^5.11.2', to: '^5.12.0', level: 'minor' as const },
  ],
};

test('leads with the grade and states the signal coverage', () => {
  const out = renderRisk(riskResult(), classification);
  assert.match(out.title, /medium/i);
  assert.match(out.summary, /5 of 6/);
});

test('names the largest jump concretely', () => {
  const out = renderRisk(riskResult(), classification);
  assert.match(out.summary, /fastify/);
  assert.match(out.summary, /5\.11\.2/);
});

test('reports the youngest package and its age', () => {
  const out = renderRisk(riskResult(), classification);
  assert.match(out.summary, /11 days/);
  assert.match(out.summary, /@fastify\/jwt/);
});

test('names every unavailable signal with its reason', () => {
  const out = renderRisk(riskResult(), classification);
  assert.match(out.summary, /not available/i);
  assert.match(out.summary, /disabled for this repository/);
});

test('a fully-graded result says nothing about unavailable signals', () => {
  const out = renderRisk(riskResult({ closesFinding: s('low', { ghsaIds: [] }) }, 'medium', 6), classification);
  assert.doesNotMatch(out.summary, /not available/i);
  assert.match(out.summary, /6 of 6/);
});

test('a closed advisory is called out by id', () => {
  const out = renderRisk(riskResult({ closesFinding: s('low', { ghsaIds: ['GHSA-j4cx-787j-xjqg'] }) }, 'low', 6), classification);
  assert.match(out.summary, /GHSA-j4cx-787j-xjqg/);
  assert.match(out.summary, /securit/i);
});

test('an all-unknown grade says so plainly rather than implying safety', () => {
  const out = renderRisk(riskResult({}, 'unknown', 0), classification);
  assert.match(out.title, /could not be graded|unknown/i);
  assert.doesNotMatch(out.title, /\blow\b/i);
});

test('every rendering states it never blocks and links the epic', () => {
  for (const r of [riskResult(), riskResult({}, 'unknown', 0)]) {
    const out = renderRisk(r, classification);
    assert.match(out.summary, /never block/i);
    assert.match(out.summary, /PLAT-1184/);
  }
});

test('a non-candidate points at the eligibility check instead of a grade', () => {
  const out = renderRiskNotEvaluated();
  assert.match(out.title, /not evaluated/i);
  assert.match(out.summary, /merge-policy\/eligibility/);
  assert.match(out.summary, /never block/i);
});

test('titles stay inside GitHub check-run limits', () => {
  assert.ok(renderRisk(riskResult(), classification).title.length <= 255);
  assert.ok(renderRiskNotEvaluated().title.length <= 255);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `renderRisk` is not exported

- [ ] **Step 3: Replace `renderRiskPlaceholder` in `src/render.ts`**

Delete the `renderRiskPlaceholder` function and add:

```ts
import type { RiskResult } from './risk.js';

const GRADE_TITLE: Record<string, string> = {
  low: 'Risk: low',
  medium: 'Risk: medium',
  high: 'Risk: high',
  unknown: 'Risk could not be graded',
};

/** Sentences describing what each signal saw. Omits any that is unknown. */
function signalSentences(risk: RiskResult, classification: ClassificationResult): string[] {
  const out: string[] = [];
  const sig = risk.signals;

  if (sig.semverDistance.grade !== 'unknown') {
    const bump = largestBump(classification);
    out.push(bump
      ? `Largest version jump is a **${classification.maxDelta}** (\`${bump.name}\` ${bump.from} → ${bump.to}).`
      : `Largest version jump is a **${classification.maxDelta}**.`);
  }

  if (sig.closesFinding.grade !== 'unknown' && (sig.closesFinding.value?.ghsaIds.length ?? 0) > 0) {
    const ids = sig.closesFinding.value!.ghsaIds;
    out.push(`Closes ${ids.length} known security ${ids.length === 1 ? 'advisory' : 'advisories'}: ${ids.join(', ')}.`);
  }

  if (sig.publishAge.grade !== 'unknown' && sig.publishAge.value) {
    const { youngestDays, package: pkg } = sig.publishAge.value;
    out.push(`The youngest package in this update (\`${pkg}\`) was published ${youngestDays} days ago.`);
  }

  if (sig.newFindings.grade !== 'unknown' && sig.newFindings.value) {
    const { failed, checked } = sig.newFindings.value;
    out.push(failed === 0
      ? `No scanner findings on this commit (${checked} checks).`
      : `**${failed} of ${checked} scanner checks are failing** on this commit.`);
  }

  if (sig.coverageDelta.grade !== 'unknown' && sig.coverageDelta.value) {
    const { deltaPct, currentPct } = sig.coverageDelta.value;
    out.push(deltaPct === 0
      ? `Coverage unchanged at ${currentPct}%.`
      : `Coverage ${deltaPct > 0 ? 'rose' : 'fell'} ${Math.abs(deltaPct)} points to ${currentPct}%.`);
  }

  if (sig.depType.grade !== 'unknown' && sig.depType.value) {
    const { production, development } = sig.depType.value;
    out.push(`${production} production ${production === 1 ? 'dependency' : 'dependencies'}, ${development} development.`);
  }

  return out;
}

/** One line per unavailable signal, naming it and why. */
function unavailableLines(risk: RiskResult): string[] {
  const labels: Record<keyof RiskResult['signals'], string> = {
    semverDistance: 'version distance',
    publishAge: 'package publish age',
    closesFinding: 'whether this closes a known security advisory',
    newFindings: 'new scanner findings',
    coverageDelta: 'coverage change',
    depType: 'production vs development dependency',
  };

  return (Object.keys(labels) as (keyof RiskResult['signals'])[])
    .filter((key) => risk.signals[key].grade === 'unknown')
    .map((key) => `- ${labels[key]} — ${risk.signals[key].reason ?? 'not available'}`);
}

/** Render the `merge-policy/risk` check body. */
export function renderRisk(risk: RiskResult, classification: ClassificationResult): CheckOutput {
  const unavailable = unavailableLines(risk);

  const body: string[] = [
    `**${GRADE_TITLE[risk.grade]}** — graded on ${risk.signalsGraded} of 6 signals`,
    '',
  ];

  const sentences = signalSentences(risk, classification);
  if (sentences.length > 0) {
    body.push(sentences.join(' '), '');
  }

  if (unavailable.length > 0) {
    body.push('Not available for this evaluation:', ...unavailable, '');
  }

  body.push(NEVER_BLOCKS, '', `Tracking: ${EPIC}.`);

  return {
    title: `${GRADE_TITLE[risk.grade]} — graded on ${risk.signalsGraded} of 6 signals`.slice(0, 255),
    summary: body.join('\n'),
  };
}

/**
 * Render the check for a pull request the gates did not admit.
 *
 * T7 runs the heuristics only on gate-passing candidates, so a non-candidate
 * gets an explanation rather than a grade computed over nothing.
 */
export function renderRiskNotEvaluated(): CheckOutput {
  return {
    title: 'Risk not evaluated',
    summary: [
      '**This pull request is not a candidate for automated merge, so no risk grade was computed.**',
      '',
      'See the `merge-policy/eligibility` check on this pull request for which rule it did not meet.',
      '',
      NEVER_BLOCKS,
      '',
      `Tracking: ${EPIC}.`,
    ].join('\n'),
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

- [ ] **Step 5: Read the output as a stranger would**

```bash
node --import tsx -e "
import { renderRisk, renderRiskNotEvaluated } from './src/render.ts';
const s=(grade,value=null,reason)=>({grade,value,...(reason?{reason}:{})});
const classification={changeClass:'dep-minor',maxDelta:'minor',bumps:[{name:'fastify',from:'^5.11.2',to:'^5.12.0',level:'minor'}]};
const risk={grade:'medium',signalsGraded:5,signals:{
  semverDistance:s('medium','minor'),
  publishAge:s('low',{youngestDays:11,package:'@fastify/jwt'}),
  closesFinding:s('unknown',null,'Dependabot alerts are disabled for this repository'),
  newFindings:s('low',{failed:0,checked:3}),
  coverageDelta:s('low',{deltaPct:0,currentPct:62.99}),
  depType:s('medium',{production:6,development:1})}};
for (const [label,out] of [['GRADED',renderRisk(risk,classification)],['NOT EVALUATED',renderRiskNotEvaluated()]]) {
  console.log('='.repeat(70)); console.log(label+': '+out.title); console.log(); console.log(out.summary); console.log();
}"
```

Read both. If either would leave someone unsure what happened or whether they must act, fix the wording now — no test can judge this.

- [ ] **Step 6: Commit**

```bash
git add src/render.ts tests/render.test.ts
git commit -m "feat: render a real risk grade with signal coverage (PLAT-1191)"
```

---

### Task 12: Wire risk into the evaluator

**Files:**
- Modify: `src/evaluate.ts`
- Modify: `src/ledger.ts` (carry `risk` on the record)
- Modify: `tests/evaluate.test.ts`
- Modify: `tests/ledger.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 4–11
- Produces: `evaluate` unchanged in signature; `EvaluateDeps` gains five fetchers; `EvalRecord` gains `risk?: RiskResult`

- [ ] **Step 1: Write the failing tests**

Append to `tests/evaluate.test.ts`:

```ts
import { readFileSync as read } from 'node:fs';

function riskDeps(n: number, over: any = {}) {
  const checkRuns = JSON.parse(read(`tests/fixtures/pr-${n}-check-runs.json`, 'utf8'));
  const manifest = JSON.parse(read('tests/fixtures/pr-27-manifest.json', 'utf8'));
  const sections: Record<string, 'production' | 'development'> = {};
  for (const name of Object.keys(manifest.dependencies ?? {})) sections[name] = 'production';
  for (const name of Object.keys(manifest.devDependencies ?? {})) sections[name] = 'development';

  return {
    fetchPrFiles: async () => JSON.parse(read(`tests/fixtures/pr-${n}-files.json`, 'utf8')),
    recordEvaluation: async () => {},
    fetchCheckRuns: async () => (await import('../src/check-runs.js')).fetchCheckRuns(
      'o/r', 'sha', (async () => ({ ok: true, status: 200, json: async () => checkRuns })) as any),
    fetchOpenAlerts: async () => ({ ok: false, reason: 'disabled' as const }),
    fetchManifestSections: async () => sections,
    fetchPublishedAt: async () => '2026-08-01T00:00:00Z',
    ...over,
  };
}

test('a candidate gets a real risk grade', async () => {
  const [, risk] = await evaluate(ctx(27), riskDeps(27) as any);
  assert.equal(risk!.name, RISK_CHECK);
  assert.match(risk!.output.title, /Risk: (low|medium|high)/);
  assert.doesNotMatch(risk!.output.title, /not yet connected/i);
});

test('a non-candidate gets "not evaluated" and fetches no signals', async () => {
  let touched = false;
  const spy = async () => { touched = true; return [] as any; };
  const [, risk] = await evaluate(ctx(37), riskDeps(37, {
    fetchCheckRuns: spy, fetchOpenAlerts: spy, fetchManifestSections: spy, fetchPublishedAt: spy,
  }) as any);
  assert.match(risk!.output.title, /not evaluated/i);
  assert.equal(touched, false, 'no signal fetch for a non-candidate');
});

test('the eval record carries the risk grade and every signal value', async () => {
  const recorded: any[] = [];
  await evaluate(ctx(27), riskDeps(27, { recordEvaluation: async (r: any) => { recorded.push(r); } }) as any);
  assert.equal(recorded.length, 1);
  assert.ok(recorded[0].risk, 'risk present on the record');
  assert.equal(Object.keys(recorded[0].risk.signals).length, 6);
  assert.equal(recorded[0].risk.signals.closesFinding.grade, 'unknown');
});

test('a non-candidate record has no risk object', async () => {
  const recorded: any[] = [];
  await evaluate(ctx(37), riskDeps(37, { recordEvaluation: async (r: any) => { recorded.push(r); } }) as any);
  assert.equal(recorded[0].risk, undefined);
});

test('a signal fetch throwing does not lose the check runs', async () => {
  const boom = async () => { throw new Error('deps.dev is down'); };
  const verdicts = await evaluate(ctx(27), riskDeps(27, { fetchPublishedAt: boom }) as any);
  assert.equal(verdicts.length, 2, 'both checks still produced');
});
```

Append to `tests/ledger.test.ts`:

```ts
test('the risk object is persisted whole when present', async () => {
  const { send, calls } = fakeSend();
  await recordEvaluation({
    ...record(),
    risk: { grade: 'medium', signalsGraded: 5, signals: { semverDistance: { grade: 'medium', value: 'minor' } } },
  } as any, send);
  assert.equal(calls[0].input.Item.riskGrade.S, 'medium');
  const stored = JSON.parse(calls[0].input.Item.risk.S);
  assert.equal(stored.signalsGraded, 5);
});

test('a record with no risk stores a null marker rather than an absent attribute', async () => {
  const { send, calls } = fakeSend();
  await recordEvaluation(record(), send);
  assert.deepEqual(calls[0].input.Item.riskGrade, { NULL: true });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `EvaluateDeps` has no `fetchCheckRuns`

- [ ] **Step 3: Extend `src/ledger.ts`**

Add to `EvalRecord`:

```ts
  /** Present only for candidates — the heuristics do not run otherwise. */
  risk?: RiskResult;
```

with `import type { RiskResult } from './risk.js';`, and add to the `Item`:

```ts
      riskGrade: record.risk ? { S: record.risk.grade } : { NULL: true },
      risk: record.risk ? { S: JSON.stringify(record.risk) } : { NULL: true },
```

`riskGrade` is a top-level scalar so "all high-risk evaluations" is a filterable
attribute; the full object stays a JSON string, matching how `eligibility` is stored.

- [ ] **Step 4: Extend `src/evaluate.ts`**

Add the imports and the new deps:

```ts
import { fetchCheckRuns } from './check-runs.js';
import { fetchOpenAlerts, closesFinding } from './signals/advisories.js';
import { fetchManifestSections, depType } from './signals/dep-type.js';
import { fetchPublishedAt, publishAge } from './signals/publish-age.js';
import type { PublishAge } from './signals/publish-age.js';
import { scanFindings } from './signals/scan-findings.js';
import { coverageDelta } from './signals/coverage.js';
import { unknownSignal } from './signals/types.js';
import { combine, gradeSemverDistance } from './risk.js';
import type { RiskResult } from './risk.js';
import { renderRisk, renderRiskNotEvaluated } from './render.js';
import type { ClassificationResult } from './classify.js';
import type { RiskThresholds } from './rules-types.js';
```

`renderRiskPlaceholder` is gone — remove it from the existing `./render.js` import line, or
the build fails on a missing export.

```ts
export interface EvaluateDeps {
  fetchPrFiles: typeof fetchPrFiles;
  recordEvaluation: typeof recordEvaluation;
  fetchCheckRuns: typeof fetchCheckRuns;
  fetchOpenAlerts: typeof fetchOpenAlerts;
  fetchManifestSections: typeof fetchManifestSections;
  fetchPublishedAt: typeof fetchPublishedAt;
}

const defaultDeps: EvaluateDeps = {
  fetchPrFiles, recordEvaluation, fetchCheckRuns,
  fetchOpenAlerts, fetchManifestSections, fetchPublishedAt,
};
```

Then, after `runGates(...)` and before the ledger write, add:

```ts
  // T7 runs the heuristics only on gate-passing candidates. A non-candidate is
  // not graded at all — no fetches, no grade, an explanation instead.
  const risk = eligibility.verdict === 'candidate'
    ? await assessRisk(ctx, classification, policy.risk, deps)
    : undefined;
```

and this function above `evaluate`:

```ts
/**
 * Gather and grade the six risk signals.
 *
 * Every fetch is wrapped: a signal that cannot be gathered becomes `unknown`,
 * never an exception. Losing the whole check run because deps.dev was slow
 * would trade the user-visible product for one of six inputs.
 */
async function assessRisk(
  ctx: EvalContext,
  classification: ClassificationResult,
  thresholds: RiskThresholds,
  deps: EvaluateDeps,
): Promise<RiskResult> {
  const safely = async <T>(what: string, run: () => Promise<T>, fallback: T): Promise<T> => {
    try {
      return await run();
    } catch (err) {
      log('warn', 'signal_fetch_failed', {
        signal: what, repo: ctx.repoFullName, pr: ctx.prNumber,
        error: err instanceof Error ? err.message : String(err),
      });
      return fallback;
    }
  };

  const [runs, alerts, sections, ages] = await Promise.all([
    safely('check_runs', () => deps.fetchCheckRuns(ctx.repoFullName, ctx.headSha), []),
    safely('advisories', () => deps.fetchOpenAlerts(ctx.repoFullName), { ok: false as const, reason: 'error' as const }),
    safely('manifest', () => deps.fetchManifestSections(ctx.repoFullName, ctx.headSha), null),
    safely('publish_age', () => publishAge(classification.bumps, thresholds.cooldownDays, {
      fetchPublishedAt: deps.fetchPublishedAt, now: () => Date.now(),
    }), unknownSignal<PublishAge>('publish-age lookup failed')),
  ]);

  return combine({
    semverDistance: gradeSemverDistance(classification.maxDelta),
    publishAge: ages,
    closesFinding: closesFinding(alerts, classification.bumps),
    newFindings: scanFindings(runs, thresholds.maxNewFindings),
    coverageDelta: coverageDelta(runs, thresholds.maxCoverageDropPct),
    depType: depType(sections, classification.bumps),
  });
}
```

Add `risk` to the `recordEvaluation` call, and change the return to:

```ts
  return [
    { name: ELIGIBILITY_CHECK, output: renderEligibility(eligibility, classification) },
    { name: RISK_CHECK, output: risk ? renderRisk(risk, classification) : renderRiskNotEvaluated() },
  ];
```

Extend the `evaluated` log line with `risk_grade: risk?.grade ?? null` and `signals_graded: risk?.signalsGraded ?? null`.

- [ ] **Step 5: Run the full suite**

Run: `pnpm test && pnpm run typecheck && pnpm run build`
Expected: PASS, clean typecheck, `dist/index.js` written

- [ ] **Step 6: Commit**

```bash
git add src/evaluate.ts src/ledger.ts tests/evaluate.test.ts tests/ledger.test.ts
git commit -m "feat: grade risk for candidates and persist every signal (PLAT-1191)"
```

---

### Task 13: Raise the runtime budget

**Files:**
- Modify: `infrastructure/terraform/main.tf` (function timeout)
- Modify: `infrastructure/terraform/sqs.tf` (queue visibility timeout)

**Interfaces:**
- Consumes: nothing
- Produces: a 30-second function budget

- [ ] **Step 1: Raise the function timeout in `main.tf`**

Change `timeout = 10` in the `module "lambda"` block to:

```hcl
  # 30s, raised from 10s for PLAT-1191. A grouped dependabot bump can carry a
  # dozen packages, each needing a publish-date lookup, on top of four GitHub
  # calls and a DynamoDB write.
  #
  # The 10s figure came from GitHub's webhook-response expectation — but since
  # PLAT-1233 that constraint belongs to the RECEIVER role, which still answers
  # in milliseconds. The worker is behind SQS precisely so it no longer has to
  # meet it.
  timeout = 30
```

- [ ] **Step 2: Raise the queue visibility timeout in `sqs.tf`**

Change `visibility_timeout_seconds = 60` on `aws_sqs_queue.deliveries` to:

```hcl
  # 6x the 30s function timeout, per AWS guidance — a message must not become
  # visible again while a worker still holds it. Raised alongside the function
  # timeout in PLAT-1191; the ratio is what matters, not either number alone.
  visibility_timeout_seconds = 180
```

- [ ] **Step 3: Validate**

```bash
cd infrastructure/terraform && terraform fmt && terraform init -backend=false && terraform validate && cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Confirm the ratio holds**

```bash
grep -n 'timeout' infrastructure/terraform/main.tf infrastructure/terraform/sqs.tf | grep -v '^.*#'
```

Confirm visibility timeout ÷ function timeout ≥ 6. If a future change raises the function timeout without raising this, SQS will redeliver messages a worker is still processing — producing duplicate check runs that the delivery-ID claim will *not* catch, because it is the same delivery being legitimately retried.

- [ ] **Step 5: Commit**

```bash
git add infrastructure/terraform/
git commit -m "feat: 30s function timeout and 180s queue visibility for signal fetches (PLAT-1191)"
```

---

### Task 14: Documentation

**Files:**
- Modify: `README.md`, `docs/architecture.md`, `docs/call-flows.md`, `AGENTS.md`

**Interfaces:**
- Consumes: everything
- Produces: nothing code-facing

- [ ] **Step 1: Update `README.md`**

Move the risk heuristics out of "still absent" into what is implemented. Add a short section on tuning: the three thresholds in `policy-rules.yaml`, that changing them means `pnpm run build:rules` and a commit of the regenerated module, and that `rulesSha` changes as a result — which is the point, since it makes every evaluation traceable to the thresholds that produced it.

State plainly that signal 3 is `unknown` on repositories where Dependabot alerts are disabled, and that this is a repository setting rather than a service limitation.

- [ ] **Step 2: Update `docs/architecture.md` and `docs/call-flows.md`**

Read both first. Add the risk path: for candidates only, four parallel fetches (check runs, alerts, manifest, publish ages) feeding six signal modules, combined worst-known-wins in `src/risk.ts`. Note the one external dependency — `api.deps.dev` — and that its failure degrades a signal rather than the evaluation.

- [ ] **Step 3: Append to `AGENTS.md`**

Following the file's own rule — concise, pointing at authoritative files:

- Publish age reads `api.deps.dev`, not npm: npm carries publish timestamps only in the full packument (fastify's is 1.78 MB; the per-version endpoint has no time field), so eleven lookups would pull ~20 MB per evaluation. deps.dev returns the same timestamp in 834 bytes. If it is ever unavailable the signal degrades to `unknown` by design.
- Two different 403s come back from the Dependabot alerts API and they mean different things — a disabled *repository setting* versus a missing *App permission*. `src/signals/advisories.ts` distinguishes them and logs `reason`; without that a permanently-unknown signal is undebuggable.
- A missing scanner or coverage check reads `unknown`, never a clean result. On `opened` this is the normal case, because CI has not run yet — real values arrive on the `synchronize` re-evaluation.
- The function timeout (30s) and the queue visibility timeout (180s) are coupled at 6:1. Raising one without the other causes SQS to redeliver messages still being processed.
- `closesFinding` is the only signal that is not in the worst-of comparison; it lowers the grade one step and can never raise it.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/ AGENTS.md
git commit -m "docs: record the risk signals, deps.dev, and the timeout coupling (PLAT-1191)"
```

---

### Task 15: Deploy to QA and validate live

**Files:** none — verification only.

**Interfaces:**
- Consumes: everything
- Produces: the evidence closing PLAT-1191

- [ ] **Step 1: Open the pull request**

```bash
gh pr create --repo bankrate/zapp --base main --head feat/plat-1191-risk-heuristics \
  --title "feat: risk heuristics — the six signals (PLAT-1191)" \
  --body "Implements PLAT-1191. Spec lives in firstmate: docs/superpowers/zapp/specs/2026-08-25-risk-heuristics-design.md"
```

Confirm CI passes, including the rules drift check and the Docker build.

- [ ] **Step 2: Merge and cut a QA pre-release**

Merge, then publish a pre-release tag (e.g. `v1.3.0-rc.1`) so `deploy-v2.yml` stops after QA.

- [ ] **Step 3: Confirm the deployed timeouts**

```bash
AWS_PROFILE=bankrate-qa aws lambda get-function-configuration \
  --function-name zapp-qa --region us-east-1 --query 'Timeout'
AWS_PROFILE=bankrate-qa aws sqs get-queue-attributes --region us-east-1 \
  --queue-url "$(AWS_PROFILE=bankrate-qa aws sqs get-queue-url --queue-name zapp-deliveries --region us-east-1 --query QueueUrl --output text)" \
  --attribute-names VisibilityTimeout --query 'Attributes.VisibilityTimeout'
```

Expected: `30` and `180`.

- [ ] **Step 4: Force a re-evaluation with CI complete**

Signals 4 and 5 need finished CI. Push an empty commit to each PR and wait for checks to go green before the `synchronize` evaluation runs:

```bash
for n in 27 32; do
  gh pr checkout $n --repo bankrate/platform-cicd-v2-demo
  git commit --allow-empty -m "chore: re-trigger merge-policy evaluation (PLAT-1191)"
  git push
done
```

- [ ] **Step 5: Confirm real grades**

```bash
for n in 27 32; do
  sha=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/$n --jq .head.sha)
  echo "===== PR $n ====="
  gh api "repos/bankrate/platform-cicd-v2-demo/commits/$sha/check-runs" \
    --jq '.check_runs[] | select(.name|startswith("merge-policy/")) | "\(.name) [\(.conclusion)] \(.output.title)"'
done
```

Expected: `merge-policy/risk` showing `Risk: <grade> — graded on N of 6 signals`, both check runs still `neutral`.

**On the signal count:** if Task 1 Step 5 found Dependabot alerts still disabled, expect **5 of 6** and a "not available" line naming that reason. If they were enabled, expect **6 of 6**.

- [ ] **Step 6: Read the rendered check on the PR page**

Open both PRs. This is where T7's readability is judged — no test can do it. Confirm each unavailable signal is named with a reason a stranger could act on.

- [ ] **Step 7: Confirm the eval record carries all six signals**

```bash
AWS_PROFILE=bankrate-qa aws dynamodb query --region us-east-1 \
  --table-name zapp-evaluations \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"repo#bankrate/platform-cicd-v2-demo#pr#27"}}' \
  --scan-index-forward false --limit 1 \
  --query 'Items[0].risk.S' --output text | jq '{grade, signalsGraded, signals: (.signals | keys)}'
```

Expected: a grade, a count, and exactly six signal keys — `closesFinding`, `coverageDelta`, `depType`, `newFindings`, `publishAge`, `semverDistance`.

- [ ] **Step 8: Confirm the raw signal values persisted, not just grades**

```bash
AWS_PROFILE=bankrate-qa aws dynamodb query --region us-east-1 \
  --table-name zapp-evaluations \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"repo#bankrate/platform-cicd-v2-demo#pr#27"}}' \
  --scan-index-forward false --limit 1 \
  --query 'Items[0].risk.S' --output text | jq '.signals | map_values(.value)'
```

Expected: real values — a publish age with a package name, a coverage percentage, dependency counts. **This is T7's "signal values persist alongside the grade" criterion.** A record of grades alone cannot answer "what would `cooldownDays: 7` have changed?", which is the whole point of the shadow phase.

- [ ] **Step 9: Confirm the checks are still on no required-checks configuration**

```bash
gh api repos/bankrate/platform-cicd-v2-demo/branches/main/protection --jq '.required_status_checks.contexts'
```

Expected: only the three `Cycode:` contexts. This repo's required checks live in classic branch protection; its ruleset is disabled, so checking rulesets alone would be vacuous.

- [ ] **Step 10: Confirm no delivery timed out**

```bash
AWS_PROFILE=bankrate-qa aws logs filter-log-events --region us-east-1 \
  --log-group-name /aws/lambda/zapp-qa \
  --filter-pattern 'Task timed out' \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --query 'length(events)'
```

Expected: `0`. A non-zero result means the 30-second budget is not enough and the parallel fetches need a tighter cap.

Also confirm the DLQ stayed empty:

```bash
AWS_PROFILE=bankrate-qa aws cloudwatch describe-alarms --region us-east-1 \
  --alarm-names zapp-qa-dlq-not-empty --query 'MetricAlarms[].StateValue'
```

Expected: `OK`.

- [ ] **Step 11: Record the evidence**

Post the outputs of Steps 5, 7, 8, 9 and 10 on the zapp PR or on PLAT-1191. These are the acceptance criteria; a claim without its output is not evidence.

Move PLAT-1191 to Done. Note on PLAT-1192 that signals 4 and 5 are `unknown` on any pull request that never receives a second push, and that its reconcile sweep is what closes that hole.

---

## Post-implementation

- **PLAT-1192 (T8), the required-checks snapshot and the 10-minute reconcile sweep.** The sweep is what would populate signals 4 and 5 on pull requests merged without a second push — currently a known hole in the shadow dataset.
- **Enabling Dependabot alerts on enrolled repos** turns signal 3 from `unknown` into real data. A repo-owner decision, but worth revisiting once the value is visible.
- **Threshold tuning** is now a reviewed one-line PR against `policy-rules.yaml`. The epic's exit criteria need ≥ 200 evaluations across ≥ 5 repos; the thresholds should not be tuned until that data exists.
- **The SNS alerts topic still has no subscribers** — carried since PLAT-1233. Both alarms are visible in CloudWatch and page nobody.
