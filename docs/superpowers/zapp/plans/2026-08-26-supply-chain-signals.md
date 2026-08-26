# Supply-chain signals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the merge-policy risk grade answer "is this specific version safe to take?" — a tiered cooldown that grades sub-day releases `high`, a seventh signal reading whether the target version is advised or deprecated, and two record-only fields (provenance regression and adoption) collected now so Phase 1 can derive thresholds instead of guessing them.

**Architecture:** Fetching moves out of `src/signals/publish-age.ts` into a new `src/signals/version-records.ts`, so one deps.dev fetch pass feeds two pure grading functions plus the provenance recorder. `publishAge` and the new `targetVersionHealth` both become pure functions over that record set. Adoption is one extra `v3alpha` call for the governing bump only, recorded and never graded. Nothing about shadow mode changes: both check runs stay `neutral` and on no required-checks configuration.

**Tech Stack:** TypeScript (ESM, `node22` target), Node's built-in test runner via `node --import tsx --test`, esbuild bundle, AWS Lambda, DynamoDB, `api.deps.dev`.

**Spec:** [`../specs/2026-08-26-supply-chain-signals-design.md`](../specs/2026-08-26-supply-chain-signals-design.md)

## Before you start

**This plan requires PR #16 (Spec E, `fm/plat1233-zapp-policy-correctness`) to be merged first.** Task 4 extends `combine()`'s reducer floor, which PR #16 introduces. If `src/risk.ts` on your base has no `publishAgeKnown` constant, you are on the wrong base — stop and say so.

Verify your base:

```bash
git log --oneline -1 && grep -c publishAgeKnown src/risk.ts
```

Expected: a commit at or after PR #16's merge, and `1`.

## Global Constraints

- **Shadow mode is unchanged.** Both check runs keep `conclusion: 'neutral'`. Nothing in this plan may add a write permission, a merge, an approval, or a required-checks entry.
- **`unknown` is never guessed.** An absent field and an empty array are different facts. A missing `advisoryKeys` grades `unknown`, never `low`. This is the exact inversion Spec E existed to fix; do not reintroduce it.
- **Never grade on provenance or adoption.** Both are recorded only. No check-run row, no effect on any verdict.
- **Signal count is 7.** Every rendering that said "of 6" says "of 7". Derive it from `SIGNAL_ROWS.length` rather than writing the literal, so it cannot drift a third time.
- **deps.dev v3 is load-bearing; v3alpha is not.** A v3 failure degrades `publishAge` and `targetVersionHealth` to `unknown`. A v3alpha failure records `null` and logs `adoption_unavailable`; it never affects a grade.
- **Concurrency stays at 8, request timeout at 3,000 ms.** The function budget is 30 seconds (our own choice in `infrastructure/terraform/main.tf`, not a GitHub limit). Do not raise the Lambda timeout in this plan — the queue's 6:1 visibility-timeout ratio would have to move with it.
- **Cooldown tiers are lowercase semver level names** (`patch`, `minor`, `major`), validated at build time. An invalid `policy-rules.yaml` must fail the build, never the Lambda.
- **Fixtures are real captured responses.** Do not hand-write a deps.dev body. Capture it with the `curl` in Task 1.

## Deviation from the spec, and why

The spec's file table says `src/signals/publish-age.ts` grows to "return the full deps.dev record". This plan instead extracts fetching into a new `src/signals/version-records.ts` and leaves `publish-age.ts` holding only its grading rule.

The reason is that three consumers now need the same fetched record — publish age, target-version health, and the provenance recorder — and the spec's "two signals read one fetch" requirement becomes structural rather than a comment someone can later violate. It also makes both signals pure functions over a record array, which is why every grading test below runs without a fake fetch.

`mapWithConcurrency` moves with the fetching. Its two existing tests move with it.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/signals/version-records.ts` | **New.** Fetch one deps.dev version record; collect target and from records for every bump; derive provenance observations. Owns `mapWithConcurrency`. |
| `src/signals/publish-age.ts` | Grade age against the per-level cooldown, `high` under a day. Pure — no fetching. |
| `src/signals/target-health.ts` | **New.** Grade advisories and deprecation off the same records. Pure. |
| `src/signals/adoption.ts` | **New.** One `v3alpha` dependents call for the governing bump. Record-only. |
| `src/classify.ts` | Gains `governingBump()`, so `render.ts` and `adoption.ts` cannot drift on what "the bump that set the class" means. |
| `src/risk.ts` | Seventh signal in `RiskSignals`, in the comparison set, and in the reducer floor. |
| `src/render.ts` | Seventh row; count derived from `SIGNAL_ROWS.length`. |
| `src/evaluate.ts` | One fetch pass; both signals; the two recorders. |
| `src/ledger.ts` | `provenance` and `adoption` on the eval record. |
| `src/rules-types.ts` | `CooldownTiers` replaces `cooldownDays`. |
| `scripts/build-rules.mjs` | Validate the tiered object; reject a stale `cooldownDays`. |
| `policy-rules.yaml` | The tiered values. |

---

## Task 1: Version records — one fetch, the whole body

Today `fetchPublishedAt` reads one field out of an 834-byte response and discards the rest. This task keeps every grade byte-identical while putting the whole record in hand.

**Files:**
- Create: `src/signals/version-records.ts`
- Create: `tests/signals-version-records.test.ts`
- Create: `tests/fixtures/deps-dev-lodash-4.17.20.json`
- Create: `tests/fixtures/deps-dev-har-validator-5.1.5.json`
- Create: `tests/fixtures/deps-dev-sigstore-sign-3.1.0.json`
- Modify: `src/signals/publish-age.ts` (remove fetching, take records)
- Modify: `src/evaluate.ts:74-87,115-131` (dep rename, fetch pass)
- Modify: `tests/signals-publish-age.test.ts` (rewrite against records)
- Modify: `tests/evaluate.test.ts:103,123,146`
- Modify: `tests/fixtures/README.md`

**Interfaces:**
- Consumes: `DependencyBump` from `src/classify.ts` (`{ name, from, to, level }`).
- Produces: `VersionRecord`, `BumpRecord`, `fetchVersionRecord`, `collectVersionRecords`, `mapWithConcurrency` from `src/signals/version-records.ts`; `publishAge(records, cooldown, now)` from `src/signals/publish-age.ts`.

- [ ] **Step 1: Capture the three new fixtures**

These are real responses. Do not edit them afterwards.

```bash
curl -s 'https://api.deps.dev/v3/systems/npm/packages/lodash/versions/4.17.20' \
  | python3 -m json.tool > tests/fixtures/deps-dev-lodash-4.17.20.json
curl -s 'https://api.deps.dev/v3/systems/npm/packages/har-validator/versions/5.1.5' \
  | python3 -m json.tool > tests/fixtures/deps-dev-har-validator-5.1.5.json
curl -s 'https://api.deps.dev/v3/systems/npm/packages/%40sigstore%2Fsign/versions/3.1.0' \
  | python3 -m json.tool > tests/fixtures/deps-dev-sigstore-sign-3.1.0.json
```

Confirm each carries what the tests below rely on:

```bash
python3 - <<'PY'
import json
def load(p): return json.load(open(p))
lod = load('tests/fixtures/deps-dev-lodash-4.17.20.json')
har = load('tests/fixtures/deps-dev-har-validator-5.1.5.json')
sig = load('tests/fixtures/deps-dev-sigstore-sign-3.1.0.json')
assert len(lod['advisoryKeys']) == 5, lod['advisoryKeys']
assert har['isDeprecated'] is True and har['advisoryKeys'] == []
assert len(sig['slsaProvenances']) == 1
print('fixtures ok')
PY
```

Expected: `fixtures ok`. If `har-validator@5.1.5` has since picked up an advisory, pick another deprecated-but-unadvised version (`popper.js@1.16.1`, `core-js@2.6.12`) and rename the fixture to match.

- [ ] **Step 2: Write the failing test**

Create `tests/signals-version-records.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  fetchVersionRecord, collectVersionRecords, mapWithConcurrency,
} from '../src/signals/version-records.js';
import type { DependencyBump } from '../src/classify.js';

const body = (p: string) => JSON.parse(readFileSync(`tests/fixtures/${p}`, 'utf8'));
const lodash = body('deps-dev-lodash-4.17.20.json');
const har = body('deps-dev-har-validator-5.1.5.json');
const sigstore = body('deps-dev-sigstore-sign-3.1.0.json');
const fastify = body('deps-dev-fastify-5.12.0.json');

const okFetch = (payload: unknown) => (async () => ({
  ok: true, status: 200, json: async () => payload,
})) as unknown as typeof fetch;

test('an advised version reports its GHSA ids', async () => {
  const r = await fetchVersionRecord('lodash', '4.17.20', okFetch(lodash));
  assert.deepEqual(r!.advisoryIds, [
    'GHSA-29mw-wpgm-hmr9', 'GHSA-35jh-r3h4-6jhm', 'GHSA-f23m-r3pf-42rh',
    'GHSA-r5fr-rjxr-66jc', 'GHSA-xxjr-mmjv-4gpg',
  ]);
  assert.equal(r!.isDeprecated, false);
  assert.equal(r!.hasProvenance, false);
});

test('a deprecated version reports its reason', async () => {
  const r = await fetchVersionRecord('har-validator', '5.1.5', okFetch(har));
  assert.equal(r!.isDeprecated, true);
  assert.match(r!.deprecatedReason!, /no longer supported/);
  assert.deepEqual(r!.advisoryIds, [], 'present-but-empty is clean, not unknown');
});

test('provenance is read from either array', async () => {
  const r = await fetchVersionRecord('@sigstore/sign', '3.1.0', okFetch(sigstore));
  assert.equal(r!.hasProvenance, true);
  const plain = await fetchVersionRecord('fastify', '5.12.0', okFetch(fastify));
  assert.equal(plain!.hasProvenance, false);
});

test('an ABSENT advisoryKeys field is null, never an empty array', async () => {
  // The whole point: absent and empty mean different things. Reading a missing
  // field as "clean" is the A1 inversion Spec E existed to remove.
  const r = await fetchVersionRecord('x', '1.0.0', okFetch({ publishedAt: '2020-01-01T00:00:00Z' }));
  assert.equal(r!.advisoryIds, null);
  assert.equal(r!.isDeprecated, null);
  assert.equal(r!.hasProvenance, null);
});

test('a non-ok response and a thrown fetch both yield null', async () => {
  const notOk = (async () => ({ ok: false, status: 404 })) as unknown as typeof fetch;
  const boom = (async () => { throw new Error('ETIMEDOUT'); }) as unknown as typeof fetch;
  assert.equal(await fetchVersionRecord('x', '1.0.0', notOk), null);
  assert.equal(await fetchVersionRecord('x', '1.0.0', boom), null);
});

test('the URL encodes a scoped name and strips nothing else', async () => {
  const calls: string[] = [];
  const spy = (async (url: string) => {
    calls.push(url);
    return { ok: true, status: 200, json: async () => fastify };
  }) as unknown as typeof fetch;
  await fetchVersionRecord('@fastify/jwt', '10.2.2', spy);
  assert.deepEqual(calls, [
    'https://api.deps.dev/v3/systems/npm/packages/%40fastify%2Fjwt/versions/10.2.2',
  ]);
});

