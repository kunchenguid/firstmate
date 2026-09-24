# CI Baseline Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an 18th eligibility gate, `ciBaselineMet`, that asks whether a repository produces the checks its *shape* requires — so "this repo has no image scan" reports as a CI gap with a named remedy instead of hiding inside `checksGreen` as an apparent test failure.

**Architecture:** Shape comes from GitHub's languages API; capability comes from the union of check-run names across the repository's last 15 pull requests, both fetched in one GraphQL request per repository per invocation. A pure module derives the required set from shape, applies per-repo aliases and expiring waivers, and tests each requirement against a produced/sampled frequency map. The gate is ordered before `checksGreen` so `failedGate` — what the weekly report groups on — separates *add a workflow* from *fix a test*.

**Tech Stack:** TypeScript (ESM, Node 22), GitHub GraphQL v4 via the existing `githubRequest`, `node:test` + `node:assert/strict`, pnpm.

**Spec:** `docs/superpowers/zapp/specs/2026-08-28-ci-baseline-gate-design.md`

## Global Constraints

- **Shape from the languages API, never from file paths or custom properties.** `crank` 404s on `contents/Dockerfile` but reports `Dockerfile` in languages, because its Dockerfile is not at the root — a path probe wrongly exempts it. Custom properties are repo-editable in this org, so shape would become self-attested.
- **Frequency, not presence.** A check must appear on **every** sampled pull request. Gate 12 fails closed on absence, so a conditionally-produced check can never be safely required. `platform-cicd-v2-demo` produced `codecov/project` on one head and not on another — this is real.
- **`ciBaselineMet` must NOT join `CI_REPORTING_GATES`.** Adding a workflow needs a new commit, so the verdict is time-invariant for a head SHA and a non-candidate failing it is correctly `final`.
- **Waived is never `pass`.** A waived check reads `waived`, and the repository still appears in the CI-standardization finding. The waiver unblocks eligibility without hiding the number, and the number is the deliverable.
- **A waiver without `expiresAt` is a validation error**, and one longer than 90 days is rejected. An expired waiver is ignored and the requirement returns — no grace period.
- **Resolution order:** shape → aliases → frequency test → waivers. Aliases resolve *before* waivers, because a naming difference should never consume a waiver.
- **GraphQL returns HTTP 200 on failure**, with an `errors` array in the body. Checking `res.ok` alone reports a failed query as an empty result — the same trap as Slack's `{"ok": false}` with a 200, which has already bitten this project once.
- Conventional Commits (`commitlint` runs in CI). Run `pnpm test` before every commit.

## Sequencing

| Depends on | Why |
|---|---|
| `2026-08-28-eligibility-finality-and-blocking-checks.md` **Task 1** | The premature-`final` fix. Independent of this work but must land first, or `ciBaselineMet`'s interaction with finality is impossible to reason about. |
| That plan's **Task 2** | **Delete it.** It shrank the global `blockingChecks` list to match what repos happen to run — the bar-lowering this design rejects. Task 4 below replaces it. |
| `2026-08-28-enrollment-registry-zapp.md` | Task 5 below adds two enrollment-record fields. If the registry has moved to DynamoDB, they are attributes; if not, they are `policy-rules.yaml` `repos[]` keys. Read that plan's state first. |

---

### Task 1: Fetch shape and check-run history in one GraphQL query

**Files:**
- Create: `src/ci-history.ts`
- Create: `tests/ci-history.test.ts`

**Interfaces:**
- Consumes: `githubRequest` from `src/github.ts` — no changes needed there; it takes any path, so `POST /graphql` works as-is.
- Produces:
  ```ts
  export interface CiBaseline {
    /** Language keys from GitHub's languages API, e.g. `Dockerfile`, `HCL`. */
    languages: string[];
    /** Pull requests sampled. Below the policy floor the gate reads `unknown`. */
    sampled: number;
    /** Check name -> how many of the sampled pull requests produced it. */
    produced: Record<string, number>;
    /** Set when the query failed; the gate reads `unknown` rather than guessing. */
    error?: string;
  }
  export function fetchCiBaseline(
    repoFullName: string,
    samplePrs: number,
    request?: typeof githubRequest,
  ): Promise<CiBaseline>;
  ```

- [ ] **Step 1: Verify the base**

```bash
cd ~/Projects/zapp
git fetch origin && git rev-list --count HEAD..origin/main
grep -n "nonCandidateFinal = " src/evaluate.ts
grep -c "seventeen\|17 gates" src/gates.ts docs/policy.md
```

Expected: `0` behind, and `nonCandidateFinal` already reading `CI_REPORTING_GATES` — meaning the finality fix has landed. **If it still reads `eligibility.failedGate`, stop and land that plan's Task 1 first.**

- [ ] **Step 2: Write the failing tests**

