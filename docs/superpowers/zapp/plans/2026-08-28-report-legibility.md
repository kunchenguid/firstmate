# Weekly report legibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the weekly report readable in ten seconds and traceable to its source — a channel post of a headline plus three or four interpreted dots, a thread carrying the numbers, and a repo document carrying the provenance — while fixing the seven correctness and framing findings from the 2026-08-28 analysis.

**Architecture:** A new pure `src/report/interpret.ts` turns a `WeeklyAggregate` into dot sentences, each generated from a stated precondition so a reassurance cannot outlive its basis. `render.ts` splits into a channel-post renderer and a thread-reply renderer. `index.ts` posts the parent, then attaches replies with its `ts`. Four aggregate fields change to fix wrong denominators.

**Tech Stack:** TypeScript (ESM, `node22` target), Node's built-in test runner via `node --import tsx --test`, Slack Block Kit + `chat.postMessage`, GitHub Actions.

**Spec:** [`../specs/2026-08-28-report-legibility-design.md`](../specs/2026-08-28-report-legibility-design.md)

## Before you start

Base is `origin/main` at or after `910b117` (v1.14.0). Verify:

```bash
git log --oneline -1 && grep -c 'CI_DEPENDENT_GATES' src/evaluate.ts && ls src/report/
```

Expected: a commit at or after `910b117`, a non-zero count, and `index.ts query.ts render.ts`.

## A correction to the spec, found while reading the code

The spec proposed reusing `CI_DEPENDENT_GATES` to justify the sentence *"mostly CI that had not reported yet."* **That would produce a wrong sentence.** The set has four members as of Spec G:

```ts
checksGreen, coverageFloor, freezeOff, notBlocked
```

It means "can resolve without a new commit" — which is broader than "CI is still running". A pull request blocked by a `do-not-automerge` label or by a fleet freeze is in that set, and describing either as CI-not-yet-reported is false.

So the export happens as decided, and it backs the claim it actually supports — **"can still clear without a new commit"**. The CI-specific wording keys on the *dominant gate by name*, not on set membership. This week `checksGreen` is 34 of 59, so "CI had not reported" is true; the rule derives that rather than assuming it.

## Global Constraints

- **The report computes nothing new about a pull request.** No gate, no signal, no ledger write changes. This plan reads and renders.
- **Every interpreted sentence is generated from a precondition over the data** and disappears when the precondition fails. Never a constant string with a comment.
- **Interpretation takes fleet size as an argument.** `fleetSize()` reads the compiled `POLICY.repos`, so calling it inside an interpretation makes the precondition untestable. Pass it in.
- **No table cell is `raw_number`.** `raw_text` with non-empty text, everywhere, asserted across the whole payload.
- **A fraction always names its population.** `5 of 12 candidates`, never a bare `5 of 12`.
- **The parent post carries the essential content.** A failed thread reply degrades the report; it never voids it, and it never deletes what already posted.
- **Zero evaluations still posts.** A silent week must not look like a broken schedule.
- **The trail must not dead-end.** Every anchor the renderer emits exists as a heading in `docs/weekly-report.md`, asserted by a test.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/report/interpret.ts` | **New.** Precondition-gated dot sentences. Pure; the only module here that encodes a judgment. |
| `src/report/render.ts` | Channel-post renderer and thread-reply renderer. `rawNumber` deleted. |
| `src/report/query.ts` | `distinctPrs`, `distinctApproved`, recorder scopes, per-signal eligible counts, scanned count. |
| `src/report/index.ts` | Post parent, then replies with its `ts`. |
| `src/evaluate.ts` | Export `CI_DEPENDENT_GATES`. |
| `docs/weekly-report.md` | **New.** Layer 3 of the trail. |
| `docs/policy.md` | The 33-line provenance section becomes a pointer. |

---

## Task 1: Fix the aggregate — denominators, populations, and the export

Five of the seven findings are data-shape problems, not wording. They land first so the renderer has honest numbers to render.

**Files:**
- Modify: `src/evaluate.ts:61-66` (export the set)
- Modify: `src/report/query.ts`
- Modify: `tests/report-query.test.ts`

**Interfaces:**
- Produces: `CI_DEPENDENT_GATES` exported from `src/evaluate.ts`; `WeeklyAggregate` with `overall.distinctPrs`, `headline.distinctApproved`, `recorderHealth[].scope`, `signalHealth[].eligible`, `scanned`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/report-query.test.ts`:

```ts
test('distinct pull requests are counted, not just evaluations', () => {
  // The live corpus has ONE pull request accounting for 40 of 71 evaluations.
  // Any evaluation-level rate is therefore dominated by whichever PR happened
  // to be re-evaluated most, which is not a fact about the fleet.
  const busy = [
    ...Array.from({ length: 40 }, (_, i) => ({
      pk: 'repo#o/r#pr#27', sk: `eval#2026-08-24T0${i % 10}:00:00Z`,
      repo: 'o/r', prNumber: 27, verdict: 'candidate',
    })),
    { pk: 'repo#o/r#pr#32', sk: 'eval#2026-08-24T12:00:00Z',
      repo: 'o/r', prNumber: 32, verdict: 'not-candidate', failedGate: 'size' },
  ];
  const a = aggregate(busy);
  assert.equal(a.overall.evaluations, 41);
  assert.equal(a.overall.distinctPrs, 2, 'the number a human means by "how many PRs"');
  assert.equal(a.headline.distinctApproved, 1);
});

test('cumulativeApproved is gone — the field is distinctApproved', () => {
  // It was never cumulative. The exit criteria DO want a cumulative figure, so
  // leaving a field that looks like one is a trap for whoever needs it.
  const a = aggregate(week);
  assert.equal('cumulativeApproved' in a.headline, false);
  assert.equal(typeof a.headline.distinctApproved, 'number');
});

test('candidate-scoped recorders divide by candidates, not by all evaluations', () => {
  // adoption and provenance are written inside assessRisk, which runs only for
  // candidates. Their ceiling is the candidate count. Reporting 5 of 71 implies
  // 66 misses when 59 of those could never have carried the field at all.
  const records = [
    { pk: 'repo#o/r#pr#1', sk: 'eval#2026-08-24T01:00:00Z', repo: 'o/r', prNumber: 1,
      verdict: 'candidate', adoption: { package: 'p', version: '1.0.0' },
      provenance: [], commitAuthorship: { commits: 1 }, wouldHaveMergedInWindow: true },
    { pk: 'repo#o/r#pr#2', sk: 'eval#2026-08-24T02:00:00Z', repo: 'o/r', prNumber: 2,
      verdict: 'not-candidate', failedGate: 'size',
      commitAuthorship: { commits: 1 }, wouldHaveMergedInWindow: false },
  ];
  const a = aggregate(records);
  const by = Object.fromEntries(a.recorderHealth.map((r) => [r.field, r]));

  assert.deepEqual({ present: by.adoption!.present, of: by.adoption!.of, scope: by.adoption!.scope },
    { present: 1, of: 1, scope: 'candidates' });
  assert.deepEqual({ present: by.commitAuthorship!.present, of: by.commitAuthorship!.of,
    scope: by.commitAuthorship!.scope }, { present: 2, of: 2, scope: 'evaluations' });
});

