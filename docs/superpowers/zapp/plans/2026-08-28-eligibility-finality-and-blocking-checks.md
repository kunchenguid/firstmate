# Eligibility Finality and Blocking-Check Alignment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop zapp marking an evaluation `final` while CI-dependent gates are still unresolved, and stop `checksGreen` being unpassable on repositories that never produce the checks it declares.

**Architecture:** Two independent fixes that present as one symptom. The first narrows the non-candidate finality test from "was the *first* failing gate CI-dependent" to "is *any* CI-reporting gate unresolved", which lets `worker.ts`'s already-final guard open for the re-evaluation it was designed to allow. The second moves non-universal check names out of the global `blockingChecks` list into per-repo overrides, so absence-fails-closed stops firing on checks a repository was never going to run. A one-off script then corrects the `final` flag on the 16 records the first defect already wrote, without deleting evidence.

**Tech Stack:** TypeScript (ESM, Node 22), `node:test` + `node:assert/strict`, `@aws-sdk/client-dynamodb`, `tsx` for scripts, pnpm.

**Spec:** `docs/superpowers/zapp/specs/2026-08-28-eligibility-finality-and-blocking-checks-design.md`

## Global Constraints

- **`CI_REPORTING_GATES` is `checksGreen` and `coverageFloor` only.** Not the same as `CI_DEPENDENT_GATES`, which also holds `freezeOff` and `notBlocked`. Those two clear without a new commit but emit no `check_suite` event, so gating finality on them would strand a record as provisional forever.
- **`skipped` is not `unresolved`.** A gate skipped because the change class is unrecognised can never resolve via CI. Treating it as unresolved makes every unclassified pull request re-evaluate forever.
- **Only declare a blocking check a repository produces on EVERY pull request.** Gate 11 fails closed on absence, so a conditionally-produced check (path-filtered workflow, `paths-ignore`, manual dispatch) can never be safely blocking. This is the selection rule for every override below.
- **A per-repo `blockingChecks` list REPLACES the global one — it never merges** (`src/enrollment.ts`'s `signalChecksFor` doc, same semantic). Every override must restate the Cycode contexts.
- **Never delete or rewrite a gate verdict in the ledger.** The stale verdicts are a true record of what the service observed. Only the computed `final` flag is corrected, and the correction is marked.
- Conventional Commits (`commitlint` runs in CI). Run `pnpm test` before every commit.

## Sequencing — read before starting

This work touches two files that PLAT-1188's zapp plan also modifies:

| This plan | Collides with |
|---|---|
| `src/evaluate.ts` (Task 1) | `2026-08-28-enrollment-registry-zapp.md` **Task 5** |
| `policy-rules.yaml` `repos[]` (Task 2) | that plan's **Task 6**, which deletes the `repos:` section |

**Land this first, before the enrollment plan reaches its Task 5.** It is small, independently valuable, and enrolling more repositories on top of an unpassable `checksGreen` would scale a broken measurement.

If the enrollment plan has already passed its Task 6, Task 2 below moves the per-repo overrides into the `zapp-enrollments` table's `blockingChecks` attribute instead — same values, different store — and that plan's seed script must carry them.

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

### Task 2: Realign `blockingChecks` with what repositories actually produce

**Files:**
- Modify: `policy-rules.yaml` (the global `blockingChecks` list, and three `repos[]` entries)
- Modify: `tests/build-rules.test.ts` (one acceptance case; see Step 3)
- **No change to `tests/gates.test.ts`** — `:243` and `:269` already pin both halves of the behaviour

**Interfaces:**
- Consumes: nothing from Task 1. These two tasks are independent and can be done in either order.

- [ ] **Step 1: Re-verify the measurement before changing policy**

The overrides below come from sampling one recent pull request per enrolled repository. Confirm it, because a wrong list here makes the gate *looser* than intended:

```bash
cd ~/Projects
for r in platform-cicd-v2-demo conductor conductor-api portkey zapp \
         brand-identity-pages-app redirect-management-api-v2 crank; do
  sha=$(gh pr list --repo bankrate/$r --state all --limit 1 --json headRefOid --jq '.[0].headRefOid')
  names=$(gh api "repos/bankrate/$r/commits/$sha/check-runs" --jq '[.check_runs[].name]|join("|")')
  row=""
  for c in "Cycode: SAST" "Cycode: Secrets" "Cycode: Vulnerable Dependencies" \
           "Build and scan image" "Terraform plan (speculative)"; do
    case "$names" in *"$c"*) row="$row yes";; *) row="$row  --";; esac
  done
  printf "  %-34s%s\n" "$r" "$row"
done
```

Expected, as measured on 2026-08-28:

```
  platform-cicd-v2-demo             yes yes yes yes yes
  conductor                         yes yes yes  --  --
  conductor-api                     yes yes yes yes  --
  portkey                           yes yes yes yes  --
  zapp                              yes yes yes  --  --
  brand-identity-pages-app          yes yes yes  --  --
  redirect-management-api-v2        yes yes yes  --  --
  crank                             yes yes yes  --  --
```

**Then check whether each non-universal check is produced on EVERY pull request, not just the sampled one.** A path-filtered workflow produces the check sometimes, and a sometimes-check can never be safely blocking under fail-closed semantics:

```bash
for r in conductor-api portkey platform-cicd-v2-demo; do
  echo "--- bankrate/$r"
  gh pr list --repo bankrate/$r --state all --limit 6 --json number,headRefOid \
    --jq '.[] | "\(.number) \(.headRefOid)"' | while read -r n sha; do
    has=$(gh api "repos/bankrate/$r/commits/$sha/check-runs" \
      --jq '[.check_runs[].name] | (index("Build and scan image") != null)')
    echo "  PR #$n  Build and scan image: $has"
  done
done
```

**If any repository shows `false` on a pull request, drop that check from its override.** A check that only appears when a Dockerfile changes would fail gate 11 on every dependency bump — the exact class of pull request this service exists to evaluate.

- [ ] **Step 2: Confirm the mechanism is already tested — add nothing that duplicates it**

**Do not write new gate tests for this.** Both halves of the behaviour this task
relies on are already pinned in `tests/gates.test.ts`:

| Line | Test | What it proves |
|---|---|---|
| `:243` | *"a MISSING blocking check fails gate 11 — absence is not green"* | Why the override is necessary rather than cosmetic |
| `:269` | *"a per-repo blockingChecks override replaces the global list"* | A repo declaring only `Cycode: SAST` passes gate 11 with only that check present — "the other four are not required here" |

Together those are exactly the defect and exactly the fix. **The override
mechanism is tested and works; it is simply unused in configuration.** That is
what makes this task a config change rather than a code change, and adding a
third test asserting the same thing would be noise.

Run them to confirm they pass on the current tree before touching policy:

```bash
cd ~/Projects/zapp
pnpm exec node --import tsx --test tests/gates.test.ts 2>&1 | grep -E "MISSING blocking|override replaces"
```

Expected: both PASS. **If either fails, stop** — the mechanism this whole task
depends on is broken, and moving the configuration onto it would be unsafe.

- [ ] **Step 3: Add the one genuinely missing validation test**

`tests/build-rules.test.ts:243` already rejects a per-repo `blockingChecks`
containing a non-string. Nothing asserts that a *valid* per-repo list is
accepted — and this task is about to add three of them, so the build failing on
them would be discovered at deploy time rather than in the suite. Add beside it:

```ts
test('a per-repo blockingChecks override of only the universal checks validates', () => {
  const doc = validDoc();
  doc.repos[0].blockingChecks = ['Cycode: SAST', 'Cycode: Secrets', 'Cycode: Vulnerable Dependencies'];
  assert.deepEqual(validatePolicy(doc), []);
});
```

```bash
pnpm exec node --import tsx --test tests/build-rules.test.ts
```

Expected: PASS — `validatePolicy` already accepts an array of strings here. This
test documents a guarantee the config now depends on rather than fixing a defect.

- [ ] **Step 4: Change the global list**

In `policy-rules.yaml`, replace the `blockingChecks` block:

```yaml
  # Must be GREEN for a pull request to be a candidate.
  #
  # ONLY UNIVERSALLY-PRODUCED CHECKS BELONG HERE. Gate 11 fails closed on an
  # absent check — correctly, since "this repo does not run it" is
  # indistinguishable from "it has not run yet" without a per-repo declaration.
  # So a name declared here that a repository never produces makes checksGreen
  # UNPASSABLE on that repository, permanently.
  #
  # That is what happened: `Build and scan image` (3 of 8 enrolled repos) and
  # `Terraform plan (speculative)` (1 of 8) were declared globally, which closed
  # the eligibility funnel on 7 of 8 repos and made the shadow phase measure
  # which repositories have a job with a particular name. Both moved to per-repo
  # overrides below. Measured 2026-08-28.
  #
  # The three Cycode contexts are produced by all eight enrolled repositories.
  #
  # DISTINCT FROM signalChecks above, which decides when the RISK grade is
  # final. These lists overlap on the Cycode contexts because both care about
  # scanners, not because they are the same question: this one asks "may we
  # automate this at all", the other "have our inputs arrived".
  blockingChecks:
    - "Cycode: SAST"
    - "Cycode: Secrets"
    - "Cycode: Vulnerable Dependencies"
```

- [ ] **Step 5: Add the per-repo overrides**

A per-repo list **replaces** the global one, so each override restates the Cycode contexts. On the `platform-cicd-v2-demo` entry:

```yaml
  - repo: bankrate/platform-cicd-v2-demo
    classification: sandbox
    ciTrustTier: 2
    mode: shadow
    stageEnabled: false
    # REPLACES the global list, never extends it — so the Cycode contexts are
    # restated. The only enrolled repo that produces all five.
    blockingChecks:
      - "Cycode: SAST"
      - "Cycode: Secrets"
      - "Cycode: Vulnerable Dependencies"
      - "Build and scan image"
      - "Terraform plan (speculative)"
```

On `conductor-api` and `portkey`, the same block without the Terraform line:

```yaml
    # Produces an image scan but no speculative plan under that job name.
    blockingChecks:
      - "Cycode: SAST"
      - "Cycode: Secrets"
      - "Cycode: Vulnerable Dependencies"
      - "Build and scan image"
```

**Leave `conductor`, `zapp`, `brand-identity-pages-app`, `redirect-management-api-v2` and `crank` with no override** — they inherit the three Cycode contexts, which is exactly what they produce.

`zapp` contains the string `Terraform plan (speculative)` in its own workflows but did not produce the check on the sampled pull request. Do **not** add an override for it on the strength of a grep: an omitted check makes the gate looser, which is visible in the weekly report and safe in shadow mode, whereas a wrongly-declared one silently closes the funnel again. Note it for follow-up instead.

- [ ] **Step 6: Build, test, commit**

```bash
pnpm build && pnpm test
grep -c "blockingChecks" src/generated/rules.ts
```

Expected: PASS, and 4 occurrences in the generated file (one global, three per-repo).

```bash
git add policy-rules.yaml src/generated/rules.ts tests/gates.test.ts tests/build-rules.test.ts
git commit -m "fix(policy): declare only universally-produced checks as globally blocking

Build and scan image (3 of 8 enrolled repos) and Terraform plan (speculative)
(1 of 8) were declared globally. Gate 11 fails closed on absence, so checksGreen
was unpassable on 7 of 8 repos regardless of the pull request. Both move to
per-repo overrides. This is a policy loosening: candidate counts will rise."
```

- [ ] **Step 7: Say so out loud**

This is a **policy loosening**, not a silent bug fix. Before it deploys, tell the captain in one line that candidate counts and the risk corpus will both grow, and that a jump in the next weekly report is the intended outcome rather than a regression to investigate.

---

### Task 3: Correct the `final` flag on the 16 affected records

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

### Task 4: Verify the fix on a live pull request

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

Expected direction: `checksGreen` falls, `none (candidate)` rises. If `checksGreen` has not moved after several evaluations across `conductor`, `crank` or `brand-identity-pages-app`, Task 2's override list is wrong for those repos — re-run Task 2 Step 1.

---

### Task 5: Update the docs

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
- A check name in `blockingChecks` that a repository does not produce on EVERY
  pull request makes gate 11 unpassable there, because absence fails closed.
  Only universally-produced checks belong in the global list; everything else
  is a per-repo override, and an override REPLACES the global list rather than
  extending it.
```

- [ ] **Step 4: Commit**

```bash
git add docs/ AGENTS.md
git commit -m "docs: record the narrowed finality rule and the blocking-check selection rule"
```

---

## Self-review notes

**Spec coverage.** Defect 1 → Task 1. Defect 2 → Task 2. The record repair → Task 3. Live verification of the one property no unit test can reach → Task 4. Docs → Task 5. The spec's out-of-scope items (the retroactive-enrollment sweep, `RECORDED_FIELDS`) have no task here, deliberately.

**Task independence.** Tasks 1 and 2 are independent and can be done in either order or in parallel — Task 1 touches `src/evaluate.ts` and `tests/evaluate.test.ts`; Task 2 touches `policy-rules.yaml`, `tests/gates.test.ts` and `tests/build-rules.test.ts`. Task 3's *script* is independent but its **application must follow Task 1's deploy**, and Task 4 needs both.

**Two tasks are not TDD, and that is correct.** Task 2 is a configuration change against a mechanism that is already tested — `tests/gates.test.ts:243` ("absence is not green") and `:269` ("an override replaces the global list") are precisely the defect and the fix, and they pass today. So Task 2 writes **no new gate tests**; an earlier draft of this plan proposed two that duplicated those exactly. Its Step 2 runs the existing pair as a gate and says to stop if either fails, since that would mean the mechanism the config move relies on is broken. The single test it does add is a `build-rules` acceptance case, because nothing currently asserts that a *valid* per-repo list validates, and this task adds three. Task 4 is verification, not construction.

**One measurement to re-run rather than trust.** Task 2's override lists come from sampling one pull request per repository on 2026-08-28. Step 1 re-runs it and adds the check that matters more — whether each non-universal check appears on *every* pull request, not just the sampled one. A path-filtered image scan declared as blocking would fail gate 11 on every dependency bump, which is the exact population this service evaluates.

**Type consistency.** `CI_REPORTING_GATES` is defined once in `src/evaluate.ts` and exported, and Task 3's script mirrors it as a plain array with a comment naming the source — a `.mjs` one-off importing a TypeScript source would need `tsx`, which it already requires, but duplicating two strings is cheaper than coupling a throwaway script to the module's export surface.