Create `tests/ci-history.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchCiBaseline } from '../src/ci-history.js';

/** A GraphQL response shaped like GitHub's, with the given PRs' check names. */
function response(languages: string[], prs: string[][]) {
  return {
    ok: true,
    json: async () => ({
      data: {
        repository: {
          languages: { nodes: languages.map((name) => ({ name })) },
          pullRequests: {
            nodes: prs.map((names, i) => ({
              number: i + 1,
              commits: {
                nodes: [{
                  commit: {
                    checkSuites: {
                      nodes: [{ checkRuns: { nodes: names.map((name) => ({ name })) } }],
                    },
                  },
                }],
              },
            })),
          },
        },
      },
    }),
  };
}

test('returns the language keys, which is where shape comes from', async () => {
  const baseline = await fetchCiBaseline('bankrate/portkey', 15,
    (async () => response(['Dockerfile', 'HCL', 'TypeScript'], [['Cycode: SAST']])) as any);

  assert.deepEqual(baseline.languages.sort(), ['Dockerfile', 'HCL', 'TypeScript']);
});

test('counts how many sampled pull requests produced each check', async () => {
  const baseline = await fetchCiBaseline('bankrate/portkey', 15, (async () => response(
    ['Dockerfile'],
    [
      ['Cycode: SAST', 'Build and scan image'],
      ['Cycode: SAST', 'Build and scan image'],
      ['Cycode: SAST'],
    ],
  )) as any);

  assert.equal(baseline.sampled, 3);
  assert.equal(baseline.produced['Cycode: SAST'], 3);
  assert.equal(baseline.produced['Build and scan image'], 2,
    'a check on 2 of 3 pull requests is conditional — presence alone would hide that');
});

test('counts a check once per pull request, not once per check run', async () => {
  // A retried check produces two runs with the same name on one commit. Counting
  // runs rather than pull requests would report 2/1 and make the frequency test
  // meaningless.
  const baseline = await fetchCiBaseline('bankrate/portkey', 15, (async () => response(
    ['Dockerfile'], [['Cycode: SAST', 'Cycode: SAST']],
  )) as any);

  assert.equal(baseline.produced['Cycode: SAST'], 1);
});

test('a repository with no pull requests reports zero sampled, not an error', async () => {
  const baseline = await fetchCiBaseline('bankrate/new', 15,
    (async () => response(['TypeScript'], [])) as any);

  assert.equal(baseline.sampled, 0);
  assert.deepEqual(baseline.produced, {});
  assert.equal(baseline.error, undefined);
});

test('a GraphQL error body is an ERROR, not an empty result', async () => {
  // GraphQL answers HTTP 200 and puts failures in `errors`. Checking res.ok
  // alone would report a failed query as "this repo produces no checks", which
  // fails the gate for the wrong reason. The same 200-on-failure trap as Slack's
  // {"ok": false}.
  const baseline = await fetchCiBaseline('bankrate/portkey', 15, (async () => ({
    ok: true,
    json: async () => ({ errors: [{ message: 'Something went wrong' }] }),
  })) as any);

  assert.match(baseline.error!, /Something went wrong/);
  assert.deepEqual(baseline.produced, {});
});

test('an HTTP failure is an error too', async () => {
  const baseline = await fetchCiBaseline('bankrate/portkey', 15,
    (async () => ({ ok: false, status: 502, json: async () => ({}) })) as any);

  assert.match(baseline.error!, /502/);
});

test('a thrown request does not propagate — the gate reads unknown', async () => {
  const baseline = await fetchCiBaseline('bankrate/portkey', 15,
    (async () => { throw new Error('socket hang up'); }) as any);

  assert.match(baseline.error!, /socket hang up/);
});

test('the query asks for the requested number of pull requests, newest first', async () => {
  let body: any;
  await fetchCiBaseline('bankrate/portkey', 15, (async (_path: string, opts: any) => {
    body = JSON.parse(opts.body);
    return response([], []);
  }) as any);

  assert.equal(body.variables.owner, 'bankrate');
  assert.equal(body.variables.name, 'portkey');
  assert.equal(body.variables.prs, 15);
  assert.match(body.query, /direction: DESC/);
});
```

- [ ] **Step 3: Run to verify they fail**

```bash
pnpm exec tsc --noEmit
```

Expected: FAIL — `src/ci-history.ts` does not exist.

- [ ] **Step 4: Implement**

Create `src/ci-history.ts`:

```ts
// What a repository's own recent history says about its CI, for gate 11.
//
// WHY HISTORY AND NOT THIS PULL REQUEST. `ciBaselineMet` asks a REPOSITORY
// question — "does this repo produce the checks its shape requires?" At
// `pull_request: opened` no checks have run, so "never produced" and "not yet
// produced" are indistinguishable from one pull request's check runs. That
// ambiguity is what the original checksGreen bug was made of. Reading the last N
// pull requests answers the repository question with repository data, and the
// verdict is definite at PR-open with no dependence on CI timing.
//
// ONE GRAPHQL REQUEST. The REST equivalent is one call to list pull requests
// plus one per head SHA — sixteen round trips inside a 30-second budget. GraphQL
// does it in one, and `githubRequest` already accepts any path, so no new
// plumbing is needed.
import { githubRequest } from './github.js';
import { log } from './log.js';

/** What a repository's recent history says about its CI. */
export interface CiBaseline {
  /** Language keys from GitHub's languages API, e.g. `Dockerfile`, `HCL`. */
  languages: string[];
  /** Pull requests sampled. Below the policy floor the gate reads `unknown`. */
  sampled: number;
  /** Check name -> how many of the sampled pull requests produced it. */
  produced: Record<string, number>;
  /** Set when the query failed. The gate reads `unknown` rather than guessing. */
  error?: string;
}

const QUERY = `
query($owner: String!, $name: String!, $prs: Int!) {
  repository(owner: $owner, name: $name) {
    languages(first: 50) { nodes { name } }
    pullRequests(first: $prs, orderBy: { field: CREATED_AT, direction: DESC }) {
      nodes {
        number
        commits(last: 1) {
          nodes {
            commit {
              checkSuites(first: 20) {
                nodes { checkRuns(first: 100) { nodes { name } } }
              }
            }
          }
        }
      }
    }
  }
}`;

/**
 * Read a repository's shape and its recent check-run names.
 *
 * NEVER THROWS. A failed query returns `error` set and empty data, because gate
 * 11 must read `unknown` rather than conclude "this repository produces no
 * checks" — which would fail the gate for the wrong reason and put the
 * repository in the CI-gap finding on the strength of a network blip.
 *
 * Args:
 *   repoFullName: `owner/repo`.
 *   samplePrs: How many recent pull requests to sample.
 *   request: Injectable GitHub request client.
 */
export async function fetchCiBaseline(
  repoFullName: string,
  samplePrs: number,
  request: typeof githubRequest = githubRequest,
): Promise<CiBaseline> {
  const empty = { languages: [], sampled: 0, produced: {} };
  const [owner, name] = repoFullName.split('/');

  try {
    const res = await request('/graphql', {
      method: 'POST',
      body: JSON.stringify({ query: QUERY, variables: { owner, name, prs: samplePrs } }),
    });

    if (!res.ok) {
      log('warn', 'ci_baseline_fetch_failed', { repo: repoFullName, status: res.status });
      return { ...empty, error: `GraphQL request failed: ${res.status}` };
    }

    const body = (await res.json()) as {
      data?: any;
      errors?: { message: string }[];
    };

    // GraphQL answers HTTP 200 and reports failures in `errors`. Trusting
    // `res.ok` alone turns a failed query into "produces no checks".
    if (body.errors !== undefined && body.errors.length > 0) {
      const message = body.errors.map((e) => e.message).join('; ');
      log('warn', 'ci_baseline_query_errors', { repo: repoFullName, error: message });
      return { ...empty, error: message };
    }

    const repo = body.data?.repository;
    if (repo === undefined || repo === null) {
      return { ...empty, error: 'GraphQL returned no repository' };
    }

    const languages: string[] = (repo.languages?.nodes ?? []).map((n: any) => n.name);
    const prs: any[] = repo.pullRequests?.nodes ?? [];
    const produced: Record<string, number> = {};

    for (const pr of prs) {
      // A retried check produces two runs with the same name on one commit, so
      // count DISTINCT names per pull request. Counting runs would report 2/1
      // and make the frequency test meaningless.
      const names = new Set<string>();
      for (const suite of pr?.commits?.nodes?.[0]?.commit?.checkSuites?.nodes ?? []) {
        for (const run of suite?.checkRuns?.nodes ?? []) {
          if (typeof run?.name === 'string') names.add(run.name);
        }
      }
      for (const n of names) produced[n] = (produced[n] ?? 0) + 1;
    }

    return { languages, sampled: prs.length, produced };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    log('warn', 'ci_baseline_fetch_threw', { repo: repoFullName, error: message });
    return { ...empty, error: message };
  }
}
```

