# Weekly shadow report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the decision ledger a read path. A weekly Slack post that leads with the exit criterion — did any would-have-approved pull request get reverted — and shows the gate-failure breakdown, per-signal `unknown` rates, and per-recorder coverage, so a broken recorder surfaces as a number somebody reads rather than as an absence nobody notices.

**Architecture:** A scheduled GitHub Actions workflow in `bankrate/zapp`, not a Lambda branch. It assumes a new **read-only** OIDC role, queries a week of `zapp-evaluations`, archives the aggregate to S3 as JSON, then posts to Slack. Rendering is defensive throughout: a ledger record missing a field a later spec added renders as "not recorded", never as zero.

**Tech Stack:** TypeScript (ESM, `node22` target) run under `tsx`, Node's built-in test runner, `@aws-sdk/client-dynamodb`, `@aws-sdk/client-s3`, GitHub Actions, Terraform, Slack incoming webhooks.

## Before you start

**This plan is parallel-safe with F, G and H.** It writes no application logic those specs touch and renders fields defensively rather than assuming a schema, so it can be built and merged at any point in the sequence. It reads whatever exists and says "not recorded" for the rest.

It does **not** require Spec G or H to be merged. Sections that depend on their fields simply render as not-recorded until they land — which is itself the behaviour Task 4 tests.

**Spec:** [`../specs/2026-08-26-weekly-shadow-report-design.md`](../specs/2026-08-26-weekly-shadow-report-design.md)

## Global Constraints

- **The Lambda is untouched.** `src/index.ts` still routes exactly two ways. If this implementation edits the dispatch or the function timeout, it took the wrong path — see "Not in the Lambda" in the spec.
- **The OIDC role is read-only.** `dynamodb:Query`/`Scan` on the evaluations table and `s3:PutObject` on the archive prefix. Nothing that can deploy, write to the ledger, or change the service.
- **Absent is never zero.** A field a later spec added, missing from an older record, renders "not recorded". Rendering it as `0` or `false` would make a recorder that never ran look like one that ran and found nothing.
- **A missing `SLACK_REPORT_WEBHOOK` fails the run.** Never skip the post silently — a report that quietly stops being delivered is the exact failure this whole spec exists to catch.
- **A week with no evaluations still posts.** A silent week is indistinguishable from a broken schedule.
- **The S3 artifact is written before the Slack post.** If Slack fails, the week's aggregate still survives.
- **Post-merge failures are shown separately from reverts,** never summed into one "things went wrong" number, with the attribution rule stated beside the count.
- **The headline counts live records only.** Backfilled merges (Spec H) were never evaluated, so they can neither corroborate nor refute a verdict that does not exist.

## Human setup step you cannot do from code

The report posts to **`#bankrate-platform-notifications`** (`C081N1H2P5K`), which is a **private** channel.

The org secret `SLACK_WEBHOOK` will not work: an incoming webhook is bound to one channel at creation, and that one is the generic deploy-notification hook. This needs a **repository** secret on `bankrate/zapp` named `SLACK_REPORT_WEBHOOK`, created from a webhook bound to that channel.

Two wrinkles, both requiring somebody with Slack workspace access:

- A webhook can post to a private channel, but it must be created by somebody who is **in** that channel, and the owning Slack app has to be added to it.
- Make it a **repository** secret, not an org one. Org secrets are visible to every repository that inherits them; this webhook needs to exist in exactly one place.

