# Eligibility Finality Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop zapp marking an evaluation `final` while a CI-reporting gate is still unresolved, which permanently freezes stale check evidence into both the check run and the ledger.

**Architecture:** One narrow change. The non-candidate finality test reads only `eligibility.failedGate` — the *first* failure in `GATE_ORDER` — so a non-candidate failing a non-CI gate first gets stamped `final` even with `checksGreen` and `coverageFloor` unresolved, and `worker.ts`'s already-final guard then skips every re-evaluation. Narrowing the test to "is *any* CI-reporting gate unresolved" lets that guard open as designed. A one-off script then corrects the `final` flag on the 16 records the defect already wrote, without deleting evidence.

**SCOPE REDUCED 2026-08-31.** This plan originally carried a second defect — the global `blockingChecks` list declaring checks most repositories never produce. That fix has been **superseded** by `2026-08-28-ci-baseline-gate.md`, which solves it properly by deriving required checks from repo *shape*. The original Task 2 shrank the global list to match whatever each repo happened to run, which is bar-lowering by self-attestation. **It has been removed from this plan. Do not reinstate it.**

**Tech Stack:** TypeScript (ESM, Node 22), `node:test` + `node:assert/strict`, `@aws-sdk/client-dynamodb`, `tsx` for scripts, pnpm.

**Spec:** `docs/superpowers/zapp/specs/2026-08-28-eligibility-finality-and-blocking-checks-design.md`

## Global Constraints

- **`CI_REPORTING_GATES` is `checksGreen` and `coverageFloor` only.** Not the same as `CI_DEPENDENT_GATES`, which also holds `freezeOff` and `notBlocked`. Those two clear without a new commit but emit no `check_suite` event, so gating finality on them would strand a record as provisional forever.
- **`skipped` is not `unresolved`.** A gate skipped because the change class is unrecognised can never resolve via CI. Treating it as unresolved makes every unclassified pull request re-evaluate forever.
- **Never delete or rewrite a gate verdict in the ledger.** The stale verdicts are a true record of what the service observed. Only the computed `final` flag is corrected, and the correction is marked.
- Conventional Commits (`commitlint` runs in CI). Run `pnpm test` before every commit.

## Sequencing — read before starting

**This is the first thing to land.** As of 2026-08-31, `src/evaluate.ts:296` on zapp `main` still reads the buggy `nonCandidateFinal`, and two other pieces of work are blocked behind it:

| Blocked work | Why it waits |
|---|---|
| `2026-08-28-ci-baseline-gate.md` | Its Task 1 Step 1 refuses to proceed until this lands — gate 11's interaction with finality is not reasonable-about otherwise. |
| Any further eval-record analysis | 16 of 97 records carry a wrongly-true `final`, so the documented "filter on `final`" safeguard does not exclude them. |

