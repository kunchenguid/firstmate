# Policy Correctness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close four places where zapp's decision logic reaches a more permissive verdict than its inputs justify.

**Architecture:** Four independent changes to three pure functions. No new modules, no new dependencies, no configuration or infrastructure change. Each fix is a comparison; each test is a table.

**Tech Stack:** Node 22, TypeScript, `node:test` + `tsx`.

**Spec:** [`../specs/2026-08-26-policy-correctness-fixes-design.md`](../specs/2026-08-26-policy-correctness-fixes-design.md)

**Repo:** `bankrate/zapp` at v1.5.0. Branch from `main`: `fix/policy-correctness`.

> **Parallel-safe with Spec D.** This plan touches `src/classify.ts`, `src/risk.ts` and `src/signals/scan-findings.ts` and their tests. Spec D touches `gates.ts`, `render.ts`, `evaluate.ts`, `coverage.ts` and `policy-rules.yaml`. No file overlap. If Spec D has already merged when you start, see Task 1 Step 5 about reusing its `GREEN` set.

## Global Constraints

- **Every change here makes the service stricter.** A fix that makes any verdict *more* permissive is wrong.
- **No change to `policy-rules.yaml`** — so `RULES_SHA` is untouched and no branch editing that file can conflict.
- **`src/gates.ts` is not modified.** Neither is `src/render.ts`, `src/evaluate.ts` or `src/checks.ts`.
- **Shadow-mode invariant** unchanged: conclusions stay `neutral`.
- **`unknown` is a value, not an error** — a signal that cannot be determined records `unknown` with a reason and is excluded from the worst-of comparison.
- **The regression that guards everything:** PR #27 must stay a `dep-minor` **candidate** and PR #32 a `dep-major` **non-candidate**. If a fixture verdict changes, the fix is wrong, not the fixture.
- **Node 22**, ESM — relative imports carry `.js` even from `.ts` sources.
- **Conventional Commits** — `release.yml` runs semantic-release on merge to `main`. These are `fix:` commits.
- **`docs/superpowers/` is gitignored in zapp.** The spec lives in firstmate.

---

### Task 1: Scanner conclusions — six of eight currently read as clean

**Files:**
- Modify: `src/signals/scan-findings.ts`
- Modify: `tests/signals-scan-findings.test.ts`

**Interfaces:**
- Consumes: `CheckRunSummary` from `src/check-runs.ts`; `Signal`, `unknownSignal` from `src/signals/types.ts`
- Produces: `scanFindings(runs, maxNewFindings)` — signature unchanged, three conclusion buckets instead of one equality check

- [ ] **Step 1: Create the branch**

```bash
cd /Users/scrosby/Projects/github/zapp
git checkout main && git pull
git checkout -b fix/policy-correctness
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/signals-scan-findings.test.ts`. The existing `run()` helper and `ALL_GREEN` constant
in that file are reused:

```ts
test('a cancelled scanner is unknown, NOT clean', () => {
  // The inversion this task exists to fix: `cancelled` is not `failure`, so it
  // used to contribute nothing and the signal graded `low` — a commit that was
  // never scanned reading as a clean scan.
  const s = scanFindings([run('Cycode: SAST', 'cancelled'), ...ALL_GREEN.slice(1)], 0);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /Cycode: SAST/);
  assert.match(s.reason!, /cancelled/);
});

test('a timed-out scanner is unknown', () => {
  const s = scanFindings([run('Cycode: SAST', 'timed_out'), ...ALL_GREEN.slice(1)], 0);
  assert.equal(s.grade, 'unknown');
});

test('a stale scanner is unknown', () => {
  const s = scanFindings([run('Cycode: SAST', 'stale'), ...ALL_GREEN.slice(1)], 0);
  assert.equal(s.grade, 'unknown');
});

test('a completed scanner with a null conclusion is unknown', () => {
  const s = scanFindings([run('Cycode: SAST', null), ...ALL_GREEN.slice(1)], 0);
  assert.equal(s.grade, 'unknown');
});

test('action_required counts as a finding, not as unknown', () => {
  // A definite non-green outcome the scanner chose to emit: something needs a
  // human. That is a finding, not an absence of information.
  const s = scanFindings([run('Cycode: SAST', 'action_required'), ...ALL_GREEN.slice(1)], 0);
  assert.equal(s.grade, 'high');
  assert.equal(s.value!.failed, 1);
});

test('every GitHub conclusion lands in exactly one bucket', () => {
  // The table this task is really about. If GitHub adds a conclusion value,
  // this test is where the omission surfaces.
  const expected: Record<string, 'low' | 'high' | 'unknown'> = {
    success: 'low', neutral: 'low', skipped: 'low',
    failure: 'high', action_required: 'high',
    cancelled: 'unknown', timed_out: 'unknown', stale: 'unknown',
  };
  for (const [conclusion, grade] of Object.entries(expected)) {
    const s = scanFindings([run('Cycode: SAST', conclusion), ...ALL_GREEN.slice(1)], 0);
    assert.equal(s.grade, grade, `${conclusion} should grade ${grade}`);
  }
});

test('one indeterminate scanner makes the whole signal unknown, even beside a real finding', () => {
  // Fail-closed ordering: we cannot report "1 of 3 failing" when we do not know
  // what the third one found.
  const s = scanFindings([
    run('Cycode: SAST', 'failure'),
    run('Cycode: Secrets', 'cancelled'),
    run('Cycode: Vulnerable Dependencies', 'success'),
  ], 0);
  assert.equal(s.grade, 'unknown');
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `cancelled` currently grades `low`

- [ ] **Step 4: Replace the conclusion check in `src/signals/scan-findings.ts`**

First add the two sets at module scope, beside the existing `EXPECTED` constant:

```ts
// GitHub has eight conclusion values and the previous implementation counted
// only `failure`, so the other six read as clean. Three buckets:
//
//   reported clean  success | neutral | skipped
//   a finding       failure | action_required
//   indeterminate   cancelled | timed_out | stale | null
//
// `action_required` is a finding rather than indeterminate because it is a
// definite non-green outcome the scanner deliberately emitted. The other three
// mean the scan produced no verdict at all — which is what `unknown` means
// everywhere else in this service.
const CLEAN = new Set(['success', 'neutral', 'skipped']);
const FINDING = new Set(['failure', 'action_required']);
```

Then replace the `const failed = …` line and its comment inside `scanFindings` with:

```ts
  // Checked BEFORE counting findings: we cannot honestly report "1 of 3
  // failing" while a third scanner's result is unknown.
  const indeterminate = found.filter(
    (run) => !CLEAN.has(run.conclusion ?? '') && !FINDING.has(run.conclusion ?? ''),
  );
  if (indeterminate.length > 0) {
    return unknownSignal(
      `scanner check(s) did not produce a verdict: ${indeterminate.map((r) => `${r.name} (${r.conclusion ?? 'no conclusion'})`).join(', ')}`,
    );
  }

  const failed = found.filter((run) => FINDING.has(run.conclusion ?? '')).length;
```

- [ ] **Step 5: If Spec D has already merged, reuse its set**

```bash
grep -n "const GREEN" src/gates.ts 2>/dev/null
```

If that prints a match, Spec D's `checksGreen` gate defines `GREEN = new Set(['success','neutral','skipped'])` —
the same set as `CLEAN` here. Export one from a shared location and import it in both rather than
keeping two definitions that could drift. If it prints nothing, D has not landed; leave `CLEAN` local
and note it for whoever lands D second.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS. The existing tests in that file — all-green, a failure above threshold, missing and
in-progress scanners — must still pass unchanged.

- [ ] **Step 7: Commit**

```bash
git add src/signals/scan-findings.ts tests/signals-scan-findings.test.ts
git commit -m "fix: an unscanned commit no longer reads as a clean scan"
```

---

### Task 2: Downgrades classify as upgrades

**Files:**
- Modify: `src/classify.ts`
- Modify: `tests/classify.test.ts`

**Interfaces:**
- Consumes: nothing new
- Produces: `isDowngrade(from: string, to: string): boolean | null`, exported alongside `deltaLevel`

- [ ] **Step 1: Write the failing tests**

Append to `tests/classify.test.ts`:

Extend the file's existing `import { classify, deltaLevel } from '../src/classify.js';` line to also
import `isDowngrade` rather than adding a second import from the same module.

```ts
test('isDowngrade detects direction at every semver position', () => {
  assert.equal(isDowngrade('2.0.0', '1.9.9'), true);
  assert.equal(isDowngrade('1.2.0', '1.1.9'), true);
  assert.equal(isDowngrade('1.2.3', '1.2.2'), true);
  assert.equal(isDowngrade('1.2.3', '1.2.4'), false);
  assert.equal(isDowngrade('1.2.3', '2.0.0'), false);
  assert.equal(isDowngrade('1.2.3', '1.2.3'), false);
});