test('collect fetches BOTH sides of every bump, range operators stripped', async () => {
  const asked: string[] = [];
  const bumps: DependencyBump[] = [
    { name: 'fastify', from: '^5.11.2', to: '^5.12.0', level: 'minor' },
  ];
  const records = await collectVersionRecords(bumps, {
    fetchVersionRecord: async (n, v) => { asked.push(`${n}@${v}`); return null; },
  });
  assert.deepEqual(asked.sort(), ['fastify@5.11.2', 'fastify@5.12.0']);
  assert.equal(records.length, 1);
  assert.equal(records[0]!.bump.name, 'fastify');
});

test('an unparseable version is not fetched and yields a null record', async () => {
  const asked: string[] = [];
  const bumps: DependencyBump[] = [
    { name: 'local-pkg', from: 'workspace:*', to: 'workspace:*', level: 'none' },
  ];
  const records = await collectVersionRecords(bumps, {
    fetchVersionRecord: async (n, v) => { asked.push(`${n}@${v}`); return null; },
  });
  assert.deepEqual(asked, [], 'nothing to look up');
  assert.equal(records[0]!.target, null);
  assert.equal(records[0]!.from, null);
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

- [ ] **Step 3: Run test to verify it fails**

Run: `pnpm test 2>&1 | grep -A3 signals-version-records`
Expected: FAIL — `Cannot find module '../src/signals/version-records.js'`

- [ ] **Step 4: Write `src/signals/version-records.ts`**

```ts
// One deps.dev version record, fetched once and read by several signals.
//
// SOURCE: api.deps.dev, NOT registry.npmjs.org. npm exposes publish timestamps
// only in the full packument (`GET /{pkg}`) — the per-version endpoint has no
// time field at all — and a popular package's packument is enormous (fastify's
// is 1,780,110 bytes). Eleven of those per evaluation would pull ~20 MB into a
// 256 MB Lambda. deps.dev returns the same record in 834 bytes, and the one
// response also carries advisory ids, deprecation and provenance.
//
// Fetching lives here rather than inside a signal because THREE consumers read
// the same record — publish age, target-version health, and the provenance
// recorder. Keeping the fetch separate makes "one fetch, several readers" a
// structural fact rather than a comment somebody can later violate.
//
// The cost is a dependency on a third party neither Bankrate nor GitHub
// operates. It is acceptable ONLY because the failure mode was designed: a
// slow, down, or reshaped deps.dev yields null, which every reader turns into
// `unknown`. No evaluation fails and no check run is lost.
import type { DependencyBump } from '../classify.js';

const DEPS_DEV = 'https://api.deps.dev/v3/systems/npm/packages';

// Bounds outbound fan-out: a grouped bump can carry a dozen packages, each
// costing two lookups, inside a 30s budget shared with several GitHub calls.
const CONCURRENCY = 8;
const REQUEST_TIMEOUT_MS = 3_000;

// Strips range operators: `^5.12.0` -> `5.12.0`.
const VERSION = /(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)/;

/**
 * One version as deps.dev describes it.
 *
 * Every field is nullable, and null means ABSENT, not empty. `advisoryIds: []`
 * is "deps.dev looked and found nothing"; `advisoryIds: null` is "deps.dev did
 * not tell us". Grading the second as the first is exactly the inversion that
 * made an unscanned commit read `low` before Spec E.
 */
export interface VersionRecord {
  publishedAt: string | null;
  advisoryIds: string[] | null;
  isDeprecated: boolean | null;
  deprecatedReason: string | null;
  hasProvenance: boolean | null;
}

/** One bump with both sides resolved. Either side may be null. */
export interface BumpRecord {
  bump: DependencyBump;
  /** The version being installed. */
  target: VersionRecord | null;
  /** The version being replaced. Fetched only for the provenance comparison. */
  from: VersionRecord | null;
}

/** Injectable collaborator (the real implementation by default). */
export interface VersionRecordDeps {
  fetchVersionRecord: (name: string, version: string) => Promise<VersionRecord | null>;
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

/** Strip range operators from a manifest version, or null if it is not semver. */
export function bareVersion(spec: string): string | null {
  return VERSION.exec(spec)?.[1] ?? null;
}

/**
 * Fetch one version's record.
 *
 * Args:
 *   name: Package name. Scoped names are URL-encoded (`@fastify/jwt` becomes
 *     `%40fastify%2Fjwt`), which `encodeURIComponent` handles.
 *   version: A bare semver, already stripped of range operators.
 *   fetchImpl: Injectable fetch.
 * Returns:
 *   The record, or null on any failure — a 404, a timeout, malformed JSON.
 *   Null becomes `unknown` upstream, never a guess.
 */
export async function fetchVersionRecord(
  name: string,
  version: string,
  fetchImpl: typeof fetch = fetch,
): Promise<VersionRecord | null> {
  try {
    const url = `${DEPS_DEV}/${encodeURIComponent(name)}/versions/${encodeURIComponent(version)}`;
    const res = await fetchImpl(url, { signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    if (!res.ok) return null;

    const body = (await res.json()) as {
      publishedAt?: string;
      advisoryKeys?: { id?: string }[];
      isDeprecated?: boolean;
      deprecatedReason?: string;
      slsaProvenances?: unknown[];
      attestations?: unknown[];
    };

    // Provenance is reported in two arrays that overlap in practice. Either one
    // being present means deps.dev answered the question; neither means it did
    // not, which is null rather than false.
    const slsa = Array.isArray(body.slsaProvenances) ? body.slsaProvenances : null;
    const att = Array.isArray(body.attestations) ? body.attestations : null;
    const hasProvenance = slsa === null && att === null
      ? null
      : (slsa?.length ?? 0) + (att?.length ?? 0) > 0;

    return {
      publishedAt: body.publishedAt ?? null,
      advisoryIds: Array.isArray(body.advisoryKeys)
        ? body.advisoryKeys.map((a) => a?.id).filter((id): id is string => typeof id === 'string')
        : null,
      isDeprecated: typeof body.isDeprecated === 'boolean' ? body.isDeprecated : null,
      deprecatedReason: body.deprecatedReason || null,
      hasProvenance,
    };
  } catch {
    // Timeout, DNS failure, malformed JSON — all the same outcome: unknown.
    return null;
  }
}

const defaultDeps: VersionRecordDeps = { fetchVersionRecord };

/**
 * Resolve both sides of every bump.
 *
 * The FROM side is fetched only so provenance regression can be observed. That
 * doubles the request count — twenty-two for an eleven-package group — which
 * fits: at concurrency 8 that is three waves, and at the 3-second per-request
 * ceiling ~9 seconds worst case against a 30-second budget. In practice these
 * are 834-byte responses and the whole pass is well under a second.
 */
export async function collectVersionRecords(
  bumps: DependencyBump[],
  deps: VersionRecordDeps = defaultDeps,
): Promise<BumpRecord[]> {
  const sides = bumps.flatMap((bump) => [
    { bump, side: 'target' as const, version: bareVersion(bump.to) },
    { bump, side: 'from' as const, version: bareVersion(bump.from) },
  ]);

  const fetched = await mapWithConcurrency(sides, CONCURRENCY, async (s) =>
    s.version === null ? null : deps.fetchVersionRecord(s.bump.name, s.version));

  return bumps.map((bump, i) => ({
    bump,
    target: fetched[i * 2] ?? null,
    from: fetched[i * 2 + 1] ?? null,
  }));
}
```

- [ ] **Step 5: Run the new test to verify it passes**

Run: `node --import tsx --test tests/signals-version-records.test.ts`
Expected: PASS, 10 tests.

- [ ] **Step 6: Make `publish-age.ts` pure**

Replace the whole file. Grading is unchanged in this task — tiers arrive in Task 2.

```ts
// Signal 2: how long the new version has been public.
//
// A version published hours ago is the supply-chain attack window; one
// published weeks ago has been under the world's scrutiny.
//
// Pure: the deps.dev fetch lives in ./version-records.ts, because three
// consumers read the same record. This file owns only the grading rule.
import type { BumpRecord } from './version-records.js';
import type { Signal } from './types.js';
import { unknownSignal } from './types.js';
import { log } from '../log.js';

const MS_PER_DAY = 24 * 60 * 60 * 1000;

/** What the signal observed. */
export interface PublishAge {
  /** Age in whole days of the youngest package in the change. */
  youngestDays: number;
  /** Which package that was. */
  package: string;
}

/**
 * Grade the change by the age of its youngest package.
 *
 * The YOUNGEST, not the governing bump: a single fresh package among ten mature
 * ones is the actual supply-chain exposure, and grading on the package that
 * happened to set the semver class would miss it.
 *
 * Args:
 *   records: Both sides of every bump, from `collectVersionRecords`.
 *   cooldownDays: Below this age, a version is still in the exposure window.
 *   now: Injected clock, in epoch milliseconds.
 */
export function publishAge(
  records: BumpRecord[],
  cooldownDays: number,
  now: number,
): Signal<PublishAge> {
  if (records.length === 0) return unknownSignal('no dependency bumps to age');

  const ages = records.map((r) => {
    const at = r.target?.publishedAt;
    if (!at) return { name: r.bump.name, days: null };
    const published = Date.parse(at);
    if (!Number.isFinite(published)) return { name: r.bump.name, days: null };
    return { name: r.bump.name, days: Math.floor((now - published) / MS_PER_DAY) };
  });

  const known = ages.filter((a): a is { name: string; days: number } => a.days !== null);
  const failed = ages.filter((a) => a.days === null).map((a) => a.name);

  if (known.length === 0) {
    log('warn', 'publish_age_all_unknown', { packages: records.length });
    return unknownSignal(`no publish date available for any of ${records.length} package(s)`);
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

- [ ] **Step 7: Rewrite `tests/signals-publish-age.test.ts` against records**

Replace the whole file. The two `mapWithConcurrency` tests moved to Task 1 Step 2 and must not be duplicated here.

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { publishAge } from '../src/signals/publish-age.js';
import type { BumpRecord, VersionRecord } from '../src/signals/version-records.js';
import type { SemverLevel } from '../src/rules-types.js';

const fastify = JSON.parse(readFileSync('tests/fixtures/deps-dev-fastify-5.12.0.json', 'utf8'));
const jwt = JSON.parse(readFileSync('tests/fixtures/deps-dev-fastify-jwt-10.2.2.json', 'utf8'));

// 2026-08-25T12:00:00Z — fastify@5.12.0 is 11.x days old, @fastify/jwt@10.2.2 is 10.x
const NOW = Date.parse('2026-08-25T12:00:00Z');

const record = (publishedAt: string | null): VersionRecord => ({
  publishedAt, advisoryIds: [], isDeprecated: false, deprecatedReason: null, hasProvenance: false,
});

const rec = (
  name: string,
  publishedAt: string | null,
  level: SemverLevel = 'patch',
): BumpRecord => ({
  bump: { name, from: '0.0.0', to: '1.0.0', level },
  target: publishedAt === null ? null : record(publishedAt),
  from: null,
});

test('grades low when every package is older than the cooldown', () => {
  const s = publishAge([rec('fastify', fastify.publishedAt), rec('@fastify/jwt', jwt.publishedAt)], 3, NOW);
  assert.equal(s.grade, 'low');
  assert.equal(s.value!.package, '@fastify/jwt', 'the youngest package is reported');
  assert.equal(s.value!.youngestDays, 10);
});

test('grades medium when any package is inside the cooldown window', () => {
  const fresh = new Date(NOW - 36 * 60 * 60 * 1000).toISOString();
  const s = publishAge([rec('fastify', fastify.publishedAt), rec('brand-new', fresh)], 3, NOW);
  assert.equal(s.grade, 'medium');
  assert.equal(s.value!.package, 'brand-new');
  assert.equal(s.value!.youngestDays, 1);
});

test('one failed lookup does not sink the signal', () => {
  const s = publishAge([rec('fastify', fastify.publishedAt), rec('unknownpkg', null)], 3, NOW);
  assert.equal(s.grade, 'low');
  assert.match(s.reason!, /unknownpkg/, 'the failure is named');
});

test('all lookups failing makes the signal unknown', () => {
  const s = publishAge([rec('a', null), rec('b', null)], 3, NOW);
  assert.equal(s.grade, 'unknown');
});

test('no bumps at all is unknown, not low', () => {
  assert.equal(publishAge([], 3, NOW).grade, 'unknown');
});

test('an unparseable publish date is unknown, not epoch', () => {
  const s = publishAge([rec('a', 'not-a-date')], 3, NOW);
  assert.equal(s.grade, 'unknown');
});
```

- [ ] **Step 8: Rewire `src/evaluate.ts`**

Change the import block: replace

```ts
import { fetchPublishedAt, publishAge } from './signals/publish-age.js';
import type { PublishAge } from './signals/publish-age.js';
```

with

```ts
import { publishAge } from './signals/publish-age.js';
import { fetchVersionRecord, collectVersionRecords } from './signals/version-records.js';
import type { BumpRecord } from './signals/version-records.js';
```

In `EvaluateDeps`, replace `fetchPublishedAt: typeof fetchPublishedAt;` with `fetchVersionRecord: typeof fetchVersionRecord;`, and in `defaultDeps` replace `fetchPublishedAt` with `fetchVersionRecord`.

In `assessRisk`, replace the `publish_age` element of the `Promise.all` and the `publishAge` line of the `combine` call:

```ts
  const [alerts, sections, records] = await Promise.all([
    safely('advisories', () => deps.fetchOpenAlerts(ctx.repoFullName), { ok: false as const, reason: 'error' as const }),
    safely('manifest', () => deps.fetchManifestSections(ctx.repoFullName, ctx.headSha), null),
    safely('version_records', () => collectVersionRecords(classification.bumps, {
      fetchVersionRecord: deps.fetchVersionRecord,
    }), [] as BumpRecord[]),
  ]);

  const risk = combine({
    semverDistance: gradeSemverDistance(classification.maxDelta, classification.bumps),
    publishAge: publishAge(records, thresholds.cooldownDays, Date.now()),
    closesFinding: closesFinding(alerts, classification.bumps),
    newFindings: scanFindings(runs, thresholds.maxNewFindings),
    coverageDelta: coverageDelta(runs, thresholds.maxCoverageDropPct),
    depType: depType(sections, classification.bumps),
  });
```

Note the `safely` fallback is now `[]`, which `publishAge` already turns into `unknown` — the `unknownSignal<PublishAge>` import is no longer needed for this call site but is still used elsewhere in the file, so leave the import alone.

- [ ] **Step 9: Update `tests/evaluate.test.ts`**

Three edits, all mechanical:

- line ~103: `fetchPublishedAt: async () => '2026-08-01T00:00:00Z',` becomes
  ```ts
  fetchVersionRecord: async () => ({
    publishedAt: '2026-08-01T00:00:00Z', advisoryIds: [], isDeprecated: false,
    deprecatedReason: null, hasProvenance: false,
  }),
  ```
- line ~123: `fetchOpenAlerts: spy, fetchManifestSections: spy, fetchPublishedAt: spy,` becomes `... fetchVersionRecord: spy,`
- line ~146: `riskDeps(27, { fetchPublishedAt: boom })` becomes `riskDeps(27, { fetchVersionRecord: boom })`

- [ ] **Step 10: Update `tests/fixtures/README.md`**

Add to the "Risk-heuristic fixtures" table:

```markdown
| `deps-dev-lodash-4.17.20.json` | `api.deps.dev` | Five real GHSA ids — target-version health grading `high` |
| `deps-dev-har-validator-5.1.5.json` | `api.deps.dev` | Deprecated with zero advisories — the `medium` path |
| `deps-dev-sigstore-sign-3.1.0.json` | `api.deps.dev` | A version carrying npm provenance, for the regression comparison |
```

- [ ] **Step 11: Full suite and typecheck**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS. Every risk grade is unchanged — this task moved code, it did not change a rule.

- [ ] **Step 12: Commit**

```bash
git add src/signals/version-records.ts src/signals/publish-age.ts src/evaluate.ts \
  tests/signals-version-records.test.ts tests/signals-publish-age.test.ts \
  tests/evaluate.test.ts tests/fixtures/
git commit -m "refactor(signals): fetch the whole deps.dev record once, grade purely"
```

---

## Task 2: Tiered cooldown, and sub-day releases graded high

The deck said `<7 days`; the service shipped a flat `cooldownDays: 3`. Dependabot's own default is 3, and cooldowns.dev's incident analysis found 8 of 10 prominent npm attacks had exploitation windows under a week — several under a day: axios 2–3 hours, Nx 4–5 hours, `debug@4.4.2` **31 minutes**. A flat three days is right for a patch and thin for a major, and grading a 31-minute-old release the same as a two-day-old one loses the distinction that matters most.

**Files:**
- Modify: `src/rules-types.ts:38-46`
- Modify: `scripts/build-rules.mjs:60-69`
- Modify: `policy-rules.yaml:17-24`
- Modify: `src/signals/publish-age.ts`
- Modify: `src/evaluate.ts` (the `publishAge` call)
- Modify: `tests/signals-publish-age.test.ts`
- Modify: `tests/build-rules.test.ts`

**Interfaces:**
- Consumes: `publishAge(records, cooldown, now)` from Task 1.
- Produces: `CooldownTiers` from `src/rules-types.ts`; `publishAge(records, cooldown: CooldownTiers, now)`.

- [ ] **Step 1: Write the failing tests**

Add to the imports at the top of `tests/signals-publish-age.test.ts`:

```ts
import type { CooldownTiers } from '../src/rules-types.js';
```

Add the constant beside the other fixtures, and append the tests:

```ts
const TIERS: CooldownTiers = { patch: 3, minor: 3, major: 7 };

test('each bump is measured against its OWN level, not the PR max', () => {
  // A major five days old is inside the 7-day major window; a patch of the same
  // age is outside the 3-day patch window. Grading both on one threshold — or
  // on the PR's max delta — is the bug this tiering exists to remove.
  const fiveDays = new Date(NOW - 5 * 24 * 60 * 60 * 1000).toISOString();
  const asMajor = publishAge([rec('big', fiveDays, 'major')], TIERS, NOW);
  const asPatch = publishAge([rec('small', fiveDays, 'patch')], TIERS, NOW);
  assert.equal(asMajor.grade, 'medium', 'inside the 7-day major window');
  assert.equal(asPatch.grade, 'low', 'outside the 3-day patch window');
});

test('a mixed-level group grades on the offending bump, not the youngest', () => {
  // The major is older in days but younger relative to its own threshold.
  const fiveDays = new Date(NOW - 5 * 24 * 60 * 60 * 1000).toISOString();
  const tenDays = new Date(NOW - 10 * 24 * 60 * 60 * 1000).toISOString();
  const s = publishAge([rec('a', tenDays, 'patch'), rec('b', fiveDays, 'major')], TIERS, NOW);
  assert.equal(s.grade, 'medium');
  assert.equal(s.value!.package, 'b', 'the youngest is still what gets reported');
});

test('under a day grades high regardless of tier', () => {
  const hours23 = new Date(NOW - 23 * 60 * 60 * 1000).toISOString();
  assert.equal(publishAge([rec('a', hours23, 'patch')], TIERS, NOW).grade, 'high');
  assert.equal(publishAge([rec('a', hours23, 'major')], TIERS, NOW).grade, 'high');
});

test('25 hours old is medium, not high', () => {
  const hours25 = new Date(NOW - 25 * 60 * 60 * 1000).toISOString();
  assert.equal(publishAge([rec('a', hours25, 'patch')], TIERS, NOW).grade, 'medium');
});

test('a `none`-level bump borrows the patch threshold', () => {
  const twoDays = new Date(NOW - 2 * 24 * 60 * 60 * 1000).toISOString();
  assert.equal(publishAge([rec('a', twoDays, 'none')], TIERS, NOW).grade, 'medium');
});
```

Change the three pre-existing tests that pass a bare `3` to pass `TIERS` instead: "grades low when every package is older than the cooldown", "grades medium when any package is inside the cooldown window", "one failed lookup does not sink the signal", "all lookups failing makes the signal unknown", "no bumps at all is unknown, not low", and "an unparseable publish date is unknown, not epoch".

Note the second of those now grades `medium` at 36 hours because 36 hours is one whole day — it is already written that way in Task 1 for exactly this reason.

In `tests/build-rules.test.ts`, **first fix the shared `validDoc()` helper at line 17** — it hard-codes the old flat key, so leaving it would fail every existing test in the file, including "a valid document produces no errors" and the several that assert `errors.length === 1`:

```ts
      risk: { cooldown: { patch: 3, minor: 3, major: 7 }, maxNewFindings: 0, maxCoverageDropPct: 0 },
```

Then append:

```ts
test('a missing tier is an error, never a default', () => {
  const doc = validDoc();
  delete doc.rules.risk.cooldown.minor;
  const errors = validatePolicy(doc);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /rules\.risk\.cooldown\.minor/);
});

test('a negative tier is rejected', () => {
  const doc = validDoc();
  doc.rules.risk.cooldown.patch = -1;
  assert.match(validatePolicy(doc)[0], /rules\.risk\.cooldown\.patch/);
});

test('an unrecognised tier name is rejected rather than ignored', () => {
  const doc = validDoc();
  doc.rules.risk.cooldown.prerelease = 1;
  assert.match(validatePolicy(doc)[0], /rules\.risk\.cooldown\.prerelease/);
});

test('a stale cooldownDays fails the build rather than being ignored', () => {
  // A rules file left on the old key would otherwise validate, compile, and
  // silently apply whatever the tiered defaults happened to be. Naming it is
  // the difference between a failed deploy and a policy that quietly stopped
  // being the one written down.
  const doc = validDoc();
  doc.rules.risk.cooldownDays = 3;
  const errors = validatePolicy(doc);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /cooldownDays/);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test 2>&1 | tail -30`
Expected: FAIL on both files — `publishAge` still takes a number, `validatePolicy` still accepts `cooldownDays`.

- [ ] **Step 3: Add `CooldownTiers` to `src/rules-types.ts`**

Replace the `RiskThresholds` block:

```ts
/**
 * Days a version must be public before it leaves the supply-chain window,
 * per semver level.
 *
 * Tiered because the exposure differs: a major carries more novel code and
 * deserves a longer soak. Matches Dependabot's own `semver-{major,minor,patch}-days`.
 */
export interface CooldownTiers {
  patch: number;
  minor: number;
  major: number;
}

/** Tunable thresholds for the risk heuristics (PLAT-1191). */
export interface RiskThresholds {
  /** Per-level soak windows. A `none`-level bump uses the patch window. */
  cooldown: CooldownTiers;
  /** Failing scanner checks tolerated before the grade goes high. */
  maxNewFindings: number;
  /** Coverage drop tolerated, in percentage points. */
  maxCoverageDropPct: number;
}
```

- [ ] **Step 4: Validate the tiers in `scripts/build-rules.mjs`**

Add near the other constants:

```js
const COOLDOWN_TIERS = ['patch', 'minor', 'major'];
```

Replace the `cooldownDays` line inside the `risk` block:

```js
    // Named explicitly rather than ignored: a rules file left on the old flat
    // key would otherwise compile and silently stop matching the policy on
    // paper. A failed build is the cheaper outcome.
    if (risk.cooldownDays !== undefined) {
      bad('rules.risk.cooldownDays', 'removed — use rules.risk.cooldown.{patch,minor,major}');
    }
    if (!risk.cooldown || typeof risk.cooldown !== 'object') {
      bad('rules.risk.cooldown', 'must be an object with patch, minor and major');
    } else {
      for (const tier of COOLDOWN_TIERS) {
        if (!isInt(risk.cooldown[tier]) || risk.cooldown[tier] < 0) {
          bad(`rules.risk.cooldown.${tier}`, 'must be a non-negative integer');
        }
      }
      for (const key of Object.keys(risk.cooldown)) {
        if (!COOLDOWN_TIERS.includes(key)) bad(`rules.risk.cooldown.${key}`, 'unrecognised tier');
      }
    }
```

- [ ] **Step 5: Update `policy-rules.yaml`**

Replace lines 17–24's `risk` block:

```yaml
  risk:
    # Days a version must be public before it leaves the supply-chain window,
    # per semver level. Each bump is measured against ITS OWN level, not the
    # pull request's maximum: a major riding along with ten patches gets the
    # major window, which is the point of tiering. A `none`-level bump uses the
    # patch window.
    #
    # 3 for patch and minor is Dependabot's own default. 7 for major reflects
    # the larger novel surface. Under 24 hours grades `high` regardless of tier
    # — that window is where nearly every documented npm compromise did its
    # damage (debug@4.4.2 was exploited within 31 minutes) — and that rule lives
    # in src/signals/publish-age.ts, where it is tested.
    cooldown:
      patch: 3
      minor: 3
      major: 7
    # Failing scanner checks tolerated before the grade goes high.
    maxNewFindings: 0
    # Coverage drop tolerated, in percentage points, before the grade rises.
    maxCoverageDropPct: 0
```

- [ ] **Step 6: Apply the tiers in `src/signals/publish-age.ts`**

Add the import and constant:

```ts
import type { CooldownTiers, SemverLevel } from '../rules-types.js';

// A `none`-level bump — same version on both sides of the manifest hunk —
// borrows the patch window. It has no tier of its own and the alternative is
// an unexplained fourth number in the rules file.
const TIER_FOR: Record<SemverLevel, keyof CooldownTiers> = {
  none: 'patch', patch: 'patch', minor: 'minor', major: 'major',
};

// Under this many days, a release has had essentially no public exposure.
// Graded `high` on its own — the sub-day window is where axios (2-3h), Nx
// (4-5h) and debug@4.4.2 (31 minutes) were each exploited.
const SUB_DAY = 1;
```

Change the signature to `cooldown: CooldownTiers`, and carry each bump's level through the age map:

```ts
  const ages = records.map((r) => {
    const at = r.target?.publishedAt;
    const level = r.bump.level;
    if (!at) return { name: r.bump.name, level, days: null };
    const published = Date.parse(at);
    if (!Number.isFinite(published)) return { name: r.bump.name, level, days: null };
    return { name: r.bump.name, level, days: Math.floor((now - published) / MS_PER_DAY) };
  });

  const known = ages.filter(
    (a): a is { name: string; level: SemverLevel; days: number } => a.days !== null);
```

Replace the grade expression:

```ts
  const youngest = known.reduce((min, a) => (a.days < min.days ? a : min));

  // Two passes, in severity order. Sub-day beats everything; otherwise a bump
  // is fresh only relative to ITS OWN tier, which is why this cannot collapse
  // into a comparison against the youngest package alone.
  const anySubDay = known.some((a) => a.days < SUB_DAY);
  const anyInCooldown = known.some((a) => a.days < cooldown[TIER_FOR[a.level]]);
  const grade = anySubDay ? 'high' : anyInCooldown ? 'medium' : 'low';

  return {
    grade,
    value: { youngestDays: youngest.days, package: youngest.name },
    ...(failed.length > 0 ? { reason: `no publish date for ${failed.join(', ')}` } : {}),
  };
```

- [ ] **Step 7: Update the `evaluate.ts` call site**

`publishAge(records, thresholds.cooldownDays, Date.now())` becomes `publishAge(records, thresholds.cooldown, Date.now())`.

- [ ] **Step 8: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 9: Prove the stale-key guard actually fails a build**

```bash
cp policy-rules.yaml /tmp/policy-backup.yaml
python3 - <<'PY'
import re
s = open('policy-rules.yaml').read()
s = s.replace('    cooldown:\n      patch: 3', '    cooldownDays: 3\n    cooldown:\n      patch: 3')
open('policy-rules.yaml','w').write(s)
PY
pnpm run build:rules; echo "exit=$?"
cp /tmp/policy-backup.yaml policy-rules.yaml
pnpm run build:rules
```

Expected: the first `build:rules` prints `rules.risk.cooldownDays: removed — use rules.risk.cooldown.{patch,minor,major}` and `exit=1`; the restore rebuilds cleanly. **Confirm `policy-rules.yaml` is back to the tiered form before committing** — `git diff policy-rules.yaml` must show no `cooldownDays`.

- [ ] **Step 10: Commit**

```bash
git add src/rules-types.ts scripts/build-rules.mjs policy-rules.yaml \
  src/signals/publish-age.ts src/evaluate.ts src/generated/rules.ts \
  tests/signals-publish-age.test.ts tests/build-rules.test.ts
git commit -m "feat(risk): tier the cooldown by semver level and grade sub-day releases high"
```

---

## Task 3: Target-version health — the seventh signal

`closesFinding` asks whether the change resolves an advisory the repo already has. Nothing asks whether the version being *installed* carries a known advisory of its own. That is the event-stream case: bumping into a compromised release. The data is already on the wire after Task 1 — this costs zero additional requests.

**Files:**
- Create: `src/signals/target-health.ts`
- Create: `tests/signals-target-health.test.ts`

**Interfaces:**
- Consumes: `BumpRecord`, `VersionRecord` from `src/signals/version-records.ts`.
- Produces: `TargetVersionHealth`, `targetVersionHealth(records)` from `src/signals/target-health.ts`.

- [ ] **Step 1: Write the failing test**

Create `tests/signals-target-health.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { targetVersionHealth } from '../src/signals/target-health.js';
import type { BumpRecord, VersionRecord } from '../src/signals/version-records.js';
import { fetchVersionRecord } from '../src/signals/version-records.js';

const body = (p: string) => JSON.parse(readFileSync(`tests/fixtures/${p}`, 'utf8'));
const ok = (payload: unknown) => (async () => ({
  ok: true, status: 200, json: async () => payload,
})) as unknown as typeof fetch;

const from = async (name: string, version: string, fixture: string): Promise<BumpRecord> => ({
  bump: { name, from: '0.0.0', to: version, level: 'patch' },
  target: await fetchVersionRecord(name, version, ok(body(fixture))),
  from: null,
});

const synthetic = (name: string, target: Partial<VersionRecord>): BumpRecord => ({
  bump: { name, from: '0.0.0', to: '1.0.0', level: 'patch' },
  target: {
    publishedAt: '2020-01-01T00:00:00Z', advisoryIds: [], isDeprecated: false,
    deprecatedReason: null, hasProvenance: false, ...target,
  },
  from: null,
});

test('an advised target version grades high and names the ids', async () => {
  const s = targetVersionHealth([await from('lodash', '4.17.20', 'deps-dev-lodash-4.17.20.json')]);
  assert.equal(s.grade, 'high');
  assert.equal(s.value!.advised.length, 1);
  assert.equal(s.value!.advised[0]!.ids.length, 5);
  assert.match(s.value!.advised[0]!.ids[0]!, /^GHSA-/);
});

test('a deprecated but unadvised target version grades medium', async () => {
  const s = targetVersionHealth([
    await from('har-validator', '5.1.5', 'deps-dev-har-validator-5.1.5.json'),
  ]);
  assert.equal(s.grade, 'medium');
  assert.equal(s.value!.deprecated.length, 1);
  assert.match(s.value!.deprecated[0]!.reason, /no longer supported/);
});

test('a clean target version grades low', async () => {
  const s = targetVersionHealth([await from('fastify', '5.12.0', 'deps-dev-fastify-5.12.0.json')]);
  assert.equal(s.grade, 'low');
  assert.equal(s.value!.checked, 1);
});

test('an advisory outranks a deprecation in the same change', () => {
  const s = targetVersionHealth([
    synthetic('a', { isDeprecated: true, deprecatedReason: 'old' }),
    synthetic('b', { advisoryIds: ['GHSA-xxxx-xxxx-xxxx'] }),
  ]);
  assert.equal(s.grade, 'high');
  assert.equal(s.value!.deprecated.length, 1, 'the deprecation is still recorded');
});

test('an ABSENT advisoryKeys field is unknown for that package, never clean', () => {
  // The load-bearing assertion of this file. Reading a missing field as "no
  // advisories" is the A1 inversion by another route.
  const s = targetVersionHealth([synthetic('a', { advisoryIds: null })]);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /1 package/);
});

test('one unknown package does not sink a change whose others are readable', () => {
  const s = targetVersionHealth([
    synthetic('a', { advisoryIds: null }),
    synthetic('b', { advisoryIds: [] }),
  ]);
  assert.equal(s.grade, 'low');
  assert.equal(s.value!.checked, 1, 'only the readable one was checked');
  assert.match(s.reason!, /a/, 'the unreadable one is named');
});

test('a null target record contributes nothing', () => {
  const s = targetVersionHealth([
    { bump: { name: 'a', from: '1.0.0', to: '2.0.0', level: 'major' }, target: null, from: null },
  ]);
  assert.equal(s.grade, 'unknown');
});

test('no bumps at all is unknown', () => {
  assert.equal(targetVersionHealth([]).grade, 'unknown');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --import tsx --test tests/signals-target-health.test.ts`
Expected: FAIL — `Cannot find module '../src/signals/target-health.js'`

- [ ] **Step 3: Write `src/signals/target-health.ts`**

```ts
// Signal 7: is the version we are installing itself known-bad?
//
// `closesFinding` asks whether this change resolves an advisory the repository
// ALREADY has. Nothing asked the opposite question — whether the version being
// installed carries an advisory of its own — and that is precisely the
// event-stream case: bumping INTO a compromised release.
//
// Costs no additional requests. Every field read here arrived on the same
// deps.dev response the publish-age lookup already made.
//
// Advisories and deprecation share one signal rather than becoming two. They
// answer the same question — "is this specific release something the ecosystem
// has flagged?" — and splitting them would push the service to eight signals
// for one bit of extra resolution.
import type { BumpRecord } from './version-records.js';
import type { Signal } from './types.js';
import { unknownSignal } from './types.js';

/** One flagged target version. */
export interface AdvisedVersion {
  package: string;
  version: string;
  ids: string[];
}

/** One deprecated target version. */
export interface DeprecatedVersion {
  package: string;
  version: string;
  reason: string;
}

/** What the signal observed. */
export interface TargetVersionHealth {
  /** How many target versions produced a usable answer. */
  checked: number;
  advised: AdvisedVersion[];
  deprecated: DeprecatedVersion[];
}

/**
 * Grade every target version, worst-of across the change.
 *
 * A package counts as CHECKED only when deps.dev actually reported its
 * advisory list. An absent `advisoryKeys` is unknown for that package — never
 * "clean" — because a missing field and an empty array are different facts.
 * That distinction is the whole reason this signal can be trusted.
 *
 * Args:
 *   records: Both sides of every bump, from `collectVersionRecords`.
 */
export function targetVersionHealth(records: BumpRecord[]): Signal<TargetVersionHealth> {
  if (records.length === 0) return unknownSignal('no dependency bumps to check');

  const advised: AdvisedVersion[] = [];
  const deprecated: DeprecatedVersion[] = [];
  const unreadable: string[] = [];
  let checked = 0;

  for (const r of records) {
    const ids = r.target?.advisoryIds;
    if (!r.target || ids === null || ids === undefined) {
      unreadable.push(r.bump.name);
      continue;
    }
    checked++;

    if (ids.length > 0) {
      advised.push({ package: r.bump.name, version: r.bump.to, ids });
    }
    if (r.target.isDeprecated === true) {
      deprecated.push({
        package: r.bump.name,
        version: r.bump.to,
        reason: r.target.deprecatedReason ?? 'no reason given',
      });
    }
  }

  if (checked === 0) {
    return unknownSignal(
      `no advisory data for any of ${records.length} package(s): ${unreadable.join(', ')}`);
  }

  const grade = advised.length > 0 ? 'high' : deprecated.length > 0 ? 'medium' : 'low';

  return {
    grade,
    value: { checked, advised, deprecated },
    // A partial failure is recorded but does not sink the signal: the packages
    // we could read still say something true.
    ...(unreadable.length > 0 ? { reason: `no advisory data for ${unreadable.join(', ')}` } : {}),
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --import tsx --test tests/signals-target-health.test.ts`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add src/signals/target-health.ts tests/signals-target-health.test.ts
git commit -m "feat(risk): grade whether the target version is advised or deprecated"
```

---

## Task 4: Seven signals — wire it in

The signal exists but nothing reads it. This task puts it in the comparison, in the table, and in the reducer floor.

**The reducer floor is the subtle part, and it goes beyond what the spec wrote down.** Spec E made the `closesFinding` reducer unable to lower a grade below publish age's rank — a fresh release closing a CVE stays graded on its freshness. The same argument applies with more force to target-version health: closing one advisory must never excuse bumping *into* another. So the floor becomes the worse of the two.

**Files:**
- Modify: `src/risk.ts`
- Modify: `src/render.ts:212-255,270`
- Modify: `src/evaluate.ts` (the `combine` call)
- Modify: `tests/risk.test.ts`
- Modify: `tests/render.test.ts:206-216,259`
- Modify: `tests/evaluate.test.ts` (the "every signal value" assertion)

**Interfaces:**
- Consumes: `targetVersionHealth`, `TargetVersionHealth` from Task 3.
- Produces: `RiskSignals` with seven members; `RiskResult.signalsGraded` counted over seven.

- [ ] **Step 1: Write the failing tests**

In `tests/risk.test.ts`, add `targetVersionHealth` to the `signals()` builder:

```ts
    targetVersionHealth: sig('low', { checked: 1, advised: [], deprecated: [] }),
```

Change `assert.equal(r.signalsGraded, 6)` to `7` in "all low grades low, on all six signals" and rename it to "...on all seven signals".

Append:

```ts
test('an advised target version drives the grade high on its own', () => {
  const r = combine(signals({
    targetVersionHealth: sig('high', {
      checked: 1, advised: [{ package: 'lodash', version: '4.17.20', ids: ['GHSA-x'] }], deprecated: [],
    }),
  }));
  assert.equal(r.grade, 'high');
});

test('an unknown target health is counted out, not counted clean', () => {
  const r = combine(signals({ targetVersionHealth: sig('unknown') }));
  assert.equal(r.grade, 'low');
  assert.equal(r.signalsGraded, 6, 'six of seven');
});

test('closing an advisory does not excuse bumping into another one', () => {
  // The reducer is a concession for resolving a known vulnerability. It must
  // never pay for introducing one: without the target-health floor this drops
  // to medium, which would read as "safer because it closes a CVE" about a
  // change that installs an advised release.
  const r = combine(signals({
    targetVersionHealth: sig('high', {
      checked: 1, advised: [{ package: 'a', version: '1.0.0', ids: ['GHSA-x'] }], deprecated: [],
    }),
    closesFinding: sig('low', { ghsaIds: ['GHSA-y'] }),
    publishAge: sig('low', { youngestDays: 90, package: 'a' }),
  }));
  assert.equal(r.grade, 'high');
});

test('the reducer still applies when nothing floors it', () => {
  const r = combine(signals({
    semverDistance: sig('high', 'major'),
    closesFinding: sig('low', { ghsaIds: ['GHSA-y'] }),
    publishAge: sig('low', { youngestDays: 90, package: 'a' }),
    targetVersionHealth: sig('low', { checked: 1, advised: [], deprecated: [] }),
  }));
  assert.equal(r.grade, 'medium', 'high, reduced one step');
});

test('a sub-day release closing a CVE still grades high', () => {
  // Spec E's floor, now proven against a `high` publish age rather than the
  // `medium` that was its ceiling before Task 2.
  const r = combine(signals({
    publishAge: sig('high', { youngestDays: 0, package: 'a' }),
    closesFinding: sig('low', { ghsaIds: ['GHSA-y'] }),
  }));
  assert.equal(r.grade, 'high');
});
```

In `tests/render.test.ts`, three edits to existing code plus two new tests. Note the file's helpers: `classification` is a **const object, not a function**, and `FINAL` / `PROVISIONAL` are the completeness constants — use them rather than inlining literals.

Add the seventh signal to the `riskResult()` builder (`tests/render.test.ts:206-223`), in the same position it holds in `RiskSignals`:

```ts
      publishAge: s('low', { youngestDays: 11, package: '@fastify/jwt' }),
      targetVersionHealth: s('low', { checked: 7, advised: [], deprecated: [] }),
```

Update the existing "renders every signal as a table row, in fixed order" test — it currently asserts six rows and names them:

```ts
test('renders every signal as a table row, in fixed order', () => {
  const out = renderRisk(riskResult(), classification, FINAL);
  const rows = out.summary.split('\n').filter((l) => /^\| (?:✅|⚠️|❌|❓) \|/.test(l));
  assert.equal(rows.length, 7);
  assert.deepEqual(rows.map((r) => r.split('|')[2]!.trim()), [
    'Version distance', 'Publish age', 'Target version health', 'Closes a known finding',
    'New scanner findings', 'Coverage change', 'Dependency type',
  ]);
});
```

Change the `graded on 5 of 6 signals` assertion in "a final result says final, in the title and once only" to `graded on 5 of 7 signals`.

Append two tests:

```ts
test('an advised target version names the package and its ids', () => {
  const out = renderRisk(riskResult({
    targetVersionHealth: s('high', {
      checked: 2,
      advised: [{ package: 'lodash', version: '4.17.20', ids: ['GHSA-29mw-wpgm-hmr9'] }],
      deprecated: [],
    }),
  }), classification, FINAL);
  assert.match(out.summary, /lodash@4\.17\.20/);
  assert.match(out.summary, /GHSA-29mw-wpgm-hmr9/);
});

test('a deprecated target version says so', () => {
  const out = renderRisk(riskResult({
    targetVersionHealth: s('medium', {
      checked: 1, advised: [],
      deprecated: [{ package: 'har-validator', version: '5.1.5', reason: 'no longer supported' }],
    }),
  }), classification, FINAL);
  assert.match(out.summary, /har-validator@5\.1\.5.*deprecated/);
});
```

In `tests/evaluate.test.ts`, change `assert.equal(Object.keys(recorded[0].risk.signals).length, 6);` to `7`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test 2>&1 | tail -40`
Expected: FAIL — `targetVersionHealth` is not a member of `RiskSignals`.

- [ ] **Step 3: Add the signal to `src/risk.ts`**

Update the header comment's "six" to "seven", add the import and the member:

```ts
import type { TargetVersionHealth } from './signals/target-health.js';
```

```ts
/** All seven signals for one evaluation. */
export interface RiskSignals {
  semverDistance: Signal<string>;
  publishAge: Signal<PublishAge>;
  targetVersionHealth: Signal<TargetVersionHealth>;
  closesFinding: Signal<ClosesFinding>;
  newFindings: Signal<ScanFindings>;
  coverageDelta: Signal<CoverageDelta>;
  depType: Signal<DepTypeCounts>;
}
```

In `combine()`, add it to `comparable`:

```ts
  const comparable = [
    signals.semverDistance,
    signals.publishAge,
    signals.targetVersionHealth,
    signals.newFindings,
    signals.coverageDelta,
    signals.depType,
  ];
```

Update the `signalsGraded` comment to say SEVEN, and replace the floor:

```ts
  // The reducer is a CONCESSION, and a floor bounds it.
  //
  // It can never lower the grade below what publish age OR target-version
  // health said on their own. A release published hours ago that closes a CVE
  // stays high, because rushed and fabricated security releases are a
  // documented attack pattern. And a change that closes one advisory while
  // installing a version carrying another gets no credit at all — the
  // concession is for resolving a vulnerability, never for trading one.
  //
  // Dependabot exempts security updates from its cooldown. That is defensible
  // for NOTIFYING a human, who can notice a suspicious release, and wrong for
  // unattended merge, which cannot.
  const rankOf = (s: Signal<unknown>): number =>
    s.grade === 'unknown' ? 0 : RANK[s.grade as Exclude<SignalGrade, 'unknown'>];

  // The reducer applies only when publish age is known: granting a concession
  // on absent data is the pattern this service refuses everywhere else.
  const publishAgeKnown = signals.publishAge.grade !== 'unknown';
  const floor = Math.max(rankOf(signals.publishAge), rankOf(signals.targetVersionHealth));

  const finalRank = closes && publishAgeKnown
    ? Math.max(floor, worstRank - 1)
    : worstRank;
```

- [ ] **Step 4: Add the row to `src/render.ts`**

Add `targetVersionHealth` to `SIGNAL_ROWS`, immediately after publish age — the two answer adjacent questions about the same version:

```ts
  { key: 'publishAge', label: 'Publish age' },
  { key: 'targetVersionHealth', label: 'Target version health' },
```

Add the `signalCell` case:

```ts
    case 'targetVersionHealth': {
      const v2 = v as { checked: number; advised: any[]; deprecated: any[] };
      if (v2.advised.length > 0) {
        const first = v2.advised[0];
        const more = v2.advised.length > 1 ? ` (+${v2.advised.length - 1} more)` : '';
        return `\`${first.package}@${first.version}\`: ${first.ids.join(', ')}${more}`;
      }
      if (v2.deprecated.length > 0) {
        const first = v2.deprecated[0];
        const more = v2.deprecated.length > 1 ? ` (+${v2.deprecated.length - 1} more)` : '';
        return `\`${first.package}@${first.version}\` deprecated — ${first.reason}${more}`;
      }
      return `${v2.checked} version${v2.checked === 1 ? '' : 's'} clean`;
    }