test('each signal reports how many evaluations could have carried it', () => {
  // Seven distinct rulesSha values landed in one week. targetVersionHealth
  // reads "0 of 5" beside a column of 11s because it did not exist yet — true,
  // and unreadable without the eligible count beside it.
  const records = [
    { pk: 'repo#o/r#pr#1', sk: 'eval#2026-08-24T01:00:00Z', repo: 'o/r', verdict: 'candidate',
      riskGrade: 'low', risk: { grade: 'low', signals: {
        semverDistance: { grade: 'low' }, targetVersionHealth: { grade: 'low' } } } },
    { pk: 'repo#o/r#pr#2', sk: 'eval#2026-08-24T02:00:00Z', repo: 'o/r', verdict: 'candidate',
      riskGrade: 'low', risk: { grade: 'low', signals: { semverDistance: { grade: 'low' } } } },
  ];
  const a = aggregate(records);
  const by = Object.fromEntries(a.signalHealth.map((s) => [s.signal, s]));
  assert.equal(by.semverDistance!.eligible, 2);
  assert.equal(by.targetVersionHealth!.eligible, 1, 'newer than one of the two records');
  assert.equal(a.gradedCandidates, 2);
});

test('graded and ungraded candidates are both counted', () => {
  // Live: 12 candidates, 11 risk grades. One record predates the heuristics.
  // Correct behaviour; a discrepancy nobody can resolve from the report.
  const records = [
    { pk: 'repo#o/r#pr#1', sk: 'eval#2026-08-24T01:00:00Z', repo: 'o/r',
      verdict: 'candidate', riskGrade: 'medium', risk: { grade: 'medium', signals: {} } },
    { pk: 'repo#o/r#pr#2', sk: 'eval#2026-08-24T02:00:00Z', repo: 'o/r', verdict: 'candidate' },
  ];
  const a = aggregate(records);
  assert.equal(a.overall.candidates, 2);
  assert.equal(a.gradedCandidates, 1);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --import tsx --test tests/report-query.test.ts`
Expected: FAIL — `distinctPrs` is undefined, `cumulativeApproved` still present.

- [ ] **Step 3: Export `CI_DEPENDENT_GATES` from `src/evaluate.ts`**

```ts
/**
 * Gates whose failure can clear WITHOUT a new commit.
 *
 * Exported for the weekly report, which needs the same set to say whether a
 * blocked pull request is likely to resolve on its own. Deliberately NOT a
 * "CI is still running" set — a `do-not-automerge` label and a fleet freeze
 * are both in here, and describing either as CI-not-yet-reported would be
 * false. The report keys its CI-specific wording on the dominant gate by name.
 */
export const CI_DEPENDENT_GATES: ReadonlySet<GateName> = new Set<GateName>([
  'checksGreen',
  'coverageFloor',
  'freezeOff',
  'notBlocked',
]);
```

Only the `export` keyword and the comment change; the members are untouched.

- [ ] **Step 4: Extend `WeeklyAggregate` in `src/report/query.ts`**

```ts
/** Which population a recorded field can possibly appear on. */
export type RecorderScope = 'candidates' | 'evaluations';

export interface WeeklyAggregate {
  weekStart: string;
  headline: {
    anyApprovedReverted: boolean;
    reverted: { repo: string; prNumber: number }[];
    /** THIS WEEK's distinct approved pull requests. Not cumulative — see the rename. */
    distinctApproved: number;
  };
  overall: {
    evaluations: number;
    candidates: number;
    /** Distinct pull requests evaluated. The denominator a human means. */
    distinctPrs: number;
  };
  /** Candidates that actually carry a risk grade. Below `overall.candidates` when a record predates the heuristics. */
  gradedCandidates: number;
  byRepo: Record<string, { evaluations: number; candidates: number; reverted: number }>;
  gateFailures: { gate: string; count: number }[];
  riskGrades: Record<string, number>;
  /** `eligible` is how many evaluations could have carried this signal at all. */
  signalHealth: { signal: string; graded: number; unknown: number; eligible: number }[];
  outcomes: {
    merged: number; closed: number; reverted: number;
    postMergeFailure: number; backfilled: number;
  };
  recorderHealth: { field: string; present: number; of: number; scope: RecorderScope; note?: string }[];
  /** Records the scan returned before windowing. Surfaces the read cost weekly (F7). */
  scanned: number;
}
```

Declare the scopes:

```ts
/**
 * Fields recorded but never graded. Their coverage IS their health check — so
 * the denominator has to be the population the field could appear on.
 *
 * `adoption` and `provenance` are written inside `assessRisk`, which runs only
 * for candidates. Dividing them by all evaluations reports misses that were
 * never possible.
 */
const RECORDED_FIELDS: { field: string; scope: RecorderScope; note?: string }[] = [
  { field: 'adoption', scope: 'candidates', note: 'deps.dev v3alpha' },
  { field: 'provenance', scope: 'candidates' },
  { field: 'commitAuthorship', scope: 'evaluations' },
  { field: 'wouldHaveMergedInWindow', scope: 'evaluations' },
];
```

In `aggregate()`, replace the return's affected fields:

```ts
  const candidates = evals.filter((e) => e.verdict === 'candidate');
  const gradedCandidates = candidates.filter((e) => typeof e.riskGrade === 'string').length;

  // Every signal's eligible count: evaluations whose risk object exists at all.
  // A signal missing from a record that HAS a risk object is a signal younger
  // than that record, which is exactly what the eligible count exposes.
  const withRisk = evals.filter((e) => e.risk?.signals && typeof e.risk.signals === 'object');
  const eligibleFor = (signal: string): number =>
    withRisk.filter((e) => signal in e.risk.signals).length;
```

and:

```ts
    headline: {
      anyApprovedReverted: revertedApproved.length > 0,
      reverted: revertedApproved.map((o) => ({ repo: o.repo, prNumber: o.prNumber })),
      distinctApproved: approved.size,
    },
    overall: {
      evaluations: evals.length,
      candidates: candidates.length,
      distinctPrs: new Set(evals.map((e) => e.pk)).size,
    },
    gradedCandidates,
    …
    signalHealth: [...signalCounts.entries()]
      .map(([signal, c]) => ({ signal, ...c, eligible: eligibleFor(signal) }))
      .sort((a, b) => b.unknown - a.unknown),
    …
    recorderHealth: RECORDED_FIELDS.map(({ field, scope, note }) => {
      const population = scope === 'candidates' ? candidates : evals;
      return {
        field,
        scope,
        present: population.filter((e) => e[field] !== undefined && e[field] !== null).length,
        of: population.length,
        ...(note ? { note } : {}),
      };
    }),
    scanned: records.length,
```

`aggregate()` receives the already-windowed array, so `scanned` here is the windowed count. The pre-window figure is threaded through from `index.ts` in Task 4 — do not guess it here.

- [ ] **Step 5: Fix the existing tests that name the old field**

`tests/report-query.test.ts` and `tests/report-render.test.ts` reference
`cumulativeApproved`. Rename every occurrence. `grep -rn cumulativeApproved src/ tests/`
must come back empty before you commit.

- [ ] **Step 6: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/evaluate.ts src/report/query.ts tests/
git commit -m "fix(report): count distinct pull requests and divide recorders by their own population"
```

---

## Task 2: `interpret.ts` — sentences that expire

The intellectual core. "Expected this early; few repos and thin history" is true today and becomes a **lie** at ten enrolled repositories. An interpretation with no expiry is worse than a raw number, because a raw number never claims to be fine.

**Files:**
- Create: `src/report/interpret.ts`, `tests/report-interpret.test.ts`

**Interfaces:**
- Consumes: `WeeklyAggregate` (Task 1); `CI_DEPENDENT_GATES` from `src/evaluate.ts`.
- Produces: `dots(aggregate, context)` returning `string[]`; `InterpretContext = { fleetSize: number; minFleet: number }`.

- [ ] **Step 1: Write the failing test**

Create `tests/report-interpret.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dots } from '../src/report/interpret.js';
import type { WeeklyAggregate } from '../src/report/query.js';

const SMALL = { fleetSize: 1, minFleet: 5 };
const MATURE = { fleetSize: 12, minFleet: 5 };

function agg(over: Partial<WeeklyAggregate> = {}): WeeklyAggregate {
  return {
    weekStart: '2026-08-24T00:00:00.000Z',
    headline: { anyApprovedReverted: false, reverted: [], distinctApproved: 2 },
    overall: { evaluations: 71, candidates: 12, distinctPrs: 6 },
    gradedCandidates: 11,
    byRepo: {},
    gateFailures: [
      { gate: 'checksGreen', count: 34 },
      { gate: 'classificationPermits', count: 20 },
    ],
    riskGrades: { medium: 11 },
    signalHealth: [
      { signal: 'internalConfidence', graded: 0, unknown: 1, eligible: 1 },
      { signal: 'semverDistance', graded: 11, unknown: 0, eligible: 11 },
    ],
    outcomes: { merged: 4, closed: 0, reverted: 0, postMergeFailure: 0, backfilled: 0 },
    recorderHealth: [
      { field: 'adoption', present: 5, of: 12, scope: 'candidates', note: 'deps.dev v3alpha' },
      { field: 'commitAuthorship', present: 33, of: 71, scope: 'evaluations' },
    ],
    scanned: 89,
    ...over,
  } as WeeklyAggregate;
}

const joined = (a: WeeklyAggregate, ctx = SMALL) => dots(a, ctx).join('\n');

test('a medium-heavy week in a SMALL fleet is called expected, with its numbers', () => {
  const out = joined(agg());
  assert.match(out, /medium/);
  assert.match(out, /11 of 11|expected/i);
});

test('a medium-heavy week in a MATURE fleet gets NO reassurance', () => {
  // THE load-bearing assertion of this file. Once the fleet is big enough for
  // corroboration to mean something, "expected this early" is a false claim —
  // and a false reassurance is worse than a bare number, because a bare number
  // never claims to be fine.
  const out = joined(agg({
    signalHealth: [{ signal: 'semverDistance', graded: 11, unknown: 0, eligible: 11 }],
  }), MATURE);
  assert.doesNotMatch(out, /expected this early/i);
  assert.doesNotMatch(out, /thin history/i);
  assert.match(out, /medium/, 'the distribution is still reported');
});

test('a CI-dominated week says so, naming the gate', () => {
  const out = joined(agg());
  assert.match(out, /checksGreen|had not reported/i);
});

test('a POLICY-dominated week makes no transience claim', () => {
  // classificationPermits cannot clear without a new commit. Calling it
  // transient would tell somebody to wait for something that will never happen.
  const out = joined(agg({
    gateFailures: [
      { gate: 'classificationPermits', count: 40 },
      { gate: 'checksGreen', count: 2 },
    ],
  }));
  assert.doesNotMatch(out, /had not reported/i);
  assert.doesNotMatch(out, /clear on its own|resolve on its own/i);
  assert.match(out, /classificationPermits/);
});

test('a label-dominated week is not described as CI', () => {
  // notBlocked IS in CI_DEPENDENT_GATES — it can clear without a commit — but
  // it clears because a human removes a label, not because CI reports. This is
  // the case that makes set membership the wrong basis for the CI sentence.
  const out = joined(agg({
    gateFailures: [{ gate: 'notBlocked', count: 30 }, { gate: 'checksGreen', count: 1 }],
  }));
  assert.doesNotMatch(out, /CI/);
  assert.match(out, /notBlocked|label/i);
});

test('a recorder whose scope and denominator disagree is explained', () => {
  const out = joined(agg());
  assert.match(out, /5 of 12/);
  assert.match(out, /candidate/i);
});

test('a recorder at full coverage produces no dot about it', () => {
  const out = joined(agg({
    recorderHealth: [
      { field: 'adoption', present: 12, of: 12, scope: 'candidates' },
      { field: 'commitAuthorship', present: 71, of: 71, scope: 'evaluations' },
    ],
  }));
  assert.doesNotMatch(out, /adoption/);
});

test('graded-vs-ungraded candidates are surfaced only when they differ', () => {
  assert.match(joined(agg({ overall: { evaluations: 71, candidates: 12, distinctPrs: 6 }, gradedCandidates: 11 })), /11 of 12|one candidate/i);
  assert.doesNotMatch(joined(agg({ gradedCandidates: 12 })), /of 12 candidates carry/i);
});

test('a week with no evaluations produces one dot, not zero', () => {
  // A post with no dots is indistinguishable from a broken renderer.
  const empty = agg({
    overall: { evaluations: 0, candidates: 0, distinctPrs: 0 },
    gradedCandidates: 0, gateFailures: [], riskGrades: {}, signalHealth: [],
    recorderHealth: [], scanned: 0,
  });
  assert.equal(dots(empty, SMALL).length >= 1, true);
});

test('never more than four dots', () => {
  // The whole premise is that a reader takes it in at a glance.
  assert.ok(dots(agg(), SMALL).length <= 4, `got ${dots(agg(), SMALL).length}`);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --import tsx --test tests/report-interpret.test.ts`
Expected: FAIL — `Cannot find module '../src/report/interpret.js'`

- [ ] **Step 3: Write `src/report/interpret.ts`**

```ts
// Turn a week's aggregate into three or four sentences a human can act on.
//
// THE ONLY MODULE HERE THAT ENCODES A JUDGMENT, which is why it is separate:
// query.ts counts and render.ts formats, but this file claims that a number
// means something. Claims need their own tests and their own review.
//
// EVERY SENTENCE HAS A PRECONDITION AND DISAPPEARS WHEN IT FAILS.
//
// "Expected this early; few repos and thin history" is true today and becomes a
// LIE at ten enrolled repositories. An interpretation with no expiry is worse
// than a raw number, because a raw number never claims to be fine. So each rule
// below states the condition under which its sentence is true, and renders
// nothing when that condition does not hold.
//
// Fleet size arrives as an ARGUMENT rather than from enrollment.fleetSize(),
// which reads the compiled POLICY — a precondition that cannot be varied in a
// test is a precondition nobody can prove expires.
import { CI_DEPENDENT_GATES } from '../evaluate.js';
import type { GateName } from '../gates.js';
import type { WeeklyAggregate } from './query.js';

/** What the interpretation needs beyond the week's own numbers. */
export interface InterpretContext {
  /** Repositories enrolled with a mode other than `off`. */
  fleetSize: number;
  /** `rules.risk.minFleetForConfidence` — below this, corroboration is meaningless. */
  minFleet: number;
}

/**
 * Gates that clear when CI reports, as opposed to when a human acts.
 *
 * A STRICT SUBSET of CI_DEPENDENT_GATES, and the distinction is the point.
 * That set means "can clear without a new commit", which also covers
 * `freezeOff` (somebody lifts a freeze) and `notBlocked` (somebody removes a
 * label). Describing either as "CI has not reported yet" would be false and
 * would tell a reader to wait for the wrong thing.
 */
const CI_REPORTING_GATES: ReadonlySet<string> = new Set(['checksGreen', 'coverageFloor']);

/** Human-readable cause for the gates that clear without a commit. */
const CLEARS_BY: Record<string, string> = {
  checksGreen: 'CI had not reported yet',
  coverageFloor: 'coverage had not been posted yet',
  freezeOff: 'automation is frozen',
  notBlocked: 'a label or draft state is holding them',
};

/** One candidate reading. `applies` gates it; `render` produces the sentence. */
interface Rule {
  applies: (a: WeeklyAggregate, ctx: InterpretContext) => boolean;
  render: (a: WeeklyAggregate, ctx: InterpretContext) => string;
}

const pct = (n: number, of: number): number => (of === 0 ? 0 : Math.round((n / of) * 100));

/**
 * Eligibility: what blocked, and whether it can clear on its own.
 *
 * Keys on the DOMINANT GATE BY NAME rather than on set membership, so the
 * wording describes what actually has to happen for the block to lift.
 */
const eligibility: Rule = {
  applies: (a) => a.gateFailures.length > 0,
  render: (a) => {
    const blocked = a.gateFailures.reduce((sum, g) => sum + g.count, 0);
    const top = a.gateFailures[0]!;
    const clears = CI_DEPENDENT_GATES.has(top.gate as GateName);

    if (!clears) {
      // Nothing to wait for: policy says no, and only a different pull request
      // changes that.
      return `Eligibility is doing real work — ${blocked} of ${a.overall.evaluations} evaluations `
        + `were blocked, most often by \`${top.gate}\`, which needs a different change rather `
        + 'than more time';
    }

    const cause = CLEARS_BY[top.gate] ?? 'the condition has not cleared yet';
    const ciFlavoured = CI_REPORTING_GATES.has(top.gate);
    return `Eligibility is doing real work — ${blocked} of ${a.overall.evaluations} evaluations `
      + `were blocked, and ${top.count} of those were \`${top.gate}\`: ${cause}`
      + (ciFlavoured ? ', which a later re-evaluation resolves on its own' : '');
  },
};