The enrollment-registry work this plan used to collide with has **already landed** (zapp v2.0.0, PR #34): `evaluate` now takes `(ctx, enrollment, deps)` and `policy-rules.yaml` no longer has a `repos:` section. Nothing here touches either, so the collision is gone.

---

### Task 1: Narrow the non-candidate finality test

**Files:**
- Modify: `src/evaluate.ts:55-66` (add `CI_REPORTING_GATES`), `:290-296` (`nonCandidateFinal`)
- Modify: `tests/evaluate.test.ts` (add two tests near the existing finality block at `:190-225`)

**Interfaces:**
- Produces: `export const CI_REPORTING_GATES: ReadonlySet<GateName>` from `src/evaluate.ts`.

- [ ] **Step 1: Verify the base**

```bash
cd ~/Projects/zapp
git fetch origin
git rev-parse --abbrev-ref HEAD
git rev-list --count HEAD..origin/main
grep -n "nonCandidateFinal = " src/evaluate.ts
```

Expected: on `main` (or a branch off current `main`), `0` behind, and `nonCandidateFinal` still reading `eligibility.failedGate`. If it already reads a set of gates, this task has landed — stop and re-read.

- [ ] **Step 2: Write the failing tests**

`tests/evaluate.test.ts:212` already has a test named *"a non-candidate on checksGreen is PROVISIONAL"* whose comment describes this exact bug. It passes today, because it only covers the case where `checksGreen` is the **first** failure. The production failure had an earlier, non-CI failure in front of it. Add both of these after it:

```ts
test('a non-candidate failing a NON-CI gate first is still provisional when CI has not reported', async () => {
  // The production failure this fixes. platform-cicd-v2-demo#32 is a dep-major
  // on a sandbox repo, so `classificationPermits` (gate 9) fails FIRST — and it
  // is not CI-dependent. The old test only covered checksGreen-first, so the
  // guard read `failedGate` and stamped this `final`, which made worker.ts skip
  // every check_suite re-evaluation. The check run then reported five checks as
  // not-green forever, all five of which went green minutes later.
  const recorded: any[] = [];
  const [, risk] = await evaluate(ctx(32), riskDeps(32, {
    fetchCheckRuns: async () => [],
    recordEvaluation: async (r: any) => { recorded.push(r); },
  }) as any);

  assert.equal(recorded[0].eligibility.failedGate, 'classificationPermits',
    'the first failure is deliberately NOT a CI gate — that is the whole case');
  assert.equal(recorded[0].eligibility.gates.checksGreen.verdict, 'fail');
  assert.equal(risk!.externalId, 'provisional');
  assert.equal(recorded[0].final, false,
    'docs/policy.md tells readers to filter analysis on `final`; a wrongly-true flag defeats that filter');
});

test('a non-candidate whose CI gates were SKIPPED stays final', async () => {
  // PR #37 is a markdown-only diff, so `changeClass` fails and gates 11 and 12
  // are `skipped` — not evaluated, and unable to resolve via CI because there is
  // no recognised change class to evaluate against.
  //
  // Without this test the obvious implementation ("anything not `pass` is
  // unresolved") ships and every unclassified pull request re-evaluates on every
  // check suite, forever, changing nothing.
  const recorded: any[] = [];
  const [, risk] = await evaluate(ctx(37), riskDeps(37, {
    fetchCheckRuns: async () => [],
    recordEvaluation: async (r: any) => { recorded.push(r); },
  }) as any);

  assert.equal(recorded[0].eligibility.failedGate, 'changeClass');
  assert.equal(recorded[0].eligibility.gates.checksGreen.verdict, 'skipped');
  assert.equal(risk!.externalId, 'final');
  assert.equal(recorded[0].final, true);
});
```

If `riskDeps` does not accept overrides in the shape used above, read its definition in that file and match it — the existing test at `:212` already passes `fetchCheckRuns` and `recordEvaluation` together, so the shape is proven.

- [ ] **Step 3: Run them to verify the first fails**

```bash
pnpm exec node --import tsx --test tests/evaluate.test.ts 2>&1 | grep -A4 "NON-CI gate first"
```

Expected: the first new test FAILS with `externalId` `'final'` where `'provisional'` was expected. The second new test should already PASS — it pins behaviour that must not change.

- [ ] **Step 4: Implement**

In `src/evaluate.ts`, after the existing `CI_DEPENDENT_GATES` declaration (which stays exactly as it is — it answers a different question and Plan J exports it for the weekly report):

```ts
/**
 * Gates whose failure resolves when CI REPORTS — which is what fires
 * `check_suite: completed`, and therefore what a re-evaluation would actually
 * see.
 *
 * A strict subset of CI_DEPENDENT_GATES. `freezeOff` and `notBlocked` also
 * clear without a new commit, but lifting an SSM freeze flag or removing a
 * label emits no check-suite event — so treating them as grounds for staying
 * provisional would leave the record provisional forever, re-evaluating never.
 */
export const CI_REPORTING_GATES: ReadonlySet<GateName> = new Set<GateName>([
  'checksGreen',
  'coverageFloor',
]);
```

Then replace `nonCandidateFinal`:

```ts
  // A non-candidate waited on no risk SIGNAL, so it is final once no gate whose
  // verdict can still change on this head SHA is unresolved.
  //
  // READS EVERY CI-REPORTING GATE, not just `failedGate`. `failedGate` is only
  // the FIRST failure in GATE_ORDER, and the failure that matters here can sit
  // behind it: platform-cicd-v2-demo#32 failed `classificationPermits` (gate 9)
  // first while gates 11 and 12 were failing purely because CI had not reported
  // four seconds after the pull request opened. Reading `failedGate` alone
  // stamped that `final`, and worker.ts's already-final guard then skipped every
  // re-evaluation — freezing five checks as not-green in the check run and in
  // the ledger, all five of which went green minutes later.
  //
  // `skipped` is NOT unresolved: a gate skipped for an unrecognised change class
  // can never resolve via CI, and counting it would leave every unclassified
  // pull request re-evaluating forever.
  const nonCandidateFinal = ![...CI_REPORTING_GATES].some((gate) => {
    const verdict = eligibility.gates[gate].verdict;
    return verdict === 'fail' || verdict === 'unknown';
  });
```

- [ ] **Step 5: Run the whole suite**

```bash
pnpm test
```

Expected: PASS. Pay attention to `tests/evaluate.test.ts:190` (*"a non-candidate is final"*) and `:196` (*"a non-candidate failing a TIME-INVARIANT gate is still final"*) — both use PR #37 with `GREEN_RUNS`, so their CI gates pass or skip and they must still report `final`. If either now fails, the `skipped` handling is wrong.

- [ ] **Step 6: Commit**

```bash
git add src/evaluate.ts tests/evaluate.test.ts
git commit -m "fix(evaluate): keep a non-candidate provisional while any CI gate is unresolved

nonCandidateFinal read only eligibility.failedGate, the FIRST failure in
GATE_ORDER. A non-candidate failing a non-CI gate first was stamped final even
with checksGreen and coverageFloor failing on absence, so worker.ts's
already-final guard skipped every check_suite re-evaluation. 16 of 97 eval
records carry a wrongly-true final flag as a result."
```

---

### Task 2: Correct the `final` flag on the 16 affected records

**Files:**
- Create: `scripts/repair-final-flag.mjs`
- Create: `tests/repair-final-flag.test.ts`

**Interfaces:**
- Consumes: nothing from Tasks 1 and 2 at runtime, but **must run after Task 1 deploys** or the service will keep writing new wrong records behind it.
- Produces: `selectAffected(records)` and `buildCorrection(record, now)`, exported for testing.

- [ ] **Step 1: Confirm the population still matches**

```bash
aws sso login --profile bankrate-qa   # if the token has expired
cd /tmp && aws dynamodb scan --table-name zapp-evaluations \
  --profile bankrate-qa --region us-east-1 --output json > evals.json

jq -r '
[.Items[] | select(.sk.S|startswith("eval#"))]
| map({
    final: (if (.final|has("BOOL")) then .final.BOOL else null end),
    failedGate: (if (.failedGate|has("S")) then .failedGate.S else null end),
    cg: (.eligibility.S|fromjson|.gates.checksGreen.verdict),
    cf: (.eligibility.S|fromjson|.gates.coverageFloor.verdict)
  })
| [.[] | select(.final == true and ((.cg|IN("fail","unknown")) or (.cf|IN("fail","unknown"))))]
| "affected: \(length)"' evals.json
```

Expected: `affected: 16` (as measured 2026-08-28), or higher if more evaluations ran before Task 1 deployed. **Note `false // null` is a jq trap** — `false` is falsy to `//`, which silently turns `final: false` into `null`. The `has("BOOL")` form above avoids it; do not simplify it.

- [ ] **Step 2: Write the failing tests**

Create `tests/repair-final-flag.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { selectAffected, buildCorrection } from '../scripts/repair-final-flag.mjs';

const AT = '2026-08-28T21:00:00.000Z';

/** One eval record, already unmarshalled. */
function record(over = {}) {
  return {
    pk: 'repo#bankrate/platform-cicd-v2-demo#pr#32',
    sk: 'eval#2026-08-27T19:11:47.000Z',
    verdict: 'not-candidate',
    final: true,
    failedGate: 'classificationPermits',
    eligibility: JSON.stringify({
      verdict: 'not-candidate',
      failedGate: 'classificationPermits',
      gates: {
        classificationPermits: { verdict: 'fail' },
        checksGreen: { verdict: 'fail' },
        coverageFloor: { verdict: 'fail' },
      },
    }),
    ...over,
  };
}

test('selects a final record whose CI gates were unresolved', () => {
  assert.equal(selectAffected([record()]).length, 1);
});

test('leaves a record that is already provisional alone', () => {
  assert.equal(selectAffected([record({ final: false })]).length, 0);
});

test('leaves a record whose CI gates PASSED alone', () => {
  const r = record({
    eligibility: JSON.stringify({
      gates: {
        classificationPermits: { verdict: 'fail' },
        checksGreen: { verdict: 'pass' },
        coverageFloor: { verdict: 'pass' },
      },
    }),
  });
  assert.equal(selectAffected([r]).length, 0);
});

test('leaves a record whose CI gates were SKIPPED alone', () => {
  // Correctly final: an unrecognised change class cannot resolve via CI.
  const r = record({
    failedGate: 'changeClass',
    eligibility: JSON.stringify({
      gates: {
        changeClass: { verdict: 'fail' },
        checksGreen: { verdict: 'skipped' },
        coverageFloor: { verdict: 'skipped' },
      },
    }),
  });
  assert.equal(selectAffected([r]).length, 0);
});

test('is idempotent — an already-corrected record is not selected again', () => {
  const r = record({ final: false, finalCorrectedAt: AT });
  assert.equal(selectAffected([r]).length, 0);
});

test('the correction flips final and records that it was corrected', () => {
  const c = buildCorrection(record(), AT);

  assert.deepEqual(c.Key, {
    pk: { S: 'repo#bankrate/platform-cicd-v2-demo#pr#32' },
    sk: { S: 'eval#2026-08-27T19:11:47.000Z' },
  });
  assert.match(c.UpdateExpression, /SET #final = :f/);
  assert.deepEqual(c.ExpressionAttributeValues[':f'], { BOOL: false });
  assert.deepEqual(c.ExpressionAttributeValues[':at'], { S: AT });
  assert.match(c.ExpressionAttributeValues[':why'].S, /first failing gate/);
});

test('the correction NEVER touches the gate verdicts', () => {
  const c = buildCorrection(record(), AT);

  // The stale verdicts are a true record of what the service observed. Only the
  // computed flag was wrong; rewriting the evidence would destroy the audit.
  assert.equal(c.UpdateExpression.includes('eligibility'), false);
  assert.equal(Object.keys(c.ExpressionAttributeValues).includes(':eligibility'), false);
});

test('the correction is conditional on final still being true', () => {
  const c = buildCorrection(record(), AT);
  assert.match(c.ConditionExpression, /#final = :expected/);
  assert.deepEqual(c.ExpressionAttributeValues[':expected'], { BOOL: true });
});
```

- [ ] **Step 3: Run to verify they fail**

```bash
pnpm exec node --import tsx --test tests/repair-final-flag.test.ts
```

Expected: FAIL — `scripts/repair-final-flag.mjs` does not exist.

- [ ] **Step 4: Write the script**

Create `scripts/repair-final-flag.mjs`:

```js
#!/usr/bin/env node
// One-off: correct the `final` flag on eval records written before
// `nonCandidateFinal` was narrowed to read every CI-reporting gate.
//
// WHY IT EXISTS: `final` is what docs/policy.md tells readers to filter Phase 1
// analysis on — the field exists to exclude evaluations made on incomplete
// inputs. A wrongly-true flag sails straight through that filter, so the
// safeguard fails silently on exactly the records it exists to catch.
//
// WHAT IT DOES NOT DO, and both are deliberate:
//
//   * It does not touch the gate verdicts. `checksGreen: fail` at 18:28:35Z is
//     a TRUE record of what the service observed four seconds after the pull
//     request opened. Rewriting it would destroy evidence; `final: false` is
//     what tells analysis to exclude the record.
//
//   * It does not delete anything, and it does not re-evaluate. The ledger is
//     append-only (sk = eval#<ISO>), so a re-evaluation adds a record rather
//     than replacing one. Forward-only re-evaluation after the fix deploys is
//     enough; the corrected flag is what makes the EXISTING corpus analysable.
//
// Every corrected record carries `finalCorrectedAt` and
// `finalCorrectionReason`, so a repaired flag is distinguishable from an
// originally-computed one. A silent flip would leave the corpus
// indistinguishable from one that never had the bug, which is worse than the
// bug.
//
// DRY-RUN BY DEFAULT, unlike scripts/backfill-outcomes.mjs. That script only
// ever adds rows under attribute_not_exists, so it cannot damage anything; this
// one MUTATES existing evidence, which earns the opposite default.
//
// USAGE:
//   EVALUATIONS_TABLE=zapp-evaluations \
//     node --import tsx scripts/repair-final-flag.mjs           # dry run
//   EVALUATIONS_TABLE=zapp-evaluations \
//     node --import tsx scripts/repair-final-flag.mjs --apply
import { DynamoDBClient, ScanCommand, UpdateItemCommand } from '@aws-sdk/client-dynamodb';
import { unmarshall } from '@aws-sdk/util-dynamodb';

const REASON =
  'PLAT-1184: nonCandidateFinal read only the first failing gate, so checksGreen '
  + 'and/or coverageFloor were unresolved at evaluation time while the record was '
  + 'stamped final. Gate verdicts are unchanged.';

/** Gates whose failure resolves when CI reports. Mirrors src/evaluate.ts. */
const CI_REPORTING_GATES = ['checksGreen', 'coverageFloor'];

/**
 * Which records carry a wrongly-true `final`.
 *
 * `skipped` is deliberately not unresolved: a gate skipped for an unrecognised
 * change class can never resolve via CI, so those records are correctly final.
 *
 * Idempotent: an already-corrected record has `final: false` and fails the
 * first test.
 */
export function selectAffected(records) {
  return records.filter((r) => {
    if (r.final !== true) return false;

    let gates;
    try {
      gates = JSON.parse(r.eligibility).gates ?? {};
    } catch {
      return false;
    }

    return CI_REPORTING_GATES.some((gate) => {
      const verdict = gates[gate]?.verdict;
      return verdict === 'fail' || verdict === 'unknown';
    });
  });
}

/**
 * The keyed, conditional correction for one record.
 *
 * `final` is a reserved-ish name in expressions, so it rides an attribute-name
 * placeholder. The condition means a concurrent write cannot be clobbered and a
 * re-run is a no-op rather than a second correction.
 */
export function buildCorrection(record, now) {
  return {
    Key: { pk: { S: record.pk }, sk: { S: record.sk } },
    UpdateExpression: 'SET #final = :f, finalCorrectedAt = :at, finalCorrectionReason = :why',
    ConditionExpression: '#final = :expected',
    ExpressionAttributeNames: { '#final': 'final' },
    ExpressionAttributeValues: {
      ':f': { BOOL: false },
      ':expected': { BOOL: true },
      ':at': { S: now },
      ':why': { S: REASON },
    },
  };
}

async function main() {
  const table = process.env.EVALUATIONS_TABLE;
  if (!table) {
    console.error('EVALUATIONS_TABLE is required.');
    process.exit(1);
  }

  const apply = process.argv.includes('--apply');
  const client = new DynamoDBClient({});

  const records = [];
  let startKey;
  do {
    const res = await client.send(new ScanCommand({
      TableName: table,
      ...(startKey ? { ExclusiveStartKey: startKey } : {}),
    }));
    for (const item of res.Items ?? []) {
      const r = unmarshall(item);
      if (typeof r.sk === 'string' && r.sk.startsWith('eval#')) records.push(r);
    }
    startKey = res.LastEvaluatedKey;
  } while (startKey !== undefined);

  const affected = selectAffected(records);
  const now = new Date().toISOString();

  console.log(`scanned ${records.length} eval records, ${affected.length} affected`);
  for (const r of affected) {
    console.log(`  ${r.repo}#${r.prNumber}  ${r.sk}  failedGate=${r.failedGate}`);
  }

  if (!apply) {
    console.log('\nDRY RUN. Re-run with --apply to write.');
    return;
  }

  let corrected = 0;
  for (const r of affected) {
    try {
      await client.send(new UpdateItemCommand({
        TableName: table,
        ...buildCorrection(r, now),
      }));
      corrected += 1;
    } catch (err) {
      if (err?.name === 'ConditionalCheckFailedException') {
        console.log(`  skipped ${r.sk} — already corrected or changed concurrently`);
        continue;
      }
      throw err;
    }
  }

  console.log(`\ncorrected ${corrected} of ${affected.length}.`);
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
```

- [ ] **Step 5: Run the tests**

```bash
pnpm test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/repair-final-flag.mjs tests/repair-final-flag.test.ts
git commit -m "feat(scripts): correct the final flag on records written before the finality fix"
```

- [ ] **Step 7: Dry-run, then apply — only after Task 1 has deployed**

Applying before Task 1 deploys corrects records the running service will immediately write more of.

```bash
cd ~/Projects/zapp
EVALUATIONS_TABLE=zapp-evaluations aws-vault exec bankrate-qa -- \
  node --import tsx scripts/repair-final-flag.mjs