```

Replace the hard-coded count in `renderRisk`, so it cannot drift again:

```ts
  const headline =
    `${RISK_TITLE[risk.grade]} — graded on ${risk.signalsGraded} of ${SIGNAL_ROWS.length} signals · ${marker}`;
```

Update the `signalTable` doc comment from "six signals" to "seven signals".

- [ ] **Step 5: Wire it in `src/evaluate.ts`**

Add the import:

```ts
import { targetVersionHealth } from './signals/target-health.js';
```

Add the member to the `combine` call, in the same position as in `RiskSignals`:

```ts
    publishAge: publishAge(records, thresholds.cooldown, Date.now()),
    targetVersionHealth: targetVersionHealth(records),
```

Update `assessRisk`'s doc comment from "six risk signals" to "seven risk signals", and add the new signal to the `evaluated` log line:

```ts
    target_health: assessed?.risk.signals.targetVersionHealth.grade ?? null,
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/risk.ts src/render.ts src/evaluate.ts \
  tests/risk.test.ts tests/render.test.ts tests/evaluate.test.ts
git commit -m "feat(risk): seventh signal, and stop the reducer excusing an advised target"
```

---

## Task 5: Provenance regression — recorded, deliberately not graded

Detecting that a new version dropped the npm provenance its predecessor carried is cheap now that Task 1 fetches both sides. It is **not** graded, and the reason is not cost: nobody knows its false-positive rate. Packages legitimately stop publishing provenance — tooling migrations, maintainer changes, CI rewrites — and grading on it today would be inventing a threshold rather than deriving one. Thirty days of data answers the question the grade would otherwise have to assume.

**Files:**
- Modify: `src/signals/version-records.ts`
- Modify: `src/ledger.ts:20-36,54-79`
- Modify: `src/evaluate.ts`
- Modify: `tests/signals-version-records.test.ts`
- Modify: `tests/ledger.test.ts`
- Modify: `tests/evaluate.test.ts`

**Interfaces:**
- Consumes: `BumpRecord` from Task 1.
- Produces: `ProvenanceObservation`, `provenanceObservations(records)` from `src/signals/version-records.ts`; `EvalRecord.provenance?: ProvenanceObservation[]`.

- [ ] **Step 1: Write the failing test**

Extend the existing import at the top of `tests/signals-version-records.test.ts` to add `provenanceObservations`, and add the type import:

```ts
import type { VersionRecord } from '../src/signals/version-records.js';
```

Then append the helpers and tests:

```ts
const withProv = (hasProvenance: boolean | null): VersionRecord => ({
  publishedAt: '2020-01-01T00:00:00Z', advisoryIds: [], isDeprecated: false,
  deprecatedReason: null, hasProvenance,
});