/**
 * Risk distribution, with the early-phase caveat ONLY while it is true.
 *
 * Precondition for the reassurance: the fleet is below the corroboration
 * threshold AND at least one signal is unknown on every graded evaluation.
 * Both are the actual mechanical causes of a medium skew this early. When
 * either stops holding, a medium-heavy week is a fact about the fleet and
 * deserves no comfort.
 */
const risk: Rule = {
  applies: (a) => Object.keys(a.riskGrades).length > 0,
  render: (a, ctx) => {
    const entries = Object.entries(a.riskGrades);
    const distribution = entries.map(([g, n]) => `${g}: ${n}`).join(', ');
    const graded = entries.reduce((sum, [, n]) => sum + n, 0);

    const smallFleet = ctx.fleetSize < ctx.minFleet;
    const alwaysUnknown = a.signalHealth.some((s) => s.eligible > 0 && s.unknown === s.eligible);
    const earlyPhase = smallFleet && alwaysUnknown;

    const head = entries.length === 1
      ? `Risk graded every candidate ${entries[0]![0]} (${graded} of ${graded})`
      : `Risk grades — ${distribution}`;

    if (!earlyPhase) return head;

    const always = a.signalHealth.filter((s) => s.eligible > 0 && s.unknown === s.eligible)
      .map((s) => `\`${s.signal}\``).join(', ');
    return `${head} — expected this early: ${ctx.fleetSize} of ${ctx.minFleet} repositories `
      + `enrolled, and ${always} cannot grade yet`;
  },
};