```

Expected: `16 affected`, listing `platform-cicd-v2-demo#32` (×12), `portkey#108` (×3), `portkey#110` (×1). Read the list before applying.

```bash
EVALUATIONS_TABLE=zapp-evaluations aws-vault exec bankrate-qa -- \
  node --import tsx scripts/repair-final-flag.mjs --apply
```

Then re-run the dry run. Expected: `0 affected` — that is the idempotence check.

---

### Task 3: Verify the fix on a live pull request

The one thing no unit test can prove: that a real re-evaluation now happens and overwrites the stale check run.

- [ ] **Step 1: Confirm both fixes are deployed**

```bash
cd ~/Projects/zapp
gh run list --workflow deploy-v2.yml --limit 3 --json conclusion,headSha,createdAt \
  --jq '.[] | "\(.createdAt) \(.conclusion) \(.headSha[0:8])"'
git log --oneline origin/main -3
```

- [ ] **Step 2: Trigger a fresh evaluation**

Pick an open dependabot pull request on `platform-cicd-v2-demo` or `portkey` and comment on it, or close-and-reopen it — both emit a routed `pull_request` event. Do **not** force a webhook redelivery: `src/deliveries.ts` holds a 7-day confirmation TTL, so a redelivery is rejected as a duplicate.

Record the head SHA and the time.