test('isDowngrade strips range prefixes like deltaLevel does', () => {
  assert.equal(isDowngrade('^5.12.0', '^5.11.2'), true);
  assert.equal(isDowngrade('~1.0.1', '~1.0.0'), true);
});

test('isDowngrade returns null on an unparseable version', () => {
  assert.equal(isDowngrade('workspace:*', '1.0.0'), null);
  assert.equal(isDowngrade('1.0.0', 'github:foo/bar#abc'), null);
});

test('a downgrade makes the whole PR unclassified', () => {
  const result = classify(
    manifest('@@ -1 +1 @@\n-    "fastify": "^5.12.0",\n+    "fastify": "^5.11.2",'),
    GENERATED,
  );
  assert.equal(result.changeClass, 'unclassified');
  assert.match(result.reason!, /downgrade/i);
});

test('the downgrade reason names the package and both versions', () => {
  const result = classify(
    manifest('@@ -1 +1 @@\n-    "fastify": "^5.12.0",\n+    "fastify": "^5.11.2",'),
    GENERATED,
  );
  assert.match(result.reason!, /fastify/);
  assert.match(result.reason!, /5\.12\.0/);
  assert.match(result.reason!, /5\.11\.2/);
});

test('one downgrade among upgrades still unclassifies the whole PR', () => {
  const result = classify(
    manifest('@@ -1 +1 @@\n-    "pg": "8.22.0",\n+    "pg": "8.23.0",\n-    "jose": "6.2.9",\n+    "jose": "6.2.8",'),
    GENERATED,
  );
  assert.equal(result.changeClass, 'unclassified');
  assert.match(result.reason!, /jose/);
});