/**
 * A recorder whose coverage is below its own population's ceiling.
 *
 * Reports the honest fraction and names the population, because the misleading
 * version of this number ("5 of 71") is what prompted the rule.
 */
const recorders: Rule = {
  applies: (a) => a.recorderHealth.some((r) => r.of > 0 && r.present < r.of),
  render: (a) => {
    const thin = a.recorderHealth
      .filter((r) => r.of > 0 && r.present < r.of)
      .sort((x, y) => pct(x.present, x.of) - pct(y.present, y.of));
    const worst = thin.slice(0, 2);
    const names = worst.map((r) => `\`${r.field}\``).join(' and ');
    const figures = worst.map((r) => `${r.present} of ${r.of} ${r.scope}`).join(', ');
    return `${names} ${worst.length === 1 ? 'is' : 'are'} not at full coverage — ${figures}`;
  },
};

/**
 * Candidates that carry no risk grade at all.
 *
 * Live cause: one record written before the heuristics shipped. Correct
 * behaviour, and exactly the discrepancy that costs somebody an afternoon
 * unless the report names it.
 */
const gradeGap: Rule = {
  applies: (a) => a.gradedCandidates < a.overall.candidates,
  render: (a) => {
    const missing = a.overall.candidates - a.gradedCandidates;
    return `${a.gradedCandidates} of ${a.overall.candidates} candidates carry a risk grade — `
      + `${missing} predate${missing === 1 ? 's' : ''} the field and cannot be graded retroactively`;
  },
};