- [ ] **Step 5: Run the tests, then prove the query against the real API**

```bash
pnpm test
```

Then verify the GraphQL shape is right before building on it — a wrong query
here is expensive to discover later:

```bash
gh api graphql -f query='
query { repository(owner:"bankrate", name:"portkey") {
  languages(first:50){nodes{name}}
  pullRequests(first:5, orderBy:{field:CREATED_AT, direction:DESC}){
    nodes{ number commits(last:1){nodes{commit{
      checkSuites(first:20){nodes{checkRuns(first:100){nodes{name}}}}}}}}}
}}' --jq '{langs: [.data.repository.languages.nodes[].name],
           prs: [.data.repository.pullRequests.nodes[]
                 | {n: .number,
                    checks: [.commits.nodes[0].commit.checkSuites.nodes[].checkRuns.nodes[].name]}]}'
```

Expected: `langs` includes `Dockerfile` and `HCL`; each PR lists its check names. If the shape differs, fix `QUERY` and the test fixture together.

- [ ] **Step 6: Commit**

```bash
git add src/ci-history.ts tests/ci-history.test.ts
git commit -m "feat(ci-baseline): read repo shape and check-run history in one GraphQL query"
```

---

### Task 2: The pure baseline assessment

The logic, with no I/O. This is the task to review hardest.

**Files:**
- Create: `src/ci-baseline.ts`
- Create: `tests/ci-baseline.test.ts`

**Interfaces:**
- Consumes: `CiBaseline` from Task 1; `CiBaselineRules` and `EnrollmentRecord` from `src/rules-types.ts` (Tasks 4 and 5 add them — define them here and let those tasks re-export).
- Produces:
  ```ts
  export interface CiBaselineRules {
    always: string[];
    whenLanguage: Record<string, string[]>;
    samplePrs: number;
    minSample: number;
  }
  export interface Waiver { check: string; reason: string; expiresAt: string }
  export type CheckStatus = 'met' | 'conditional' | 'absent' | 'waived';
  export interface CheckAssessment {
    /** The required check, as this repository names it after aliasing. */
    check: string;
    /** The policy name, when an alias redirected it. */
    declaredAs?: string;
    status: CheckStatus;
    produced: number;
    sampled: number;
  }
  export function requiredChecks(languages: readonly string[], rules: CiBaselineRules): string[];
  export function assessCiBaseline(
    baseline: CiBaseline,
    rules: CiBaselineRules,
    enrollment: Pick<EnrollmentRecord, 'checkAliases' | 'ciBaselineWaivers'> | undefined,
    now: Date,
  ): { verdict: 'pass' | 'fail' | 'unknown'; checks: CheckAssessment[]; waived: string[] };
  ```

- [ ] **Step 1: Write the failing tests**

Create `tests/ci-baseline.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { requiredChecks, assessCiBaseline } from '../src/ci-baseline.js';

const CYCODE = ['Cycode: SAST', 'Cycode: Secrets', 'Cycode: Vulnerable Dependencies'];

const RULES = {
  always: [...CYCODE, 'codecov/project'],
  whenLanguage: {
    Dockerfile: ['Build and scan image'],
    HCL: ['Terraform plan (speculative)'],
  },
  samplePrs: 15,
  minSample: 3,
};

const NOW = new Date('2026-08-28T12:00:00Z');

/** A baseline where every listed check appeared on all 15 sampled PRs. */
function produces(languages: string[], names: string[], sampled = 15) {
  return {
    languages,
    sampled,
    produced: Object.fromEntries(names.map((n) => [n, sampled])),
  };
}

test('conductor is exempt from image scanning and speculative plans', () => {
  // No Dockerfile, no HCL — it is a CLI npm package. Requiring an image scan of
  // it is a category error, and a flat global required set would mark it
  // permanently ineligible for a check it should never run.
  assert.deepEqual(
    requiredChecks(['EJS', 'Handlebars', 'JavaScript', 'TypeScript'], RULES).sort(),
    [...CYCODE, 'codecov/project'].sort(),
  );
});

test('crank is NOT exempt from image scanning', () => {
  // Its Dockerfile is not at the repo root, so `contents/Dockerfile` 404s — but
  // the languages API reports Dockerfile. This is why shape comes from
  // languages and not from path probing.
  assert.ok(requiredChecks(['CSS', 'Dockerfile', 'HCL', 'TypeScript'], RULES)
    .includes('Build and scan image'));
});

test('a repo with both Dockerfile and HCL requires both conditional checks', () => {
  assert.deepEqual(
    requiredChecks(['Dockerfile', 'HCL'], RULES).sort(),
    [...CYCODE, 'codecov/project', 'Build and scan image', 'Terraform plan (speculative)'].sort(),
  );
});

test('a fully compliant repo passes', () => {
  const r = assessCiBaseline(
    produces(['Dockerfile', 'HCL'],
      [...CYCODE, 'codecov/project', 'Build and scan image', 'Terraform plan (speculative)']),
    RULES, undefined, NOW,
  );
  assert.equal(r.verdict, 'pass');
  assert.ok(r.checks.every((c) => c.status === 'met'));
});

test('an absent required check fails, and is named', () => {
  const r = assessCiBaseline(
    produces(['Dockerfile'], [...CYCODE, 'codecov/project']),
    RULES, undefined, NOW,
  );
  assert.equal(r.verdict, 'fail');
  const scan = r.checks.find((c) => c.check === 'Build and scan image')!;
  assert.equal(scan.status, 'absent');
  assert.equal(scan.produced, 0);
});

test('a check on 11 of 15 pull requests is CONDITIONAL, not met', () => {
  // Gate 12 fails closed on absence, so a check that runs on some pull requests
  // cannot be safely required. platform-cicd-v2-demo produced codecov/project on
  // one head and not another — this is observed, not hypothetical.
  const baseline = produces([], CYCODE);
  baseline.produced['codecov/project'] = 11;

  const r = assessCiBaseline(baseline, RULES, undefined, NOW);
  assert.equal(r.verdict, 'fail');
  assert.equal(r.checks.find((c) => c.check === 'codecov/project')!.status, 'conditional');
});

test('below the sample floor the verdict is unknown, not fail', () => {
  // A brand-new repository has not demonstrated anything either way, and
  // guessing would put it in the CI-gap finding on no evidence.
  const r = assessCiBaseline(produces([], CYCODE, 2), RULES, undefined, NOW);
  assert.equal(r.verdict, 'unknown');
});

test('a failed history read is unknown, not fail', () => {
  const r = assessCiBaseline(
    { languages: [], sampled: 0, produced: {}, error: 'socket hang up' },
    RULES, undefined, NOW,
  );
  assert.equal(r.verdict, 'unknown');
});

test('an alias redirects a requirement without lowering it', () => {
  const baseline = produces(['HCL'], [...CYCODE, 'codecov/project', 'terraform / plan']);
  const r = assessCiBaseline(baseline, RULES, {
    checkAliases: { 'Terraform plan (speculative)': 'terraform / plan' },
  } as any, NOW);

  assert.equal(r.verdict, 'pass');
  const aliased = r.checks.find((c) => c.check === 'terraform / plan')!;
  assert.equal(aliased.status, 'met');
  assert.equal(aliased.declaredAs, 'Terraform plan (speculative)');
});

test('an alias pointing at a check the repo does not produce still fails', () => {
  const r = assessCiBaseline(
    produces(['HCL'], [...CYCODE, 'codecov/project']),
    RULES, { checkAliases: { 'Terraform plan (speculative)': 'terraform / plan' } } as any, NOW,
  );
  assert.equal(r.verdict, 'fail', 'aliasing renames a requirement, it never removes one');
});

test('a waived check reads WAIVED, never pass, and is still reported', () => {
  const r = assessCiBaseline(
    produces(['Dockerfile'], [...CYCODE, 'codecov/project']),
    RULES,
    { ciBaselineWaivers: [{
      check: 'Build and scan image',
      reason: 'image scanned downstream in the release pipeline',
      expiresAt: '2026-11-01',
    }] } as any,
    NOW,
  );

  assert.equal(r.verdict, 'pass', 'the waiver unblocks eligibility');
  const scan = r.checks.find((c) => c.check === 'Build and scan image')!;
  assert.equal(scan.status, 'waived', 'NOT "met" — the gap is acknowledged, not closed');
  assert.deepEqual(r.waived, ['Build and scan image'],
    'the repo still appears in the CI-standardization finding');
});

test('an EXPIRED waiver is ignored and the requirement returns', () => {
  const r = assessCiBaseline(
    produces(['Dockerfile'], [...CYCODE, 'codecov/project']),
    RULES,
    { ciBaselineWaivers: [{
      check: 'Build and scan image', reason: 'stale', expiresAt: '2026-08-01',
    }] } as any,
    NOW,
  );

  assert.equal(r.verdict, 'fail');
  assert.equal(r.checks.find((c) => c.check === 'Build and scan image')!.status, 'absent');
  assert.deepEqual(r.waived, []);
});

test('a waiver cannot rescue a check that is merely conditional', () => {
  // Deliberate: "runs sometimes" is a CI defect to fix, not an exemption to
  // grant. A waiver says "we will never run this here", which is a different
  // claim from "it runs on some pull requests".
  const baseline = produces([], CYCODE);
  baseline.produced['codecov/project'] = 11;

  const r = assessCiBaseline(baseline, RULES, {
    ciBaselineWaivers: [{ check: 'codecov/project', reason: 'flaky', expiresAt: '2026-11-01' }],
  } as any, NOW);

  assert.equal(r.verdict, 'fail');
  assert.equal(r.checks.find((c) => c.check === 'codecov/project')!.status, 'conditional');
});

test('a waiver is matched against the ALIASED name', () => {
  // Aliases resolve before waivers, so a waiver written against the policy name
  // must still apply after the rename. Getting this backwards makes a repo need
  // both an alias and a waiver for one check.
  const r = assessCiBaseline(
    produces(['HCL'], [...CYCODE, 'codecov/project']),
    RULES,
    {
      checkAliases: { 'Terraform plan (speculative)': 'terraform / plan' },
      ciBaselineWaivers: [{
        check: 'Terraform plan (speculative)', reason: 'no TFC workspace yet', expiresAt: '2026-11-01',
      }],
    } as any,
    NOW,
  );

  assert.equal(r.verdict, 'pass');
  assert.deepEqual(r.waived, ['Terraform plan (speculative)']);
});
```