- [ ] **Step 3: Watch for the re-evaluation**

Immediately after the event, the eligibility check should report `checksGreen` failing on absence and the risk check should carry `external_id: provisional` — **that is the fix working**, not a regression. Then as each check suite completes, the check run should update.

```bash
R=platform-cicd-v2-demo; SHA=<head sha>
watch -n 20 "gh api repos/bankrate/\$R/commits/\$SHA/check-runs \
  --jq '.check_runs[] | select(.app.slug==\"neutral-planet\") \
        | \"\(.name) \(.external_id // \"-\") completed=\(.completed_at)\"'"
```

Expected: `completed_at` on `merge-policy/*` advances past the last CI check's `completed_at`, and `external_id` settles on `final`. Before this fix it froze at the first evaluation.

- [ ] **Step 4: Confirm in the ledger**

```bash
aws dynamodb query --table-name zapp-evaluations --profile bankrate-qa --region us-east-1 \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"repo#bankrate/platform-cicd-v2-demo#pr#<N>"}}' \
  --query 'Items[].{sk:sk.S,final:final.BOOL,failedGate:failedGate.S,trigger:trigger.S}' --output table
```

Expected: at least two new records — an early one with `final=false` and `trigger=pull_request`, and a later one with `trigger=check_suite` whose `checksGreen` has resolved. **Two records rather than one overwritten is correct**: the ledger is append-only, and the pair is the audit trail of the evaluation converging.