**Do not block on this to start.** Tasks 1–5 are testable without it; Task 7 is where it is needed. Flag it early so it can be requested in parallel.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/report/query.ts` | Read a week of evaluations and outcomes; aggregate into a plain object. No rendering, no I/O beyond DynamoDB. |
| `src/report/render.ts` | Turn the aggregate into Slack Block Kit and into the JSON artifact. Pure. |
| `src/report/index.ts` | Entry point: query, archive, post. The only file that knows about S3 or Slack. |
| `.github/workflows/weekly-report.yml` | Schedule, OIDC assume, run. |
| `infrastructure/terraform/report.tf` | The S3 bucket and the read-only OIDC role. |

`src/report/` is a directory rather than one file because querying, aggregating
and rendering are independently testable and the rendering will change far more
often than the querying.

---

## Task 1: Aggregate a week of the ledger

**Files:**
- Create: `src/report/query.ts`, `tests/report-query.test.ts`
- Create: `tests/fixtures/ledger-week.json`

**Interfaces:**
- Produces: `WeeklyAggregate`, `aggregate(records)`, `weekStart(now)`, `fetchWeek(tableName, since, send?)` from `src/report/query.ts`.

- [ ] **Step 1: Write the fixture**

Create `tests/fixtures/ledger-week.json` — a hand-written array of ledger
records in the shape `recordEvaluation` writes, **deliberately mixed vintages**:

```json
[
  {
    "pk": "repo#bankrate/platform-cicd-v2-demo#pr#27",
    "sk": "eval#2026-08-24T10:00:00Z",
    "repo": "bankrate/platform-cicd-v2-demo",
    "prNumber": 27,
    "headSha": "f00d42",
    "rulesSha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "verdict": "candidate",
    "changeClass": "dep-minor",
    "failedGate": null,
    "final": true,
    "riskGrade": "medium",
    "risk": {
      "grade": "medium",
      "signalsGraded": 6,
      "signals": {
        "semverDistance": { "grade": "medium", "value": "minor" },
        "publishAge": { "grade": "low", "value": { "youngestDays": 11, "package": "pg" } },
        "targetVersionHealth": { "grade": "low", "value": { "checked": 7, "advised": [], "deprecated": [] } },
        "closesFinding": { "grade": "unknown", "value": null, "reason": "Dependabot alerts are disabled for this repository" },
        "newFindings": { "grade": "low", "value": { "failed": 0, "checked": 3 } },
        "coverageDelta": { "grade": "low", "value": { "deltaPct": 0, "currentPct": 62.99 } },
        "depType": { "grade": "medium", "value": { "production": 6, "development": 1 } }
      }
    },
    "adoption": { "package": "fastify", "version": "5.12.0", "dependentCount": 25, "directDependentCount": 11 },
    "provenance": [
      { "package": "jose", "from": "^6.2.8", "to": "^6.2.9", "fromHadProvenance": true, "toHasProvenance": true, "lost": false }
    ]
  },
  {
    "pk": "repo#bankrate/platform-cicd-v2-demo#pr#32",
    "sk": "eval#2026-08-25T09:00:00Z",
    "repo": "bankrate/platform-cicd-v2-demo",
    "prNumber": 32,
    "verdict": "not-candidate",
    "changeClass": "dep-major",
    "failedGate": "classificationPermits",
    "final": true,
    "riskGrade": null
  },
  {
    "pk": "repo#bankrate/platform-cicd-v2-demo#pr#33",
    "sk": "eval#2026-08-25T11:00:00Z",
    "repo": "bankrate/platform-cicd-v2-demo",
    "prNumber": 33,
    "verdict": "not-candidate",
    "changeClass": "dep-patch",
    "failedGate": "checksGreen",
    "final": false
  },
  {
    "pk": "repo#bankrate/platform-cicd-v2-demo#pr#27",
    "sk": "outcome#2026-08-24T12:00:00Z",
    "repo": "bankrate/platform-cicd-v2-demo",
    "prNumber": 27,
    "outcome": "merged",
    "headSha": "f00d42",
    "backfilled": false
  },
  {
    "pk": "repo#bankrate/other#pr#5",
    "sk": "eval#2026-08-23T08:00:00Z",
    "repo": "bankrate/other",
    "prNumber": 5,
    "verdict": "candidate",
    "changeClass": "dep-patch",
    "failedGate": null,
    "final": true,
    "riskGrade": "low"
  },
  {
    "pk": "repo#bankrate/other#pr#5",
    "sk": "outcome#2026-08-23T09:00:00Z",
    "repo": "bankrate/other",
    "prNumber": 5,
    "outcome": "reverted",
    "headSha": "beef01",
    "backfilled": false
  }
]
```

Note what this fixture deliberately contains: a would-have-approved pull request
that was **reverted** (the headline must say yes), a candidate that merged
cleanly, three distinct gate failures, one permanently-`unknown` signal, and
records with **no** `adoption` or `provenance` fields at all — the pre-Spec-F
vintage the defensive-rendering test needs.

- [ ] **Step 2: Write the failing test**

Create `tests/report-query.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { aggregate, weekStart } from '../src/report/query.js';

const week = JSON.parse(readFileSync('tests/fixtures/ledger-week.json', 'utf8'));

test('the headline is whether a would-have-approved PR was reverted', () => {
  // THE assertion of this file. A report that says "no reverts" because the
  // join silently failed is worse than no report at all.
  const a = aggregate(week);
  assert.equal(a.headline.anyApprovedReverted, true);
  assert.deepEqual(a.headline.reverted, [
    { repo: 'bankrate/other', prNumber: 5 },
  ]);
});

test('a revert of a NON-candidate does not trip the headline', () => {
  const notCandidateReverted = week.map((r: any) =>
    r.pk === 'repo#bankrate/other#pr#5' && r.sk.startsWith('eval#')
      ? { ...r, verdict: 'not-candidate', failedGate: 'size' }
      : r);
  assert.equal(aggregate(notCandidateReverted).headline.anyApprovedReverted, false);
});

test('would-have-approved rate is counted per repo and overall', () => {
  const a = aggregate(week);
  assert.equal(a.overall.evaluations, 4);
  assert.equal(a.overall.candidates, 2);
  assert.equal(a.byRepo['bankrate/platform-cicd-v2-demo']!.candidates, 1);
});

test('gate failures are ranked, most blocking first', () => {
  // The direct input to Phase 1 threshold tuning: which rule is doing work and
  // which is just failing everything.
  const doubled = [...week, ...week.filter((r: any) => r.failedGate === 'checksGreen')];
  const a = aggregate(doubled);
  assert.equal(a.gateFailures[0]!.gate, 'checksGreen');
  assert.equal(a.gateFailures[0]!.count, 2);
});

test('per-signal unknown rates are counted', () => {
  // A signal unknown 90% of the time is not contributing and should be fixed or
  // removed. That is invisible today.
  const a = aggregate(week);
  const closes = a.signalHealth.find((s) => s.signal === 'closesFinding')!;
  assert.equal(closes.unknown, 1);
  assert.equal(closes.graded, 0);
});

test('post-merge failures are counted separately from reverts', () => {
  const withFailure = [...week, {
    pk: 'repo#bankrate/other#pr#6', sk: 'outcome#2026-08-25T10:00:00Z',
    repo: 'bankrate/other', prNumber: 6, outcome: 'post_merge_failure', backfilled: false,
  }];
  const a = aggregate(withFailure);
  assert.equal(a.outcomes.reverted, 1);
  assert.equal(a.outcomes.postMergeFailure, 1);
  assert.equal('total' in a.outcomes, false, 'never summed into one number');
});