- [ ] **Step 2: Run to verify they fail**

```bash
pnpm exec tsc --noEmit
```

Expected: FAIL — `src/ci-baseline.ts` does not exist.

- [ ] **Step 3: Implement**

Create `src/ci-baseline.ts`:

```ts
// Gate 11: does this repository produce the checks its SHAPE requires?
//
// A pure function over what Task 1 observed. No I/O, no clock except the `now`
// passed in — which is what makes the waiver-expiry tests possible.
//
// SHAPE, NOT CI. What a repository IS decides what it must prove; what its CI
// happens to do decides whether it currently proves it. Deriving the
// requirement from observed CI instead would be self-attestation: the bar
// becomes whatever each team already does, and a repo with no image scan is
// graded as though scanning were never expected.
import type { CiBaseline } from './ci-history.js';

/** Shape rules, from policy-rules.yaml. */
export interface CiBaselineRules {
  /** Required on every enrolled repository. */
  always: string[];
  /** Language key from the GitHub languages API -> checks it makes required. */
  whenLanguage: Record<string, string[]>;
  /** Pull requests to sample. */
  samplePrs: number;
  /** Below this many sampled pull requests the gate reads `unknown`. */
  minSample: number;
}

/** A deliberate, expiring exemption. Self-attested — see the design's guards. */
export interface Waiver {
  check: string;
  reason: string;
  /** ISO 8601. Mandatory, capped at 90 days, and fails closed when past. */
  expiresAt: string;
}

/**
 * `waived` is deliberately NOT `met`. The waiver unblocks eligibility; the
 * repository still appears in the CI-standardization finding, because that
 * number is the phase's deliverable and a waiver must not hide it.
 */
export type CheckStatus = 'met' | 'conditional' | 'absent' | 'waived';

export interface CheckAssessment {
  /** The required check, as this repository names it after aliasing. */
  check: string;
  /** The policy name, present only when an alias redirected it. */
  declaredAs?: string;
  status: CheckStatus;
  produced: number;
  sampled: number;
}

/**
 * The checks a repository of this shape must produce.
 *
 * Coverage is in `always`, not `whenLanguage`, deliberately: every change class
 * sets `minCoveragePct: 60`, so automating a dependency bump with no coverage
 * signal at all is exactly what a floor exists to prevent.
 */
export function requiredChecks(
  languages: readonly string[],
  rules: CiBaselineRules,
): string[] {
  const required = new Set(rules.always);
  for (const language of languages) {
    for (const check of rules.whenLanguage[language] ?? []) required.add(check);
  }
  return [...required];
}

/**
 * Assess one repository's CI baseline.
 *
 * RESOLUTION ORDER — shape, then aliases, then the frequency test, then
 * waivers. Aliases resolve before waivers so a mere naming difference never
 * consumes a waiver, and a waiver written against the policy name still applies
 * after a rename.
 *
 * Args:
 *   baseline: What Task 1 observed.
 *   rules: The shape rules from the compiled policy.
 *   enrollment: Per-repo aliases and waivers, if any.
 *   now: For waiver expiry. Injected so expiry is testable.
 */
export function assessCiBaseline(
  baseline: CiBaseline,
  rules: CiBaselineRules,
  enrollment: { checkAliases?: Record<string, string>; ciBaselineWaivers?: Waiver[] } | undefined,
  now: Date,
): { verdict: 'pass' | 'fail' | 'unknown'; checks: CheckAssessment[]; waived: string[] } {
  // Not enough evidence is not evidence of a gap. A failed read or a brand-new
  // repository must not land in the CI-gap finding on no data.
  if (baseline.error !== undefined || baseline.sampled < rules.minSample) {
    return { verdict: 'unknown', checks: [], waived: [] };
  }

  const aliases = enrollment?.checkAliases ?? {};
  const waivers = enrollment?.ciBaselineWaivers ?? [];
  const waived: string[] = [];

  const checks: CheckAssessment[] = requiredChecks(baseline.languages, rules).map((declared) => {
    const effective = aliases[declared] ?? declared;
    const produced = baseline.produced[effective] ?? 0;

    const base: CheckAssessment = {
      check: effective,
      ...(effective === declared ? {} : { declaredAs: declared }),
      status: produced === baseline.sampled ? 'met' : produced > 0 ? 'conditional' : 'absent',
      produced,
      sampled: baseline.sampled,
    };

    if (base.status !== 'absent') return base;

    // A waiver may excuse an ABSENT check only. "Runs sometimes" is a CI defect
    // to fix, not an exemption to grant — a waiver claims "we will never run
    // this here", which is a different assertion.
    //
    // Matched against the DECLARED name, so an aliased check needs one waiver,
    // not one per name.
    const waiver = waivers.find((w) => w.check === declared && !isExpired(w, now));
    if (waiver === undefined) return base;

    waived.push(declared);
    return { ...base, status: 'waived' };
  });

  const unmet = checks.filter((c) => c.status === 'conditional' || c.status === 'absent');
  return { verdict: unmet.length === 0 ? 'pass' : 'fail', checks, waived };
}

/** An unparseable or past expiry is expired. Fails closed, no grace period. */
function isExpired(waiver: Waiver, now: Date): boolean {
  const expires = Date.parse(waiver.expiresAt);
  return Number.isNaN(expires) || expires <= now.getTime();
}
```