/** Nothing happened, and saying so is the point. */
const emptyWeek: Rule = {
  applies: (a) => a.overall.evaluations === 0,
  render: (a) => `No evaluations recorded — ${a.scanned} ledger records scanned, none in this window`,
};

// Order is priority: the first four that apply are the post. Eligibility and
// risk come first because they describe the service working; the other two are
// data-quality notes a reader needs less often.
const RULES: Rule[] = [emptyWeek, eligibility, risk, recorders, gradeGap];

const MAX_DOTS = 4;

/**
 * The dots for one week.
 *
 * Never empty: a post with no dots is indistinguishable from a broken
 * renderer, so the empty-week rule always has something to say.
 *
 * Never more than four: the whole premise is that a reader takes the post in
 * at a glance, and a fifth bullet is where that stops being true.
 */
export function dots(a: WeeklyAggregate, ctx: InterpretContext): string[] {
  const applicable = RULES.filter((r) => {
    try {
      return r.applies(a, ctx);
    } catch {
      // A rule that throws is a rule with a bug. A missing dot beats a report
      // that failed to post.
      return false;
    }
  });

  const rendered: string[] = [];
  for (const rule of applicable) {
    if (rendered.length >= MAX_DOTS) break;
    try {
      rendered.push(rule.render(a, ctx));
    } catch { /* same reasoning as above */ }
  }

  return rendered.length > 0
    ? rendered
    : [`${a.overall.evaluations} evaluations recorded; nothing else to report`];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --import tsx --test tests/report-interpret.test.ts`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add src/report/interpret.ts tests/report-interpret.test.ts
git commit -m "feat(report): interpret the week's numbers, with every claim gated on a precondition"
```

---

## Task 3: Split the renderer — channel post and thread replies

**Files:**
- Modify: `src/report/render.ts`
- Modify: `tests/report-render.test.ts`

**Interfaces:**
- Consumes: `dots()` (Task 2); `WeeklyAggregate` (Task 1).
- Produces: `renderChannelPost(aggregate, ctx)`, `renderThreadReplies(aggregate)` returning `{ section: string; blocks: SlackBlock[] }[]`, `DOC_ANCHORS`.

- [ ] **Step 1: Write the failing tests**

Replace `tests/report-render.test.ts`'s existing structural tests (the six that assert on the single-post shape) and add:

```ts
import { renderChannelPost, renderThreadReplies, DOC_ANCHORS } from '../src/report/render.js';

const SMALL = { fleetSize: 1, minFleet: 5 };
const allText = (blocks: any[]) => JSON.stringify(blocks);

test('the channel post is a headline plus dots, and carries no table', () => {
  const blocks = renderChannelPost(aggregate(week), SMALL);
  assert.equal(blocks.some((b: any) => b.type === 'table'), false,
    'tables belong in the thread');
  assert.match(allText(blocks), /reverted/i);
  assert.match(allText(blocks), /🧵/, 'the post points at the thread');
});

test('the channel post carries at most one caveat block', () => {
  // Four context blocks is what made the old post read as hedging. The revert
  // caveat earns its place next to the headline; the rest move to the thread.
  const blocks = renderChannelPost(aggregate(week), SMALL);
  assert.ok(blocks.filter((b: any) => b.type === 'context').length <= 1);
});

test('NO table cell anywhere is raw_number', () => {
  // The bug this replaces: Slack accepted a `raw_number` cell and rendered
  // nothing, hiding the entire gate-failure distribution while the run went
  // green. A shape test could not catch it; this rule can.
  const all = [
    ...renderChannelPost(aggregate(week), SMALL),
    ...renderThreadReplies(aggregate(week)).flatMap((r) => r.blocks),
  ];
  for (const block of all.filter((b: any) => b.type === 'table') as any[]) {
    for (const row of block.rows) {
      for (const cell of row) {
        assert.equal(cell.type, 'raw_text', `found ${cell.type} — Slack renders it blank`);
        assert.ok(typeof cell.text === 'string' && cell.text.length > 0,
          `empty cell text: ${JSON.stringify(cell)}`);
      }
    }
  }
});

test('gate-failure counts are present as visible text', () => {
  const reply = renderThreadReplies(aggregate(week)).find((r) => r.section === 'eligibility')!;
  assert.match(allText(reply.blocks), /checksGreen/);
  assert.match(allText(reply.blocks), /"1"|"2"|"3"/, 'the count renders as text');
});

test('thread replies come back in a fixed order regardless of content', () => {
  const order = (a: any) => renderThreadReplies(a).map((r) => r.section);
  assert.deepEqual(order(aggregate(week)),
    ['eligibility', 'risk', 'outcomes', 'recorders']);
  // Same order on a week with almost nothing in it: a thread whose shape
  // changes weekly is a thread nobody learns to skim.
  assert.deepEqual(order(aggregate([])),
    ['eligibility', 'risk', 'outcomes', 'recorders']);
});

test('every reply links to its own anchor in the docs', () => {
  for (const reply of renderThreadReplies(aggregate(week))) {
    const anchor = DOC_ANCHORS[reply.section as keyof typeof DOC_ANCHORS];
    assert.ok(anchor, `no anchor declared for ${reply.section}`);
    assert.match(allText(reply.blocks), new RegExp(`docs/weekly-report\\.md#${anchor}`));
  }
});

test('recorder fractions name their population', () => {
  const reply = renderThreadReplies(aggregate(week)).find((r) => r.section === 'recorders')!;
  assert.match(allText(reply.blocks), /candidates|evaluations/);
});