test('recorder coverage is a fraction, and absence is not zero', () => {
  const a = aggregate(week);
  const adoption = a.recorderHealth.find((r) => r.field === 'adoption')!;
  assert.equal(adoption.present, 1);
  assert.equal(adoption.of, 4, 'denominator is evaluations, not records');
});

test('backfilled outcomes are counted but excluded from the headline', () => {
  const withBackfill = [...week, {
    pk: 'repo#bankrate/third#pr#1', sk: 'outcome#2026-08-24T00:00:00Z',
    repo: 'bankrate/third', prNumber: 1, outcome: 'reverted', backfilled: true,
  }];
  const a = aggregate(withBackfill);
  assert.equal(a.headline.reverted.length, 1, 'the backfilled revert has no evaluation to refute');
  assert.equal(a.outcomes.backfilled, 1);
});

test('an empty week aggregates without throwing', () => {
  const a = aggregate([]);
  assert.equal(a.overall.evaluations, 0);
  assert.equal(a.headline.anyApprovedReverted, false);
});

test('weekStart is the previous Monday at midnight UTC', () => {
  // 2026-08-26 is a Wednesday.
  assert.equal(weekStart(new Date('2026-08-26T13:00:00Z')).toISOString(), '2026-08-24T00:00:00.000Z');
  // A Monday returns itself, not the week before.
  assert.equal(weekStart(new Date('2026-08-24T13:00:00Z')).toISOString(), '2026-08-24T00:00:00.000Z');
  // A Sunday belongs to the week that started six days earlier.
  assert.equal(weekStart(new Date('2026-08-23T13:00:00Z')).toISOString(), '2026-08-17T00:00:00.000Z');
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `node --import tsx --test tests/report-query.test.ts`
Expected: FAIL — `Cannot find module '../src/report/query.js'`

- [ ] **Step 4: Write `src/report/query.ts`**

```ts
// Read a week of the decision ledger and aggregate it.
//
// WHY THIS EXISTS AT ALL: the service has been recording a meaningful amount of
// data with NO READ PATH — visible only by querying DynamoDB by hand, which
// nobody will do. Two concrete failure modes follow from that. A recorder that
// silently breaks produces null for weeks and looks like data. And Phase 1's
// thresholds are supposed to be DERIVED from this corpus, which requires
// somebody having looked at it before the derivation meeting.
//
// Pure aggregation: no S3, no Slack, no clock beyond what is passed in. The
// entry point owns the I/O.
import { ScanCommand } from '@aws-sdk/client-dynamodb';
import { unmarshall } from '@aws-sdk/util-dynamodb';

/** One evaluation or outcome record, already unmarshalled and JSON-parsed. */
export type LedgerRecord = Record<string, any>;

export interface WeeklyAggregate {
  weekStart: string;
  headline: {
    anyApprovedReverted: boolean;
    reverted: { repo: string; prNumber: number }[];
    cumulativeApproved: number;
  };
  overall: { evaluations: number; candidates: number };
  byRepo: Record<string, { evaluations: number; candidates: number; reverted: number }>;
  gateFailures: { gate: string; count: number }[];
  riskGrades: Record<string, number>;
  signalHealth: { signal: string; graded: number; unknown: number }[];
  outcomes: {
    merged: number; closed: number; reverted: number;
    postMergeFailure: number; backfilled: number;
  };
  recorderHealth: { field: string; present: number; of: number; note?: string }[];
}

/** Fields recorded but never graded. Their coverage IS their health check. */
const RECORDED_FIELDS = [
  { field: 'adoption', note: 'deps.dev v3alpha' },
  { field: 'provenance' },
  { field: 'commitAuthorship' },
  { field: 'wouldHaveMergedInWindow' },
];

const isEval = (r: LedgerRecord) => typeof r.sk === 'string' && r.sk.startsWith('eval#');
const isOutcome = (r: LedgerRecord) =>
  typeof r.sk === 'string' && r.sk.startsWith('outcome#') && !r.sk.includes('#pkg#');

/** Midnight UTC on the Monday of `now`'s week. */
export function weekStart(now: Date): Date {
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  // getUTCDay: 0 = Sunday. Monday-based weeks make Sunday six days in, not one.
  const back = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - back);
  return d;
}

/**
 * Aggregate a week's records.
 *
 * DEFENSIVE THROUGHOUT. This ships before Specs F, G and H have all landed, and
 * older records will always outlive newer fields. Every read is optional and a
 * missing field becomes an absent count, never a zero — because a recorder that
 * never ran and one that ran and found nothing are different facts, and the
 * whole point of the recorder-health section is telling them apart.
 */
export function aggregate(records: LedgerRecord[]): WeeklyAggregate {
  const evals = records.filter(isEval);
  const outcomes = records.filter(isOutcome);

  // Approved pull requests, keyed so an outcome can find its evaluation. The
  // join is by key rather than by lookup, which is why the ledger puts both
  // record types under one partition key.
  const approved = new Set(
    evals.filter((e) => e.verdict === 'candidate').map((e) => e.pk));

  // BACKFILLED OUTCOMES ARE EXCLUDED HERE. A backfilled merge was never
  // evaluated, so it can neither corroborate nor refute a verdict that does not
  // exist. They are still counted in `outcomes.backfilled` below.
  const revertedApproved = outcomes.filter(
    (o) => o.outcome === 'reverted' && o.backfilled !== true && approved.has(o.pk));

  const byRepo: WeeklyAggregate['byRepo'] = {};
  for (const e of evals) {
    const repo = e.repo ?? 'unknown';
    byRepo[repo] ??= { evaluations: 0, candidates: 0, reverted: 0 };
    byRepo[repo].evaluations++;
    if (e.verdict === 'candidate') byRepo[repo].candidates++;
  }
  for (const o of revertedApproved) {
    const repo = o.repo ?? 'unknown';
    byRepo[repo] ??= { evaluations: 0, candidates: 0, reverted: 0 };
    byRepo[repo].reverted++;
  }

  const gateCounts = new Map<string, number>();
  for (const e of evals) {
    if (typeof e.failedGate === 'string') {
      gateCounts.set(e.failedGate, (gateCounts.get(e.failedGate) ?? 0) + 1);
    }
  }

  const riskGrades: Record<string, number> = {};
  const signalCounts = new Map<string, { graded: number; unknown: number }>();
  for (const e of evals) {
    if (typeof e.riskGrade === 'string') {
      riskGrades[e.riskGrade] = (riskGrades[e.riskGrade] ?? 0) + 1;
    }
    const signals = e.risk?.signals;
    if (!signals || typeof signals !== 'object') continue;
    for (const [name, signal] of Object.entries(signals as Record<string, any>)) {
      const entry = signalCounts.get(name) ?? { graded: 0, unknown: 0 };
      if (signal?.grade === 'unknown') entry.unknown++;
      else entry.graded++;
      signalCounts.set(name, entry);
    }
  }

  const outcomeCounts = {
    merged: outcomes.filter((o) => o.outcome === 'merged').length,
    closed: outcomes.filter((o) => o.outcome === 'closed').length,
    reverted: outcomes.filter((o) => o.outcome === 'reverted').length,
    // SEPARATE, never summed with reverts. A revert is a human judgment; a
    // post-merge failure is an inference that may be misattributed, and one
    // combined "things went wrong" number would hide which is which.
    postMergeFailure: outcomes.filter((o) => o.outcome === 'post_merge_failure').length,
    backfilled: outcomes.filter((o) => o.backfilled === true).length,
  };

  return {
    weekStart: '',   // filled by the caller, which owns the clock
    headline: {
      anyApprovedReverted: revertedApproved.length > 0,
      reverted: revertedApproved.map((o) => ({ repo: o.repo, prNumber: o.prNumber })),
      cumulativeApproved: approved.size,
    },
    overall: {
      evaluations: evals.length,
      candidates: evals.filter((e) => e.verdict === 'candidate').length,
    },
    byRepo,
    gateFailures: [...gateCounts.entries()]
      .map(([gate, count]) => ({ gate, count }))
      .sort((a, b) => b.count - a.count),
    riskGrades,
    signalHealth: [...signalCounts.entries()]
      .map(([signal, c]) => ({ signal, ...c }))
      .sort((a, b) => b.unknown - a.unknown),
    outcomes: outcomeCounts,
    // The denominator is EVALUATIONS, not records that happen to carry the
    // field. That is what makes each line a health check: a recorder that stops
    // working shows up as a numerator that stops matching.
    recorderHealth: RECORDED_FIELDS.map(({ field, note }) => ({
      field,
      present: evals.filter((e) => e[field] !== undefined && e[field] !== null).length,
      of: evals.length,
      ...(note ? { note } : {}),
    })),
  };
}

/**
 * Read a week of records.
 *
 * A SCAN, deliberately, and the assumption is stated so it can be revisited
 * rather than inherited: at Phase 0 volumes — hundreds of records a week across
 * five repositories — a scan is fine and a purpose-built index is not worth the
 * schema. At fifty repositories it is not fine.
 *
 * Running outside the Lambda removes the timeout pressure that would otherwise
 * make this worth worrying about: an Actions job has six hours.
 */
export async function fetchWeek(
  tableName: string,
  since: Date,
  send: (cmd: ScanCommand) => Promise<any>,
): Promise<LedgerRecord[]> {
  const records: LedgerRecord[] = [];
  let startKey: Record<string, unknown> | undefined;

  do {
    const res = await send(new ScanCommand({
      TableName: tableName,
      FilterExpression: 'sk >= :since',
      ExpressionAttributeValues: { ':since': { S: `eval#${since.toISOString()}` } },
      ExclusiveStartKey: startKey as never,
    }));
    for (const item of res.Items ?? []) {
      const r = unmarshall(item) as LedgerRecord;
      // The nested maps are stored as JSON strings; parse defensively so one
      // malformed record cannot take down the whole report.
      for (const key of ['risk', 'eligibility', 'classification', 'provenance', 'adoption', 'commitAuthorship']) {
        if (typeof r[key] === 'string') {
          try { r[key] = JSON.parse(r[key]); } catch { r[key] = null; }
        }
      }
      records.push(r);
    }
    startKey = res.LastEvaluatedKey;
  } while (startKey);

  return records;
}
```

**Note the `FilterExpression` caveat and do not "fix" it:** `sk >= :since` with
an `eval#` prefix also admits `outcome#` records, because `o` sorts after `e`.
That is intentional — the report needs both — but it means the filter is a
coarse floor rather than a precise window, and outcome records older than the
week can slip in. Task 2's rendering treats outcome counts as
week-and-newer rather than exactly-this-week, and the report says so.

