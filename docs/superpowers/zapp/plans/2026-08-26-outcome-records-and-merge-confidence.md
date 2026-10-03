# Outcome records and internal merge confidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record what actually happened to every evaluated pull request — merged, closed, reverted, or followed by a broken default branch — and use the fleet's own merge history to build the one Merge Confidence input we cannot buy: how many other Bankrate repositories already took this exact package at this exact version and kept it.

**Architecture:** A second record type under the pull request's existing partition key, plus one small indexed row per bumped package so a single `Query` still returns evaluations, outcome and packages together. Two sparse GSIs make the two lookups possible: merge-commit SHA (for revert and post-merge attribution) and package@version (for the confidence signal). A one-off script backfills history so the signal is not `unknown` for months.

**Tech Stack:** TypeScript (ESM, `node22` target), Node's built-in test runner via `node --import tsx --test`, `@aws-sdk/client-dynamodb`, Terraform, AWS Lambda, GitHub REST.

**Spec:** [`../specs/2026-08-26-outcome-records-and-merge-confidence-design.md`](../specs/2026-08-26-outcome-records-and-merge-confidence-design.md)

## Before you start

**This plan requires Spec G to be merged.** It extends `src/worker.ts`'s routing, `src/render.ts`'s signal table and recorded-not-enforced table, and `src/evaluate.ts`'s hoisted fetches — all of which G reshapes. Verify:

```bash
git log --oneline -1 && grep -c 'baseBranchAllowed' src/gates.ts && grep -c 'RecordedNotEnforced' src/render.ts
```

Expected: both counts non-zero. If either is `0` you are before Spec G; stop and say so.

## Global Constraints

- **Shadow mode is unchanged.** Both check runs keep `conclusion: 'neutral'`. Nothing here approves, merges, or becomes a required check.
- **A revert disqualifies corroboration; an inferred post-merge failure does not.** A revert is a human judgment. A post-merge failure is our own inference and may be misattributed — suppressing corroboration on it would broadcast one bad guess fleet-wide. It is disclosed in the signal's value instead.
- **`post_merge_failure` is attributed only on a green-to-red transition.** Blaming the next merge for a check that was already red re-blames an existing failure on whoever went through the door next.
- **Every inferred record says so.** `attribution: 'inferred'`, both commit SHAs, the check name.
- **Backfilled rows carry `backfilled: true`,** and the exit-criterion headline counts live records only. A backfilled merge was never evaluated, so it can neither corroborate nor refute a verdict that does not exist.
- **Backfill writes no eval records.** Manufacturing retroactive verdicts under today's `rulesSha` would corrupt the one dataset the shadow phase exists to produce.
- **`unknown` below the fleet threshold is correct, not a defect.** "Nobody else has taken this" means nothing when there is nobody else.
- **Signal count becomes 8.** Derive it from `SIGNAL_ROWS.length`, never a literal.

## Deviation from the spec: a second GSI

The spec names one index, `gsi-package-version`. This plan adds a second, `gsi-merge-commit`.

Both revert detection and post-merge attribution start from a **commit SHA** and need the pull request that produced it. Without an index that lookup is either a table scan or a dependence on GitHub's commit-message conventions (`Merge pull request #27 from …`, or a squash commit's trailing `(#27)`) for the *lookup itself* — not just for detecting that a revert happened. Convention parsing is fine for "is this a revert"; it is not fine as the only way to find the record, because a merge whose message was edited would silently drop out of the corpus.

Both indexes are **sparse**: only records carrying the attribute are indexed, so eval records cost nothing. `gsi-merge-commit` projects `KEYS_ONLY`.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/outcomes.ts` | **New.** Outcome and per-package record shapes and writers; revert-message parsing; merge-commit lookup. |
| `src/post-merge.ts` | **New.** The green-to-red attribution rule, isolated because it is the one inference in this service. |
| `src/signals/internal-confidence.ts` | **New.** Query `gsi-package-version`; grade on the weakest link. |
| `src/worker.ts` | Route `pull_request` `closed`; route `push`; route default-branch check completions. |
| `src/risk.ts`, `src/render.ts` | Eighth signal, eighth row. |
| `src/evaluate.ts` | Gather the confidence signal for candidates. |
| `scripts/backfill-outcomes.mjs` | **New.** One-off, idempotent historical reconstruction. |
| `infrastructure/terraform/dynamodb.tf` | `gsi-package-version`, `gsi-merge-commit`. |
| `infrastructure/terraform/iam.tf` | `dynamodb:Query` on the table and both indexes. |

---

## Task 1: Outcome records, package rows, and the indexes

**Files:**
- Create: `src/outcomes.ts`, `tests/outcomes.test.ts`
- Modify: `infrastructure/terraform/dynamodb.tf`, `infrastructure/terraform/iam.tf`

**Interfaces:**
- Produces: `Outcome`, `OutcomeRecord`, `recordOutcome(record, send?)`, `findByMergeCommit(repoFullName, sha, send?)` from `src/outcomes.ts`.

- [ ] **Step 1: Write the failing test**

Create `tests/outcomes.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recordOutcome } from '../src/outcomes.js';

process.env.EVALUATIONS_TABLE = 'zapp-evaluations-test';

function fakeSend() {
  const calls: any[] = [];
  return { calls, send: async (cmd: any) => { calls.push(cmd); return {}; } };
}

const base = () => ({
  repoFullName: 'bankrate/platform-cicd-v2-demo',
  prNumber: 27,
  outcome: 'merged' as const,
  headSha: 'f00d42',
  mergeCommitSha: 'abc123',
  at: '2026-08-26T12:00:00Z',
  bumps: [
    { name: 'fastify', from: '^5.11.2', to: '^5.12.0', level: 'minor' as const },
    { name: 'pg', from: '^8.22.0', to: '^8.23.0', level: 'minor' as const },
  ],
});

test('writes one outcome row plus one row per bump, all under the PR key', async () => {
  const { send, calls } = fakeSend();
  await recordOutcome(base(), send);

  const items = calls.map((c) => c.input.Item);
  assert.equal(items.length, 3, 'one outcome, two packages');
  assert.ok(items.every((i: any) => i.pk.S === 'repo#bankrate/platform-cicd-v2-demo#pr#27'),
    'grouping by pull request must stay a single Query');

  assert.equal(items[0].sk.S, 'outcome#2026-08-26T12:00:00Z');
  assert.deepEqual(items.slice(1).map((i: any) => i.sk.S), [
    'outcome#2026-08-26T12:00:00Z#pkg#fastify@5.12.0',
    'outcome#2026-08-26T12:00:00Z#pkg#pg@8.23.0',
  ]);
});

test('package rows carry the GSI key and denormalised fields', async () => {
  // Denormalised on purpose: the confidence query reads the GSI projection
  // alone and must never need a follow-up read per corroborating repository.
  const { send, calls } = fakeSend();
  await recordOutcome(base(), send);
  const pkg = calls[1].input.Item;

  assert.equal(pkg.pkgVersion.S, 'pkg#fastify@5.12.0');
  assert.equal(pkg.repo.S, 'bankrate/platform-cicd-v2-demo');
  assert.equal(pkg.outcome.S, 'merged');
  assert.equal(pkg.backfilled.BOOL, false);
});

test('the outcome row carries the merge commit for the second index', async () => {
  const { send, calls } = fakeSend();
  await recordOutcome(base(), send);
  assert.equal(calls[0].input.Item.mergeCommitSha.S, 'abc123');
});

test('a closed-unmerged outcome writes no package rows', async () => {
  // "Who successfully took this" is the question. A pull request that never
  // merged is not evidence of anything, and indexing it would corroborate
  // versions nobody ran.
  const { send, calls } = fakeSend();
  await recordOutcome({ ...base(), outcome: 'closed', mergeCommitSha: null }, send);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].input.Item.mergeCommitSha, undefined);
});

test('writes are conditional so a replay cannot double-count corroboration', async () => {
  const { send, calls } = fakeSend();
  await recordOutcome(base(), send);
  assert.match(calls[0].input.ConditionExpression, /attribute_not_exists\(sk\)/);
});