- [ ] **Step 4: Run the tests**

```bash
pnpm test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ci-baseline.ts tests/ci-baseline.test.ts
git commit -m "feat(ci-baseline): derive required checks from repo shape, with aliases and waivers"
```

---

### Task 3: Wire in gate 11 — and the 17-to-18 churn

**Files:**
- Modify: `src/gates.ts` (`GATE_ORDER`, `GateInput`, `runGates`, header comment)
- Modify: `src/render.ts:195` and the gate-row rendering
- Modify: `src/evaluate.ts` (fetch the baseline, pass it in, record the waivers)
- Modify: `src/ledger.ts` (`EvalRecord.ciBaselineWaived`)
- Modify: `tests/gates.test.ts:225,412,438`, `tests/render.test.ts`, `tests/evaluate.test.ts`

**Interfaces:**
- Consumes: `fetchCiBaseline` (Task 1), `assessCiBaseline` (Task 2).
- Produces: `GATE_ORDER` with `ciBaselineMet` at position 11; `GateInput.ciBaseline: CiBaseline`; `EvalRecord.ciBaselineWaived?: string[]`.

- [ ] **Step 1: Write the failing tests**

In `tests/gates.test.ts`, update the three count assertions and add the gate's own tests. The existing counts are at `:225` (*"the ladder is 17 gates with freezeOff last"*), `:412` (*"PR #27 is still a candidate at 17 of 17"*) and `:438` (*"there are seventeen gates and freezeOff is last"*) — change 17 to 18 in each, and prefer `GATE_ORDER.length` over a literal where the test allows it.

`fromFixture` needs a default `ciBaseline`, or every existing test fails on the new gate. Add a fully-compliant default beside `GREEN_RUNS`:

```ts
/** A compliant baseline, so existing fixtures are unaffected by gate 11. */
const COMPLIANT_BASELINE = {
  languages: ['Dockerfile', 'HCL', 'TypeScript'],
  sampled: 15,
  produced: Object.fromEntries([
    'Cycode: SAST', 'Cycode: Secrets', 'Cycode: Vulnerable Dependencies',
    'codecov/project', 'Build and scan image', 'Terraform plan (speculative)',
  ].map((n) => [n, 15])),
};
```

and reference it from `fromFixture`'s defaults. Then:

```ts
test('gate 11 fails when the repo does not produce a shape-required check', () => {
  const baseline = {
    ...COMPLIANT_BASELINE,
    produced: { ...COMPLIANT_BASELINE.produced, 'Build and scan image': 0 },
  };
  const r = runGates(fromFixture(27, { ciBaseline: baseline }));

  assert.equal(r.gates.ciBaselineMet.verdict, 'fail');
  assert.equal(r.failedGate, 'ciBaselineMet',
    'ordered before checksGreen, so a missing workflow reports as a missing workflow');
});

test('gate 11 is ordered before checksGreen', () => {
  assert.ok(GATE_ORDER.indexOf('ciBaselineMet') < GATE_ORDER.indexOf('checksGreen'));
});

test('a repo whose shape requires nothing extra can still pass gate 11', () => {
  const r = runGates(fromFixture(27, {
    ciBaseline: {
      languages: ['TypeScript'],
      sampled: 15,
      produced: Object.fromEntries([
        'Cycode: SAST', 'Cycode: Secrets', 'Cycode: Vulnerable Dependencies', 'codecov/project',
      ].map((n) => [n, 15])),
    },
  }));
  assert.equal(r.gates.ciBaselineMet.verdict, 'pass');
});
```

In `tests/evaluate.test.ts`, the finality property:

```ts
test('a non-candidate failing gate 11 is FINAL — a missing workflow needs a new commit', async () => {
  // ciBaselineMet must not be in CI_REPORTING_GATES: no amount of CI reporting
  // on this head SHA adds a workflow, so staying provisional would mean
  // re-evaluating forever.
  const recorded: any[] = [];
  const [, risk] = await evaluate(ctx(27), riskDeps(27, {
    fetchCiBaseline: async () => ({
      languages: ['Dockerfile'], sampled: 15,
      produced: { 'Cycode: SAST': 15, 'Cycode: Secrets': 15,
                  'Cycode: Vulnerable Dependencies': 15, 'codecov/project': 15 },
    }),
    recordEvaluation: async (r: any) => { recorded.push(r); },
  }) as any);

  assert.equal(recorded[0].eligibility.failedGate, 'ciBaselineMet');
  assert.equal(risk!.externalId, 'final');
  assert.equal(recorded[0].final, true);
});

test('the eval record names which checks were waived', async () => {
  // So "which candidates were eligible only because of a waiver" is a query
  // rather than archaeology.
  const recorded: any[] = [];
  await evaluate(ctx(27), riskDeps(27, {
    fetchCiBaseline: async () => ({
      languages: ['Dockerfile'], sampled: 15,
      produced: { 'Cycode: SAST': 15, 'Cycode: Secrets': 15,
                  'Cycode: Vulnerable Dependencies': 15, 'codecov/project': 15 },
    }),
    recordEvaluation: async (r: any) => { recorded.push(r); },
  }) as any, { ciBaselineWaivers: [{
    check: 'Build and scan image', reason: 'scanned downstream', expiresAt: '2099-01-01',
  }] } as any);

  assert.deepEqual(recorded[0].ciBaselineWaived, ['Build and scan image']);
});
```