- [ ] **Step 5: Confirm the loosening landed**

```bash
cd /tmp && aws dynamodb scan --table-name zapp-evaluations \
  --profile bankrate-qa --region us-east-1 --output json > after.json
jq -r '[.Items[]|select(.sk.S|startswith("eval#"))]
  | group_by(if (.failedGate|has("S")) then .failedGate.S else "none (candidate)" end)
  | map("\(.[0]|if (.failedGate|has("S")) then .failedGate.S else "none (candidate)" end): \(length)")|.[]' after.json
```

Compare against the 2026-08-28 baseline:

```
none (candidate): 12    botAllowlisted: 5    changeClass: 17
checksGreen: 34         classificationPermits: 24    conventionalTitle: 5
```

Expected direction: records that were wrongly `final` become provisional and then resolve, so `checksGreen`'s *gate-verdict* count falls as stale evidence is replaced by fresh evidence.

**`checksGreen` will remain the top `failedGate` after this plan, and that is correct** — it is unpassable on 7 of 8 repos because the global list declares checks they never produce. That is the separate defect, and `2026-08-28-ci-baseline-gate.md` fixes it. Do not treat an unchanged `failedGate: checksGreen` count as this plan failing.

---

### Task 4: Update the docs

**Files:**
- Modify: `docs/policy.md` (gate 11's description, and the `final` filtering guidance)
- Modify: `docs/architecture.md` (the finality and already-final-guard prose)
- Modify: `AGENTS.md` (a sharp-edge entry)

- [ ] **Step 1: Document the finality rule where it is asserted**

Find and correct every place that describes finality in terms of the first failing gate:

```bash
cd ~/Projects/zapp
grep -rn "failedGate\|already.final\|nonCandidateFinal\|CI_DEPENDENT" docs/ AGENTS.md README.md
```

`docs/architecture.md`'s evaluator section and `docs/policy.md`'s note on filtering by `final` both need the narrower rule: a non-candidate is final once no **CI-reporting** gate is unresolved, and `skipped` does not count as unresolved.

- [ ] **Step 2: Document gate 11's new shape in `docs/policy.md`**

Gate 11's row should say that the blocking list is the repository's own when it declares one, that a per-repo list replaces rather than extends the global one, and that only checks a repository produces on **every** pull request belong in either list — because absence fails closed.

- [ ] **Step 3: Add the sharp edge to `AGENTS.md`**

```markdown
- `nonCandidateFinal` in `src/evaluate.ts` must read EVERY gate in
  `CI_REPORTING_GATES`, not `eligibility.failedGate`. `failedGate` is only the
  first failure in `GATE_ORDER`, and the CI-dependent failure that decides
  finality can sit behind a non-CI one — which is how 16 eval records ended up
  stamped `final` with `checksGreen` failing on absence, permanently skipping
  the `check_suite` re-evaluation in `worker.ts`. `skipped` is not unresolved:
  counting it would leave every unclassified pull request re-evaluating forever.
```

- [ ] **Step 4: Commit**

```bash
git add docs/ AGENTS.md
git commit -m "docs: record the narrowed finality rule and the blocking-check selection rule"
```

---

## Self-review notes

**Spec coverage.** The finality defect → Task 1. The record repair → Task 2. Live verification of the one property no unit test can reach → Task 3. Docs → Task 4.

The spec's second defect (`blockingChecks` declaring unproduced checks) and its out-of-scope items (the retroactive-enrollment sweep, `RECORDED_FIELDS`) have no task here. The second defect moved to `2026-08-28-ci-baseline-gate.md`; the spec's Defect 2 section is retained as history and its proposed fix is **superseded** — read that section for the measurement, not for the remedy.

**Task independence.** Task 1 is self-contained. Task 2's *script* is independent but its **application must follow Task 1's deploy**, or the running service keeps writing new wrong records behind it. Task 3 needs both.

**Task 3 is verification, not construction**, so it is deliberately not TDD.

**Type consistency.** `CI_REPORTING_GATES` is defined once in `src/evaluate.ts` and exported, and Task 2's script mirrors it as a plain array with a comment naming the source — duplicating two strings is cheaper than coupling a throwaway `.mjs` to the module's export surface. The CI-baseline plan imports the same export rather than redefining it.