test('the signal table shows the eligible count', () => {
  const reply = renderThreadReplies(aggregate(week)).find((r) => r.section === 'risk')!;
  assert.match(allText(reply.blocks), /[Ee]ligible|could have/);
});

test('the risk reply states the scanned record count', () => {
  // F7: the number somebody needs to notice the scan growing, in front of them
  // weekly rather than discovered during an incident.
  const replies = renderThreadReplies(aggregate(week));
  assert.match(allText(replies.flatMap((r) => r.blocks)), /scanned/i);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --import tsx --test tests/report-render.test.ts`
Expected: FAIL — `renderChannelPost` is not exported.

- [ ] **Step 3: Restructure `src/report/render.ts`**

Delete `rawNumber` entirely — it has one call site and it is the F1 bug. Keep
`rawText`, `table`, `section`, `context`, `header`, `divider`, `fraction`.

Add the anchor map, which is the trail's contract:

```ts
/**
 * Where each thread reply points for the full explanation.
 *
 * Declared in one place because `tests/report-docs.test.ts` asserts every one
 * of these resolves to a real heading in docs/weekly-report.md. A trail that
 * dead-ends is worse than no trail — it is invisible to everyone except the
 * person who most needed it.
 */
export const DOC_ANCHORS = {
  eligibility: 'eligibility--what-blocked',
  risk: 'risk-and-signal-health',
  outcomes: 'outcomes',
  recorders: 'recorder-health',
} as const;

const DOC = 'https://github.com/bankrate/zapp/blob/main/docs/weekly-report.md';
const docLink = (section: keyof typeof DOC_ANCHORS): string =>
  `<${DOC}#${DOC_ANCHORS[section]}|Where this comes from →>`;
```

`renderChannelPost`:

```ts
/**
 * Layer 1: the channel post. A headline, three or four dots, one pointer.
 *
 * NO TABLES AND AT MOST ONE CAVEAT. Four context blocks is what made the old
 * post read as hedging; the revert caveat earns its place beside the headline
 * because "no reverts" is the one number a reader might over-trust.
 */
export function renderChannelPost(a: WeeklyAggregate, ctx: InterpretContext): SlackBlock[] {
  const week = a.weekStart ? ` — week of ${a.weekStart.slice(0, 10)}` : '';

  const answer = a.headline.anyApprovedReverted
    ? `*Yes* — ${a.headline.reverted.map((r) => `${r.repo}#${r.prNumber}`).join(', ')} `
      + 'would have been approved and was reverted.'
    : a.overall.evaluations === 0
      ? 'No evaluations recorded this week.'
      : `No would-have-approved pull request was reverted. `
        + `${a.headline.distinctApproved} of ${a.overall.distinctPrs} pull requests would have been candidates.`;

  return [
    header(`Weekly Shadow Report${week}`),
    section(answer),
    context(REVERT_CAVEAT),
    section(dots(a, ctx).map((d) => `• ${d}`).join('\n')),
    context(`🧵 Numbers, tables and caveats in thread · <${DOC}|full reference>`),
  ];
}
```

Note the headline is now **per pull request** (`distinctApproved` of `distinctPrs`) — F3. The evaluation-level fraction moves to the eligibility reply with its skew stated.

`renderThreadReplies`:

```ts
/** One thread reply: which section it is, and the blocks to post. */
export interface ThreadReply {
  section: keyof typeof DOC_ANCHORS;
  blocks: SlackBlock[];
}

/**
 * Layer 2: the numbers.
 *
 * FIXED ORDER, ALWAYS ALL FOUR, even when a section has nothing — a thread
 * whose shape changes weekly is a thread nobody learns to skim, and "no gate
 * failures this week" is itself information.
 */
export function renderThreadReplies(a: WeeklyAggregate): ThreadReply[] {
  return [
    { section: 'eligibility', blocks: eligibilityReply(a) },
    { section: 'risk', blocks: riskReply(a) },
    { section: 'outcomes', blocks: outcomesReply(a) },
    { section: 'recorders', blocks: recordersReply(a) },
  ];
}
```

The four reply builders carry what the old sections carried, plus the fixes:

- `eligibilityReply` — the ranked gate table with **`rawText(String(count))`** (F1); the per-evaluation fraction with its skew stated: `12 of 71 evaluations — note one pull request can be re-evaluated many times, so this is not a per-PR rate` (F3); `docLink('eligibility')`.
- `riskReply` — the grade distribution; the signal table with a fourth column `Eligible` from `signalHealth[].eligible` and a line explaining that a lower eligible count means the signal is newer than some records (F5); the graded-vs-candidates line when they differ (F6); `${a.scanned} ledger records scanned` (F7); `docLink('risk')`.
- `outcomesReply` — unchanged content; post-merge failures keep their own line and their own caveat; `docLink('outcomes')`.
- `recordersReply` — fractions with their population named (F2); `RECORDER_CAVEAT`; `docLink('recorders')`.

Keep `renderJson` exactly as it is. The archive shape is consumed by later
analysis and should not follow the post's layout.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 5: Verify `rawNumber` is gone**

```bash
grep -rn 'raw_number\|rawNumber' src/ tests/
```

Expected: **no output.** A single surviving occurrence is the F1 bug still shipping.

- [ ] **Step 6: Commit**

```bash
git add src/report/render.ts tests/report-render.test.ts
git commit -m "feat(report): split the post into dots and a thread, and make counts visible"
```

---

## Task 4: Post the parent, then the thread

**Files:**
- Modify: `src/report/index.ts`
- Modify: `tests/report-index.test.ts`

**Interfaces:**
- Produces: `postSlack(token, channel, blocks, threadTs?)` returning the message `ts`.

- [ ] **Step 1: Write the failing tests**

```ts
test('the parent posts first, then every reply, threaded to it', async () => {
  const calls: any[] = [];
  const { deps: d } = deps({
    postSlack: async (t: string, c: string, b: unknown, threadTs?: string) => {
      calls.push({ threadTs }); return 'ts-parent';
    },
  });
  await main(env as any, d);
  assert.equal(calls[0].threadTs, undefined, 'parent is not threaded');
  assert.equal(calls.length, 5, 'parent plus four replies');
  assert.ok(calls.slice(1).every((c) => c.threadTs === 'ts-parent'));
});

test('a failed parent posts nothing else', async () => {
  let count = 0;
  const { deps: d } = deps({
    postSlack: async () => { count++; throw new Error('channel_not_found'); },
  });
  await assert.rejects(() => main(env as any, d), /channel_not_found/);
  assert.equal(count, 1, 'no replies attempted against a parent that never landed');
});

test('a failed reply leaves the parent up, names the section, and fails the run', async () => {
  // The parent carries the essential content. Losing a detail reply degrades
  // the report; it does not void it. And nothing is deleted — a thread missing
  // its fourth reply is legible, a half-deleted thread is not.
  let posted = 0;
  const { deps: d } = deps({
    postSlack: async (t: string, c: string, b: unknown, threadTs?: string) => {
      posted++;
      if (posted === 3) throw new Error('rate_limited');
      return 'ts-parent';
    },
  });
  await assert.rejects(() => main(env as any, d), /risk|rate_limited/);
  assert.ok(posted >= 3, 'the parent and the first reply stay up');
});

test('the scanned count is the pre-window total, not the windowed one', async () => {
  // F7 only means something if the number reflects what the scan actually read.
  const captured: any[] = [];
  const { deps: d } = deps({
    fetchWeek: async () => [
      { pk: 'repo#o/r#pr#1', sk: 'eval#2026-08-25T00:00:00Z', repo: 'o/r', verdict: 'candidate' },
      { pk: 'repo#o/r#pr#2', sk: 'eval#2020-01-01T00:00:00Z', repo: 'o/r', verdict: 'candidate' },
    ],
    putObject: async (k: string, body: string) => { captured.push(JSON.parse(body)); },
  });
  await main({ ...env, REPORT_START_DATE: '2026-08-24', REPORT_END_DATE: '2026-08-31' } as any, d);
  assert.equal(captured[0].scanned, 2, 'both records were read, one was outside the window');
  assert.equal(captured[0].overall.evaluations, 1);
});
```

- [ ] **Step 2: Return the `ts` from `postSlack` and accept a `thread_ts`**

```ts
/**
 * Post to a channel, optionally as a threaded reply.
 *
 * Returns the message `ts`, which the caller passes back as `threadTs` for
 * every reply. That is the whole thread mechanism — no new scope, no new API.
 */
export async function postSlack(
  token: string, channel: string, body: SlackBlocks, threadTs?: string,
): Promise<string> {
  const res = await fetch('https://slack.com/api/chat.postMessage', {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify({ channel, blocks: body, ...(threadTs ? { thread_ts: threadTs } : {}) }),
  });

  if (!res.ok) throw new Error(`chat.postMessage HTTP ${res.status}`);

  const payload = (await res.json()) as {
    ok?: boolean; ts?: string; error?: string; errors?: string[];
    response_metadata?: { messages?: string[] };
  };
  if (payload.ok !== true) {
    const detail = payload.response_metadata?.messages ?? payload.errors;
    const suffix = detail && detail.length > 0 ? ` — ${detail.join('; ')}` : '';
    throw new Error(`chat.postMessage failed: ${payload.error ?? 'unknown error'}${suffix}`);
  }
  if (!payload.ts) throw new Error('chat.postMessage succeeded without a ts — cannot thread replies');
  return payload.ts;
}
```

- [ ] **Step 3: Thread it in `main()`**

Replace the single post at the end. Note `scanned` is overwritten with the
**pre-window** count, which is the number F7 needs:

```ts
  const records = await deps.fetchWeek(table, since);
  const windowed = withinWindow(records, since, until);
  let summary = {
    ...aggregate(windowed),
    weekStart: since.toISOString(),
    // aggregate() only ever sees the windowed array. The figure worth surfacing
    // is what the SCAN read, which grows with the whole table (see F7).
    scanned: records.length,
  };
```

and, after the archive:

```ts
  const interpretCtx = { fleetSize: fleetSize(), minFleet: rules().risk.minFleetForConfidence };

  // Parent first, and alone if it fails: nothing partial gets published.
  const parentTs = await deps.postSlack(token, channel, renderChannelPost(summary, interpretCtx));

  // Replies are detail. A failure here degrades the report rather than voiding
  // it, so the parent stays up — but the run still goes red, and the error
  // names the section so the next person knows which reply is missing.
  for (const reply of renderThreadReplies(summary)) {
    try {
      await deps.postSlack(token, channel, reply.blocks, parentTs);
    } catch (err) {
      throw new Error(
        `weekly report posted, but the "${reply.section}" thread reply failed: `
        + `${err instanceof Error ? err.message : String(err)}`);
    }
  }
```

Import `fleetSize` from `../enrollment.js` and `rules` from `../rules.js`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/report/index.ts tests/report-index.test.ts
git commit -m "feat(report): post the dots, then thread the numbers under them"
```

---

## Task 5: `docs/weekly-report.md`, and shrink `policy.md`

The bottom of the trail. Without it, "dive deeper" terminates in a Slack message.

**Files:**
- Create: `docs/weekly-report.md`
- Create: `tests/report-docs.test.ts`
- Modify: `docs/policy.md:293-328`

- [ ] **Step 1: Write the anchor test first**

Create `tests/report-docs.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DOC_ANCHORS } from '../src/report/render.js';

const doc = readFileSync('docs/weekly-report.md', 'utf8');

/** GitHub's heading-to-anchor rule: lowercase, drop punctuation, spaces to hyphens. */
const slug = (heading: string): string => heading
  .toLowerCase()
  .replace(/[^\w\s-]/g, '')
  .trim()
  .replace(/\s+/g, '-');

const headings = doc.split('\n')
  .filter((l) => l.startsWith('#'))
  .map((l) => slug(l.replace(/^#+\s*/, '')));

test('every anchor the report links to exists as a heading', () => {
  // The trail IS the product of this change. A broken anchor is invisible to
  // everyone except the person who most needed it, which is why this is a test
  // and not a convention.
  for (const [section, anchor] of Object.entries(DOC_ANCHORS)) {
    assert.ok(headings.includes(anchor),
      `docs/weekly-report.md has no heading slugging to "${anchor}" (for ${section}). `
      + `Headings found: ${headings.join(', ')}`);
  }
});

test('policy.md points at the report doc rather than restating it', () => {
  const policy = readFileSync('docs/policy.md', 'utf8');
  assert.match(policy, /weekly-report\.md/);
  // The 33-line line-anchored provenance list moved. If these come back,
  // policy.md is drifting from the report doc again.
  assert.doesNotMatch(policy, /query\.ts#L\d+/);
  assert.doesNotMatch(policy, /render\.ts#L\d+/);
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `node --import tsx --test tests/report-docs.test.ts`
Expected: FAIL — `docs/weekly-report.md` does not exist.

- [ ] **Step 3: Write `docs/weekly-report.md`**

Seed it from `/Users/scrosby/Projects/research/2026-08-28-zapp-weekly-report-provenance.md`, taking **only the durable half**. That file mixes two kinds of content and only one belongs in the repo:

| Take | Leave |
|---|---|
| The pipeline diagram | The seven findings |
| The per-section provenance map | The live corpus snapshot |
| The DynamoDB schema reference | Anything dated |
| What `unknown` means per signal | |
| The caveats moved out of the post | |

Copying the findings in would ship a snapshot of bugs as if it were reference —
and this plan fixes them, so they would be wrong within a day.

Required headings, whose slugs the test above pins:

```markdown
# Reading the weekly shadow report

## How to read the post
## Eligibility — what blocked
## Risk and signal health
## Outcomes
## Recorder health
## Where each number comes from
## What the ledger stores
```

`## Eligibility — what blocked` slugs to `eligibility--what-blocked` — an em
dash produces **two** hyphens, which is why `DOC_ANCHORS` spells it that way.
If you reword a heading, the test tells you immediately.

Each section answers three things: what the number is, what makes it `unknown`
or absent, and which function computes it. The per-signal `unknown` captions
currently living in `render.ts`'s `SIGNAL_UNKNOWN_CAPTIONS` are the seed for the
risk section — they are already written well; move the prose here and keep the
map in code for the table.

- [ ] **Step 4: Replace `policy.md`'s provenance section**

Delete lines 293–328 (the whole "Where the weekly shadow report's numbers come from" section) and replace with:

```markdown
## The weekly report

Separately from the two per-pull-request checks above, this service posts a
weekly fleet summary to Slack: a short post with three or four findings, and a
thread carrying the numbers behind each one.

It answers a different question from this document — "how is the fleet doing"
rather than "why did this check say that about my pull request" — so it has its
own reference: **[Reading the weekly shadow report](weekly-report.md)**. That
covers what each number means, what makes a signal `unknown`, and which
function computes it.
```

- [ ] **Step 5: Run the docs test**

Run: `node --import tsx --test tests/report-docs.test.ts`
Expected: PASS, 2 tests.

- [ ] **Step 6: Full verification**

```bash
pnpm run typecheck && pnpm test && pnpm run build
grep -rn 'cumulativeApproved\|raw_number\|rawNumber' src/ tests/ docs/
```

Expected: all pass; the grep returns nothing.

- [ ] **Step 7: Commit**

```bash
git add docs/weekly-report.md docs/policy.md tests/report-docs.test.ts
git commit -m "docs: add the weekly-report reference and point policy.md at it"
```

---

## Task 6: Live validation

**Files:** none.

- [ ] **Step 1: Open the PR and run the report on demand**

```bash
gh pr create --repo bankrate/zapp --base main \
  --title "feat(PLAT-1184): make the weekly report readable and its denominators honest" \
  --body "Implements docs/superpowers/zapp/specs/2026-08-28-report-legibility-design.md (Spec J)."
```

After merge:

```bash
gh workflow run weekly-report.yml --repo bankrate/zapp \
  -f start_date=2026-08-24 -f end_date=2026-08-31
gh run watch --repo bankrate/zapp
```

Use the same window the analysed post used, so the output is directly comparable to the screenshot in the spec.

- [ ] **Step 2: Confirm the post against the numbers already verified**

The live corpus for that window is known, so these are exact expectations, not eyeballing:

| Expect | Value |
|---|---|
| Headline | `2 of 6 pull requests would have been candidates` |
| Gate counts **visible** | `checksGreen 34`, `classificationPermits 20`, `changeClass 3`, `botAllowlisted 2` |
| `adoption` | `5 of 12 candidates` — **not** 5 of 71 |
| `commitAuthorship` | `33 of 71 evaluations` |
| Risk dot | mentions `medium`, `11 of 11`, and the early-phase reason |
| Grade-gap dot | `11 of 12 candidates carry a risk grade` |
| Scanned | `89` (or higher if the table has grown) |
| Dots | between 1 and 4 |
| Thread | exactly four replies, in order |

**The gate counts are the one to check first.** They are the whole reason F1 was ranked first, and they are the only item here whose failure mode is silent.

- [ ] **Step 3: Confirm the trail actually works**

Click the "Where this comes from →" link in each of the four replies. Each must land on a real heading in `docs/weekly-report.md`, not the top of the file. A test asserts the anchors exist; only a human can confirm they land somewhere useful.

- [ ] **Step 4: Report the outcome**

Paste the new post beside the old one. State whether the dots read as something a human would act on, and whether any dot is doing the thing this whole spec exists to prevent — asserting a number is fine without saying why.

---

## Definition of done

- [ ] The channel post is a headline plus 3–4 dots, and nothing else *(Task 3)*
- [ ] Every dot carries both a claim and its number *(Task 2)*
- [ ] The post has at most one caveat block *(Task 3)*
- [ ] Thread replies land in fixed order: eligibility · risk · outcomes · recorders *(Tasks 3, 4)*
- [ ] Every reply links to its own anchor, and every anchor resolves *(Tasks 3, 5)*
- [ ] "Expected this early" vanishes at a 12-repo fleet, proven by a fixture *(Task 2)*
- [ ] A policy-dominated week makes no transience claim; a label-dominated week is not called CI *(Task 2)*
- [ ] Gate-failure counts are visible in the rendered post *(Tasks 3, 6)* — **F1**
- [ ] No table cell anywhere is `raw_number`, asserted across parent and replies *(Task 3)* — **F1**
- [ ] Recorder fractions name their population; candidate-scoped fields divide by candidates *(Tasks 1, 3)* — **F2**
- [ ] The headline is per pull request; the per-evaluation fraction is in the thread with its skew stated *(Tasks 1, 3)* — **F3**
- [ ] `cumulativeApproved` is renamed `distinctApproved` and the old name appears nowhere *(Task 1)* — **F4**
- [ ] The signal table shows how many evaluations could have carried each signal *(Tasks 1, 3)* — **F5**
- [ ] Graded-vs-ungraded candidates are stated when they differ *(Tasks 1, 2)* — **F6**
- [ ] The thread states the pre-window scanned record count *(Tasks 1, 4)* — **F7**
- [ ] `CI_DEPENDENT_GATES` is exported and used for what it means, not for a CI claim *(Tasks 1, 2)*
- [ ] `docs/weekly-report.md` exists; `policy.md`'s provenance section is a pointer *(Task 5)*
- [ ] A failed parent posts nothing else; a failed reply leaves the parent up and reddens the run *(Task 4)*
- [ ] Zero evaluations still posts, with at least one dot *(Tasks 2, 3)*