The second test's third argument is the enrollment record — match whatever
`evaluate`'s signature is at this point (the enrollment-registry plan may have
made it a positional parameter). Read the signature before writing.

- [ ] **Step 2: Run to verify they fail**

```bash
pnpm exec tsc --noEmit
```

Expected: FAIL — `ciBaselineMet` is not in `GATE_ORDER`, `GateInput` has no `ciBaseline`.

- [ ] **Step 3: Add the gate**

In `src/gates.ts`:

Header comment: `// The eighteen eligibility gates (PLAT-1190, PLAT-1233).`

`GATE_ORDER` — insert after `tierFloor`:

```ts
  'tierFloor',
  // Before checksGreen deliberately. "This repository does not run the check"
  // and "the check failed" need different words because they need different
  // remedies — add a workflow versus fix a test — and `failedGate` is what the
  // weekly report groups on.
  'ciBaselineMet',
  'checksGreen',
```

`GateInput` gains:

```ts
  /** The repo's shape and recent check-run history. Gate 11 reads this. */
  ciBaseline: CiBaseline;
```

In `runGates`, before the gate-12 block:

```ts
    // 11 — does this repository produce the checks its SHAPE requires? Answered
    // from the repo's own recent history, not from this pull request's check
    // runs: at `pull_request: opened` nothing has run, so "never produced" and
    // "not yet produced" would be indistinguishable — the ambiguity the original
    // checksGreen bug was made of.
    //
    // TIME-INVARIANT for this head SHA. Adding a workflow needs a new commit, so
    // this gate must NOT be in CI_REPORTING_GATES.
    const baseline = assessCiBaseline(
      input.ciBaseline, input.rules.ciBaseline, input.enrollment, input.now,
    );
    gates.ciBaselineMet = {
      verdict: baseline.verdict,
      value: { checks: baseline.checks, waived: baseline.waived },
    };
```

`GateInput` also needs `now: Date` if it does not already have one — `runGates`
is documented as having "no clock", so **pass the clock in** rather than calling
`new Date()` inside, preserving that property.

- [ ] **Step 4: Render it**

`src/render.ts:195`'s comment becomes "The eighteen gates…". Add a row renderer
for `ciBaselineMet` whose wording distinguishes the four statuses — this is the
whole user-facing point of the gate:

- `absent` → ``this repository does not run `Build and scan image` (0 of 15 recent pull requests)``
- `conditional` → ``` `codecov/project` ran on only 11 of 15 recent pull requests — it must run on every one ```
- `waived` → ``` `Build and scan image` waived until 2026-11-01: image scanned downstream ```
- `pass` → `produces all 6 checks its shape requires`

Add a sentence naming the remedy when it fails, because "add a workflow" is
actionable and a check-name list is not.

- [ ] **Step 5: Fetch it in `evaluate.ts`**

Add `fetchCiBaseline` to `EvaluateDeps` and call it alongside the existing
`fetchCheckRuns` / `fetchRepoProperties` fetches — the same `skipFetches`
short-circuit applies, since an unenrolled repo should cost nothing.

Then thread `baseline.waived` onto the eval record and add to `src/ledger.ts`:

```ts
  /** Checks that were waived rather than met. Empty or absent means none. */
  ciBaselineWaived?: string[];
```

marshalled as `{ SS: … }` when non-empty and `{ NULL: true }` otherwise, matching
`pendingChecks` — DynamoDB rejects an empty string set.

- [ ] **Step 6: Run everything**

```bash
pnpm test
```

Expected: PASS. Fixture-driven tests in `tests/gates.test.ts` and
`tests/render.test.ts` will need the `COMPLIANT_BASELINE` default; if any fail on
`ciBaselineMet`, that is the default not being wired into `fromFixture`.

- [ ] **Step 7: Commit**

```bash
git add src/gates.ts src/render.ts src/evaluate.ts src/ledger.ts tests/
git commit -m "feat(gates): add ciBaselineMet as gate 11, before checksGreen

Distinguishes 'this repository does not run the check' from 'the check
failed' at the failedGate level, so the weekly report separates platform
work from team work."
```

---

### Task 4: Policy schema for the shape rules

**Files:**
- Modify: `policy-rules.yaml` (add `ciBaseline`)
- Modify: `src/rules-types.ts` (`Rules.ciBaseline`)
- Modify: `scripts/build-rules.mjs` (validate it)
- Modify: `tests/build-rules.test.ts`

- [ ] **Step 1: Write the failing validation tests**

In `tests/build-rules.test.ts`, using the existing `validDoc()` and
`validatePolicy()` (which **returns an array of errors and does not throw**):

```ts
test('a valid ciBaseline section produces no errors', () => {
  assert.deepEqual(validatePolicy(validDoc()), []);
});

test('ciBaseline.always must be an array of strings', () => {
  const doc = validDoc();
  doc.rules.ciBaseline.always = ['ok', 7];
  assert.match(validatePolicy(doc)[0], /ciBaseline\.always/);
});

test('ciBaseline.whenLanguage values must be arrays of strings', () => {
  const doc = validDoc();
  doc.rules.ciBaseline.whenLanguage.Dockerfile = 'Build and scan image';
  assert.match(validatePolicy(doc)[0], /ciBaseline\.whenLanguage\.Dockerfile/);
});

test('minSample must be at least 1 — zero would make the gate meaningless', () => {
  const doc = validDoc();
  doc.rules.ciBaseline.minSample = 0;
  assert.match(validatePolicy(doc)[0], /ciBaseline\.minSample/);
});

test('a waiver without expiresAt is rejected', () => {
  const doc = validDoc();
  doc.repos[0].ciBaselineWaivers = [{ check: 'Build and scan image', reason: 'later' }];
  assert.match(validatePolicy(doc)[0], /expiresAt/);
});

test('a waiver longer than 90 days is rejected', () => {
  // A waiver settable for ten years is a permanent exemption with extra steps.
  const doc = validDoc();
  doc.repos[0].ciBaselineWaivers = [{
    check: 'Build and scan image', reason: 'x', expiresAt: '2030-01-01',
  }];
  assert.match(validatePolicy(doc)[0], /90 days/);
});

test('a waiver without a reason is rejected', () => {
  const doc = validDoc();
  doc.repos[0].ciBaselineWaivers = [{
    check: 'Build and scan image', expiresAt: '2026-10-01',
  }];
  assert.match(validatePolicy(doc)[0], /reason/);
});

test('a repo that both aliases and waives the same check is rejected', () => {
  // A configuration smell: the alias should have resolved it. Flagging beats
  // silently preferring one.
  const doc = validDoc();
  doc.repos[0].checkAliases = { 'Terraform plan (speculative)': 'terraform / plan' };
  doc.repos[0].ciBaselineWaivers = [{
    check: 'Terraform plan (speculative)', reason: 'x', expiresAt: '2026-10-01',
  }];
  assert.match(validatePolicy(doc)[0], /both aliased and waived/);
});
```