test('a downgrade does NOT become a new change class', () => {
  // dep-downgrade would need a size ceiling, tier floor, semver cap and
  // classification list that nobody has reasoned about. Unclassified is the
  // fail-closed answer and costs nothing real for allow-listed bots.
  const result = classify(
    manifest('@@ -1 +1 @@\n-    "fastify": "^5.12.0",\n+    "fastify": "^5.11.2",'),
    GENERATED,
  );
  assert.doesNotMatch(result.changeClass, /downgrade/);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `isDowngrade` is not exported, and the downgrade fixture currently classifies
`dep-minor`

- [ ] **Step 3: Add `isDowngrade` to `src/classify.ts`**

Beside `deltaLevel`:

```ts
/**
 * Is `to` an earlier version than `from`?
 *
 * `deltaLevel` compares components without direction, so `5.12.0 -> 5.11.2`
 * reads `minor` exactly as the upgrade does — and a downgrade into a
 * known-vulnerable version would ride the routine dep-minor path.
 *
 * Returns null when either side is unparseable, matching `deltaLevel`'s
 * convention; the caller treats null the same way it already does.
 */
export function isDowngrade(from: string, to: string): boolean | null {
  const a = VERSION.exec(from);
  const b = VERSION.exec(to);
  if (!a || !b) return null;

  for (let i = 1; i <= 3; i++) {
    const left = Number(a[i]);
    const right = Number(b[i]);
    if (left !== right) return right < left;
  }
  return false;
}
```

- [ ] **Step 4: Check direction before computing the level**

In `classify()`, inside the loop that walks `removed`, insert the direction check immediately before
the existing `deltaLevel` call:

```ts
      const down = isDowngrade(from, to);
      if (down === null) return unclassified(`unparseable version for ${name}: "${from}" -> "${to}"`);
      if (down) return unclassified(`version downgrade: ${name} ${from} -> ${to}`);

      const level = deltaLevel(from, to);
      if (level === null) return unclassified(`unparseable version for ${name}: "${from}" -> "${to}"`);
```

The `down === null` branch duplicates the existing unparseable message deliberately: both mean the
same thing to a reader, and collapsing them would mean calling `deltaLevel` first and discarding its
answer.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS, including the existing fixture tests for PRs #27 and #32

- [ ] **Step 6: Commit**

```bash
git add src/classify.ts tests/classify.test.ts
git commit -m "fix: a version downgrade no longer classifies as a routine bump"
```

---

### Task 3: 0.x minors are de-facto majors

**Files:**
- Modify: `src/classify.ts`
- Modify: `tests/classify.test.ts`

**Interfaces:**
- Consumes: `deltaLevel` from Task 2's file
- Produces: `deltaLevel` — signature unchanged, 0.x minors return `'major'`

- [ ] **Step 1: Write the failing tests**

Append to `tests/classify.test.ts`:

```ts
test('a 0.x minor bump ranks major — semver promises nothing below 1.0', () => {
  assert.equal(deltaLevel('0.1.0', '0.2.0'), 'major');
  assert.equal(deltaLevel('^0.4.1', '^0.5.0'), 'major');
});

test('a 0.x patch bump stays patch', () => {
  // Deliberately unchanged. The citation is that a 0.x MINOR is a de-facto
  // major; shifting 0.x patches up as well would be inventing policy.
  assert.equal(deltaLevel('0.1.1', '0.1.2'), 'patch');
});

test('a 0.x major bump is still major', () => {
  assert.equal(deltaLevel('0.9.0', '1.0.0'), 'major');
});

test('the rule keys on the FROM version, not the to', () => {
  // 1.0.0 -> 1.1.0 is an ordinary minor and must be untouched.
  assert.equal(deltaLevel('1.0.0', '1.1.0'), 'minor');
  assert.equal(deltaLevel('1.9.0', '1.10.0'), 'minor');
});

test('a 0.x minor bump classifies the PR as dep-major', () => {
  const result = classify(
    manifest('@@ -1 +1 @@\n-    "tiny-lib": "^0.4.1",\n+    "tiny-lib": "^0.5.0",'),
    GENERATED,
  );
  assert.equal(result.changeClass, 'dep-major');
  assert.equal(result.maxDelta, 'major');
});

test('a 1.x control in the same shape stays dep-minor', () => {
  const result = classify(
    manifest('@@ -1 +1 @@\n-    "tiny-lib": "^1.4.1",\n+    "tiny-lib": "^1.5.0",'),
    GENERATED,
  );
  assert.equal(result.changeClass, 'dep-minor');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `deltaLevel('0.1.0', '0.2.0')` returns `'minor'`

- [ ] **Step 3: Add the 0.x rule to `deltaLevel`**

Replace the body's comparison chain:

```ts
  if (a[1] !== b[1]) return 'major';

  // Below 1.0 semver makes no compatibility promise, so a 0.x minor is a
  // de-facto major — Renovate's automerge guidance excludes pre-1.0 packages
  // outright for this reason. Keyed on the FROM version: 0.9.0 -> 1.0.0 is
  // already major by the comparison above, and 1.x is untouched.
  //
  // 0.x PATCH bumps deliberately stay `patch`: the citation is specifically
  // about minors, and the change class already caps size and paths for patches.
  if (a[2] !== b[2]) return a[1] === '0' ? 'major' : 'minor';

  if (a[3] !== b[3]) return 'patch';
  return 'none';
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

**If PR #27 or #32's fixture verdict changed, stop.** Neither fixture contains a 0.x dependency, so
neither should move. A change means the rule is matching more than it should — most likely keying on
the wrong side of the comparison.

- [ ] **Step 5: Commit**

```bash
git add src/classify.ts tests/classify.test.ts
git commit -m "fix: treat a 0.x minor bump as a major version change"
```

---

### Task 4: The security reducer can override the cooldown

**Files:**
- Modify: `src/risk.ts`
- Modify: `tests/risk.test.ts`

**Interfaces:**
- Consumes: `RiskSignals`, `RANK`, `BY_RANK` — all already in `src/risk.ts`
- Produces: `combine(signals)` — signature unchanged, reducer gated and floored

- [ ] **Step 1: Write the failing tests**

Append to `tests/risk.test.ts`. The existing `sig` and `signals` helpers in that file are reused:

```ts
const closesOne = sig('low', { ghsaIds: ['GHSA-1'] });

test('the reducer cannot lower a grade below the publish-age grade', () => {
  // A release published hours ago grades medium on publish age. Closing a CVE
  // must NOT drop it to low: rushed and fabricated security releases are a
  // documented attack pattern, and fresh publish age is the signal that catches
  // them.
  const r = combine(signals({
    publishAge: sig('medium', { youngestDays: 0, package: 'fresh-pkg' }),
    closesFinding: closesOne,
  }));
  assert.equal(r.grade, 'medium');
});

test('the reducer does not apply at all when publish age is unknown', () => {
  // Granting a concession on absent data is the pattern this service refuses
  // everywhere else.
  const r = combine(signals({
    semverDistance: sig('high', 'major'),
    publishAge: sig('unknown'),
    closesFinding: closesOne,
  }));
  assert.equal(r.grade, 'high');
});

test('the reducer still does its job for a mature package', () => {
  // The case it exists for must keep working: a high grade, a package that has
  // been public for a month, closing a real advisory.
  const r = combine(signals({
    semverDistance: sig('high', 'major'),
    publishAge: sig('low', { youngestDays: 30, package: 'mature-pkg' }),
    closesFinding: closesOne,
  }));
  assert.equal(r.grade, 'medium');
});

test('the reducer never lowers below publish age across the whole matrix', () => {
  const RANKS = { low: 0, medium: 1, high: 2 } as const;
  for (const ageGrade of ['low', 'medium', 'high'] as const) {
    for (const worstGrade of ['low', 'medium', 'high'] as const) {
      const r = combine(signals({
        semverDistance: sig(worstGrade, 'x'),
        publishAge: sig(ageGrade, { youngestDays: 1, package: 'p' }),
        closesFinding: closesOne,
      }));
      assert.ok(
        RANKS[r.grade as 'low' | 'medium' | 'high'] >= RANKS[ageGrade],
        `age=${ageGrade} worst=${worstGrade} produced ${r.grade}, below the publish-age floor`,
      );
    }
  }
});

test('closing nothing still changes nothing', () => {
  const r = combine(signals({
    semverDistance: sig('high', 'major'),
    publishAge: sig('low', { youngestDays: 30, package: 'p' }),
    closesFinding: sig('low', { ghsaIds: [] }),
  }));
  assert.equal(r.grade, 'high');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — the first test grades `low`

- [ ] **Step 3: Gate and floor the reducer in `src/risk.ts`**

Replace the reducer block:

```ts
  // The reducer: only when the signal is known AND actually closed something.
  const closes = signals.closesFinding.grade !== 'unknown'
    && (signals.closesFinding.value?.ghsaIds.length ?? 0) > 0;

  // The reducer is a CONCESSION, and two things bound it.
  //
  // It applies only when publish age is known: granting a concession on absent
  // data is the pattern this service refuses everywhere else.
  //
  // And it can never lower the grade below publish age's own rank. A release
  // published hours ago that closes a CVE stays medium, because rushed and
  // fabricated security releases are a documented attack pattern and fresh
  // publish age is precisely the signal that catches them.
  //
  // Dependabot exempts security updates from its cooldown. That is defensible
  // for NOTIFYING a human, who can notice a suspicious release, and wrong for
  // unattended merge, which cannot.
  const publishAgeKnown = signals.publishAge.grade !== 'unknown';
  const floor = publishAgeKnown
    ? RANK[signals.publishAge.grade as Exclude<SignalGrade, 'unknown'>]
    : 0;

  const finalRank = closes && publishAgeKnown
    ? Math.max(floor, worstRank - 1)
    : worstRank;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS, including the existing reducer tests — `closesFinding lowers the grade by exactly one
step` should still pass, because its fixture has `publishAge` at `low`.

If that existing test now fails, read it before changing it: it may be asserting the old unfloored
behaviour with a `publishAge` that makes the floor bite. Adjust its fixture, not the implementation.

- [ ] **Step 5: Commit**

```bash
git add src/risk.ts tests/risk.test.ts
git commit -m "fix: the security reducer can no longer override a fresh-release warning"
```

---

### Task 5: Prove the fixtures did not move, and document

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/policy.md`

**Interfaces:**
- Consumes: everything
- Produces: nothing code-facing

- [ ] **Step 1: Assert the two fixture verdicts explicitly**

Append to `tests/gates.test.ts`:

```ts
test('SPEC E REGRESSION: PR #27 is still a dep-minor candidate', () => {
  // Every fix in Spec E makes the service stricter. A stricter service that
  // flips the one pull request demonstrating a pass has broken something.
  const r = runGates(fromFixture(27));
  assert.equal(r.changeClass, 'dep-minor');
  assert.equal(r.verdict, 'candidate');
});

test('SPEC E REGRESSION: PR #32 is still a dep-major non-candidate', () => {
  const r = runGates(fromFixture(32));
  assert.equal(r.changeClass, 'dep-major');
  assert.equal(r.verdict, 'not-candidate');
});
```

If Spec D has merged, `fromFixture` requires `runs` and `properties`; its defaults already supply
them and these tests need no arguments either way.

- [ ] **Step 2: Run the full suite**

Run: `pnpm test && pnpm run typecheck && pnpm run build`
Expected: PASS, clean typecheck, `dist/index.js` written

- [ ] **Step 3: Append to `AGENTS.md`**

Concise, pointing at authoritative files:

- Scanner verdicts have three buckets, not two: `success`/`neutral`/`skipped` are clean,
  `failure`/`action_required` are findings, and `cancelled`/`timed_out`/`stale`/null are `unknown`.
  Counting only `failure` let an unscanned commit read as a clean scan.
- `deltaLevel` has no direction; `isDowngrade` does. Check direction before computing a level, or a
  downgrade into a vulnerable version classifies as a routine bump.
- A 0.x **minor** ranks `major` (semver promises nothing below 1.0). 0.x patches deliberately do not.
- The security reducer in `src/risk.ts` is floored at the publish-age grade and does not apply when
  publish age is unknown. Removing either bound lets a hours-old "security" release grade `low`,
  which is the attack this bound exists for. We diverge from Dependabot here on purpose.

- [ ] **Step 4: Update `docs/policy.md`**

It is the reader-facing page both checks link. Two changes:

- In the risk-signals section, note that a scanner which was cancelled or timed out reads as *not
  known*, not as clean, and that this shows as `❓` on the check.
- In the change-classes section, note that dependency **downgrades** are never candidates, and that
  pre-1.0 packages are treated as major-version changes on any minor bump — with the one-line reason
  (semver makes no compatibility promise below 1.0) so a reader can argue with the rule rather than
  just meet it.

- [ ] **Step 5: Commit**

```bash
git add tests/gates.test.ts AGENTS.md docs/policy.md
git commit -m "test: pin the fixture verdicts against the correctness fixes"
```

---

### Task 6: Deploy to QA and confirm nothing regressed

**Files:** none — verification only.

- [ ] **Step 1: Open the pull request**

```bash
gh pr create --repo bankrate/zapp --base main --head fix/policy-correctness \
  --title "fix: four places the policy logic failed open" \
  --body "Spec lives in firstmate: docs/superpowers/zapp/specs/2026-08-26-policy-correctness-fixes-design.md

A1 unscanned commits read as clean scans; A2 downgrades classified as upgrades; A4 the security reducer could override the cooldown; B3 0.x minors ranked as minors."
```

Confirm CI passes.

- [ ] **Step 2: Merge and cut a QA pre-release**

Merge, then publish a pre-release tag so `deploy-v2.yml` stops after QA.

- [ ] **Step 3: Re-evaluate PR #27 and confirm it is unchanged**

```bash
gh pr checkout 27 --repo bankrate/platform-cicd-v2-demo
git commit --allow-empty -m "chore: re-trigger merge-policy evaluation"
git push
```

Wait for CI, then:

```bash
SHA=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/27 --jq .head.sha)
gh api "repos/bankrate/platform-cicd-v2-demo/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name|startswith("merge-policy/")) | "\(.name) :: \(.output.title)"'
```

Expected: eligibility still `Would have been a candidate — dep-minor`.

**The risk grade may legitimately differ** — if any Cycode check came back `cancelled` this run, the
scanner signal is now `unknown` where it used to be `low`, and the check will say so. That is the fix
working. What must not change is the eligibility verdict.

- [ ] **Step 4: Confirm the scanner signal reports honestly**

```bash
AWS_PROFILE=bankrate-qa aws logs filter-log-events --region us-east-1 \
  --log-group-name /aws/lambda/zapp-qa \
  --filter-pattern '{ $.msg = "evaluated" }' \
  --start-time $(( ($(date +%s) - 1800) * 1000 )) \
  --query 'events[].message' --output text | tail -3
```

Confirm the evaluation ran and recorded a verdict. There is no new log line in this work — the point
is that the existing one still fires with an unchanged eligibility verdict.

- [ ] **Step 5: Record the evidence**

Post Step 3's output on the zapp PR. The single acceptance criterion for this work is *"stricter, and
nothing that passed before now fails for the wrong reason"*, and Step 3 is what demonstrates it.

---

## Post-implementation

- **Spec F** — supply-chain signals (tiered cooldown, target-version advisories, adoption proxy).
  Depends on this work: F's sub-day `high` grade only behaves correctly because Task 4's floor
  prevents the reducer cancelling it. Its plan should be written once this and Spec D have landed.
- **Spec G** — controls and override (runtime freeze, base-branch and blocking-label gates, commit
  authorship and merge-window recording). After F.
- **The review's C2 and C3** — outcome records and the ops runbook — remain PLAT-1193 and T11.