- [ ] **Step 5: Add the two SDK dependencies**

```bash
pnpm add @aws-sdk/util-dynamodb @aws-sdk/client-s3
```

- [ ] **Step 6: Run test to verify it passes**

Run: `node --import tsx --test tests/report-query.test.ts`
Expected: PASS, 10 tests.

- [ ] **Step 7: Commit**

```bash
git add src/report/query.ts tests/report-query.test.ts tests/fixtures/ledger-week.json \
  package.json pnpm-lock.yaml
git commit -m "feat(report): aggregate a week of the decision ledger"
```

---

## Task 2: Render it

**Files:**
- Create: `src/report/render.ts`, `tests/report-render.test.ts`

**Interfaces:**
- Consumes: `WeeklyAggregate` (Task 1).
- Produces: `renderSlack(aggregate)`, `renderJson(aggregate)`.

- [ ] **Step 1: Write the failing test**

Create `tests/report-render.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { aggregate } from '../src/report/query.js';
import { renderSlack } from '../src/report/render.js';

const week = JSON.parse(readFileSync('tests/fixtures/ledger-week.json', 'utf8'));
const text = (a: any) => JSON.stringify(renderSlack(a));

test('the post leads with the revert question, answered', () => {
  const out = text(aggregate(week));
  assert.match(out, /Did any would-have-approved pull request get reverted/i);
  assert.match(out, /\*\*Yes\*\*|Yes —/);
  assert.match(out, /bankrate\/other#5/);
});

test('a clean week says no, with the denominator', () => {
  const clean = week.filter((r: any) => r.outcome !== 'reverted');
  const out = text(aggregate(clean));
  assert.match(out, /No —/);
  assert.match(out, /2 would-have-approved/);
});

test('gate failures are ranked in the post', () => {
  const out = text(aggregate(week));
  const i = out.indexOf('classificationPermits');
  const j = out.indexOf('checksGreen');
  assert.ok(i > 0 && j > 0);
});

test('a permanently-unknown signal is visible as a rate', () => {
  const out = text(aggregate(week));
  assert.match(out, /closesFinding/);
  assert.match(out, /unknown/i);
});

test('recorder health renders a fraction, and an absent field says so', () => {
  const out = text(aggregate(week));
  assert.match(out, /adoption/);
  assert.match(out, /1 of 4|1\/4/);
  // commitAuthorship exists in no record in this fixture — pre-Spec-G vintage.
  assert.match(out, /commitAuthorship[^0-9]*0 of 4|not recorded/);
});

test('post-merge failures render separately, with the attribution rule stated', () => {
  const withFailure = [...week, {
    pk: 'repo#bankrate/other#pr#6', sk: 'outcome#2026-08-25T10:00:00Z',
    repo: 'bankrate/other', prNumber: 6, outcome: 'post_merge_failure', backfilled: false,
  }];
  const out = text(aggregate(withFailure));
  assert.match(out, /green-to-red|inferred/i, 'the rule is stated beside the count');
  assert.doesNotMatch(out, /1 problems|2 problems/, 'never summed with reverts');
});

test('an empty week still produces a post that says so', () => {
  // A silent week is indistinguishable from a broken schedule.
  const out = text(aggregate([]));
  assert.match(out, /no evaluations/i);
});

test('a pre-Spec-F record with no adoption field renders without throwing', () => {
  // The property that makes this parallel-safe with F, G and H.
  const ancient = [{
    pk: 'repo#o/r#pr#1', sk: 'eval#2026-08-24T00:00:00Z', repo: 'o/r',
    prNumber: 1, verdict: 'candidate', changeClass: 'dep-patch', failedGate: null,
  }];
  assert.doesNotThrow(() => renderSlack(aggregate(ancient)));
});

test('the revert limitation is stated beside the number', () => {
  // So nobody reads "zero reverts" as "nothing went wrong". Detection only
  // matches git's revert convention.
  const out = text(aggregate(week));
  assert.match(out, /convention|may miss|understate/i);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --import tsx --test tests/report-render.test.ts`