Also add `ciBaseline` to `validDoc()`'s `rules` object so the first test can pass.

**The 90-day check needs a fixed clock.** `validatePolicy` is currently
time-independent; give it an optional `now` parameter defaulting to
`new Date()`, and pass a fixed date from the test. A validator whose result
depends on an untestable wall clock is a validator that will fail mysteriously
in CI one day.

- [ ] **Step 2: Run to verify they fail**

```bash
pnpm exec node --import tsx --test tests/build-rules.test.ts
```

- [ ] **Step 3: Add the policy section**

In `policy-rules.yaml`, inside `rules:`:

```yaml
  # CI baseline (gate 11). What a repository must PROVE, derived from what it
  # IS — not from what its CI happens to do.
  #
  # Deriving the requirement from observed CI would be self-attestation: the bar
  # becomes whatever each team already does, and a repo with no image scan gets
  # graded as though scanning were never expected. Shape comes from GitHub's
  # languages API, which reports `Dockerfile` and `HCL` — and catches a
  # Dockerfile that is not at the repo root, which a path probe misses.
  #
  # A check must appear on EVERY sampled pull request. Gate 12 fails closed on
  # absence, so a check that runs sometimes can never be safely required.
  ciBaseline:
    # Required on every enrolled repository, whatever its shape.
    #
    # codecov/project is here rather than under a language condition on purpose:
    # every changeClass sets minCoveragePct: 60, so automating a dependency bump
    # with no coverage signal at all is exactly what a floor exists to prevent.
    always:
      - "Cycode: SAST"
      - "Cycode: Secrets"
      - "Cycode: Vulnerable Dependencies"
      - "codecov/project"

    # Language key from the GitHub languages API -> the checks it makes required.
    whenLanguage:
      Dockerfile:
        - "Build and scan image"
      HCL:
        - "Terraform plan (speculative)"

    # Recent pull requests to sample.
    samplePrs: 15
    # Below this many sampled pull requests the gate reads `unknown` rather than
    # guessing — a brand-new repository has demonstrated nothing either way.
    minSample: 3
```

Add the matching `CiBaselineRules` field to `Rules` in `src/rules-types.ts`,
re-exporting the interface Task 2 defined rather than duplicating it.

- [ ] **Step 4: Validate, test, commit**

```bash
pnpm build && pnpm test
grep -c "ciBaseline" src/generated/rules.ts
```

```bash
git add policy-rules.yaml src/rules-types.ts scripts/build-rules.mjs src/generated/rules.ts tests/build-rules.test.ts
git commit -m "feat(policy): declare the CI baseline as shape rules with waiver validation"
```

---

### Task 5: Enrollment fields, and `signalChecks` applicability