test('an unparseable version is skipped, and the others still index', async () => {
  const { send, calls } = fakeSend();
  await recordOutcome({ ...base(), bumps: [
    { name: 'local', from: 'workspace:*', to: 'workspace:*', level: 'none' },
    { name: 'pg', from: '^8.22.0', to: '^8.23.0', level: 'minor' },
  ] }, send);
  assert.equal(calls.length, 2, 'outcome plus the one indexable package');
  assert.equal(calls[1].input.Item.pkgVersion.S, 'pkg#pg@8.23.0');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --import tsx --test tests/outcomes.test.ts`
Expected: FAIL — `Cannot find module '../src/outcomes.js'`

- [ ] **Step 3: Write `src/outcomes.ts`**

```ts
// What actually happened to an evaluated pull request.
//
// Completes PLAT-1193's `outcome#` half. Two reasons this exists, and the
// second is the stronger one:
//
//   1. The exit criterion — "zero would-have-approved PRs subsequently
//      reverted" — is unmeasurable without it.
//   2. It is the missing half of a signal we cannot buy. Every eval record
//      already carries which package went to which version; what was missing is
//      whether it merged and stayed merged. Together those are crowd-passing
//      percentage, where the crowd is us.
//
// SHAPE: a second record type under the pull request's OWN partition key, so
// one Query returns evaluations, outcome and package rows together, already
// sorted. No join, no second table, no cross-table consistency question.
//
//   pk = repo#<owner>/<name>#pr#<number>
//     sk = eval#<ISO>
//     sk = outcome#<ISO>
//     sk = outcome#<ISO>#pkg#fastify@5.12.0
//
// The item count is therefore driven by bump count rather than pull-request
// count. Accepted: eleven ~200-byte items per merge is negligible, and the
// alternative buys nothing except a second table to provision, grant and
// reason about.
import { PutItemCommand, QueryCommand } from '@aws-sdk/client-dynamodb';
import { client, type DynamoSender } from './deliveries.js';
import type { DependencyBump } from './classify.js';
import { bareVersion } from './signals/version-records.js';
import { log } from './log.js';

const defaultSend: DynamoSender = (cmd) => client.send(cmd as never);

/** The four terminal facts about a pull request, in the order they can occur. */
export type Outcome = 'merged' | 'closed' | 'reverted' | 'post_merge_failure';

/** One outcome, as written to the ledger. */
export interface OutcomeRecord {
  repoFullName: string;
  prNumber: number;
  outcome: Outcome;
  /** The head SHA this outcome resolves — the code an evaluation actually saw. */
  headSha: string;
  /** The merge or squash commit. Null for a pull request that never merged. */
  mergeCommitSha: string | null;
  /** ISO timestamp; also the record's sort-key discriminator. */
  at: string;
  /** Bumps from the evaluation. Indexed one row each — merged outcomes only. */
  bumps: readonly DependencyBump[];
  /** True for rows written by scripts/backfill-outcomes.mjs. */
  backfilled?: boolean;
  /** Present on `post_merge_failure` only. Never presented as established fact. */
  attribution?: { kind: 'inferred'; check: string; goodSha: string; badSha: string };
}

/**
 * Write one outcome and its package rows.
 *
 * Conditional on `attribute_not_exists(sk)`: a redelivered webhook or a re-run
 * backfill must not double-count corroboration, which would silently inflate
 * every confidence grade that reads it.
 *
 * Package rows are written for MERGED outcomes only. "Who successfully took
 * this" is the question the confidence signal asks; a pull request that never
 * merged is not evidence of anything.
 */
export async function recordOutcome(
  record: OutcomeRecord,
  send: DynamoSender = defaultSend,
): Promise<void> {
  const pk = `repo#${record.repoFullName}#pr#${record.prNumber}`;
  const sk = `outcome#${record.at}`;
  const table = process.env.EVALUATIONS_TABLE!;

  await send(new PutItemCommand({
    TableName: table,
    ConditionExpression: 'attribute_not_exists(sk)',
    Item: {
      pk: { S: pk },
      sk: { S: sk },
      repo: { S: record.repoFullName },
      prNumber: { N: String(record.prNumber) },
      outcome: { S: record.outcome },
      headSha: { S: record.headSha },
      ...(record.mergeCommitSha ? { mergeCommitSha: { S: record.mergeCommitSha } } : {}),
      at: { S: record.at },
      backfilled: { BOOL: record.backfilled === true },
      ...(record.attribution ? { attribution: { S: JSON.stringify(record.attribution) } } : {}),
    },
  }));

  if (record.outcome !== 'merged') return;

  for (const bump of record.bumps) {
    const version = bareVersion(bump.to);
    // A workspace protocol or a git URL has no version to corroborate. Skipping
    // it silently is right: the OTHER packages in the same change are still
    // real evidence, and inventing a key for this one would poison the index.
    if (!version) continue;

    await send(new PutItemCommand({
      TableName: table,
      ConditionExpression: 'attribute_not_exists(sk)',
      Item: {
        pk: { S: pk },
        sk: { S: `${sk}#pkg#${bump.name}@${version}` },
        pkgVersion: { S: `pkg#${bump.name}@${version}` },
        repo: { S: record.repoFullName },
        prNumber: { N: String(record.prNumber) },
        outcome: { S: record.outcome },
        headSha: { S: record.headSha },
        at: { S: record.at },
        backfilled: { BOOL: record.backfilled === true },
      },
    }));
  }
}

/**
 * Find the pull request a merge or squash commit came from.
 *
 * Reads `gsi-merge-commit` rather than parsing the commit message. Message
 * parsing is fine for deciding whether a commit IS a revert; it is not fine as
 * the only way to find a record, because a merge whose message was edited would
 * drop out of the corpus without anyone noticing.
 *
 * Returns:
 *   The record's keys, or null when no evaluated merge matches.
 */
export async function findByMergeCommit(
  repoFullName: string,
  sha: string,
  send: DynamoSender = defaultSend,
): Promise<{ pk: string; sk: string; prNumber: number } | null> {
  const res = (await send(new QueryCommand({
    TableName: process.env.EVALUATIONS_TABLE!,
    IndexName: 'gsi-merge-commit',
    KeyConditionExpression: 'mergeCommitSha = :sha',
    ExpressionAttributeValues: { ':sha': { S: sha } },
    Limit: 1,
  }))) as { Items?: Record<string, { S?: string }>[] };

  const item = res.Items?.[0];
  if (!item?.pk?.S || !item?.sk?.S) return null;

  // Guard against a SHA collision across repositories — vanishingly unlikely,
  // and cheap to exclude.
  if (!item.pk.S.startsWith(`repo#${repoFullName}#`)) {
    log('warn', 'merge_commit_cross_repo', { repo: repoFullName, sha, pk: item.pk.S });
    return null;
  }

  return {
    pk: item.pk.S,
    sk: item.sk.S,
    prNumber: Number(item.pk.S.split('#pr#')[1]),
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --import tsx --test tests/outcomes.test.ts`
Expected: PASS, 6 tests.

- [ ] **Step 5: Add both indexes to `infrastructure/terraform/dynamodb.tf`**

Inside `aws_dynamodb_table.evaluations`, add two attributes and two indexes:

```hcl
  attribute {
    name = "pkgVersion"
    type = "S"
  }

  attribute {
    name = "mergeCommitSha"
    type = "S"
  }

  # "Who else merged this package at this exact version, and did it stick?" —
  # the fleet's own crowd-passing percentage, which no vendor sells us.
  #
  # SPARSE: only package rows carry pkgVersion, so eval records and plain
  # outcome records cost nothing here.
  #
  # INCLUDE rather than ALL: the confidence query must answer from the
  # projection alone. A follow-up read per corroborating repository would turn
  # one query into a dozen inside the evaluation budget.
  global_secondary_index {
    name               = "gsi-package-version"
    projection_type    = "INCLUDE"
    non_key_attributes = ["repo", "prNumber", "outcome", "backfilled", "at"]

    key_schema {
      attribute_name = "pkgVersion"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "sk"
      key_type       = "RANGE"
    }
  }

  # Commit SHA -> the pull request it came from. Both revert detection and
  # post-merge attribution start from a SHA; without this the lookup is a scan
  # or a dependence on GitHub's commit-message wording, and a merge whose
  # message was edited would silently leave the corpus.
  #
  # SPARSE and KEYS_ONLY: only merged outcomes carry mergeCommitSha, and the
  # caller reads the full item by key afterwards when it needs more.
  global_secondary_index {
    name            = "gsi-merge-commit"
    projection_type = "KEYS_ONLY"

    key_schema {
      attribute_name = "mergeCommitSha"
      key_type       = "HASH"
    }
  }
```

- [ ] **Step 6: Grant the reads in `infrastructure/terraform/iam.tf`**

The `WriteEvaluations` statement says `PutItem only: the service writes evidence and never reads it back.` That is no longer true — the confidence signal and the two attribution lookups read. Replace it:

```hcl
  # PutItem plus Query. The "writes evidence, never reads it" property held
  # until PLAT-1195: the confidence signal asks the fleet's own merge history
  # what other repositories already took a package version, and revert and
  # post-merge attribution look a commit SHA up to the pull request it came
  # from. Still no Scan — every read here is an indexed lookup.
  statement {
    sid     = "WriteAndQueryEvaluations"
    actions = ["dynamodb:PutItem", "dynamodb:Query"]
    resources = [
      aws_dynamodb_table.evaluations.arn,
      "${aws_dynamodb_table.evaluations.arn}/index/*",
    ]
  }
```

- [ ] **Step 7: Commit**

```bash
git add src/outcomes.ts tests/outcomes.test.ts infrastructure/terraform/
git commit -m "feat(ledger): outcome records, per-package rows, and the two lookup indexes"
```

---

## Task 2: Route `pull_request: closed`

**Files:**
- Modify: `src/worker.ts:19,26-38,68-86,157-177`
- Modify: `tests/worker.test.ts`

**Interfaces:**
- Consumes: `recordOutcome` (Task 1).
- Produces: `WorkerDeps.recordOutcome`.

- [ ] **Step 1: Write the failing test**

Append to `tests/worker.test.ts`:

```ts
test('a merged pull request writes a merged outcome', async () => {
  const written: any[] = [];
  await runWorker({ recordOutcome: async (r: any) => { written.push(r); } },
    'pull_request', { ...prPayload(27), action: 'closed',
      pull_request: { ...prPayload(27).pull_request, merged: true, merge_commit_sha: 'abc123' } });

  assert.equal(written.length, 1);
  assert.equal(written[0].outcome, 'merged');
  assert.equal(written[0].mergeCommitSha, 'abc123');
});

test('an abandoned pull request writes a closed outcome, not merged', async () => {
  // Abandonment is a real signal about the change, and conflating it with a
  // merge would corroborate versions nobody ran.
  const written: any[] = [];
  await runWorker({ recordOutcome: async (r: any) => { written.push(r); } },
    'pull_request', { ...prPayload(27), action: 'closed',
      pull_request: { ...prPayload(27).pull_request, merged: false, merge_commit_sha: null } });

  assert.equal(written[0].outcome, 'closed');
  assert.equal(written[0].mergeCommitSha, null);
});

test('a closed pull request posts no check runs', async () => {
  // The pull request is closed; there is nothing left to tell anybody, and
  // re-evaluating merged code would waste a GitHub round trip per delivery.
  let posted = 0;
  await runWorker({
    recordOutcome: async () => {},
    upsertShadowCheck: async () => { posted++; },
  }, 'pull_request', { ...prPayload(27), action: 'closed',
      pull_request: { ...prPayload(27).pull_request, merged: true } });

  assert.equal(posted, 0);
});

test('a closed pull request on an unenrolled repo writes nothing', async () => {
  const written: any[] = [];
  await runWorker({
    isEnrolled: () => false,
    recordOutcome: async (r: any) => { written.push(r); },
  }, 'pull_request', { ...prPayload(27), action: 'closed',
      pull_request: { ...prPayload(27).pull_request, merged: true } });

  assert.equal(written.length, 0);
});

test('an outcome write failure settles the claim rather than burning retries', async () => {
  // Same reasoning as the ledger write in evaluate.ts: the outcome is
  // reconstructable by replaying the delivery or by backfill, and failing the
  // delivery would put a healthy event through the DLQ.
  await assert.doesNotReject(() => runWorker(
    { recordOutcome: async () => { throw new Error('ProvisionedThroughputExceededException'); } },
    'pull_request', { ...prPayload(27), action: 'closed',
      pull_request: { ...prPayload(27).pull_request, merged: true } }));
});
```

Use the file's existing worker-test harness rather than the `runWorker(...)`
shape sketched above if it differs — the assertions are what matter.

- [ ] **Step 2: Run test to verify it fails**

Run: `node --import tsx --test tests/worker.test.ts`
Expected: FAIL — `closed` is not in `PR_ACTIONS` and nothing writes an outcome.

- [ ] **Step 3: Route it in `src/worker.ts`**

Add `recordOutcome: typeof recordOutcome;` to `WorkerDeps` and its default.

`closed` deliberately does **not** join `PR_ACTIONS` — that set is "actions that
warrant re-evaluating and re-posting checks", and a closed pull request warrants
neither. Handle it before that check:

```ts
async function handlePullRequest(deps: WorkerDeps, deliveryId: string, payload: any): Promise<void> {
  const repoFullName: string | undefined = payload.repository?.full_name;

  // `closed` is handled first and separately: it is the one pull_request action
  // that records a FACT rather than producing a verdict. No evaluation, no
  // check runs — the pull request is closed and there is nobody left to tell.
  if (payload.action === 'closed') {
    if (!repoFullName || !deps.isEnrolled(repoFullName)) return;
    await recordClosure(deps, deliveryId, repoFullName, payload.pull_request);
    return;
  }

  if (!PR_ACTIONS.has(payload.action)) { … unchanged … }
  …
}

/**
 * Write the terminal outcome for a pull request that just closed.
 *
 * Best-effort, and the ONLY other failure in this service handled this way (see
 * evaluate.ts's ledger write). An outcome is reconstructable by replaying the
 * delivery or by running the backfill script; failing the delivery would send a
 * perfectly healthy event to the DLQ.
 */
async function recordClosure(
  deps: WorkerDeps, deliveryId: string, repoFullName: string, pr: any,
): Promise<void> {
  const merged = pr?.merged === true;
  try {
    await deps.recordOutcome({
      repoFullName,
      prNumber: pr?.number,
      outcome: merged ? 'merged' : 'closed',
      headSha: pr?.head?.sha,
      mergeCommitSha: merged ? (pr?.merge_commit_sha ?? null) : null,
      at: pr?.closed_at ?? new Date().toISOString(),
      // Re-derived from the diff rather than remembered: the classification on
      // the eval record was made against the head SHA, and this is the same
      // parser reading the same files.
      bumps: merged ? classify(await deps.fetchPrFiles(repoFullName, pr.number), rules().generatedPaths).bumps : [],
    });
    log('info', 'outcome_recorded', {
      repo: repoFullName, pr: pr?.number, outcome: merged ? 'merged' : 'closed', delivery: deliveryId,
    });
  } catch (err) {
    log('error', 'outcome_write_failed', {
      repo: repoFullName, pr: pr?.number, delivery: deliveryId,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}
```

Add `fetchPrFiles: typeof fetchPrFiles;` to `WorkerDeps` and its default, plus
the `classify` and `rules` imports.

A `ConditionalCheckFailedException` from the conditional put lands in the same
`catch` and is logged as a failure. That is acceptable but noisy on a
redelivery; if it becomes noise, special-case it to an `info` line rather than
removing the condition.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/worker.ts tests/worker.test.ts
git commit -m "feat(outcomes): record whether an evaluated pull request merged or was abandoned"
```

---

## Task 3: Revert detection

`push` has been subscribed on the App and dropped by the worker since PLAT-1233. This is the first thing that needs it.

**Files:**
- Modify: `src/outcomes.ts` (revert parsing)
- Modify: `src/worker.ts` (route `push`)
- Modify: `tests/outcomes.test.ts`, `tests/worker.test.ts`

**Interfaces:**
- Produces: `revertedShas(commitMessage)` from `src/outcomes.ts`.

- [ ] **Step 1: Write the failing test**

Append to `tests/outcomes.test.ts`:

```ts
import { revertedShas } from '../src/outcomes.js';

test('GitHub\'s own revert format is recognised', () => {
  const msg = 'Revert "chore(deps): bump fastify from 5.11.2 to 5.12.0"\n\n'
    + 'This reverts commit abc1234567890abcdef1234567890abcdef12345.';
  assert.deepEqual(revertedShas(msg), ['abc1234567890abcdef1234567890abcdef12345']);
});

test('a trailer without the Revert subject still counts', () => {
  // A hand-written revert often keeps the trailer and rewrites the subject.
  assert.deepEqual(
    revertedShas('fix: undo the fastify bump\n\nThis reverts commit abc1234567890abcdef1234567890abcdef12345.'),
    ['abc1234567890abcdef1234567890abcdef12345']);
});

test('prose mentioning the word revert does not match', () => {
  // The single most important negative here. A commit saying "we may need to
  // revert this later" must not mark a merge reverted and silently suppress
  // that package across the fleet.
  assert.deepEqual(revertedShas('feat: add a flag so we can revert this commit quickly'), []);
  assert.deepEqual(revertedShas('Revert "something"'), [], 'a subject alone is not enough');
});

test('multiple reverts in one message are all returned', () => {
  const msg = 'Revert two bumps\n\nThis reverts commit ' + 'a'.repeat(40) + '.\n'
    + 'This reverts commit ' + 'b'.repeat(40) + '.';
  assert.deepEqual(revertedShas(msg), ['a'.repeat(40), 'b'.repeat(40)]);
});

test('an abbreviated SHA is not matched', () => {
  // A 7-char SHA cannot be looked up in the index, and guessing a prefix match
  // would be a scan. Missing it understates harm, which is the safe direction.
  assert.deepEqual(revertedShas('This reverts commit abc1234.'), []);
});
```

Append to `tests/worker.test.ts`:

```ts
test('a revert on the default branch marks the original merge reverted', async () => {
  const written: any[] = [];
  await runWorker({
    findByMergeCommit: async () => ({ pk: 'repo#o/r#pr#27', sk: 'outcome#x', prNumber: 27 }),
    recordOutcome: async (r: any) => { written.push(r); },
  }, 'push', {
    repository: { full_name: 'o/r', default_branch: 'main' },
    ref: 'refs/heads/main',
    commits: [{ id: 'z'.repeat(40), message: 'Revert "x"\n\nThis reverts commit ' + 'a'.repeat(40) + '.' }],
  });

  assert.equal(written.length, 1);
  assert.equal(written[0].outcome, 'reverted');
  assert.equal(written[0].prNumber, 27);
});

test('a push to a non-default branch is ignored', async () => {
  const written: any[] = [];
  await runWorker({ recordOutcome: async (r: any) => { written.push(r); } }, 'push', {
    repository: { full_name: 'o/r', default_branch: 'main' },
    ref: 'refs/heads/feature/x',
    commits: [{ id: 'z'.repeat(40), message: 'This reverts commit ' + 'a'.repeat(40) + '.' }],
  });
  assert.equal(written.length, 0);
});

test('a revert matching no recorded merge is logged, not written', async () => {
  const written: any[] = [];
  await runWorker({
    findByMergeCommit: async () => null,
    recordOutcome: async (r: any) => { written.push(r); },
  }, 'push', {
    repository: { full_name: 'o/r', default_branch: 'main' },
    ref: 'refs/heads/main',
    commits: [{ id: 'z'.repeat(40), message: 'This reverts commit ' + 'a'.repeat(40) + '.' }],
  });
  assert.equal(written.length, 0, 'it reverted something we never evaluated');
});

test('a push with no revert commits writes nothing and is not an error', async () => {
  await assert.doesNotReject(() => runWorker({ recordOutcome: async () => {} }, 'push', {
    repository: { full_name: 'o/r', default_branch: 'main' },
    ref: 'refs/heads/main',
    commits: [{ id: 'z'.repeat(40), message: 'feat: something ordinary' }],
  }));
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test 2>&1 | tail -20`
Expected: FAIL — `revertedShas` is not exported; `push` is in `KNOWN_UNROUTED`.

- [ ] **Step 3: Add `revertedShas` to `src/outcomes.ts`**

```ts
// `This reverts commit <40-hex>.` — git's own trailer, written by GitHub's
// revert button and by `git revert`. Full SHAs only: an abbreviated one cannot
// be looked up in the index, and a prefix match would be a table scan.
const REVERT_TRAILER = /This reverts commit ([0-9a-f]{40})/g;

/**
 * Every commit SHA this message claims to revert.
 *
 * DELIBERATELY NARROW. It matches the trailer and nothing else — not a
 * `Revert "..."` subject on its own, and not prose about reverting.
 *
 * This will miss reverts that do not follow the convention: a hand-written fix
 * that undoes a change without saying so, a force-push, a follow-up pull
 * request that reverses it. That is accepted. A missed revert UNDERSTATES harm,
 * and the alternative — diffing every push against every merged change — is
 * expensive and still not exhaustive. The weekly report states the limitation
 * beside the number so nobody reads "zero reverts" as "nothing went wrong".
 *
 * The false-positive direction matters more than the false-negative one here: a
 * wrongly-detected revert disqualifies a package from corroborating across the
 * whole fleet.
 */
export function revertedShas(commitMessage: string): string[] {
  return [...(commitMessage ?? '').matchAll(REVERT_TRAILER)].map((m) => m[1]!);
}
```

- [ ] **Step 4: Route `push` in `src/worker.ts`**

Remove `'push'` from `KNOWN_UNROUTED`, add `'push'` to the routed events in
`handleDelivery`, and add `findByMergeCommit: typeof findByMergeCommit;` to
`WorkerDeps`.

```ts
/**
 * Route a `push` to the default branch and look for reverts.
 *
 * Only the default branch: a revert on a feature branch has not undone anything
 * that shipped.
 */
async function handlePush(deps: WorkerDeps, deliveryId: string, payload: any): Promise<void> {
  const repoFullName: string | undefined = payload?.repository?.full_name;
  const defaultBranch: string | undefined = payload?.repository?.default_branch;
  if (!repoFullName || !defaultBranch) {
    throw new Error('malformed push payload: missing repository.full_name or repository.default_branch');
  }

  if (payload?.ref !== `refs/heads/${defaultBranch}`) {
    log('info', 'push_not_default_branch', { repo: repoFullName, ref: payload?.ref, delivery: deliveryId });
    return;
  }

  if (!deps.isEnrolled(repoFullName)) return;

  for (const commit of payload?.commits ?? []) {
    for (const sha of revertedShas(commit?.message ?? '')) {
      const original = await deps.findByMergeCommit(repoFullName, sha);
      if (original === null) {
        // It reverted something we never evaluated — a hand-landed commit, or a
        // merge from before this service was enrolled. Not an error, and worth
        // a line so a systematic mismatch is visible rather than silent.
        log('info', 'revert_unmatched', { repo: repoFullName, reverted_sha: sha, delivery: deliveryId });
        continue;
      }

      await deps.recordOutcome({
        repoFullName,
        prNumber: original.prNumber,
        outcome: 'reverted',
        headSha: sha,
        mergeCommitSha: null,
        at: commit?.timestamp ?? new Date().toISOString(),
        bumps: [],
      });
      log('info', 'revert_recorded', {
        repo: repoFullName, pr: original.prNumber, reverted_sha: sha, delivery: deliveryId,
      });
    }
  }
}
```

The `reverted` record writes no package rows — `recordOutcome` already skips
them for any non-`merged` outcome. The confidence query excludes a package whose
pull request has a `reverted` outcome by reading the outcome rows for that
`pk`; see Task 5.

- [ ] **Step 5: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/outcomes.ts src/worker.ts tests/
git commit -m "feat(outcomes): detect reverts on the default branch and match them to merges"
```

---

## Task 4: `post_merge_failure`, with its attribution rule visible

This is the loosest of the four outcomes and it is tracked anyway, because you cannot compare a verdict against reality while only recording the outcomes that are easy to attribute — that selects for the cases where nothing went wrong.

**Files:**
- Create: `src/post-merge.ts`, `tests/post-merge.test.ts`
- Modify: `src/worker.ts`
- Modify: `tests/worker.test.ts`

**Interfaces:**
- Produces: `attributeFailure(repoFullName, failing, deps)` from `src/post-merge.ts`.

- [ ] **Step 1: Write the failing test**

Create `tests/post-merge.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { attributeFailure } from '../src/post-merge.js';

const runs = (name: string, conclusion: string | null) =>
  [{ name, status: 'completed', conclusion, title: null }];

function deps(over: Partial<any> = {}) {
  return {
    fetchCheckRuns: async () => runs('Cycode: SAST', 'success'),
    fetchParent: async () => 'parent0000000000000000000000000000000000',
    findByMergeCommit: async () => ({ pk: 'repo#o/r#pr#27', sk: 'outcome#x', prNumber: 27 }),
    ...over,
  };
}

const failing = { sha: 'fail0000000000000000000000000000000000000', check: 'Cycode: SAST' };

test('a green-to-red transition is attributed to the merge', async () => {
  const r = await attributeFailure('o/r', failing, deps());
  assert.equal(r!.prNumber, 27);
  assert.equal(r!.attribution.kind, 'inferred');
  assert.equal(r!.attribution.check, 'Cycode: SAST');
  assert.equal(r!.attribution.badSha, failing.sha);
});

test('a check that was ALREADY red is not attributed', async () => {
  // The clause that does the real work. Attributing to a merge after a check
  // was already failing just re-blames an existing failure on whoever went
  // through the door next.
  const r = await attributeFailure('o/r', failing, deps({
    fetchCheckRuns: async (_r: string, sha: string) =>
      runs('Cycode: SAST', sha.startsWith('parent') ? 'failure' : 'failure'),
  }));
  assert.equal(r, null);
});

test('a commit that is not a recorded merge is not attributed', async () => {
  // A hand-landed commit is not our verdict to be judged against.
  const r = await attributeFailure('o/r', failing, deps({ findByMergeCommit: async () => null }));
  assert.equal(r, null);
});

test('an unreadable parent is not attributed', async () => {
  // Without the previous state there is no transition to observe, and guessing
  // one would manufacture the least trustworthy record in the corpus.
  const r = await attributeFailure('o/r', failing, deps({ fetchParent: async () => null }));
  assert.equal(r, null);
});

test('a check absent from the parent is not attributed', async () => {
  // Absent is not green. A check that did not run before cannot have gone from
  // green to red.
  const r = await attributeFailure('o/r', failing, deps({
    fetchCheckRuns: async (_r: string, sha: string) =>
      sha.startsWith('parent') ? [] : runs('Cycode: SAST', 'failure'),
  }));
  assert.equal(r, null);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --import tsx --test tests/post-merge.test.ts`
Expected: FAIL — module missing.

- [ ] **Step 3: Write `src/post-merge.ts`**

```ts
// Did this merge break the default branch?
//
// THE ONE INFERENCE IN THIS SERVICE, isolated in its own file for that reason.
// Everything else here records a fact somebody stated: a bot opened a pull
// request, a human merged it, a scanner reported a conclusion. This guesses.
//
// It is tracked anyway because the question the shadow phase exists to answer
// is "did our verdict predict the outcome?", and you cannot answer that while
// recording only the outcomes that are easy to attribute — that selects for the
// cases where nothing went wrong, which is the one bias that would make the
// whole corpus useless.
//
// THE RULE, stated narrowly:
//
//   A required check failing on the default branch is attributed to the most
//   recent merge commit that is an ancestor of the failing commit — provided
//   that merge is one we evaluated, and the same check was PASSING on the
//   commit immediately before it.
//
// The green-to-red clause does the real work. Without it, attribution just
// re-blames an existing failure on whoever went through the door next.
//
// It will still be wrong sometimes: a flaky test, an expired credential, an
// unrelated change landing in the same window. Three things handle that — every
// record says `attribution: 'inferred'`, the record names the check and both
// SHAs so any case can be re-judged later, and the weekly report shows these
// SEPARATELY from reverts rather than summing them into one number.
import type { CheckRunSummary } from './check-runs.js';
import { log } from './log.js';

const GREEN = new Set(['success', 'neutral', 'skipped']);

/** The failing observation that starts an attribution. */
export interface FailingCheck {
  sha: string;
  check: string;
}

/** Injectable collaborators. */
export interface PostMergeDeps {
  fetchCheckRuns: (repoFullName: string, sha: string) => Promise<CheckRunSummary[]>;
  /** First parent of a commit, or null when it cannot be read. */
  fetchParent: (repoFullName: string, sha: string) => Promise<string | null>;
  findByMergeCommit: (repoFullName: string, sha: string) =>
    Promise<{ pk: string; sk: string; prNumber: number } | null>;
}

/** What to record, or null when the rule does not fire. */
export interface Attribution {
  prNumber: number;
  attribution: { kind: 'inferred'; check: string; goodSha: string; badSha: string };
}

/**
 * Decide whether a failing check on the default branch is attributable.
 *
 * Returns null far more often than it returns a record, and that is correct:
 * every `null` here is a case where the honest answer is "we do not know".
 */
export async function attributeFailure(
  repoFullName: string,
  failing: FailingCheck,
  deps: PostMergeDeps,
): Promise<Attribution | null> {
  const original = await deps.findByMergeCommit(repoFullName, failing.sha);
  if (original === null) {
    // A hand-landed commit, or a merge from before enrolment. Not our verdict
    // to be judged against.
    return null;
  }

  const parent = await deps.fetchParent(repoFullName, failing.sha);
  if (parent === null) {
    log('info', 'post_merge_no_parent', { repo: repoFullName, sha: failing.sha });
    return null;
  }

  const before = await deps.fetchCheckRuns(repoFullName, parent);
  const previous = before.find((r) => r.name === failing.check);

  // ABSENT IS NOT GREEN. A check that did not run on the parent cannot have
  // gone from green to red, and treating its absence as a pass would
  // manufacture a transition that never happened.
  if (previous === undefined || previous.status !== 'completed' || !GREEN.has(previous.conclusion ?? '')) {
    return null;
  }

  return {
    prNumber: original.prNumber,
    attribution: { kind: 'inferred', check: failing.check, goodSha: parent, badSha: failing.sha },
  };
}
```

- [ ] **Step 4: Route default-branch check completions in `src/worker.ts`**

`check_run` currently sits in `KNOWN_UNROUTED`. Remove it and add a handler.
`check_run: completed` is the right event rather than `check_suite`, because it
names the individual check that failed — which the attribution record has to
carry.

```ts
/**
 * Route a `check_run: completed` on the default branch.
 *
 * Almost all of these are ignored. Only a FAILING run, on the default branch,
 * on a commit we recorded as a merge, with the same check green on the parent,
 * produces a record.
 */
async function handleCheckRun(deps: WorkerDeps, deliveryId: string, payload: any): Promise<void> {
  const run = payload?.check_run;
  if (payload?.action !== 'completed' || run?.conclusion !== 'failure') return;

  // Our own checks are neutral by construction and can never reach this branch,
  // but the guard is kept for the same reason handleCheckSuite has one: an
  // upstream change that made them non-neutral must not create a feedback loop.
  if (await isOurApp(run?.app?.id, deps.getGitHubConfig)) return;

  const repoFullName: string | undefined = payload?.repository?.full_name;
  const defaultBranch: string | undefined = payload?.repository?.default_branch;
  const sha: string | undefined = run?.head_sha;
  if (!repoFullName || !defaultBranch || !sha) return;

  if (!deps.isEnrolled(repoFullName)) return;

  // A failing check on a pull-request branch is ordinary CI, not a post-merge
  // failure. Only the default branch counts.
  const onDefault = (run?.check_suite?.head_branch ?? null) === defaultBranch;
  if (!onDefault) return;

  const attributed = await deps.attributeFailure(repoFullName, { sha, check: run.name }, {
    fetchCheckRuns: deps.fetchCheckRuns,
    fetchParent: deps.fetchParent,
    findByMergeCommit: deps.findByMergeCommit,
  });
  if (attributed === null) return;

  await deps.recordOutcome({
    repoFullName,
    prNumber: attributed.prNumber,
    outcome: 'post_merge_failure',
    headSha: sha,
    mergeCommitSha: null,
    at: run?.completed_at ?? new Date().toISOString(),
    bumps: [],
    attribution: attributed.attribution,
  });

  log('info', 'post_merge_failure_recorded', {
    repo: repoFullName, pr: attributed.prNumber, check: run.name,
    good_sha: attributed.attribution.goodSha, bad_sha: sha, delivery: deliveryId,
  });
}
```

Add `attributeFailure`, `fetchParent`, `fetchCheckRuns` to `WorkerDeps` and its
default. `fetchParent` is a small new helper in `src/check-runs.ts` or
`src/github.ts`:

```ts
/** First parent of a commit, or null on any failure. */
export async function fetchParent(
  repoFullName: string,
  sha: string,
  request: typeof githubRequest = githubRequest,
): Promise<string | null> {
  try {
    const res = await request(`/repos/${repoFullName}/commits/${sha}`);
    if (!res.ok) return null;
    const body = (await res.json()) as { parents?: { sha?: string }[] };
    return body.parents?.[0]?.sha ?? null;
  } catch {
    return null;
  }
}
```

- [ ] **Step 5: Add worker tests**

```ts
test('a passing check run on the default branch records nothing', async () => {
  const written: any[] = [];
  await runWorker({ recordOutcome: async (r: any) => { written.push(r); } }, 'check_run', {
    action: 'completed',
    repository: { full_name: 'o/r', default_branch: 'main' },
    check_run: { name: 'Cycode: SAST', conclusion: 'success', head_sha: 'x', check_suite: { head_branch: 'main' } },
  });
  assert.equal(written.length, 0);
});

test('a failing check run on a pull-request branch records nothing', async () => {
  // Ordinary CI on a feature branch is not a post-merge failure.
  const written: any[] = [];
  await runWorker({ recordOutcome: async (r: any) => { written.push(r); } }, 'check_run', {
    action: 'completed',
    repository: { full_name: 'o/r', default_branch: 'main' },
    check_run: { name: 'Cycode: SAST', conclusion: 'failure', head_sha: 'x', check_suite: { head_branch: 'feature/y' } },
  });
  assert.equal(written.length, 0);
});

test('an attributed failure is recorded with both SHAs and marked inferred', async () => {
  const written: any[] = [];
  await runWorker({
    attributeFailure: async () => ({ prNumber: 27, attribution: {
      kind: 'inferred', check: 'Cycode: SAST', goodSha: 'good', badSha: 'bad' } }),
    recordOutcome: async (r: any) => { written.push(r); },
  }, 'check_run', {
    action: 'completed',
    repository: { full_name: 'o/r', default_branch: 'main' },
    check_run: { name: 'Cycode: SAST', conclusion: 'failure', head_sha: 'bad', check_suite: { head_branch: 'main' } },
  });
  assert.equal(written[0].outcome, 'post_merge_failure');
  assert.equal(written[0].attribution.kind, 'inferred');
  assert.equal(written[0].attribution.goodSha, 'good');
});
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/post-merge.ts src/worker.ts src/check-runs.ts tests/
git commit -m "feat(outcomes): attribute post-merge failures on a green-to-red transition only"
```

---

## Task 5: `internalConfidence` — the eighth signal

**Files:**
- Create: `src/signals/internal-confidence.ts`, `tests/signals-internal-confidence.test.ts`
- Modify: `src/risk.ts`, `src/render.ts`, `src/evaluate.ts`, `policy-rules.yaml`, `src/rules-types.ts`, `scripts/build-rules.mjs`
- Modify: `tests/risk.test.ts`, `tests/render.test.ts`, `tests/evaluate.test.ts`

**Interfaces:**
- Consumes: `gsi-package-version` (Task 1).
- Produces: `InternalConfidence`, `internalConfidence(bumps, thisRepo, deps)`.

- [ ] **Step 1: Add the fleet threshold to the rules**

`policy-rules.yaml`, under `rules.risk`:

```yaml
    # Below this many enrolled repositories, `internalConfidence` grades
    # `unknown` on every evaluation — correctly. "Nobody else has taken this"
    # means nothing when there is nobody else. The epic's exit criteria already
    # require at least five pilot repositories.
    minFleetForConfidence: 5
```

`RiskThresholds` gains `minFleetForConfidence: number;` and the validator gains
`if (!isInt(risk.minFleetForConfidence) || risk.minFleetForConfidence < 1) bad('rules.risk.minFleetForConfidence', 'must be a positive integer');`

- [ ] **Step 2: Write the failing test**

Create `tests/signals-internal-confidence.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { internalConfidence } from '../src/signals/internal-confidence.js';
import type { DependencyBump } from '../src/classify.js';

const bump = (name: string, to: string): DependencyBump =>
  ({ name, from: '0.0.0', to, level: 'minor' });

/** `merges` maps pkg#name@version to the repos that merged it. */
function deps(merges: Record<string, { repo: string; outcome: string; backfilled?: boolean }[]>, fleet = 9) {
  const asked: string[] = [];
  return {
    asked,
    deps: {
      fleetSize: () => fleet,
      queryPackage: async (key: string) => { asked.push(key); return merges[key] ?? []; },
    },
  };
}

const ME = 'bankrate/mine';

test('three clean merges elsewhere grade low', () => {});  // placeholder replaced below

test('three clean merges elsewhere grade low', async () => {
  const { deps: d } = deps({ 'pkg#fastify@5.12.0': [
    { repo: 'bankrate/a', outcome: 'merged' },
    { repo: 'bankrate/b', outcome: 'merged' },
    { repo: 'bankrate/c', outcome: 'merged' },
  ] });
  const s = await internalConfidence([bump('fastify', '^5.12.0')], ME, 5, d);
  assert.equal(s.grade, 'low');
  assert.equal(s.value!.weakest.repos, 3);
});

test('one or two grade medium', async () => {
  const { deps: d } = deps({ 'pkg#fastify@5.12.0': [{ repo: 'bankrate/a', outcome: 'merged' }] });
  assert.equal((await internalConfidence([bump('fastify', '^5.12.0')], ME, 5, d)).grade, 'medium');
});

test('nobody else, in a fleet large enough to expect somebody, grades high', async () => {
  const { deps: d } = deps({});
  assert.equal((await internalConfidence([bump('fastify', '^5.12.0')], ME, 5, d)).grade, 'high');
});

test('a fleet too small for the question is unknown, forever, and that is correct', async () => {
  // With one enrolled repository this signal is unknown on every evaluation.
  // Not a defect: "nobody else has taken this" means nothing when there is
  // nobody else.
  const { deps: d } = deps({}, 1);
  const s = await internalConfidence([bump('fastify', '^5.12.0')], ME, 5, d);
  assert.equal(s.grade, 'unknown');
  assert.match(s.reason!, /1 of 5/);
});

test('this repository does not corroborate itself', async () => {
  const { deps: d } = deps({ 'pkg#fastify@5.12.0': [
    { repo: ME, outcome: 'merged' }, { repo: ME, outcome: 'merged' },
  ] });
  assert.equal((await internalConfidence([bump('fastify', '^5.12.0')], ME, 5, d)).grade, 'high');
});

test('a REVERTED prior merge does not corroborate', async () => {
  const { deps: d } = deps({ 'pkg#fastify@5.12.0': [
    { repo: 'bankrate/a', outcome: 'merged' },
    { repo: 'bankrate/b', outcome: 'reverted' },
    { repo: 'bankrate/c', outcome: 'reverted' },
  ] });
  const s = await internalConfidence([bump('fastify', '^5.12.0')], ME, 5, d);
  assert.equal(s.value!.weakest.repos, 1);
  assert.equal(s.grade, 'medium');
});

test('a post-merge failure DOES corroborate, and is disclosed', async () => {
  // A revert is a human judgment; a post-merge failure is our own inference.
  // Suppressing corroboration on an inference would broadcast one bad
  // attribution to every repository considering this package.
  const { deps: d } = deps({ 'pkg#pg@8.23.0': [
    { repo: 'bankrate/a', outcome: 'merged' },
    { repo: 'bankrate/b', outcome: 'merged' },
    { repo: 'bankrate/c', outcome: 'post_merge_failure' },
  ] });
  const s = await internalConfidence([bump('pg', '^8.23.0')], ME, 5, d);
  assert.equal(s.grade, 'low', 'three repos took it');
  assert.equal(s.value!.weakest.withPostMergeFailure, 1, 'and the reader is told');
});

test('grades on the WEAKEST link across a multi-package change', async () => {
  // One unproven package in a group is the exposure.
  const { deps: d } = deps({
    'pkg#fastify@5.12.0': [
      { repo: 'bankrate/a', outcome: 'merged' }, { repo: 'bankrate/b', outcome: 'merged' },
      { repo: 'bankrate/c', outcome: 'merged' },
    ],
    'pkg#pg@8.23.0': [],
  });
  const s = await internalConfidence([bump('fastify', '^5.12.0'), bump('pg', '^8.23.0')], ME, 5, d);
  assert.equal(s.grade, 'high');
  assert.equal(s.value!.weakest.package, 'pg');
});

test('the backfilled fraction is recorded', async () => {
  const { deps: d } = deps({ 'pkg#fastify@5.12.0': [
    { repo: 'bankrate/a', outcome: 'merged', backfilled: true },
    { repo: 'bankrate/b', outcome: 'merged', backfilled: true },
    { repo: 'bankrate/c', outcome: 'merged' },
  ] });
  const s = await internalConfidence([bump('fastify', '^5.12.0')], ME, 5, d);
  assert.equal(s.value!.weakest.backfilled, 2);
});

test('a failed query is unknown, never confident', async () => {
  const d = { fleetSize: () => 9, queryPackage: async () => { throw new Error('throttled'); } };
  const s = await internalConfidence([bump('fastify', '^5.12.0')], ME, 5, d);
  assert.equal(s.grade, 'unknown');
});

test('no bumps is unknown', async () => {
  const { deps: d } = deps({});
  assert.equal((await internalConfidence([], ME, 5, d)).grade, 'unknown');
});
```

Delete the placeholder duplicate `test('three clean merges elsewhere grade low', () => {});` line — it is shown above only to flag that Node's runner does not error on duplicate names, so a stray stub would silently pass.

- [ ] **Step 3: Run test to verify it fails**

Run: `node --import tsx --test tests/signals-internal-confidence.test.ts`
Expected: FAIL — module missing.

- [ ] **Step 4: Write `src/signals/internal-confidence.ts`**

```ts
// Signal 8: has anybody else here already taken this exact version, and did it
// stick?
//
// Renovate gates automerge on Merge Confidence — release age, adoption
// percentage, and CROWD PASSING PERCENTAGE, the last built from telemetry
// across thousands of repositories. We cannot buy that data.
//
// But the same signal is buildable from our own fleet. If bankrate/repo-a took
// fastify@5.12.0, merged it, and nothing reverted, that is real evidence for
// bankrate/repo-c's pending bump of the same package to the same version. It is
// crowd-passing percentage where the crowd is us.
//
// WHAT DISQUALIFIES, AND WHAT ONLY DISCLOSES:
//
//   reverted            -> does not corroborate. A human decided it was wrong.
//   post_merge_failure  -> DOES corroborate, and is counted separately.
//
// The asymmetry is deliberate. A post-merge failure is this service's own
// inference and may be misattributed; letting an inference suppress
// corroboration would broadcast one bad guess to every repository considering
// that package. So the merge counts and the signal SAYS how many of its
// corroborating merges were followed by a failure, leaving the reader to weigh
// it — a number they can see beats a number quietly reduced by a rule they
// cannot.
import type { DependencyBump } from '../classify.js';
import type { Signal } from './types.js';
import { unknownSignal } from './types.js';
import { bareVersion } from './version-records.js';
import { log } from '../log.js';

/** One prior merge of a package version, from the GSI. */
export interface PriorMerge {
  repo: string;
  outcome: string;
  backfilled?: boolean;
}

/** The least-corroborated package in the change — the one that sets the grade. */
export interface WeakestLink {
  package: string;
  version: string;
  /** Distinct OTHER repositories that merged this and did not revert it. */
  repos: number;
  /** How many of those were later followed by an inferred post-merge failure. */
  withPostMergeFailure: number;
  /** How many came from the historical backfill rather than a live evaluation. */
  backfilled: number;
}

export interface InternalConfidence {
  weakest: WeakestLink;
  /** How many packages produced an answer. */
  checked: number;
}

/** Injectable collaborators. */
export interface ConfidenceDeps {
  /** How many repositories are enrolled with `mode` other than `off`. */
  fleetSize: () => number;
  /** Prior merges of one `pkg#name@version` key, from `gsi-package-version`. */
  queryPackage: (pkgVersion: string) => Promise<PriorMerge[]>;
}

const CLEAN = 'low';

/**
 * Grade how well the fleet's own history corroborates this change.
 *
 * Args:
 *   bumps: Every dependency bump, from `classify()`.
 *   thisRepo: `owner/repo` — excluded from its own corroboration.
 *   minFleet: Below this many enrolled repos the question is meaningless.
 *   deps: Injected fleet size and package query.
 */
export async function internalConfidence(
  bumps: readonly DependencyBump[],
  thisRepo: string,
  minFleet: number,
  deps: ConfidenceDeps,
): Promise<Signal<InternalConfidence>> {
  if (bumps.length === 0) return unknownSignal('no dependency bumps to corroborate');

  const fleet = deps.fleetSize();
  if (fleet < minFleet) {
    // Correct, not a defect. With one enrolled repository this reads unknown on
    // every evaluation forever, because "nobody else has taken this" means
    // nothing when there is nobody else.
    return unknownSignal(
      `only ${fleet} of ${minFleet} repositories are enrolled — too few for fleet corroboration to mean anything`);
  }

  const links: WeakestLink[] = [];

  for (const bump of bumps) {
    const version = bareVersion(bump.to);
    if (!version) continue;

    let priors: PriorMerge[];
    try {
      priors = await deps.queryPackage(`pkg#${bump.name}@${version}`);
    } catch (err) {
      log('warn', 'confidence_query_failed', {
        package: bump.name, version,
        error: err instanceof Error ? err.message : String(err),
      });
      continue;
    }

    // Group by repository first: several rows can exist for one repo (a merge,
    // then a post-merge failure), and counting rows would inflate the number.
    const byRepo = new Map<string, string[]>();
    for (const p of priors) {
      if (p.repo === thisRepo) continue;
      byRepo.set(p.repo, [...(byRepo.get(p.repo) ?? []), p.outcome]);
    }

    const corroborating = [...byRepo.entries()].filter(([, outcomes]) =>
      outcomes.includes('merged') && !outcomes.includes('reverted'));

    links.push({
      package: bump.name,
      version,
      repos: corroborating.length,
      withPostMergeFailure: corroborating.filter(([, o]) => o.includes('post_merge_failure')).length,
      backfilled: priors.filter((p) => p.repo !== thisRepo && p.backfilled === true).length,
    });
  }

  if (links.length === 0) return unknownSignal('no package could be looked up');

  // THE WEAKEST LINK, not the average: one unproven package in a group is the
  // exposure, and averaging would let ten well-known packages carry an unknown
  // one through.
  const weakest = links.reduce((min, l) => (l.repos < min.repos ? l : min));

  const grade = weakest.repos >= 3 ? CLEAN : weakest.repos >= 1 ? 'medium' : 'high';

  return { grade, value: { weakest, checked: links.length } };
}
```

- [ ] **Step 5: Wire it in `src/risk.ts`, `src/render.ts` and `src/evaluate.ts`**

`RiskSignals` gains `internalConfidence: Signal<InternalConfidence>;` after
`targetVersionHealth`, and it joins the `comparable` array. It is **not** part
of the reducer floor — the floor is about a change being dangerous on its own
terms, and thin corroboration is an absence of evidence rather than evidence of
danger.

`SIGNAL_ROWS` gains `{ key: 'internalConfidence', label: 'Taken elsewhere' }`.
The count already reads `SIGNAL_ROWS.length` after Spec F, so "of 8" needs no
literal change — **verify that** rather than assuming it.

`signalCell`:

```ts
    case 'internalConfidence': {
      const v2 = v as { weakest: WeakestLink };
      const w = v2.weakest;
      const suffix = [
        w.withPostMergeFailure > 0 ? `${w.withPostMergeFailure} later had a failing check` : null,
        w.backfilled > 0 ? `${w.backfilled} from historical backfill` : null,
      ].filter(Boolean).join('; ');
      const base = w.repos === 0
        ? `\`${w.package}@${w.version}\` — no other enrolled repo has taken this`
        : `\`${w.package}@${w.version}\` — ${w.repos} other repo${w.repos === 1 ? '' : 's'}`;
      return suffix ? `${base} (${suffix})` : base;
    }
```

`evaluate.ts` adds it to the `Promise.all` inside `assessRisk`, wrapped by
`safely` with an `unknownSignal` fallback, passing `ctx.repoFullName`,
`thresholds.minFleetForConfidence`, and a `queryPackage` that reads the GSI.

- [ ] **Step 6: Update the test harnesses**

`tests/risk.test.ts`'s `signals()` builder gains
`internalConfidence: sig('low', { weakest: { package: 'a', version: '1.0.0', repos: 3, withPostMergeFailure: 0, backfilled: 0 }, checked: 1 })`,
and the "all low" test's `signalsGraded` becomes 8.

`tests/render.test.ts`'s `riskResult()` gains the same, the fixed-order test
asserts 8 rows with `'Taken elsewhere'` last, and the title assertion becomes
`of 8 signals`.

`tests/evaluate.test.ts` gains `internalConfidence` deps and the signal-count
assertion becomes 8.

- [ ] **Step 7: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/signals/internal-confidence.ts src/risk.ts src/render.ts src/evaluate.ts \
  src/rules-types.ts scripts/build-rules.mjs policy-rules.yaml src/generated/rules.ts tests/
git commit -m "feat(risk): grade whether the fleet has already taken this package version"
```

---

## Task 6: Backfill

Without it, `internalConfidence` reads `unknown` on every evaluation until the fleet merges the same package version three times *after* this ships — plausibly months. The raw material already exists in GitHub.

**Files:**
- Create: `scripts/backfill-outcomes.mjs`
- Create: `tests/backfill-outcomes.test.ts`
- Modify: `README.md`

- [ ] **Step 1: Write the failing test**

Create `tests/backfill-outcomes.test.ts`, testing the pure pieces (pagination
filter and record assembly) rather than the network loop:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { eligibleForBackfill, outcomeFromPr } from '../scripts/backfill-outcomes.mjs';

const BOTS = ['dependabot[bot]'];
const SINCE = Date.parse('2026-03-01T00:00:00Z');

const pr = (over = {}) => ({
  number: 27, merged_at: '2026-08-01T00:00:00Z', closed_at: '2026-08-01T00:00:00Z',
  user: { login: 'dependabot[bot]' }, head: { sha: 'f00d' }, merge_commit_sha: 'abc123',
  ...over,
});

test('a merged bot pull request inside the window is eligible', () => {
  assert.equal(eligibleForBackfill(pr(), BOTS, SINCE), true);
});

test('a human pull request is not', () => {
  assert.equal(eligibleForBackfill(pr({ user: { login: 'scrosby' } }), BOTS, SINCE), false);
});

test('an unmerged pull request is not', () => {
  assert.equal(eligibleForBackfill(pr({ merged_at: null }), BOTS, SINCE), false);
});

test('a pull request older than the window is not', () => {
  assert.equal(eligibleForBackfill(pr({ merged_at: '2025-01-01T00:00:00Z' }), BOTS, SINCE), false);
});

test('the record is marked backfilled and carries no verdict', () => {
  // Manufacturing retroactive verdicts under today's rulesSha would corrupt the
  // one dataset the shadow phase exists to produce.
  const r = outcomeFromPr('o/r', pr(), [{ name: 'pg', from: '^8.22.0', to: '^8.23.0', level: 'minor' }]);
  assert.equal(r.backfilled, true);
  assert.equal(r.outcome, 'merged');
  assert.equal(r.at, '2026-08-01T00:00:00Z');
  assert.equal('eligibility' in r, false);
  assert.equal('risk' in r, false);
});
```

- [ ] **Step 2: Write `scripts/backfill-outcomes.mjs`**

```js
#!/usr/bin/env node
// One-off historical reconstruction of outcome records.
//
// WHY IT EXISTS: without it, `internalConfidence` reads `unknown` on every
// evaluation until the fleet merges the same package version three times AFTER
// this ships — plausibly months. The raw material is already in GitHub.
//
// WHAT IT DOES NOT DO, and both are deliberate:
//
//   * No post_merge_failure. Reconstructing it needs the default branch's
//     check-run history plus the green-to-red test, for every commit in the
//     window — a large number of API calls to produce the LEAST trustworthy of
//     the four outcomes, under a rule that was not running at the time. The
//     field is absent on backfilled rows rather than false.
//
//   * No eval records. Backfill reconstructs what HAPPENED, never what this
//     service would have decided. Manufacturing retroactive verdicts under
//     today's rulesSha would corrupt the one dataset the shadow phase exists to
//     produce.
//
// Every row carries `backfilled: true`, and three things depend on it: the
// exit-criterion headline counts live records only; the confidence signal counts
// backfilled rows but records how many; and the weekly report shows that
// fraction, because corroboration from rows with no post-merge information is
// weaker than it looks.
//
// USAGE:
//   EVALUATIONS_TABLE=zapp-evaluations-qa \
//     node scripts/backfill-outcomes.mjs --repo bankrate/platform-cicd-v2-demo --since 180 [--dry-run]
//
// Idempotent: every write is conditional on attribute_not_exists(sk), so a
// re-run is safe and can never overwrite a record the live service wrote.

/** Is this pull request worth reconstructing? */
export function eligibleForBackfill(pr, botLogins, sinceMs) {
  if (!pr?.merged_at) return false;
  if (!botLogins.includes(pr?.user?.login)) return false;
  return Date.parse(pr.merged_at) >= sinceMs;
}

/** Assemble one outcome record. Carries no verdict — see the header. */
export function outcomeFromPr(repoFullName, pr, bumps) {
  return {
    repoFullName,
    prNumber: pr.number,
    outcome: 'merged',
    headSha: pr.head?.sha,
    mergeCommitSha: pr.merge_commit_sha ?? null,
    at: pr.merged_at,
    bumps,
    backfilled: true,
  };
}
```

The network loop below it (not shown as a separate step because it is one
function) does, per enrolled repository:

1. `GET /repos/{o}/{r}/pulls?state=closed&per_page=100`, paginated, filtered
   through `eligibleForBackfill`.
2. `GET /repos/{o}/{r}/pulls/{n}/files` → **the shipped `classify()`** → bumps.
   Using the real parser matters: a pull request that would not classify today
   must not get invented bumps.
3. `recordOutcome(outcomeFromPr(...))`.
4. A revert sweep: `GET /repos/{o}/{r}/commits?sha={default}&since={oldest merged_at}`,
   `revertedShas()` on each message, and a `reverted` record for each match —
   the same functions the live path uses, so the two cannot drift.

`--dry-run` prints what it would write and makes no call to DynamoDB. Run it
that way first, every time.

- [ ] **Step 3: Run test to verify it passes**

Run: `node --import tsx --test tests/backfill-outcomes.test.ts`
Expected: PASS, 5 tests.

- [ ] **Step 4: Document it in `README.md`**

Add an "Operations" subsection with the dry-run command, the real command, and
one sentence on why backfilled rows are flagged.

- [ ] **Step 5: Commit**

```bash
git add scripts/backfill-outcomes.mjs tests/backfill-outcomes.test.ts README.md
git commit -m "feat(backfill): reconstruct merged and reverted history, flagged as backfilled"
```

---

## Task 7: Documentation and live validation

- [ ] **Step 1: `docs/policy.md`**

Retitle "The seven risk signals" to eight and add the row:

```markdown
| **Taken elsewhere** | How many *other* enrolled Bankrate repositories already merged this exact package at this exact version and did not revert it. This is Merge Confidence's crowd-passing percentage, where the crowd is us. | Low: three or more. Medium: one or two. High: none, in a fleet large enough to expect some. | Fewer repositories are enrolled than the threshold makes meaningful — in which case "nobody else has taken this" means nothing. |
```

Add a short subsection explaining that a revert disqualifies corroboration, a
post-merge failure does not, and why.

- [ ] **Step 2: `AGENTS.md`, `README.md`, `docs/architecture.md`, `docs/call-flows.md`**

Update the signal count to eight, add the two GSIs, record that `push` and
`check_run` are now routed (removing them from any "subscribed but not routed"
list), and state the post-merge attribution rule where the events are described.

- [ ] **Step 3: Full verification**

```bash
pnpm run typecheck && pnpm test && pnpm run build
grep -rn 'of 7 signals\|seven signals\|seven risk' src/ docs/ tests/ *.md
grep -rn "KNOWN_UNROUTED" src/worker.ts
```

Expected: the first two pass, the first grep returns nothing, and the third
shows `push` and `check_run` no longer listed.

- [ ] **Step 4: Live validation**

Open the PR, let it deploy to QA, then:

1. **Merge** a dependabot PR on `bankrate/platform-cicd-v2-demo` and confirm an
   `outcome#` row plus one `#pkg#` row per bump appear under that PR's key.
2. **Revert** it through GitHub's button and confirm a `reverted` row appears
   against the same pull request.
3. Query the package index directly and confirm the reverted package no longer
   corroborates:

```bash
aws dynamodb query --table-name zapp-evaluations \
  --index-name gsi-package-version \
  --key-condition-expression 'pkgVersion = :p' \
  --expression-attribute-values '{":p":{"S":"pkg#fastify@5.12.0"}}' \
  --query 'Items[].{repo:repo.S,outcome:outcome.S,backfilled:backfilled.BOOL}'
```

4. Run the backfill **`--dry-run` first**, read the output, then for real, and
   confirm every written row has `backfilled: true`.
5. Confirm the risk check says **of 8 signals** and both checks are still
   `neutral`.

- [ ] **Step 5: Report the outcome**

State the outcome counts written, whether the revert was matched, what
`internalConfidence` graded on a real PR and why, and how many rows the backfill
added per repository. If the signal is `unknown` because only one repository is
enrolled, say so plainly — that is the expected result today, not a failure.

---

## Definition of done

- [ ] `pull_request` action `closed` writes a `merged` or `closed` outcome record *(Task 2)*
- [ ] `push` to the default branch is routed and revert commits are matched to recorded merges *(Task 3)*
- [ ] A revert that matches no recorded merge is logged, not written *(Task 3)*
- [ ] Prose mentioning "revert" does not mark anything reverted *(Task 3)*
- [ ] Outcome records carry the `headSha` they resolve *(Task 1)*
- [ ] One `pkg#` row per bump, under the pull request's own partition key, so a single `Query` returns evaluations, outcome and packages together *(Task 1)*
- [ ] `post_merge_failure` is attributed only on a green-to-red transition, carries `attribution: 'inferred'`, and names both commit SHAs *(Task 4)*
- [ ] A check absent from the parent commit does not count as green *(Task 4)*
- [ ] `gsi-package-version` and `gsi-merge-commit` exist, both sparse *(Task 1)*
- [ ] A package whose prior merge was **reverted** does not count as corroboration *(Task 5)*
- [ ] A package whose prior merge had an inferred post-merge failure **does** count, and the signal says how many *(Task 5)*
- [ ] `internalConfidence` grades on the weakest link and reads `unknown` below the fleet threshold *(Task 5)*
- [ ] A repository does not corroborate itself *(Task 5)*
- [ ] `scripts/backfill-outcomes.mjs` uses the shipped `classify()` and `revertedShas()`, is idempotent, and writes no eval records *(Task 6)*
- [ ] Every backfilled row carries `backfilled: true` and the confidence signal counts the backfilled fraction *(Tasks 5, 6)*
- [ ] Renderings say "of 8", derived from `SIGNAL_ROWS.length` *(Task 5)*
- [ ] Both checks remain `neutral` and on no required-checks configuration *(Task 7)*