Expected: FAIL — module missing.

- [ ] **Step 3: Write `src/report/render.ts`**

Slack Block Kit, one `section` per part of the report. The structure, in order,
because the order is the argument:

1. **Headline** — the question this phase exists to answer, and its answer.
2. **Would-have-approved rate**, weekly and cumulative, overall and per repo.
3. **Gate-failure breakdown**, ranked — the direct input to Phase 1 tuning.
4. **Risk grades and per-signal `unknown` rates** — a signal `unknown` 90% of
   the time is not contributing and should be fixed or removed.
5. **Outcomes** — merged, closed, reverted, and post-merge failures **on their
   own line** with the attribution rule stated.
6. **Recorder health** — each recorded-only field's coverage as a fraction.

Two rules the implementation must follow and the tests enforce:

```ts
/** Absent is not zero. */
const fraction = (present: number, of: number): string =>
  of === 0 ? 'no evaluations' : `${present} of ${of}`;

/**
 * Every count that could be misread as "nothing went wrong" carries its
 * limitation inline. Detection only matches git's revert convention, so a
 * hand-written fix that undoes a change without saying so is missed — a missed
 * revert UNDERSTATES harm, and the reader has to know that.
 */
const REVERT_CAVEAT =
  '_Reverts are detected from git\'s revert convention only; a hand-written undo that does not '
  + 'say so is missed, so this number can understate harm._';

const POST_MERGE_CAVEAT =
  '_Attributed to a merge only when the same check went green-to-red across it. Inferred, not '
  + 'established — a flaky test or an unrelated change can land here._';
```