**Files:**
- Modify: the enrollment record type (`src/enrollment.ts` or `src/rules-types.ts` — read the enrollment-registry plan's state first)
- Modify: `src/evaluate.ts` (filter `signalChecks` by what the repo produces)
- Modify: `tests/evaluate.test.ts`, `tests/completeness.test.ts`

**Interfaces:**
- Produces: `EnrollmentRecord.checkAliases?: Record<string, string>` and `EnrollmentRecord.ciBaselineWaivers?: Waiver[]`.

- [ ] **Step 1: Write the failing test**

The property that makes "never final" unreachable:

```ts
test('a repo that does not produce a declared signal check does not wait for it', async () => {
  // codecov/project is absent on 6 of 8 enrolled repos. Waiting for a check the
  // repo demonstrably never produces leaves every evaluation provisional
  // forever, so `final` never becomes true and the corpus is unusable.
  const recorded: any[] = [];
  await evaluate(ctx(27), riskDeps(27, {
    fetchCiBaseline: async () => ({
      languages: ['TypeScript'], sampled: 15,
      produced: { 'Cycode: SAST': 15, 'Cycode: Secrets': 15,
                  'Cycode: Vulnerable Dependencies': 15 },
    }),
    fetchCheckRuns: async () => [
      { name: 'Cycode: SAST', status: 'completed', conclusion: 'success', title: null },
      { name: 'Cycode: Secrets', status: 'completed', conclusion: 'success', title: null },
      { name: 'Cycode: Vulnerable Dependencies', status: 'completed', conclusion: 'success', title: null },
    ],
    recordEvaluation: async (r: any) => { recorded.push(r); },
  }) as any);

  assert.deepEqual(recorded[0].pendingChecks, [],
    'codecov/project is declared but never produced here, so it is not waited on');
});
```

- [ ] **Step 2: Implement**

Add the two fields to the enrollment record type, then in `evaluate.ts` where
`assessCompleteness` is called, intersect the declared signal checks with what
the repository actually produces on every pull request:

```ts
  // A declared signal check the repository never produces would leave every
  // evaluation provisional forever. Intersect with the observed baseline so
  // provisional always terminates.
  //
  // Belt and braces: such a repository also fails gate 11 (codecov/project is
  // always-required), so it is a non-candidate and assessRisk never runs. This
  // keeps the property true even if that ordering changes.
  const declared = signalChecksFor(enrollment, policy);
  const applicable = declared.filter(
    (name) => (ciBaseline.produced[enrollment?.checkAliases?.[name] ?? name] ?? 0) === ciBaseline.sampled
      && ciBaseline.sampled > 0,
  );
```

and pass `applicable` to `assessCompleteness`. When `ciBaseline.error` is set,
fall back to `declared` — an unreadable baseline must not silently stop waiting
for real signals.

- [ ] **Step 3: Test and commit**

```bash
pnpm test
git add src/ tests/
git commit -m "feat(enrollment): add checkAliases and ciBaselineWaivers, scope signalChecks to what a repo produces"
```

---

### Task 6: Docs, and the seventeen-to-eighteen sweep

**Files:** 16 references, enumerated so none is missed.

- [ ] **Step 1: Update every gate-count reference**

| File | Lines |
|---|---|
| `src/gates.ts` | `:1` header ("seventeen"), `:285` ("17 — freeze, last" → 18) |
| `src/render.ts` | `:195` ("The seventeen gates as a markdown table") |
| `docs/architecture.md` | `:134`, `:353` |
| `docs/call-flows.md` | `:97`, `:99` |
| `docs/policy.md` | `:23`, `:31` (heading "## The seventeen gates"), `:33`, `:136`, `:335` |
| `README.md` | `:9`, `:109`, `:167` |
| `AGENTS.md` | `:5` |
| `tests/gates.test.ts` | `:49`, `:225`, `:412`, `:438` (done in Task 3) |

```bash
cd ~/Projects/zapp
grep -rn "seventeen\|17 gates\|of 17" src/ docs/ README.md AGENTS.md tests/
```

Expected after the sweep: no hits.

- [ ] **Step 2: Document gate 11 in `docs/policy.md`**

Add its row to the gate table, and a short section covering: shape comes from
the languages API; a check must run on every recent pull request; how to fix an
absent check (add the workflow), a conditional one (make it unconditional), a
misnamed one (`checkAliases`), and — last, with its guards stated — how to waive
one.

- [ ] **Step 3: Add the sharp edges to `AGENTS.md`**

```markdown
- Gate 11 (`ciBaselineMet`) reads the repo's OWN recent history, not this pull
  request's check runs. At `pull_request: opened` nothing has run, so "never
  produced" and "not yet produced" are indistinguishable from one PR — the
  ambiguity the original checksGreen bug was made of. It is time-invariant for a
  head SHA, so it must NEVER be added to `CI_REPORTING_GATES`.
- Repo shape comes from GitHub's languages API, not file paths and not custom
  properties. `bankrate/crank` 404s on `contents/Dockerfile` but reports
  `Dockerfile` in languages, because its Dockerfile is not at the root. Custom
  properties are repo-editable in this org, which would make shape
  self-attested.
- A `waived` check must never render or record as `pass`. The waiver unblocks
  eligibility; the repo still appears in the CI-standardization finding, and
  that number is the phase's deliverable.
- GitHub GraphQL answers HTTP 200 and reports failures in an `errors` array.
  Checking `res.ok` alone turns a failed query into "this repo produces no
  checks", which fails gate 11 for the wrong reason.
```

- [ ] **Step 4: Commit**

```bash
git add src/ docs/ README.md AGENTS.md
git commit -m "docs: describe gate 11 and update the gate count to eighteen"
```

---

### Task 7: Verify against the real fleet

- [ ] **Step 1: Confirm the deploy, then read the baseline for all eight repos**

After the deploy, a one-off script or `node --import tsx -e` using
`fetchCiBaseline` against each enrolled repository. Expected, from the
2026-08-28 measurement:

| repo | shape | expected gate 11 |
|---|---|---|
| platform-cicd-v2-demo | Dockerfile, HCL | **pass** |
| conductor | neither | fail — codecov absent |
| conductor-api | Dockerfile, HCL | fail — tf plan, codecov |
| portkey | Dockerfile, HCL | fail — tf plan |
| zapp | Dockerfile, HCL | fail — image scan, tf plan, codecov |
| brand-identity-pages-app | Dockerfile, HCL | fail — image scan, tf plan |
| redirect-management-api-v2 | Dockerfile, HCL | fail — image scan, tf plan, codecov |
| crank | Dockerfile, HCL | fail — image scan, tf plan, codecov |

**`conductor` is the test that matters.** It must fail on `codecov/project`
only — *not* on an image scan or a speculative plan. If it fails on either, the
shape rules are being applied unconditionally and the flat-list regression is
back.

- [ ] **Step 2: Confirm the finding is now legible**

Comment on an open dependabot pull request on `portkey` to trigger a fresh
evaluation, then read the check run. Expected: `failedGate: ciBaselineMet`, with
wording naming the missing check and the remedy — not a list of five check names
under `checksGreen`.

- [ ] **Step 3: Confirm the split in the corpus**

```bash
cd /tmp && aws dynamodb scan --table-name zapp-evaluations \
  --profile bankrate-qa --region us-east-1 --output json > after.json
jq -r '[.Items[]|select(.sk.S|startswith("eval#"))]
  | group_by(if (.failedGate|has("S")) then .failedGate.S else "none (candidate)" end)
  | map("\(.[0]|if (.failedGate|has("S")) then .failedGate.S else "none (candidate)" end): \(length)")|.[]' after.json
```

Expected direction: a new `ciBaselineMet` bucket appears and absorbs most of what
was `checksGreen`. Baseline for comparison, 2026-08-28:

```
none (candidate): 12    botAllowlisted: 5    changeClass: 17
checksGreen: 34         classificationPermits: 24    conventionalTitle: 5
```

- [ ] **Step 4: Report the finding**

The deliverable, in the form the spec argues for:

```
add coverage reporting     N repos
add a speculative plan     N repos
add an image scan          N repos
fully compliant            N of 8
```

That is CI/CD v2 adoption work with a named remedy per repository, and it is the
output this gate exists to produce.

---

## Self-review notes

**Spec coverage.** Shape from languages + 15-PR frequency → Task 1. The pure assessment, aliases, waivers, resolution order → Task 2. The gate, its ordering, rendering, and the eval-record field → Task 3. Shape rules and waiver validation in policy → Task 4. Enrollment fields and `signalChecks` applicability → Task 5. Docs and the gate-count sweep → Task 6. Fleet verification and the finding → Task 7.

**The spec's out-of-scope items have no tasks**, deliberately: auto-filing CI gaps, `observe` mode, retroactive evaluation of already-open pull requests, and a waiver approval workflow.

**Two guards I added beyond the spec, and why.** A waiver can excuse only an `absent` check, never a `conditional` one — "runs sometimes" is a CI defect to fix, and a waiver asserts "we will never run this here", which is a different claim. And `validatePolicy` gains an injectable `now` for the 90-day cap, because a validator whose result depends on an untestable wall clock fails mysteriously in CI eventually.

**Where I need the executor to read before writing.** Task 3's second new test passes an enrollment record to `evaluate`, and Task 5 edits the enrollment record type — both depend on whether `2026-08-28-enrollment-registry-zapp.md` has landed, which changes `evaluate`'s signature and moves the record's home from `policy-rules.yaml` to DynamoDB. Each step says to check the signature first rather than assuming.

**One thing not fully resolved.** `GateInput` is documented as having "no I/O, no clock, no environment" — that purity is what makes the fixture-driven suite possible. Gate 11 needs a clock for waiver expiry, so Task 3 passes `now: Date` in as input rather than calling `new Date()` inside `runGates`. That preserves the property but does widen `GateInput`, and it is worth a reviewer's eye.