const pair = (fromProv: boolean | null, toProv: boolean | null) => ({
  bump: { name: 'p', from: '1.0.0', to: '1.0.1', level: 'patch' as const },
  from: fromProv === null && toProv === null ? null : withProv(fromProv),
  target: withProv(toProv),
});

test('losing provenance is recorded as lost', () => {
  const [o] = provenanceObservations([pair(true, false)]);
  assert.equal(o!.lost, true);
  assert.equal(o!.fromHadProvenance, true);
  assert.equal(o!.toHasProvenance, false);
});

test('gaining, keeping, or never having provenance is not a loss', () => {
  assert.equal(provenanceObservations([pair(false, true)])[0]!.lost, false);
  assert.equal(provenanceObservations([pair(true, true)])[0]!.lost, false);
  assert.equal(provenanceObservations([pair(false, false)])[0]!.lost, false);
});

test('an unreadable side is null, never false', () => {
  // "We could not tell" is not "it did not happen". Recording null keeps the
  // Phase 1 denominator honest.
  assert.equal(provenanceObservations([pair(null, false)])[0]!.lost, null);
  assert.equal(provenanceObservations([pair(true, null)])[0]!.lost, null);
});

test('a missing from-record yields a null observation, not an omitted bump', () => {
  const [o] = provenanceObservations([{
    bump: { name: 'p', from: 'workspace:*', to: '1.0.1', level: 'patch' },
    from: null, target: withProv(true),
  }]);
  assert.equal(o!.lost, null);
  assert.equal(o!.package, 'p', 'the bump is still represented');
});
```

Append to `tests/ledger.test.ts` (the file asserts individual `Item` keys, never the whole object, so adding attributes breaks nothing existing):

```ts
test('provenance is stored as JSON, and absent provenance is NULL', async () => {
  // DynamoDB rejects an empty string, and an empty list would read as "we
  // looked and found no bumps" rather than "this evaluation did not look".
  const first = fakeSend();
  await recordEvaluation({ ...record(), provenance: [
    { package: 'p', from: '1.0.0', to: '1.0.1',
      fromHadProvenance: true, toHasProvenance: false, lost: true },
  ] }, first.send);
  assert.equal(JSON.parse(first.calls[0].input.Item.provenance.S).length, 1);

  const second = fakeSend();
  await recordEvaluation(record(), second.send);
  assert.deepEqual(second.calls[0].input.Item.provenance, { NULL: true });
});
```

Append to `tests/evaluate.test.ts`:

```ts
test('the eval record carries a provenance observation per bump', async () => {
  const recorded: any[] = [];
  await evaluate(ctx(27), riskDeps(27, {
    recordEvaluation: async (r: any) => { recorded.push(r); },
  }) as any);
  assert.equal(recorded[0].provenance.length, 7, 'one per bump in PR #27');
  assert.ok(recorded[0].provenance.every((p: any) => 'lost' in p));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test 2>&1 | tail -20`
Expected: FAIL — `provenanceObservations` is not exported.

- [ ] **Step 3: Add `provenanceObservations` to `src/signals/version-records.ts`**

```ts
/**
 * Whether one bump kept the npm provenance its predecessor carried.
 *
 * RECORDED, NEVER GRADED. Packages legitimately stop publishing provenance —
 * tooling migrations, maintainer changes, CI rewrites — and nobody knows how
 * often. Grading on it today would be inventing a threshold rather than
 * deriving one; thirty days of these records answer that question properly.
 */
export interface ProvenanceObservation {
  package: string;
  from: string;
  to: string;
  fromHadProvenance: boolean | null;
  toHasProvenance: boolean | null;
  /** True only when the from-version had it and the target does not. Null when either side is unreadable. */
  lost: boolean | null;
}

/** One observation per bump, in input order. Never omits a bump. */
export function provenanceObservations(records: BumpRecord[]): ProvenanceObservation[] {
  return records.map((r) => {
    const before = r.from?.hasProvenance ?? null;
    const after = r.target?.hasProvenance ?? null;
    return {
      package: r.bump.name,
      from: r.bump.from,
      to: r.bump.to,
      fromHadProvenance: before,
      toHasProvenance: after,
      // Null, not false: "we could not tell" is a different fact from "it did
      // not happen", and conflating them would poison the Phase 1 denominator.
      lost: before === null || after === null ? null : before && !after,
    };
  });
}
```

- [ ] **Step 4: Add the field to `src/ledger.ts`**

Add the import and the record field:

```ts
import type { ProvenanceObservation } from './signals/version-records.js';
```

```ts
  /** One per bump. Recorded for Phase 1 threshold derivation; grades nothing. */
  provenance?: ProvenanceObservation[];
```

In `recordEvaluation`'s `Item`:

```ts
      provenance: record.provenance && record.provenance.length > 0
        ? { S: JSON.stringify(record.provenance) }
        : { NULL: true },
```

- [ ] **Step 5: Record it from `src/evaluate.ts`**

Add the import:

```ts
import { collectVersionRecords, provenanceObservations } from './signals/version-records.js';
import type { BumpRecord, ProvenanceObservation } from './signals/version-records.js';
```

Change `assessRisk`'s return type and body:

```ts
): Promise<{ risk: RiskResult; completeness: Completeness; provenance: ProvenanceObservation[] }> {
```

```ts
  const provenance = provenanceObservations(records);

  const lost = provenance.filter((p) => p.lost === true);
  if (lost.length > 0) {
    // Greppable before the weekly report exists. Not a grade, not a check-run
    // row — just a line somebody can find when the Phase 1 question comes up.
    log('info', 'provenance_lost', {
      repo: ctx.repoFullName, pr: ctx.prNumber,
      packages: lost.map((p) => `${p.package}@${p.to}`),
    });
  }

  return {
    risk,
    completeness: assessCompleteness(runs, signalChecksFor(ctx.repoFullName)),
    provenance,
  };
```

In `evaluate()`'s `recordEvaluation` call, add:

```ts
      provenance: assessed?.provenance,
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS. The PR #27 assertion expects 7 observations, all `lost: false` — `jose` and `newrelic` carry provenance on both sides, the other five carry it on neither.

- [ ] **Step 7: Commit**

```bash
git add src/signals/version-records.ts src/ledger.ts src/evaluate.ts \
  tests/signals-version-records.test.ts tests/evaluate.test.ts
git commit -m "feat(ledger): record provenance regression per bump, grading nothing"
```

---

## Task 6: Adoption — one alpha call, record-only

Renovate gates automerge on release age plus adoption percentage plus crowd-passing percentage. We cannot buy the crowd data, but deps.dev exposes dependent counts. **This is a `v3alpha` endpoint**, which is survivable only because the field is recorded and never graded: a shape change degrades it to null and nothing else moves.

One call, for the governing bump only. Eleven extra requests for a field nothing grades on would not be proportionate; one is.

**Files:**
- Create: `src/signals/adoption.ts`
- Create: `tests/signals-adoption.test.ts`
- Create: `tests/fixtures/deps-dev-dependents-fastify-5.12.0.json`
- Modify: `src/classify.ts` (add `governingBump`)
- Modify: `src/render.ts:21-24` (use it)
- Modify: `src/ledger.ts`
- Modify: `src/evaluate.ts`
- Modify: `tests/classify.test.ts`
- Modify: `tests/ledger.test.ts`
- Modify: `tests/evaluate.test.ts`
- Modify: `tests/fixtures/README.md`

**Interfaces:**
- Consumes: `ClassificationResult` from `src/classify.ts`; `bareVersion` from `src/signals/version-records.ts`.
- Produces: `governingBump(classification)` from `src/classify.ts`; `Adoption`, `fetchDependents`, `adoption(classification, deps)` from `src/signals/adoption.ts`; `EvalRecord.adoption?: Adoption | null`.

- [ ] **Step 1: Capture the fixture**

```bash
curl -s 'https://api.deps.dev/v3alpha/systems/npm/packages/fastify/versions/5.12.0:dependents' \
  | python3 -m json.tool > tests/fixtures/deps-dev-dependents-fastify-5.12.0.json
cat tests/fixtures/deps-dev-dependents-fastify-5.12.0.json
```

Expected: an object with `dependentCount`, `directDependentCount`, `indirectDependentCount`. If this returns a 404 or an error page, **that is the alpha endpoint doing exactly what the spec anticipated** — capture whatever it returns as the fixture, mark the "reshaped response records null" test as the live one, and say so in the handoff. Do not stub a success shape that no longer exists.

- [ ] **Step 2: Write the failing test**

Create `tests/signals-adoption.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { adoption, fetchDependents } from '../src/signals/adoption.js';
import type { ClassificationResult } from '../src/classify.js';

const dependents = JSON.parse(
  readFileSync('tests/fixtures/deps-dev-dependents-fastify-5.12.0.json', 'utf8'));

const ok = (payload: unknown) => (async () => ({
  ok: true, status: 200, json: async () => payload,
})) as unknown as typeof fetch;

const classification = (): ClassificationResult => ({
  changeClass: 'dep-minor',
  maxDelta: 'minor',
  bumps: [
    { name: '@fastify/jwt', from: '^10.2.1', to: '^10.2.2', level: 'patch' },
    { name: 'fastify', from: '^5.11.2', to: '^5.12.0', level: 'minor' },
    { name: 'pg', from: '^8.22.0', to: '^8.23.0', level: 'minor' },
  ],
});

test('reads the dependent counts', async () => {
  const a = await fetchDependents('fastify', '5.12.0', ok(dependents));
  assert.equal(a!.dependentCount, dependents.dependentCount);
  assert.equal(a!.directDependentCount, dependents.directDependentCount);
});

test('asks about the GOVERNING bump only — exactly one call', async () => {
  const asked: string[] = [];
  const spy = (async (url: string) => {
    asked.push(url);
    return { ok: true, status: 200, json: async () => dependents };
  }) as unknown as typeof fetch;

  const a = await adoption(classification(), { fetchImpl: spy });

  assert.equal(asked.length, 1, 'eleven calls for an ungraded field is not proportionate');
  assert.match(asked[0]!, /packages\/fastify\/versions\/5\.12\.0:dependents$/);
  assert.equal(a!.package, 'fastify');
  assert.equal(a!.version, '5.12.0');
});

test('a 404 records null and never throws', async () => {
  const notFound = (async () => ({ ok: false, status: 404 })) as unknown as typeof fetch;
  assert.equal(await adoption(classification(), { fetchImpl: notFound }), null);
});

test('a reshaped response records null rather than a partial object', async () => {
  // The alpha endpoint is allowed to change under us. What it is NOT allowed to
  // do is quietly produce a record that looks like data.
  const reshaped = ok({ counts: { total: 25 } });
  assert.equal(await adoption(classification(), { fetchImpl: reshaped }), null);
});

test('a thrown fetch records null', async () => {
  const boom = (async () => { throw new Error('ENOTFOUND'); }) as unknown as typeof fetch;
  assert.equal(await adoption(classification(), { fetchImpl: boom }), null);
});

test('no bumps means no call at all', async () => {
  let called = false;
  const spy = (async () => { called = true; return { ok: true, status: 200, json: async () => dependents }; }) as unknown as typeof fetch;
  const empty: ClassificationResult = { changeClass: 'unclassified', maxDelta: 'none', bumps: [] };
  assert.equal(await adoption(empty, { fetchImpl: spy }), null);
  assert.equal(called, false);
});
```

Append to `tests/classify.test.ts`:

```ts
test('the governing bump is the one that set the max delta', () => {
  const result = {
    changeClass: 'dep-minor', maxDelta: 'minor' as const,
    bumps: [
      { name: 'a', from: '1.0.0', to: '1.0.1', level: 'patch' as const },
      { name: 'b', from: '1.0.0', to: '1.1.0', level: 'minor' as const },
      { name: 'c', from: '2.0.0', to: '2.1.0', level: 'minor' as const },
    ],
  };
  assert.equal(governingBump(result)!.name, 'b', 'the first at the max level');
});

test('there is no governing bump when there are no bumps', () => {
  assert.equal(governingBump({ changeClass: 'unclassified', maxDelta: 'none', bumps: [] }), undefined);
});
```

with `governingBump` added to the file's import from `../src/classify.js`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `pnpm test 2>&1 | tail -20`
Expected: FAIL — `Cannot find module '../src/signals/adoption.js'` and `governingBump` is not exported.

- [ ] **Step 4: Add `governingBump` to `src/classify.ts`**

At the end of the file:

```ts
/**
 * The bump that set the pull request's class.
 *
 * Exported so `render.ts` and `adoption.ts` cannot drift on what "the governing
 * bump" means — a rationale naming one package while a recorded field describes
 * another would be worse than either alone.
 */
export function governingBump(result: ClassificationResult): DependencyBump | undefined {
  return result.bumps.find((b) => b.level === result.maxDelta);
}
```

In `src/render.ts`, delete the private `largestBump` function and import the shared one:

```ts
import { governingBump } from './classify.js';
```

Replace every `largestBump(` call with `governingBump(` — there are three (`rejectionDetail`'s `classificationPermits` case, `renderEligibility`, and `signalCell`'s `semverDistance` case).

- [ ] **Step 5: Write `src/signals/adoption.ts`**

```ts
// Adoption: how widely the target version is already depended on.
//
// RECORDED, NEVER GRADED. Renovate's Merge Confidence gates automerge on
// release age plus adoption percentage plus crowd-passing percentage. We cannot
// buy the crowd data, and adoption alone has no defensible threshold yet — so
// this is collected for Phase 1 to derive one from, and nothing reads it.
//
// THIS IS A v3alpha ENDPOINT. Alpha APIs change without notice. That is
// survivable only because nothing grades on the value: a withdrawn or reshaped
// endpoint records null, logs `adoption_unavailable`, and moves on.
//
// The failure is logged rather than swallowed because a field that has been
// quietly null for six weeks is worse than one never collected — it looks like
// data. The weekly report (Spec I) counts that log line, so a persistent
// failure surfaces as a number somebody reads.
import type { ClassificationResult } from '../classify.js';
import { governingBump } from '../classify.js';
import { bareVersion } from './version-records.js';
import { log } from '../log.js';

const DEPS_DEV_ALPHA = 'https://api.deps.dev/v3alpha/systems/npm/packages';
const REQUEST_TIMEOUT_MS = 3_000;

/** What the recorder observed. Null everywhere it could not. */
export interface Adoption {
  package: string;
  version: string;
  dependentCount: number;
  directDependentCount: number;
}

/** Injectable collaborator. */
export interface AdoptionDeps {
  fetchImpl: typeof fetch;
}

/**
 * Ask deps.dev how many packages depend on one exact version.
 *
 * Returns:
 *   The counts, or null on any failure or unrecognised shape. A partial object
 *   is never returned: half a record that looks whole is the failure mode this
 *   guards against.
 */
export async function fetchDependents(
  name: string,
  version: string,
  fetchImpl: typeof fetch = fetch,
): Promise<Adoption | null> {
  try {
    const url = `${DEPS_DEV_ALPHA}/${encodeURIComponent(name)}/versions/${encodeURIComponent(version)}:dependents`;
    const res = await fetchImpl(url, { signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    if (!res.ok) {
      log('warn', 'adoption_unavailable', { package: name, version, status: res.status });
      return null;
    }

    const body = (await res.json()) as { dependentCount?: number; directDependentCount?: number };
    if (typeof body.dependentCount !== 'number' || typeof body.directDependentCount !== 'number') {
      log('warn', 'adoption_unavailable', { package: name, version, status: 'reshaped' });
      return null;
    }

    return {
      package: name,
      version,
      dependentCount: body.dependentCount,
      directDependentCount: body.directDependentCount,
    };
  } catch (err) {
    log('warn', 'adoption_unavailable', {
      package: name, version,
      status: err instanceof Error ? err.message : 'error',
    });
    return null;
  }
}

const defaultDeps: AdoptionDeps = { fetchImpl: fetch };

/**
 * Record adoption for the governing bump.
 *
 * ONE call, not one per package: eleven extra requests for a field nothing
 * grades on would not be proportionate, and the governing bump is the package
 * the rationale already names to the reader.
 */
export async function adoption(
  classification: ClassificationResult,
  deps: AdoptionDeps = defaultDeps,
): Promise<Adoption | null> {
  const bump = governingBump(classification);
  if (!bump) return null;

  const version = bareVersion(bump.to);
  if (!version) return null;

  return fetchDependents(bump.name, version, deps.fetchImpl);
}
```

- [ ] **Step 6: Add the field to `src/ledger.ts`**

```ts
import type { Adoption } from './signals/adoption.js';
```

```ts
  /** Governing bump's dependent counts, or null. Recorded only; grades nothing. */
  adoption?: Adoption | null;
```

In the `Item`:

```ts
      adoption: record.adoption ? { S: JSON.stringify(record.adoption) } : { NULL: true },
```

Append to `tests/ledger.test.ts`:

```ts
test('a null adoption is stored as NULL, distinguishable from a zero count', async () => {
  // `{ dependentCount: 0 }` means "nobody depends on this yet"; NULL means "we
  // could not ask". Collapsing them would make the Phase 1 denominator a lie.
  const absent = fakeSend();
  await recordEvaluation({ ...record(), adoption: null }, absent.send);
  assert.deepEqual(absent.calls[0].input.Item.adoption, { NULL: true });

  const zero = fakeSend();
  await recordEvaluation({ ...record(), adoption: {
    package: 'p', version: '1.0.0', dependentCount: 0, directDependentCount: 0,
  } }, zero.send);
  assert.equal(JSON.parse(zero.calls[0].input.Item.adoption.S).dependentCount, 0);
});
```

Note this makes `record.adoption ? ... : ...` subtly wrong for a zero-count object — it is truthy as an object, so the ternary is safe. Do **not** rewrite it as a numeric check.

- [ ] **Step 7: Wire it in `src/evaluate.ts`**

Import and add to `EvaluateDeps`:

```ts
import { adoption } from './signals/adoption.js';
import type { Adoption } from './signals/adoption.js';
```

```ts
  adoption: typeof adoption;
```

and to `defaultDeps`. In `assessRisk`, add it to the `Promise.all` and the return:

```ts
  const [alerts, sections, records, adoptionCounts] = await Promise.all([
    safely('advisories', () => deps.fetchOpenAlerts(ctx.repoFullName), { ok: false as const, reason: 'error' as const }),
    safely('manifest', () => deps.fetchManifestSections(ctx.repoFullName, ctx.headSha), null),
    safely('version_records', () => collectVersionRecords(classification.bumps, {
      fetchVersionRecord: deps.fetchVersionRecord,
    }), [] as BumpRecord[]),
    safely('adoption', () => deps.adoption(classification), null as Adoption | null),
  ]);
```

Widen the return type to include `adoption: Adoption | null`, return `adoptionCounts` as `adoption`, and add `adoption: assessed?.adoption ?? null` to the `recordEvaluation` call.

In `tests/evaluate.test.ts`'s `riskDeps` helper, add:

```ts
    adoption: async () => ({ package: 'fastify', version: '5.12.0', dependentCount: 25, directDependentCount: 11 }),
```

and add `adoption: spy` to the non-candidate no-fetch spy list, which must still assert `touched === false`.

- [ ] **Step 8: Add a test that adoption never sinks an evaluation**

Append to `tests/evaluate.test.ts`:

```ts
test('a failed adoption lookup records null and leaves the grade alone', async () => {
  const recorded: any[] = [];
  const [, risk] = await evaluate(ctx(27), riskDeps(27, {
    adoption: async () => { throw new Error('v3alpha withdrawn'); },
    recordEvaluation: async (r: any) => { recorded.push(r); },
  }) as any);
  assert.match(risk!.output.title, /Risk: (low|medium|high)/);
  assert.equal(recorded[0].adoption, null);
});
```

- [ ] **Step 9: Update `tests/fixtures/README.md`**

```markdown
| `deps-dev-dependents-fastify-5.12.0.json` | `api.deps.dev` **v3alpha** | Adoption counts. Alpha endpoint — if it reshapes, the null path is the live test |
```

- [ ] **Step 10: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add src/signals/adoption.ts src/classify.ts src/render.ts src/ledger.ts src/evaluate.ts \
  tests/signals-adoption.test.ts tests/classify.test.ts tests/evaluate.test.ts tests/fixtures/
git commit -m "feat(ledger): record adoption for the governing bump, grading nothing"
```

---

## Task 7: Documentation, and the honest regression

Five documents describe six signals and a flat cooldown. A reader-facing explainer that disagrees with the service is worse than none, because it is the thing people cite.

**Files:**
- Modify: `docs/policy.md:61-95,212,239`
- Modify: `AGENTS.md:5,10,11`
- Modify: `README.md:19,27,31,40,104`
- Modify: `docs/architecture.md:30,151-183,307`
- Modify: `docs/call-flows.md:97-103`

- [ ] **Step 1: `docs/policy.md` — seven signals**

Retitle `## The six risk signals` to `## The seven risk signals`, change "grades six signals" to "grades seven", and the two later "six" references at lines ~94, ~212 and ~239.

Replace the **Publish age** row:

```markdown
| **Publish age** | How many days ago the youngest updated package's new version was published (looked up from `api.deps.dev`). | High: any package published less than 24 hours ago. Medium: any package younger than the cooldown for **its own** semver level (3 days for a patch or minor, 7 for a major). Low: every package past its window. | There are no bumps, or no publish date could be found for any of them. |
```

Add, immediately after it:

```markdown
| **Target version health** | Whether the version being *installed* is itself flagged — carrying a published security advisory, or marked deprecated by its maintainer. Read from the same `api.deps.dev` response as publish age, so it costs nothing extra. | High: any target version has an advisory. Medium: any is deprecated without one. Low: every version we could check is clean. | deps.dev did not report an advisory list for any package. A missing list is **never** read as "clean". |
```

Add a new section after the signals table:

```markdown
### Recorded, but not graded

Two more things are collected on every evaluation and deliberately do **not**
affect any grade or any check run:

- **Provenance regression** — whether a package that previously published npm
  provenance stopped doing so at the version being installed.
- **Adoption** — how many packages already depend on the governing bump's exact
  target version.

Both are recorded because storage is nearly free and retroactive collection is
impossible: a field not written today cannot be recovered for the evaluations
Phase 1 will tune against. Neither is graded because nobody yet knows its
false-positive rate, and inventing a threshold is exactly what the shadow phase
exists to avoid. They surface in the weekly shadow report, not on your pull
request.
```

- [ ] **Step 2: `AGENTS.md` — counts and the call budget**

Line 5: "six signals" becomes "seven signals".

Line 10: replace "per-package `api.deps.dev` publish-age lookups" with:

```
per-bump `api.deps.dev` version-record lookups (BOTH the target and the from version, so a seven-package group is fourteen requests at concurrency 8 — three waves, ~9s worst case at the 3s per-request ceiling), and one `v3alpha` dependents lookup for the governing bump
```

Line 11: retitle the paragraph's subject from "The publish-age signal (`src/signals/publish-age.ts`)" to "The deps.dev version-record fetch (`src/signals/version-records.ts`)", and add a closing sentence:

```
The same record feeds three readers — publish age, target-version health, and the provenance recorder — which is why fetching lives in its own module rather than inside a signal.
```

- [ ] **Step 3: `README.md`**

- line 19: "six signal modules" becomes "seven signal modules", and the list gains "whether the target version is itself advised or deprecated".
- line 27: "how many of the six signals" becomes "how many of the seven signals".
- line 31: "The three risk thresholds (`cooldownDays`, `maxNewFindings`, `maxCoverageDropPct`)" becomes "The risk thresholds (a per-semver-level `cooldown`, `maxNewFindings`, `maxCoverageDropPct`)".
- line 40: "grades on 5 of 6 signals, not 6" becomes "grades on 6 of 7 signals, not 7" — the demo repo has Dependabot alerts disabled, so `closesFinding` is permanently `unknown` there, and that is the only permanently-unknown one.
- line 104: "the six risk signals" becomes "the seven risk signals".

- [ ] **Step 4: `docs/architecture.md`**

- line 30: the Mermaid node label `api.deps.dev<br/>(publish-age signal only)` becomes `api.deps.dev<br/>(version records + adoption)`.
- lines 151–152: replace "timestamps from `api.deps.dev`" with "version records from `api.deps.dev` — publish date, advisory ids, deprecation and provenance, in one 834-byte response per version".
- line 159: "feed six signal modules" becomes "feed seven signal modules".
- line 164: the table row becomes `| 2 | publish age | `src/signals/publish-age.ts` | each bump's age vs `risk.cooldown` for its own level; under a day is high |`, and add a row `| 7 | target version health | `src/signals/target-health.ts` | advisories and deprecation on the version being installed |`.
- line 170: "folds the six into one `RiskResult`" becomes "folds the seven into one `RiskResult`", and add after the worst-known-wins sentence:

```
The `closesFinding` reducer is floored by the worse of publish age and target-version health: closing a known vulnerability never pays for installing a fresh release or one that carries an advisory of its own.
```

- lines 181–183 and 307: update the deps.dev paragraphs to say two calls per bump plus one alpha call for the governing bump.

- [ ] **Step 5: `docs/call-flows.md`**

- line 97: `src/signals/publish-age.ts` becomes `src/signals/version-records.ts`.
- line 103: "feed six signal modules" becomes "feed seven signal modules".

- [ ] **Step 6: Full verification**

```bash
pnpm run typecheck && pnpm test && pnpm run build
grep -rn 'of 6 signals\|six signals\|six risk\|cooldownDays' src/ docs/ tests/ *.md
```

Expected: all three commands pass; the grep returns **nothing**. A hit means a document still describes a service that no longer exists.

- [ ] **Step 7: Record the honest regression expectation**

PR #27's risk grade legitimately moves, and the test records the new value rather than asserting nothing changed. Append to `tests/evaluate.test.ts`:

```ts
test('PR #27 is still a candidate, and its risk grade is recorded not assumed', async () => {
  const [eligibility, risk] = await evaluate(ctx(27), riskDeps(27) as any);
  assert.match(eligibility!.output.title, /would have been a candidate/i);
  // Six of seven: the demo repo has Dependabot alerts disabled, so
  // closesFinding is permanently unknown there. Target-version health is
  // stubbed clean by riskDeps, publish age is stubbed at 2026-08-01.
  assert.match(risk!.output.title, /graded on 6 of 7 signals/);
});
```

- [ ] **Step 8: Commit**

```bash
git add docs/ AGENTS.md README.md tests/evaluate.test.ts
git commit -m "docs: seven signals, tiered cooldown, and what is recorded but not graded"
```

---

## Task 8: Live validation on the demo repo

**Files:** none — this is verification against the deployed service.

- [ ] **Step 1: Open the PR and let CI deploy to QA**

```bash
gh pr create --repo bankrate/zapp --base main \
  --title "feat(PLAT-1191): supply-chain signals — tiered cooldown, target-version health, recorded provenance and adoption" \
  --body "Implements docs/superpowers/zapp/specs/2026-08-26-supply-chain-signals-design.md (Spec F)."
```

- [ ] **Step 2: Trigger an evaluation on the demo repo**

Close and reopen the newest open dependabot PR on `bankrate/platform-cicd-v2-demo` to fire a fresh `pull_request` delivery:

```bash
gh pr list --repo bankrate/platform-cicd-v2-demo --author 'app/dependabot' --json number,title
```

- [ ] **Step 3: Read the risk check and confirm four things**

```bash
gh api repos/bankrate/platform-cicd-v2-demo/commits/<headSha>/check-runs \
  --jq '.check_runs[] | select(.name=="merge-policy/risk") | {title: .output.title, conclusion, external_id}'
```

Confirm, and paste the actual output into the PR:

1. The headline says **`of 7 signals`**.
2. A **Target version health** row is present in the table.
3. `conclusion` is **`neutral`**.
4. The publish-age cell reports days, and if any package is under its tier's window the grade moved accordingly.

- [ ] **Step 4: Confirm the recorded-only fields actually landed**

```bash
aws dynamodb query --table-name zapp-evaluations \
  --key-condition-expression 'pk = :p' \
  --expression-attribute-values '{":p":{"S":"repo#bankrate/platform-cicd-v2-demo#pr#<n>"}}' \
  --query 'Items[-1].{provenance:provenance.S, adoption:adoption.S}' --output json
```

Expected: `provenance` is a JSON array with one entry per bump; `adoption` is either a counts object or `null`. **If `adoption` is null, check the logs for `adoption_unavailable` and report the status** — that is the alpha endpoint failing, which is designed-for but must be known rather than assumed.

- [ ] **Step 5: Report the outcome**

State plainly whether the grade moved, what it moved to, and whether adoption came back. If deps.dev's v3alpha endpoint is gone, say so — it changes nothing about whether this ships, and it is the first data point on a dependency the spec flagged as expendable.

---

## Definition of done

Mapped from the spec, each traceable to a task:

- [ ] `cooldown` is per-semver-tier and validated at build time; `cooldownDays` is gone *(Task 2)*
- [ ] Each bump is measured against its own level's threshold *(Task 2, "own level, not the PR max")*
- [ ] A release under 24 hours old grades `high` *(Task 2)*
- [ ] `targetVersionHealth` grades advisories `high` and deprecation `medium`, from the existing call *(Task 3)*
- [ ] A response missing `advisoryKeys` grades `unknown`, never `low` *(Tasks 1 and 3, asserted in both)*
- [ ] The from-version is fetched and `provenanceLost` recorded per bump, grading nothing *(Tasks 1 and 5)*
- [ ] Provenance and attestation fields are recorded raw on the eval record *(Task 5)*
- [ ] A failed dependents lookup logs `adoption_unavailable` with status and package *(Task 6)*
- [ ] `adoption` is one call for the governing bump, record-only, null-safe against the alpha endpoint *(Task 6)*
- [ ] Renderings say "of 7"; the ledger's `signalsGraded` matches *(Task 4)*
- [ ] A sub-day release closing a CVE still grades `high` *(Task 4)*
- [ ] Both checks remain `neutral` and on no required-checks configuration *(Task 8)*

Plus one the spec did not anticipate, added because adding the seventh signal created it:

- [ ] Closing an advisory does not reduce the grade of a change that installs an advised version *(Task 4)*