`renderJson` returns the aggregate itself plus a `generatedAt`, so a later
analysis does not have to re-derive a week's numbers or scrape Slack.

- [ ] **Step 4: Run test to verify it passes**

Run: `node --import tsx --test tests/report-render.test.ts`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add src/report/render.ts tests/report-render.test.ts
git commit -m "feat(report): render the weekly post, with every caveat beside its number"
```

---

## Task 3: The entry point

**Files:**
- Create: `src/report/index.ts`, `tests/report-index.test.ts`

**Interfaces:**
- Produces: `main(env, deps)` from `src/report/index.ts`.

- [ ] **Step 1: Write the failing test**

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { main } from '../src/report/index.js';

const env = {
  EVALUATIONS_TABLE: 'zapp-evaluations-test',
  REPORT_BUCKET: 'zapp-reports-test',
  SLACK_REPORT_WEBHOOK: 'https://hooks.slack.com/services/x',
};

function deps(over: Partial<any> = {}) {
  const posted: any[] = [];
  const archived: any[] = [];
  return {
    posted, archived,
    deps: {
      fetchWeek: async () => [],
      putObject: async (key: string, body: string) => { archived.push({ key, body }); },
      postSlack: async (url: string, body: unknown) => { posted.push({ url, body }); },
      now: () => new Date('2026-08-31T13:00:00Z'),
      ...over,
    },
  };
}

test('a missing webhook fails the run rather than skipping the post', async () => {
  // A report that silently stops being delivered is the exact failure this
  // whole thing exists to catch.
  const { deps: d } = deps();
  await assert.rejects(
    () => main({ ...env, SLACK_REPORT_WEBHOOK: undefined } as any, d),
    /SLACK_REPORT_WEBHOOK/);
});

test('the artifact is archived BEFORE the post', async () => {
  const order: string[] = [];
  const { deps: d } = deps({
    putObject: async () => { order.push('s3'); },
    postSlack: async () => { order.push('slack'); },
  });
  await main(env as any, d);
  assert.deepEqual(order, ['s3', 'slack']);
});

test('an S3 failure is logged and the post still goes out', async () => {
  const { deps: d, posted } = deps({
    putObject: async () => { throw new Error('AccessDenied'); },
  });
  await main(env as any, d);
  assert.equal(posted.length, 1);
});

test('a Slack failure throws so the workflow run goes red', async () => {
  const { deps: d } = deps({ postSlack: async () => { throw new Error('404 no_service'); } });
  await assert.rejects(() => main(env as any, d), /no_service/);
});

test('the archive key is the week start, so a re-run overwrites rather than piles up', async () => {
  const { deps: d, archived } = deps();
  await main(env as any, d);
  assert.match(archived[0].key, /2026-08-31/);
});

test('an empty week still posts', async () => {
  const { deps: d, posted } = deps({ fetchWeek: async () => [] });
  await main(env as any, d);
  assert.equal(posted.length, 1);
});
```

- [ ] **Step 2: Write `src/report/index.ts`**

```ts
// Weekly shadow report entry point.
//
// RUNS IN GITHUB ACTIONS, NOT IN THE LAMBDA. `lambda-deploy` deploys exactly
// one function per environment, which is why the receiver and worker share one
// — but sharing has a cost this job should not impose: a weekly scan needs a
// longer timeout than the request roles, and raising the function timeout drags
// the queue's visibility timeout with it to keep the 6:1 ratio. A reporting job
// would then be able to change how the WORKER fails. Running it here sidesteps
// the one-function constraint rather than working around it, and puts the
// report's own failures in the Actions tab where somebody already looks.
import { DynamoDBClient, ScanCommand } from '@aws-sdk/client-dynamodb';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
import { aggregate, fetchWeek, weekStart } from './query.js';
import { renderSlack, renderJson } from './render.js';

export interface ReportDeps {
  fetchWeek: typeof fetchWeek extends (t: string, s: Date, send: any) => infer R
    ? (table: string, since: Date) => R : never;
  putObject: (key: string, body: string) => Promise<void>;
  postSlack: (url: string, body: unknown) => Promise<void>;
  now: () => Date;
}

export async function main(
  env: Record<string, string | undefined>,
  deps: ReportDeps,
): Promise<void> {
  const table = env.EVALUATIONS_TABLE;
  const bucket = env.REPORT_BUCKET;
  const webhook = env.SLACK_REPORT_WEBHOOK;

  // Checked FIRST and hard. A run that quietly produces no post is
  // indistinguishable from a healthy week, which is the failure mode this
  // report exists to make impossible.
  if (!webhook) throw new Error('SLACK_REPORT_WEBHOOK is not set — refusing to run and post nothing');
  if (!table) throw new Error('EVALUATIONS_TABLE is not set');

  const since = weekStart(deps.now());
  const records = await deps.fetchWeek(table, since);
  const summary = { ...aggregate(records), weekStart: since.toISOString() };

  // Archived BEFORE the post: if Slack is down, the week's aggregate still
  // survives and the run can be replayed without re-deriving it.
  if (bucket) {
    try {
      await deps.putObject(`weekly/${since.toISOString().slice(0, 10)}.json`,
        JSON.stringify(renderJson(summary), null, 2));
    } catch (err) {
      // Logged, not fatal. The post is the product; the artifact is a
      // convenience for later analysis.
      console.error(JSON.stringify({ level: 'error', msg: 'report_archive_failed',
        error: err instanceof Error ? err.message : String(err) }));
    }
  }

  await deps.postSlack(webhook, renderSlack(summary));
}
```

Plus the real `deps` wiring and an `import.meta.main`-style guard so `tsx
src/report/index.ts` runs it.

The archive key is the **week start**, not the run time, so re-running via
`workflow_dispatch` overwrites that week rather than piling up near-duplicates.

- [ ] **Step 3: Run test to verify it passes**

Run: `node --import tsx --test tests/report-index.test.ts`
Expected: PASS, 6 tests.

- [ ] **Step 4: Commit**

```bash
git add src/report/index.ts tests/report-index.test.ts
git commit -m "feat(report): entry point — archive, then post, and fail loudly with no webhook"
```

---

## Task 4: Prove the Lambda is untouched

A one-step task, because it is the single easiest thing to get wrong and the cheapest to check.

- [ ] **Step 1: Assert it**

Append to `tests/index.test.ts`:

```ts
test('the Lambda still routes exactly two ways', () => {
  // The weekly report deliberately does NOT live here. If this test had to
  // change to accommodate it, the report took the Lambda path and inherited the
  // shared-timeout coupling the spec rejected.
  const source = readFileSync('src/index.ts', 'utf8');
  assert.doesNotMatch(source, /report/i);
  assert.doesNotMatch(source, /aws\.events/);
});
```

- [ ] **Step 2: Verify the existing dispatch tests pass unmodified**

Run: `git diff --stat origin/main -- src/index.ts tests/index.test.ts`
Expected: `src/index.ts` shows **no changes**. If it does, stop.

Also confirm `infrastructure/terraform/main.tf`'s `timeout = 30` is unchanged:

```bash
git diff origin/main -- infrastructure/terraform/main.tf | grep -c 'timeout'
```

Expected: `0`.

- [ ] **Step 3: Commit**

```bash
git add tests/index.test.ts
git commit -m "test: assert the weekly report stayed out of the Lambda dispatch"
```

---

## Task 5: Terraform — the bucket and the read-only role

**Files:**
- Create: `infrastructure/terraform/report.tf`

- [ ] **Step 1: Write it**

```hcl
# Weekly-report archive. The human-readable post goes to Slack; this is the
# machine-readable aggregate, so a later analysis does not have to re-derive a
# week's numbers or scrape a channel.
resource "aws_s3_bucket" "reports" {
  bucket = "${local.name}-reports"
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A SECOND, READ-ONLY OIDC role — deliberately not `gha_role`, which carries
# ECR PowerUser and lambda:UpdateFunctionCode. A reporting job has no business
# holding permissions that can change the service, and the whole value of
# moving the report out of the Lambda is lost if it runs with deploy rights.
module "gha_report_role" {
  source  = "app.terraform.io/bankrate/gha-role/aws"
  version = "~> 3.1"

  name         = "gha-role-${var.app_name}-report"
  repositories = ["${var.github_org}@${var.github_org_id}/${var.repo_name}@${var.repo_id}"]

  # Scheduled workflows run on the default branch; there is no pull-request or
  # tag path into this role.
  pull_request     = false
  allowed_branches = ["main"]

  inline_policies = {
    read_ledger = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["dynamodb:Query", "dynamodb:Scan"]
          Resource = [
            aws_dynamodb_table.evaluations.arn,
            "${aws_dynamodb_table.evaluations.arn}/index/*",
          ]
        },
        {
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = "${aws_s3_bucket.reports.arn}/weekly/*"
        },
      ]
    })
  }
}

output "report_role_arn" {
  description = "Role the weekly-report workflow assumes. Read-only by construction."
  value       = module.gha_report_role.arn
}
```

- [ ] **Step 2: Verify the separation is real, and say which it is**

The two roles trust the same repository and the same branch, so the OIDC subject
claim alone does not stop the deploy workflow assuming the report role or vice
versa. Check whether `gha-role` supports environment-scoped subjects:

```bash
gh api repos/bankrate/finserv-reusable-gha/contents/README.md --jq '.content' \
  | base64 -d | grep -i -A5 'allowed_environments' | head -20
```

If it emits `repo:org/repo:environment:<name>` subjects, give the report role
its own `allowed_environments = ["report"]`, drop `allowed_branches`, and add
`environment: report` to the workflow — then the separation is enforced by
policy.

If it only emits branch subjects, **say so explicitly in the PR description**:
the roles are separated by convention and least-privilege intent, not by a hard
boundary. Do not describe it as enforced isolation if it is not.

- [ ] **Step 3: Commit**

```bash
git add infrastructure/terraform/report.tf
git commit -m "feat(report): archive bucket and a read-only OIDC role"
```

---

## Task 6: The workflow

**Files:**
- Create: `.github/workflows/weekly-report.yml`

- [ ] **Step 1: Write it**

```yaml
# Weekly shadow report (PLAT-1184 M4/T12).
#
# NOT a Lambda branch. See src/report/index.ts for why: sharing the service's
# function would let a reporting job's timeout drag the worker's SQS visibility
# timeout with it.
name: Weekly report

on:
  schedule:
    # Mondays 13:00 UTC — 09:00 America/New_York in EDT, 08:00 in EST. The
    # week's data is complete and there is a working week to act in.
    - cron: '0 13 * * 1'
  # Regenerate on demand: after fixing a renderer, or when somebody asks a
  # question mid-week. The scheduled-Lambda alternative had no equivalent.
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: pnpm

      - run: pnpm install --frozen-lockfile

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.REPORT_ROLE_ARN }}
          aws-region: us-east-1

      - name: Generate and post
        env:
          EVALUATIONS_TABLE: ${{ vars.EVALUATIONS_TABLE }}
          REPORT_BUCKET: ${{ vars.REPORT_BUCKET }}
          # REPOSITORY secret, not the org's SLACK_WEBHOOK — an incoming webhook
          # is bound to one channel at creation, and the org one posts to the
          # generic deploy channel. See the spec's Delivery section.
          SLACK_REPORT_WEBHOOK: ${{ secrets.SLACK_REPORT_WEBHOOK }}
        run: pnpm exec tsx src/report/index.ts
```

GitHub delays `schedule` triggers under load, sometimes by tens of minutes, and
skips them on repositories inactive for 60 days. Neither matters for a weekly
report read during the week, and the second is unreachable for a repository
under active development — but it is a known property, not a surprise, and it
belongs in the workflow's header comment.

- [ ] **Step 2: Set the three repository variables**

```bash
gh variable set REPORT_ROLE_ARN --repo bankrate/zapp --body '<from terraform output>'
gh variable set EVALUATIONS_TABLE --repo bankrate/zapp --body 'zapp-evaluations-qa'
gh variable set REPORT_BUCKET --repo bankrate/zapp --body 'zapp-qa-reports'
```

Take the exact values from `terraform output` after the apply, not from this
plan — `local.name` composition is the source of truth.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/weekly-report.yml
git commit -m "feat(report): scheduled workflow, regenerable on demand"
```

---

## Task 7: Live validation

**Files:** none.

- [ ] **Step 1: Confirm the secret exists before running anything**

```bash
gh secret list --repo bankrate/zapp | grep SLACK_REPORT_WEBHOOK
```

If absent, this is the human setup step at the top of this plan. Request it and
stop here — running without it is designed to fail, and burning a run to prove
that is not useful.

- [ ] **Step 2: Trigger it by hand**

```bash
gh workflow run weekly-report.yml --repo bankrate/zapp
gh run watch --repo bankrate/zapp
```

- [ ] **Step 3: Confirm four things**

1. The post arrives in **`#bankrate-platform-notifications`**.
2. It **leads** with the revert question and its answer.
3. The recorder-health section shows fractions — including `0 of N` for fields
   whose spec has not landed yet, rendered as not-recorded rather than as zero.
4. The JSON artifact exists:

```bash
aws s3 ls s3://<bucket>/weekly/
```

- [ ] **Step 4: Prove the failure path**

Re-run with the secret temporarily removed, or point `SLACK_REPORT_WEBHOOK` at a
deliberately invalid URL, and confirm the run goes **red** rather than green
with no post. Restore it afterwards and confirm with a second run.

This is worth a burnt run: the whole argument for this report is that a silent
failure is the thing being guarded against, and an untested failure path is
exactly how that argument stops being true.

- [ ] **Step 5: Report the outcome**

State what the headline said, what the gate-failure ranking looked like on real
data, which signals are grading `unknown` most often, and which recorders showed
`0 of N`. That last list is the first genuinely new information this whole epic
has produced — it says which of the things being collected are not actually
being collected.

---

## Definition of done

- [ ] A scheduled workflow run produces a Slack post in `#bankrate-platform-notifications` *(Tasks 6, 7)*
- [ ] `workflow_dispatch` regenerates it on demand *(Tasks 6, 7)*
- [ ] The OIDC role is read-only — it cannot deploy, write to the ledger, or change the service *(Task 5)*
- [ ] Whether the role separation is policy-enforced or convention-only is stated explicitly, not assumed *(Task 5)*
- [ ] An absent `SLACK_REPORT_WEBHOOK` fails the run rather than skipping the post, proven by a real run *(Tasks 3, 7)*
- [ ] `src/index.ts` and the Lambda's timeout are unchanged, asserted by a test *(Task 4)*
- [ ] The post leads with whether any would-have-approved pull request was reverted *(Tasks 1, 2)*
- [ ] A revert of a non-candidate does not trip the headline *(Task 1)*
- [ ] Backfilled outcomes are counted but excluded from the headline *(Task 1)*
- [ ] Gate-failure breakdown is ranked *(Tasks 1, 2)*
- [ ] Per-signal `unknown` rates are shown, so a non-contributing signal is visible *(Tasks 1, 2)*
- [ ] The recorder-health section shows each recorded-only field's coverage as a fraction, with evaluations as the denominator *(Task 1)*
- [ ] A week with no evaluations still posts *(Tasks 1, 2, 3)*
- [ ] A ledger record missing a newer field renders "not recorded", never zero *(Tasks 1, 2)*
- [ ] Post-merge failures are shown separately from reverts, with the attribution rule stated *(Tasks 1, 2)*
- [ ] The revert-detection limitation is stated beside its number *(Task 2)*
- [ ] The JSON artifact is archived to S3 before the Slack post, keyed by week start *(Task 3)*
