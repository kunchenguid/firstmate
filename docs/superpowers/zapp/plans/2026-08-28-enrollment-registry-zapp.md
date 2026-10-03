# Enrollment Registry (zapp side) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move zapp's repository enrollment out of `policy-rules.yaml` and into a DynamoDB table that zapp reads at runtime, so a UI can change it without a deploy.

**Architecture:** A new `zapp-enrollments` table holds one item per enrolled repository, all under a single partition key so "the whole fleet" is one `Query`. zapp reads it and never writes it. The worker resolves enrollment once per delivery, *before* claiming the delivery, and drops unenrolled repositories at that point; a failed read throws so the delivery reaches the DLQ rather than silently vanishing. Every eval record snapshots the enrollment it used, because `rulesSha` no longer covers it.

**Tech Stack:** TypeScript (ESM, Node 22), `@aws-sdk/client-dynamodb`, `node:test` + `node:assert/strict`, Terraform, pnpm.

**Spec:** `docs/superpowers/zapp/specs/2026-08-28-enrollment-registry-and-conductor-ui-design.md`

**Companion plan:** `docs/superpowers/zapp/plans/2026-08-28-enrollment-registry-conductor.md` (the Conductor UI). That plan consumes the table schema fixed in Task 1 here and can run in parallel from that point on.

## Global Constraints

- **Table name:** `zapp-enrollments`. No environment suffix — `local.name = var.app_name` in `infrastructure/terraform/init.tf`, exactly like the existing `zapp-evaluations` and `zapp-delivery-ids`.
- **Partition key:** `pk = "repo"` (constant) for enrollment records; **`sk` is GitHub's `repository.id` as a string**, e.g. `"1202845285"`.
- **History key:** `pk = "history#{repository.id}"`, `sk = "<ISO8601>#<version>"`. zapp reads neither and writes neither; the schema is fixed here so Conductor can rely on it.
- **ENROLLMENT IS KEYED ON THE REPOSITORY ID, NEVER THE NAME.** `owner/repo` is mutable; `repository.id` is not. Keyed on the name, a **rename silently unenrolls the repository** — the record strands on the old name, webhooks arrive under the new one and get dropped by the enrollment gate, the repo stops being evaluated with nothing reporting that it has, and it keeps counting toward `fleetSize` so `minFleetForConfidence` is satisfied by a partly fictional fleet. Every record carries a `repo` attribute holding `owner/repo`, but it is a **display label only**; nothing resolves enrollment through it and it may lag a rename.
- `repository.id` is present on every repository-scoped webhook event, so all four routed events can resolve enrollment.
- **zapp never writes enrollment.** Its IAM grant is `GetItem` and `Query` only, and the absence of `PutItem` is the enforcement.
- **No `dynamodb:Scan` anywhere.** The existing IAM policy states this as a design property; this work must not be what breaks it.
- **`ConsistentRead: true` on every read.**
- **Absent and empty are different facts.** `signalChecks`, `blockingChecks` and `baseBranches` absent means "use the global list"; present-and-empty means "use nothing".
- **A failed enrollment read throws.** It never returns `undefined`, and it never drops the delivery.
- **`isEnrolled` is an allow-list:** `mode === 'shadow'`, not `mode !== 'off'`. The value now comes from a table rather than a build-time-validated file, so an unrecognised mode must not read as enrolled.
- Commit messages follow Conventional Commits; the repo runs `commitlint`.
- Run `pnpm test` (which runs `tsc` then `node --test`) before every commit.

---

### Task 1: Create the table, the IAM grant, and the env var

Terraform only. Nothing reads the table yet, so this is safe to apply on its own and it unblocks the Conductor plan.

**Files:**
- Create: `infrastructure/terraform/enrollments.tf`
- Modify: `infrastructure/terraform/iam.tf` (append a new policy document + role policy)
- Modify: `infrastructure/terraform/main.tf:196-200` (the Lambda environment block)

**Interfaces:**
- Consumes: nothing.
- Produces: the `zapp-enrollments` table; `ENROLLMENTS_TABLE` in the Lambda environment; `aws_dynamodb_table.enrollments.arn` for later reference.

- [ ] **Step 1: Verify the base**

The zapp working tree must be current before anything else. A previous session in this epic built on a branch that was not what it appeared to be.

```bash
cd ~/Projects/zapp
git fetch origin
git rev-parse --abbrev-ref HEAD
git rev-list --count HEAD..origin/main
```

Expected: `main` (or a branch off current `main`), and `0` commits behind. If the count is non-zero, `git pull --ff-only` before continuing. Then confirm the starting point:

```bash
grep -c "^  - repo:" policy-rules.yaml
```

Expected: `8`. If it is not 8, stop — this plan's seed and parity steps assume those eight records.

- [ ] **Step 2: Write the table**

Create `infrastructure/terraform/enrollments.tf`:

```hcl
# The enrollment registry (PLAT-1188 T4). One item per enrolled repository,
# written by conductor-api's Auto-Merge page and read — never written — here.
#
# SINGLE PARTITION ON PURPOSE. Every enrollment record shares `pk = "repo"`, so
# "the whole fleet" is one Query rather than a Scan. `fleetSize` needs that
# count, and the ingestion policy's "no Scan" property is worth keeping. The
# partition holds one item per ENROLLED repo — eight today — against a 10 GB and
# 3,000 RCU/s ceiling, so it is nowhere near hot.
#
# `sk` IS GITHUB'S repository.id, NOT owner/repo. The name is mutable, and keyed
# on the name a rename silently unenrols the repository: the record strands on
# the old name while webhooks arrive under the new one and get dropped. Each
# record also carries a `repo` attribute for humans reading this table, but it is
# a label, not an identifier.
#
# History rows live under `pk = "history#{repository.id}"`, a separate partition
# per repository, precisely so they never appear in a fleet read.
#
# No TTL: this table is configuration, and its history is the audit trail.
resource "aws_dynamodb_table" "enrollments" {
  name         = "${local.name}-enrollments"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # Enabled in every environment, not just prod. Unlike the evaluations table,
  # a bad write here silently changes what the service evaluates, and the qa
  # table is the one an operator will experiment against.
  point_in_time_recovery {
    enabled = true
  }
}
```

- [ ] **Step 3: Write the IAM grant**

Append to `infrastructure/terraform/iam.tf`:

```hcl
# Read-only, deliberately. conductor-api's Auto-Merge page is the only writer;
# zapp reading its own enrollment and never writing it is what keeps "the
# service cannot enrol itself" structural rather than conventional.
#
# GetItem is the per-delivery drop check; Query is the fleet count that
# `internalConfidence` needs. Still no Scan.
data "aws_iam_policy_document" "lambda_enrollments" {
  statement {
    sid       = "ReadEnrollments"
    actions   = ["dynamodb:GetItem", "dynamodb:Query"]
    resources = [aws_dynamodb_table.enrollments.arn]
  }
}

resource "aws_iam_role_policy" "lambda_enrollments" {
  name   = "enrollments-read"
  role   = module.lambda.iam_role_name
  policy = data.aws_iam_policy_document.lambda_enrollments.json
}
```

- [ ] **Step 4: Add the env var**

In `infrastructure/terraform/main.tf`, the environment block currently reads:

```hcl
    DELIVERY_IDS_TABLE = aws_dynamodb_table.delivery_ids.name
    EVALUATIONS_TABLE  = aws_dynamodb_table.evaluations.name
```

Add a third line, keeping the existing alignment:

```hcl
    DELIVERY_IDS_TABLE = aws_dynamodb_table.delivery_ids.name
    EVALUATIONS_TABLE  = aws_dynamodb_table.evaluations.name
    ENROLLMENTS_TABLE  = aws_dynamodb_table.enrollments.name
```

- [ ] **Step 5: Validate**

```bash
cd infrastructure/terraform
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

Expected: `fmt` reports no changes needed, `validate` reports "Success!".

- [ ] **Step 6: Commit**

```bash
cd ~/Projects/zapp
git add infrastructure/terraform/enrollments.tf infrastructure/terraform/iam.tf infrastructure/terraform/main.tf
git commit -m "feat(infra): add the zapp-enrollments table and its read grant"
```

- [ ] **Step 7: Apply in qa and confirm**

Open a PR, get it merged, and let the `zapp-qa` TFC workspace apply. Then confirm the table exists and is empty:

```bash
aws dynamodb describe-table --table-name zapp-enrollments --profile bankrate-qa --region us-east-1 \
  --query 'Table.{Name:TableName,Keys:KeySchema,Status:TableStatus,Items:ItemCount}'
```

Expected: `ACTIVE`, hash `pk`, range `sk`, `Items: 0`.

**Tell the Conductor plan it can start.** Its Task 1 needs nothing but this schema.

---

### Task 2: Add the DynamoDB-backed enrollment reader, alongside the old one

The new functions land next to the existing YAML-backed ones. Nothing calls them yet, the build stays green, and every subsequent task migrates one caller. The old functions are deleted in Task 6.

**Files:**
- Modify: `src/enrollment.ts` (add; do not remove anything yet)
- Create: `tests/enrollment-store.test.ts`

**Interfaces:**
- Consumes: `client` and `DynamoSender` from `src/deliveries.ts`; `EnrollmentRecord` and `Rules` from `src/rules-types.ts`.
- Produces:
  - `interface StoredEnrollment extends EnrollmentRecord { version: number; updatedBy: string; updatedAt: string }`
  - `lookupEnrollment(repoId: string, send?: DynamoSender): Promise<StoredEnrollment | undefined>` — **takes `repository.id`, not `owner/repo`**
  - `loadFleet(send?: DynamoSender): Promise<StoredEnrollment[]>`
  - `fleetSizeFromTable(send?: DynamoSender): Promise<number>`
  - `isEnrolledRecord(e: StoredEnrollment | undefined): boolean`
  - `signalChecksForRecord(e: EnrollmentRecord | undefined, rules: Rules): readonly string[]`

  The `…Record` / `…FromTable` suffixes exist only to avoid colliding with the
  functions this task leaves in place. Task 6 deletes the old ones and renames
  these to `isEnrolled`, `fleetSize` and `signalChecksFor`.

- [ ] **Step 1: Write the failing tests**

Create `tests/enrollment-store.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  lookupEnrollment, loadFleet, fleetSizeFromTable,
  isEnrolledRecord, signalChecksForRecord,
} from '../src/enrollment.js';
import { rules } from '../src/rules.js';

// The convention in this suite: name the table in the file, with a -test
// suffix. See tests/ledger.test.ts:7 and tests/deliveries.test.ts:5.
process.env.ENROLLMENTS_TABLE = 'zapp-enrollments-test';

const DEMO = 'bankrate/platform-cicd-v2-demo';
const DEMO_ID = '1324428773';

/** One stored item, in the AttributeValue shape DynamoDB returns. */
function item(over: Record<string, unknown> = {}) {
  return {
    pk: { S: 'repo' },
    // The GitHub repository id. `repo` below is a display label, not the key.
    sk: { S: DEMO_ID },
    repoId: { S: DEMO_ID },
    repo: { S: DEMO },
    classification: { S: 'sandbox' },
    ciTrustTier: { N: '2' },
    mode: { S: 'shadow' },
    stageEnabled: { BOOL: false },
    version: { N: '3' },
    updatedBy: { S: 'scrosby@bankrate.com' },
    updatedAt: { S: '2026-08-28T12:00:00.000Z' },
    ...over,
  };
}

test('lookupEnrollment returns the record, including its write metadata', async () => {
  const record = await lookupEnrollment(DEMO_ID, async () => ({ Item: item() }));
  assert.equal(record?.repoId, DEMO_ID);
  assert.equal(record?.repo, DEMO, 'the display label rides along, but is not the key');
  assert.equal(record?.classification, 'sandbox');
  assert.equal(record?.ciTrustTier, 2);
  assert.equal(record?.mode, 'shadow');
  assert.equal(record?.stageEnabled, false);
  assert.equal(record?.version, 3);
  assert.equal(record?.updatedBy, 'scrosby@bankrate.com');
});

test('lookupEnrollment keys on the repository id, not the name', async () => {
  let sent: any;
  await lookupEnrollment(DEMO_ID, async (cmd: any) => { sent = cmd.input; return { Item: item() }; });
  assert.equal(sent.TableName, 'zapp-enrollments-test');
  assert.deepEqual(sent.Key, { pk: { S: 'repo' }, sk: { S: DEMO_ID } },
    'the name is mutable — keyed on it, a rename would silently unenrol the repository');
  assert.equal(sent.ConsistentRead, true);
});

test('a renamed repository keeps its enrollment', async () => {
  // The whole reason for id-keying. The stored label still says the old name;
  // the lookup succeeds anyway because the id is what was asked for.
  const record = await lookupEnrollment(DEMO_ID, async () => ({
    Item: item({ repo: { S: 'bankrate/renamed-demo' } }),
  }));
  assert.equal(isEnrolledRecord(record), true);
  assert.equal(record?.repoId, DEMO_ID);
});

test('an absent item is not enrolled — a fact, not an error', async () => {
  const record = await lookupEnrollment('999999999', async () => ({}));
  assert.equal(record, undefined);
  assert.equal(isEnrolledRecord(record), false);
});

test('a FAILED read throws — it never reads as "not enrolled"', async () => {
  await assert.rejects(
    () => lookupEnrollment(DEMO_ID, async () => { throw new Error('throttled'); }),
    /throttled/,
    'a read that could not answer must not be reported as an answer',
  );
});

test('mode "off" is retrievable but not enrolled — paused and absent differ', async () => {
  const record = await lookupEnrollment(DEMO_ID, async () => ({ Item: item({ mode: { S: 'off' } }) }));
  assert.equal(record?.mode, 'off');
  assert.equal(isEnrolledRecord(record), false);
});

test('an UNRECOGNISED mode is not enrolled — the check is an allow-list', async () => {
  const record = await lookupEnrollment(DEMO_ID, async () => ({ Item: item({ mode: { S: 'enforce' } }) }));
  assert.equal(isEnrolledRecord(record), false,
    'the table is not build-time validated, so only a known active mode may count as enrolled');
});

test('an absent signalChecks attribute inherits the global list', async () => {
  const record = await lookupEnrollment(DEMO_ID, async () => ({ Item: item() }));
  assert.equal(record?.signalChecks, undefined, 'the key must not be set at all');
  assert.ok(signalChecksForRecord(record, rules()).includes('codecov/project'));
});

test('a present-but-empty signalChecks means nothing is waited on', async () => {
  const record = await lookupEnrollment(DEMO_ID, async () => ({ Item: item({ signalChecks: { L: [] } }) }));
  assert.deepEqual(record?.signalChecks, []);
  assert.deepEqual(signalChecksForRecord(record, rules()), []);
});

test('a per-repo override replaces the global list rather than merging', async () => {
  const record = await lookupEnrollment(DEMO_ID, async () => ({
    Item: item({ signalChecks: { L: [{ S: 'Cycode: SAST' }] } }),
  }));
  assert.deepEqual(signalChecksForRecord(record, rules()), ['Cycode: SAST']);
});

test('loadFleet follows LastEvaluatedKey to the end', async () => {
  const pages = [
    { Items: [item({ sk: { S: '111' }, repoId: { S: '111' }, repo: { S: 'bankrate/a' } })], LastEvaluatedKey: { pk: { S: 'repo' }, sk: { S: '111' } } },
    { Items: [item({ sk: { S: '222' }, repoId: { S: '222' }, repo: { S: 'bankrate/b' } })] },
  ];
  let call = 0;
  const fleet = await loadFleet(async () => pages[call++]);
  assert.equal(call, 2, 'a truncated read must not be mistaken for the whole fleet');
  assert.deepEqual(fleet.map((r) => r.repoId), ['111', '222']);
});

test('fleetSizeFromTable counts only repos whose mode is shadow', async () => {
  const size = await fleetSizeFromTable(async () => ({
    Items: [
      item({ sk: { S: '111' }, repoId: { S: '111' }, repo: { S: 'bankrate/a' } }),
      item({ sk: { S: '222' }, repoId: { S: '222' }, repo: { S: 'bankrate/b' }, mode: { S: 'off' } }),
      item({ sk: { S: '333' }, repoId: { S: '333' }, repo: { S: 'bankrate/c' } }),
    ],
  }));
  assert.equal(size, 2);
});

test('the fleet Query targets the fleet partition and never scans', async () => {
  let sent: any;
  await loadFleet(async (cmd: any) => { sent = cmd.input; return { Items: [] }; });
  assert.equal(sent.KeyConditionExpression, 'pk = :pk');
  assert.deepEqual(sent.ExpressionAttributeValues, { ':pk': { S: 'repo' } });
  assert.equal(sent.ConsistentRead, true);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/Projects/zapp
pnpm exec tsc --noEmit
```

Expected: FAIL — `tsc` reports that `lookupEnrollment`, `loadFleet`, `fleetSizeFromTable`, `isEnrolledRecord` and `signalChecksForRecord` are not exported from `src/enrollment.js`.

- [ ] **Step 3: Write the implementation**

Append to `src/enrollment.ts`, and add the two imports at the **top of the file** (next to the existing `import { POLICY }` line — not at the bottom):

```ts
import { GetItemCommand, QueryCommand } from '@aws-sdk/client-dynamodb';
import { client, type DynamoSender } from './deliveries.js';
import type { Rules } from './rules-types.js';
```

Then, at the end of the file:

```ts
// ---------------------------------------------------------------------------
// PLAT-1188 T4: enrollment read from the zapp-enrollments table.
//
// The functions above still read the compiled policy document; they are removed
// once every caller has moved (see the plan's Task 6). Nothing below reads
// POLICY.
// ---------------------------------------------------------------------------

const defaultSend: DynamoSender = (cmd) => client.send(cmd as never);

const enrollmentsTable = (): string => process.env.ENROLLMENTS_TABLE!;

/**
 * Every enrollment record shares one partition, so "the whole fleet" is one
 * Query. History records use `history#{owner}/{repo}` and never appear here.
 */
const FLEET_PK = 'repo';

/** An enrollment record plus the write metadata the ledger snapshots. */
export interface StoredEnrollment extends EnrollmentRecord {
  /** Monotonic, bumped on every write. The concurrency control and audit key. */
  version: number;
  updatedBy: string;
  updatedAt: string;
}

/**
 * Translate one stored item.
 *
 * The three optional list attributes are set ONLY when the attribute exists.
 * An absent `signalChecks` means "use the global list" and an empty one means
 * "wait on nothing", so writing `[]` for a missing attribute would silently
 * change behaviour on every repository read.
 *
 * No validation beyond that. An unrecognised `classification` fails gate 9
 * closed (no change class lists it), and an unrecognised `mode` fails
 * `isEnrolledRecord`'s allow-list — so bad data degrades to "not eligible"
 * without a validation layer that could itself be wrong.
 */
function fromItem(item: Record<string, any>): StoredEnrollment {
  const strings = (attr: any): string[] | undefined =>
    attr === undefined ? undefined : ((attr.L ?? []) as any[]).map((v) => v.S as string);

  const record: StoredEnrollment = {
    repoId: item.repoId.S,
    // A LABEL, not an identifier. May lag a rename until Conductor's sync
    // refreshes it; nothing resolves enrollment through it.
    repo: item.repo.S,
    classification: item.classification.S,
    ciTrustTier: Number(item.ciTrustTier.N),
    mode: item.mode.S,
    stageEnabled: item.stageEnabled?.BOOL === true,
    version: Number(item.version.N),
    updatedBy: item.updatedBy?.S ?? 'unknown',
    updatedAt: item.updatedAt?.S ?? 'unknown',
  };

  const signalChecks = strings(item.signalChecks);
  if (signalChecks !== undefined) record.signalChecks = signalChecks;
  const blockingChecks = strings(item.blockingChecks);
  if (blockingChecks !== undefined) record.blockingChecks = blockingChecks;
  const baseBranches = strings(item.baseBranches);
  if (baseBranches !== undefined) record.baseBranches = baseBranches;

  return record;
}

/**
 * The enrollment record for one repository, if it has one.
 *
 * KEYED ON `repository.id`, NOT `owner/repo`. The name is mutable, and keyed on
 * it a rename silently unenrols the repository: the record strands on the old
 * name while webhooks arrive under the new one and get dropped by the gate
 * below. The id never changes, so a rename is a non-event.
 *
 * Returns the record even when `mode` is `off`: "enrolled but paused" and "not
 * enrolled at all" are different facts, and gate 1 reports which.
 *
 * `ConsistentRead` because the Conductor page is a control surface — an
 * operator who clicks Enroll and sees the next pull request ignored cannot tell
 * that from a bug.
 *
 * Raises:
 *   Error: On any DynamoDB failure. NEVER returns undefined for a failed read —
 *     "we could not find out" is not "not enrolled", and the caller's whole job
 *     is to tell those apart.
 */
export async function lookupEnrollment(
  repoId: string,
  send: DynamoSender = defaultSend,
): Promise<StoredEnrollment | undefined> {
  const res = (await send(new GetItemCommand({
    TableName: enrollmentsTable(),
    Key: { pk: { S: FLEET_PK }, sk: { S: repoId } },
    ConsistentRead: true,
  }))) as { Item?: Record<string, any> };

  return res.Item === undefined ? undefined : fromItem(res.Item);
}

/**
 * Every enrollment record.
 *
 * PAGINATES. `fleetSizeFromTable` turns this into a denominator, and a silently
 * truncated read produces a plausible wrong number instead of an error. The
 * 1 MB response limit is not reachable at today's size; the loop is insurance.
 *
 * Raises:
 *   Error: On any DynamoDB failure.
 */
export async function loadFleet(send: DynamoSender = defaultSend): Promise<StoredEnrollment[]> {
  const out: StoredEnrollment[] = [];
  let start: Record<string, any> | undefined;

  do {
    const res = (await send(new QueryCommand({
      TableName: enrollmentsTable(),
      KeyConditionExpression: 'pk = :pk',
      ExpressionAttributeValues: { ':pk': { S: FLEET_PK } },
      ConsistentRead: true,
      ...(start === undefined ? {} : { ExclusiveStartKey: start }),
    }))) as { Items?: Record<string, any>[]; LastEvaluatedKey?: Record<string, any> };

    for (const item of res.Items ?? []) out.push(fromItem(item));
    start = res.LastEvaluatedKey;
  } while (start !== undefined);

  return out;
}

/**
 * How many repositories are actively enrolled.
 *
 * `internalConfidence` reads this to decide whether the fleet is large enough
 * for "nobody else has taken this" to mean anything.
 *
 * Raises:
 *   Error: On any DynamoDB failure.
 */
export async function fleetSizeFromTable(send: DynamoSender = defaultSend): Promise<number> {
  return (await loadFleet(send)).filter((r) => r.mode === 'shadow').length;
}

/**
 * Is this repository actively enrolled?
 *
 * An ALLOW-LIST, not `mode !== 'off'`. The old check was safe when the value
 * came from a build-time-validated file; read from a table, an unrecognised
 * mode must not read as enrolled.
 */
export function isEnrolledRecord(enrollment: StoredEnrollment | undefined): boolean {
  return enrollment !== undefined && enrollment.mode === 'shadow';
}

/**
 * The check runs the risk signals must wait for on this repository.
 *
 * A per-repo list REPLACES the global one — merging would make it impossible to
 * remove a check a repo does not run, which is the main reason to override at
 * all. An empty list means nothing is waited on. An ABSENT list means the
 * global one.
 */
export function signalChecksForRecord(
  enrollment: EnrollmentRecord | undefined,
  rules: Rules,
): readonly string[] {
  return enrollment?.signalChecks ?? rules.signalChecks;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
pnpm test
```

Expected: PASS, including every pre-existing test — nothing has been removed yet.

- [ ] **Step 5: Commit**

```bash
git add src/enrollment.ts tests/enrollment-store.test.ts
git commit -m "feat(enrollment): read enrollment from the zapp-enrollments table"
```

---

### Task 3: Seed the table from the YAML, with a parity assertion

A one-off script the operator runs with their own credentials. zapp's Lambda role cannot write this table and must not be able to.

**Files:**
- Create: `scripts/seed-enrollments.mjs`
- Create: `tests/seed-enrollments.test.ts`
- Modify: `package.json` (add a `seed:enrollments` script)

**Interfaces:**
- Consumes: `policy-rules.yaml`'s `repos:` section; the table from Task 1.
- Produces: `buildSeedItems(repos, actor, now)` exported from the script for testing — returns the `PutItemCommand` inputs, one per record.

- [ ] **Step 1: Write the failing test**

Create `tests/seed-enrollments.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildSeedItems } from '../scripts/seed-enrollments.mjs';

const AT = '2026-08-28T12:00:00.000Z';
const ACTOR = 'scrosby@bankrate.com';

test('a minimal record seeds at version 1 with both write-metadata pairs', () => {
  const [put] = buildSeedItems([{
    repo: 'bankrate/zapp', classification: 'sandbox', ciTrustTier: 2,
    mode: 'shadow', stageEnabled: false,
  }], ACTOR, AT);

  assert.deepEqual(put.Item.pk, { S: 'repo' });
  assert.deepEqual(put.Item.sk, { S: '1344975715' }, 'keyed on the id, not the name');
  assert.deepEqual(put.Item.repoId, { S: '1344975715' });
  assert.deepEqual(put.Item.repo, { S: 'bankrate/zapp' }, 'the name rides along as a label');
  assert.deepEqual(put.Item.classification, { S: 'sandbox' });
  assert.deepEqual(put.Item.ciTrustTier, { N: '2' });
  assert.deepEqual(put.Item.mode, { S: 'shadow' });
  assert.deepEqual(put.Item.stageEnabled, { BOOL: false });
  assert.deepEqual(put.Item.version, { N: '1' });
  assert.deepEqual(put.Item.enrolledBy, { S: ACTOR });
  assert.deepEqual(put.Item.enrolledAt, { S: AT });
  assert.deepEqual(put.Item.updatedBy, { S: ACTOR });
  assert.deepEqual(put.Item.updatedAt, { S: AT });
});

test('an unknown repo fails loudly rather than seeding an unkeyed record', () => {
  assert.throws(() => buildSeedItems([{
    repo: 'bankrate/never-heard-of-it', classification: 'sandbox', ciTrustTier: 2,
    mode: 'shadow', stageEnabled: false,
  }], ACTOR, AT), /no GitHub repository id known/);
});

test('an absent override writes NO attribute at all', () => {
  const [put] = buildSeedItems([{
    repo: 'bankrate/zapp', classification: 'sandbox', ciTrustTier: 2,
    mode: 'shadow', stageEnabled: false,
  }], ACTOR, AT);

  assert.equal('signalChecks' in put.Item, false,
    'an absent list means "use the global one" — writing [] would mean "wait on nothing"');
  assert.equal('blockingChecks' in put.Item, false);
  assert.equal('baseBranches' in put.Item, false);
});

test('a present override is written as a string list, empty included', () => {
  const [put] = buildSeedItems([{
    repo: 'bankrate/crank', classification: 'internal-tool', ciTrustTier: 2,
    mode: 'shadow', stageEnabled: false, signalChecks: [],
  }], ACTOR, AT);

  assert.deepEqual(put.Item.signalChecks, { L: [] });
});

test('seeding is idempotent by construction — it overwrites by key', () => {
  const items = buildSeedItems([
    { repo: 'bankrate/zapp', classification: 'sandbox', ciTrustTier: 2, mode: 'shadow', stageEnabled: false },
    { repo: 'bankrate/zapp', classification: 'sandbox', ciTrustTier: 2, mode: 'shadow', stageEnabled: false },
  ], ACTOR, AT);

  assert.deepEqual(items[0].Item.sk, items[1].Item.sk,
    'the same repo produces the same key, so a re-run replaces rather than duplicates');
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
pnpm exec tsc --noEmit
```

Expected: FAIL — `scripts/seed-enrollments.mjs` does not exist.

- [ ] **Step 3: Write the script**

Create `scripts/seed-enrollments.mjs`:

```js
// One-off: seed zapp-enrollments from policy-rules.yaml's `repos:` section.
//
// Run with an operator's own credentials. zapp's Lambda role has GetItem and
// Query on this table and nothing else, deliberately — the service must not be
// able to enrol itself.
//
// IDEMPOTENT: each record's key is derived from its repo name, so a re-run
// replaces rather than duplicates.
//
// PARITY-ASSERTING: refuses to write anything if the YAML and the compiled
// policy document disagree, because in that situation neither is trustworthy as
// the thing being migrated.
import { readFileSync } from 'node:fs';
import { parse } from 'yaml';
import { DynamoDBClient, PutItemCommand } from '@aws-sdk/client-dynamodb';

// GitHub repository ids for the eight repos in policy-rules.yaml, resolved once
// with `gh api repos/bankrate/<name> --jq .id`.
//
// HARD-CODED rather than fetched. The YAML has no ids, and a seed script that
// needs GitHub credentials is a seed script that fails in the one situation it
// exists for. This map is used exactly once, by this migration.
const REPO_IDS = {
  'bankrate/platform-cicd-v2-demo': '1324428773',
  'bankrate/conductor': '660337931',
  'bankrate/conductor-api': '782637277',
  'bankrate/portkey': '1202845285',
  'bankrate/zapp': '1344975715',
  'bankrate/brand-identity-pages-app': '1244666547',
  'bankrate/redirect-management-api-v2': '656712940',
  'bankrate/crank': '1323400735',
};

/**
 * Build one PutItemCommand input per enrollment record.
 *
 * Exported for testing; the AWS call is not.
 *
 * Args:
 *   repos: The `repos:` array from policy-rules.yaml.
 *   actor: Recorded as both enrolledBy and updatedBy.
 *   now: ISO 8601 timestamp.
 */
export function buildSeedItems(repos, actor, now) {
  return repos.map((r) => {
    const repoId = REPO_IDS[r.repo];
    if (repoId === undefined) {
      throw new Error(`no GitHub repository id known for ${r.repo} — add it to REPO_IDS`);
    }

    const Item = {
      pk: { S: 'repo' },
      // The id, not the name: enrollment must survive a rename.
      sk: { S: repoId },
      repoId: { S: repoId },
      // A display label for humans reading this table.
      repo: { S: r.repo },
      classification: { S: r.classification },
      ciTrustTier: { N: String(r.ciTrustTier) },
      mode: { S: r.mode },
      stageEnabled: { BOOL: r.stageEnabled === true },
      version: { N: '1' },
      enrolledBy: { S: actor },
      enrolledAt: { S: now },
      updatedBy: { S: actor },
      updatedAt: { S: now },
    };

    // Absent and empty are different facts. Only set a key when the YAML had one.
    for (const field of ['signalChecks', 'blockingChecks', 'baseBranches']) {
      if (Array.isArray(r[field])) Item[field] = { L: r[field].map((s) => ({ S: s })) };
    }

    return { Item };
  });
}

async function main() {
  const table = process.env.ENROLLMENTS_TABLE ?? 'zapp-enrollments';
  const actor = process.env.SEED_ACTOR;
  if (!actor) {
    console.error('SEED_ACTOR is required — the audit trail names a person, not a script.');
    process.exit(1);
  }

  const doc = parse(readFileSync('policy-rules.yaml', 'utf8'));
  const repos = doc?.repos;
  if (!Array.isArray(repos) || repos.length === 0) {
    console.error('policy-rules.yaml has no `repos:` section to seed from.');
    process.exit(1);
  }

  // Parity: the YAML on disk must match what the build compiled. If they
  // differ, the working tree is not what the deployed service is running and
  // there is nothing safe to migrate.
  const { POLICY } = await import('../src/generated/rules.js');
  const yamlNames = repos.map((r) => r.repo).sort();
  const compiledNames = POLICY.repos.map((r) => r.repo).sort();
  if (JSON.stringify(yamlNames) !== JSON.stringify(compiledNames)) {
    console.error('PARITY FAILURE — policy-rules.yaml and src/generated/rules.ts disagree.');
    console.error(`  yaml:     ${yamlNames.join(', ')}`);
    console.error(`  compiled: ${compiledNames.join(', ')}`);
    console.error('Run `pnpm build` and re-check before seeding.');
    process.exit(1);
  }

  const items = buildSeedItems(repos, actor, new Date().toISOString());
  const client = new DynamoDBClient({});

  for (const { Item } of items) {
    await client.send(new PutItemCommand({ TableName: table, Item }));
    console.log(`seeded ${Item.sk.S}`);
  }
  console.log(`\n${items.length} records written to ${table}.`);
}

// Only run when invoked directly, so the test can import buildSeedItems.
if (import.meta.url === `file://${process.argv[1]}`) await main();
```

- [ ] **Step 4: Add the package script**

In `package.json`'s `scripts` block, add:

```json
    "seed:enrollments": "node scripts/seed-enrollments.mjs",
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
pnpm test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/seed-enrollments.mjs tests/seed-enrollments.test.ts package.json
git commit -m "feat(enrollment): seed the enrollment table from policy-rules.yaml"
```

- [ ] **Step 7: Seed qa and verify**

```bash
cd ~/Projects/zapp
pnpm build
SEED_ACTOR=scrosby@bankrate.com ENROLLMENTS_TABLE=zapp-enrollments \
  aws-vault exec bankrate-qa -- pnpm seed:enrollments
```

(Substitute whatever wrapper puts qa credentials in the environment — `ax bankrate-qa --` also works.)

Expected: eight `seeded …` lines. Then confirm the count and that no override attributes were invented:

```bash
aws dynamodb query --table-name zapp-enrollments \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"repo"}}' \
  --profile bankrate-qa --region us-east-1 \
  --query 'length(Items)'

aws dynamodb query --table-name zapp-enrollments \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"repo"}}' \
  --profile bankrate-qa --region us-east-1 \
  --query 'Items[].{id:repoId.S,repo:repo.S,mode:mode.S,cls:classification.S,sc:signalChecks}' --output table
```

Expected: `8`, and every `sc` column empty — none of the eight YAML records carries an override today.

---

### Task 4: Resolve enrollment once per delivery, before the claim

The behavioural core of this plan. With eight enrolled repos against 1,112 in the org, an irrelevant delivery must cost one `GetItem` and nothing else.

**Files:**
- Modify: `src/worker.ts` (`WorkerDeps`, `createWorker`, `handleDelivery`, and the four handlers)
- Modify: `src/index.ts:38-55` (the `createWorker` wiring)
- Modify: `tests/worker.test.ts` (harness and the enrollment tests)

**Interfaces:**
- Consumes: `lookupEnrollment` and `isEnrolledRecord` from Task 2.
- Produces: `WorkerDeps.lookupEnrollment: typeof lookupEnrollment` replacing `WorkerDeps.isEnrolled`; `handleDelivery(deps, ghEvent, deliveryId, payload, enrollment)` taking a parsed payload and a resolved `StoredEnrollment`.

- [ ] **Step 1: Write the failing tests**

In `tests/worker.test.ts`, replace the `harness` helper's `isEnrolled` line and add the new tests. The helper becomes:

```ts
// `prPayload()` at the top of this file builds `repository: { full_name: repo }`.
// Add the id, since enrollment now resolves through it:
//
//   repository: { id: 1324428773, full_name: repo },
//
// and give `sqsEvent`-driven tests whatever id they assert on.
function harness({ claimed = true, enrolled = true, postFails = false, readFails = false } = {}) {
  const state = {
    claims: [] as string[], confirms: [] as string[], releases: [] as string[],
    posts: [] as any[], lookups: [] as string[],
  };
  const worker = createWorker({
    claimDelivery: async (id: string) => { state.claims.push(id); return claimed; },
    confirmDelivery: async (id: string) => { state.confirms.push(id); },
    releaseDelivery: async (id: string) => { state.releases.push(id); },
    lookupEnrollment: async (repoId: string) => {
      state.lookups.push(repoId);
      if (readFails) throw new Error('throttled');
      return enrolled
        ? { repoId, repo: DEMO, classification: 'sandbox' as const, ciTrustTier: 2,
            mode: 'shadow' as const, stageEnabled: false,
            version: 1, updatedBy: 'x', updatedAt: 'y' }
        : undefined;
    },
    upsertShadowCheck: async (repo: string, sha: string, name: string) => {
      if (postFails) throw new Error('check-run POST failed for ' + name + ': 500 ');
      state.posts.push({ repo, sha, name });
    },
    evaluate: async () => ([
      { name: 'merge-policy/eligibility', output: { title: 't', summary: 's' } },
      { name: 'merge-policy/risk', output: { title: 't', summary: 's' } },
    ]),
  } as any);
  return { worker, state };
}
```

Then add:

```ts
test('an unenrolled repo is dropped WITHOUT claiming the delivery', async () => {
  const { worker, state } = harness({ enrolled: false });
  await worker(sqsEvent(prPayload({ repo: 'bankrate/not-enrolled', id: 42 })));
  assert.deepEqual(state.lookups, ['42'], 'the lookup key is the id, not the name');
  assert.deepEqual(state.claims, [], 'nothing was done, so nothing needed claiming');
  assert.deepEqual(state.confirms, []);
  assert.deepEqual(state.releases, []);
  assert.deepEqual(state.posts, []);
});

test('a paused repo (mode off) is dropped without claiming', async () => {
  const { worker, state } = createWorkerWithMode('off');
  await worker(sqsEvent(prPayload()));
  assert.deepEqual(state.claims, []);
  assert.deepEqual(state.posts, []);
});

test('a FAILED enrollment read throws and claims nothing', async () => {
  const { worker, state } = harness({ readFails: true });
  await assert.rejects(() => worker(sqsEvent(prPayload())), /throttled/);
  assert.deepEqual(state.claims, [], 'the throw happens before the claim');
  assert.deepEqual(state.releases, [], 'so there is no claim to release');
});

test('an unrouted event costs no enrollment read at all', async () => {
  const { worker, state } = harness();
  await worker(sqsEvent(prPayload(), { event: 'status' }));
  assert.deepEqual(state.lookups, [], 'the event gate runs before the read');
  assert.deepEqual(state.claims, []);
});

test('a payload with no repository is malformed and reaches the DLQ', async () => {
  const { worker, state } = harness();
  await assert.rejects(
    () => worker(sqsEvent(JSON.stringify({ action: 'opened', pull_request: { number: 1 } }))),
    /repository\.id/,
  );
  assert.deepEqual(state.claims, []);
});

test('a payload carrying a name but no repository id is malformed', async () => {
  const { worker, state } = harness();
  await assert.rejects(
    () => worker(sqsEvent(JSON.stringify({
      action: 'opened',
      pull_request: { number: 1, head: { sha: 'f00d42' } },
      repository: { full_name: 'bankrate/x' },
    }))),
    /repository\.id/,
    'the name alone is not enough to resolve enrollment',
  );
  assert.deepEqual(state.claims, []);
});

test('the enrollment record is resolved once, not per handler', async () => {
  const { worker, state } = harness();
  await worker(sqsEvent(prPayload()));
  assert.equal(state.lookups.length, 1);
});
```

Add the `createWorkerWithMode` helper next to `harness`:

```ts
/** A worker whose single enrolled record carries a given mode. */
function createWorkerWithMode(mode: 'shadow' | 'off') {
  const state = { claims: [] as string[], posts: [] as any[] };
  const worker = createWorker({
    claimDelivery: async (id: string) => { state.claims.push(id); return true; },
    confirmDelivery: async () => {},
    releaseDelivery: async () => {},
    lookupEnrollment: async (repoId: string) => ({
      repoId, repo: DEMO, classification: 'sandbox' as const, ciTrustTier: 2, mode,
      stageEnabled: false, version: 1, updatedBy: 'x', updatedAt: 'y',
    }),
    upsertShadowCheck: async (repo: string, sha: string, name: string) => { state.posts.push({ repo, sha, name }); },
    evaluate: async () => ([{ name: 'merge-policy/eligibility', output: { title: 't', summary: 's' } }]),
  } as any);
  return { worker, state };
}
```

Also update the existing tests that set `isEnrolled` directly — `tests/worker.test.ts` lines 127, 153, 241, 267, 341, 370, 420, 459. Each `isEnrolled: () => true` becomes:

```ts
    lookupEnrollment: async (repoId: string) => ({
      repoId, repo: DEMO, classification: 'sandbox' as const, ciTrustTier: 2,
      mode: 'shadow' as const, stageEnabled: false,
      version: 1, updatedBy: 'x', updatedAt: 'y',
    }),
```

and each `isEnrolled: () => false` becomes `lookupEnrollment: async () => undefined`.

The two tests at lines 241 and 341 assert that an unenrolled repo records no outcome. They keep asserting that, but they must **also** now assert `state.claims` is empty, because the drop moved earlier.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
pnpm exec tsc --noEmit
```

Expected: FAIL — `lookupEnrollment` is not a property of `WorkerDeps`.

- [ ] **Step 3: Rewrite the worker's routing**

In `src/worker.ts`:

Change the import at line 9:

```ts
import { lookupEnrollment, isEnrolledRecord, type StoredEnrollment } from './enrollment.js';
```

In `WorkerDeps`, replace line 38:

```ts
  /** Resolves one repository's enrollment. THROWS on a failed read — see createWorker. */
  lookupEnrollment: typeof lookupEnrollment;
```

Add, next to `KNOWN_UNROUTED`:

```ts
// The four events this worker routes. Hoisted out of handleDelivery so the
// event gate can run in createWorker, BEFORE the enrollment read — an event we
// do not route should not cost a DynamoDB call.
const ROUTED_EVENTS = new Set(['pull_request', 'check_suite', 'push', 'check_run']);
```

Replace `handleDelivery` entirely:

```ts
/**
 * Route one delivery to its handler.
 *
 * Returning without posting is a success, not a failure: an unrouted event is
 * a normal outcome that should settle the claim rather than burn an SQS retry.
 *
 * Both the event gate and the enrollment gate have already run in
 * `createWorker`, so `payload` is parsed and `enrollment` is a repository this
 * service actively evaluates.
 *
 * Raises:
 *   Error: On a malformed payload or a failed GitHub call — the caller
 *     releases the claim and rethrows so the message eventually reaches the DLQ.
 */
async function handleDelivery(
  deps: WorkerDeps,
  ghEvent: string,
  deliveryId: string,
  payload: any,
  enrollment: StoredEnrollment,
): Promise<void> {
  if (ghEvent === 'check_suite') {
    await handleCheckSuite(deps, deliveryId, payload, enrollment);
    return;
  }

  if (ghEvent === 'push') {
    await handlePush(deps, deliveryId, payload);
    return;
  }

  if (ghEvent === 'check_run') {
    await handleCheckRun(deps, deliveryId, payload);
    return;
  }

  await handlePullRequest(deps, deliveryId, payload, enrollment);
}
```

In `createWorker`, replace the body of the `for` loop's head — everything from the `deliveryId`/`ghEvent` lines through the `claimDelivery` check:

```ts
export function createWorker(deps: WorkerDeps) {
  return async (event: SQSEvent): Promise<void> => {
    for (const record of event.Records) {
      const deliveryId = record.messageAttributes?.deliveryId?.stringValue ?? record.messageId;
      const ghEvent = record.messageAttributes?.githubEvent?.stringValue ?? 'unknown';

      // EVENT GATE FIRST, before any I/O. `status` on 1,112 repositories should
      // cost nothing, and it does not route anywhere yet.
      if (!ROUTED_EVENTS.has(ghEvent)) {
        const known = KNOWN_UNROUTED.has(ghEvent);
        log('info', known ? 'event_not_routed_yet' : 'event_unknown', { event: ghEvent, delivery: deliveryId });
        continue;
      }

      // Parsed once here rather than inside handleDelivery: the enrollment gate
      // below needs the repository name, and parsing twice to preserve the old
      // call shape would be the only reason to.
      //
      // A parse failure throws before any claim is taken, which is correct —
      // there is nothing to release.
      const payload = JSON.parse(record.body);

      // BOTH are needed, for different jobs. `id` resolves enrollment because it
      // survives a rename; `full_name` is what logs, EvalContext and the
      // name-based freeze path use.
      const repoId: string | undefined = payload?.repository?.id === undefined
        ? undefined
        : String(payload.repository.id);
      const repoFullName: string | undefined = payload?.repository?.full_name;

      if (!repoId || !repoFullName) {
        log('error', 'payload_missing_repo', { event: ghEvent, delivery: deliveryId });
        throw new Error('malformed payload: missing repository.id or repository.full_name');
      }

      // ENROLLMENT GATE, BEFORE THE CLAIM. Eight repositories are enrolled out
      // of 1,112 in the org, so over 99% of deliveries end here and should cost
      // exactly one GetItem — not a claim write and a release write as well.
      //
      // Dropping without claiming is safe precisely because nothing was done: a
      // redelivery takes the identical path to the identical decision. The
      // dedupe table exists to stop side effects happening twice, and there are
      // none here.
      let enrollment: StoredEnrollment | undefined;
      try {
        enrollment = await deps.lookupEnrollment(repoId);
      } catch (err) {
        // Deliberately outside the try/catch below: no claim has been taken, so
        // there is nothing to release. The throw propagates, SQS retries, and
        // the message reaches the DLQ where `zapp-{env}-dlq-not-empty` fires.
        //
        // NOT degraded to "not enrolled". That would stop evaluating the entire
        // fleet while every delivery reported success.
        log('error', 'enrollment_read_failed', {
          repo: repoFullName, repo_id: repoId, event: ghEvent, delivery: deliveryId,
          error: err instanceof Error ? err.message : String(err),
        });
        throw err;
      }

      if (!isEnrolledRecord(enrollment)) {
        log('info', enrollment === undefined ? 'repo_not_enrolled' : 'repo_paused', {
          repo: repoFullName, repo_id: repoId, mode: enrollment?.mode,
          event: ghEvent, delivery: deliveryId,
        });
        continue;
      }

      // Claim BEFORE processing: exactly one of two racing workers wins, so a
      // duplicate can never produce a duplicate check run.
      if (!(await deps.claimDelivery(deliveryId))) {
        log('info', 'duplicate_delivery', { delivery: deliveryId, event: ghEvent });
        continue;
      }

      try {
        await handleDelivery(deps, ghEvent, deliveryId, payload, enrollment!);
        await deps.confirmDelivery(deliveryId);
      } catch (err) {
        // Release the claim so the SQS redelivery can re-claim and retry;
        // without this the retry would look like a duplicate and drop the event.
        await deps.releaseDelivery(deliveryId);
        log('error', 'delivery_failed', {
          delivery: deliveryId,
          event: ghEvent,
          error: err instanceof Error ? err.message : String(err),
        });
        throw err;
      }
    }
  };
}
```

- [ ] **Step 4: Remove the now-redundant checks from the four handlers**

Delete the five `deps.isEnrolled(...)` guards at `src/worker.ts` lines 87, 105, 184, 232 and 285, along with their `repo_not_enrolled` log lines. Each handler's other early returns stay.

`handlePullRequest` and `handleCheckSuite` take the resolved record as a fifth/fourth parameter and pass it into `postVerdicts` → `evaluate` (wired in Task 5). Until Task 5 lands, thread it through unused with a `void enrollment;` in `postVerdicts` — or better, do Tasks 4 and 5 back to back and pass it straight through.

`handlePullRequest`'s own `if (!repoFullName || !headSha)` check keeps the `headSha` half. The `repoFullName` half is now unreachable — leave it, since removing it would make the function unsafe to call directly.

- [ ] **Step 5: Rewire `src/index.ts`**

In the `createWorker({...})` call, replace `isEnrolled,` with `lookupEnrollment,` and update the import on line 13:

```ts
import { lookupEnrollment } from './enrollment.js';
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
pnpm test
```

Expected: PASS. If `tests/index.test.ts` asserts on the deps object's keys, update it.

- [ ] **Step 7: Commit**

```bash
git add src/worker.ts src/index.ts tests/worker.test.ts
git commit -m "feat(worker): resolve enrollment from the table before claiming a delivery"
```

---

### Task 5: Thread the record into `evaluate`, make `fleetSize` async, snapshot it in the ledger

**Files:**
- Modify: `src/evaluate.ts:151-192` (the `assessRisk` signal block) and `:205-232` (the `evaluate` signature and short-circuits)
- Modify: `src/signals/internal-confidence.ts:63` and `:112`
- Modify: `src/ledger.ts` (`EvalRecord`, `recordEvaluation`)
- Modify: `src/worker.ts` (`postVerdicts` passes the record through)
- Modify: `tests/evaluate.test.ts`, `tests/signals-internal-confidence.test.ts`, `tests/ledger.test.ts`

**Interfaces:**
- Consumes: `StoredEnrollment`, `fleetSizeFromTable`, `signalChecksForRecord` from Task 2.
- Produces: `evaluate(ctx, enrollment, deps?)`; `ConfidenceDeps.fleetSize: () => Promise<number>`; `EvalRecord.enrollment?: StoredEnrollment`.

- [ ] **Step 1: Write the failing tests**

In `tests/signals-internal-confidence.test.ts`, the deps at line 17 and 151 become async:

```ts
      fleetSize: async () => fleet,
```
```ts
  const d = { fleetSize: async () => 9, queryPackage: async () => { throw new Error('throttled'); } };
```

Add a new test that the Query is not paid for on the common path:

```ts
test('fleetSize is not consulted when there are no bumps to corroborate', async () => {
  let called = 0;
  const signal = await internalConfidence([], 'bankrate/zapp', 5, {
    fleetSize: async () => { called += 1; return 9; },
    queryPackage: async () => [],
  });
  assert.equal(called, 0, 'the fleet Query must not happen for a pull request with no bumps');
  assert.equal(signal.ok, false);
});
```

In `tests/ledger.test.ts`, add these, using the file's existing `fakeSend()`
(line 9) and `record()` (line 21) helpers — do not introduce new ones:

```ts
test('the eval record snapshots the enrollment it was decided under', async () => {
  const { send, calls } = fakeSend();
  await recordEvaluation({
    ...record(),
    enrollment: {
      repoId: '1324428773',
      repo: 'bankrate/platform-cicd-v2-demo', classification: 'sandbox' as const,
      ciTrustTier: 2, mode: 'shadow' as const, stageEnabled: false,
      version: 7, updatedBy: 'scrosby@bankrate.com', updatedAt: '2026-08-28T12:00:00.000Z',
    },
  }, send);

  const snapshot = JSON.parse(calls[0].input.Item.enrollment.S);
  assert.equal(snapshot.classification, 'sandbox',
    'rulesSha no longer covers enrollment, so gates 9 and 10 inputs must be on the record');
  assert.equal(snapshot.ciTrustTier, 2);
  assert.equal(snapshot.version, 7);
  assert.equal(snapshot.repoId, '1324428773',
    'the id is what identifies the enrollment, so an audit survives a later rename');
});

test('a record with no enrollment writes NULL, not a missing attribute', async () => {
  const { send, calls } = fakeSend();
  await recordEvaluation(record(), send);
  assert.deepEqual(calls[0].input.Item.enrollment, { NULL: true });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
pnpm exec tsc --noEmit
```

Expected: FAIL — `EvalRecord` has no `enrollment` property, and `fleetSize` is typed `() => number`.

- [ ] **Step 3: Make `fleetSize` async**

`src/signals/internal-confidence.ts` line 63:

```ts
  /** How many repositories are enrolled with mode `shadow`. Reads DynamoDB, so async. */
  fleetSize: () => Promise<number>;
```

Line 112:

```ts
  const fleet = await deps.fleetSize();
```

This sits after the `bumps.length === 0` early return, so the fleet `Query` is doubly gated: `internalConfidence` runs only for candidates, and within it only when there is something to corroborate.

- [ ] **Step 4: Add the ledger field**

In `src/ledger.ts`, add the import and the field:

```ts
import type { StoredEnrollment } from './enrollment.js';
```

In `EvalRecord`, after `wouldHaveMergedInWindow`:

```ts
  /**
   * The enrollment record this decision was made under, version included.
   *
   * `rulesSha` no longer covers enrollment — it pins the gates and thresholds
   * only. Gates 9 and 10 read `classification` and `ciTrustTier`, so without
   * this a record cannot explain its own verdict.
   *
   * Snapshotted rather than pointed at: resolving a pointer means reading a
   * table that has since changed. Optional because records written before
   * PLAT-1188 do not have it.
   */
  enrollment?: StoredEnrollment;
```

In `recordEvaluation`'s `Item`, after `wouldHaveMergedInWindow`:

```ts
      enrollment: record.enrollment
        ? { S: JSON.stringify(record.enrollment) }
        : { NULL: true },
```

- [ ] **Step 5: Change `evaluate`'s signature**

In `src/evaluate.ts`:

Replace the import on line 17 and delete line 40's `fleetSize` import:

```ts
import { signalChecksForRecord, fleetSizeFromTable, type StoredEnrollment } from './enrollment.js';
```

Line 160's signal deps:

```ts
      { fleetSize: fleetSizeFromTable, queryPackage: queryPackageVersion },
```

`assessRisk` needs the record to resolve signal checks. Give it a parameter and change line 189:

```ts
    completeness: assessCompleteness(runs, signalChecksForRecord(enrollment, policy)),
```

where `enrollment` and `policy` are threaded into `assessRisk` from `evaluate`. (`policy` here is the `Rules` object `evaluate` already holds as `rules()`.)

Then the signature and the deleted lookup:

```ts
export async function evaluate(
  ctx: EvalContext,
  enrollment: StoredEnrollment | undefined,
  deps: EvaluateDeps = defaultDeps,
): Promise<ShadowVerdict[]> {
  const policy = rules();
```

Delete line 211 (`const enrollment = enrollmentFor(ctx.repoFullName);`). The four
`enrollment === undefined || enrollment.mode === 'off'` short-circuits at lines
216, 228, 233 and 271 are unchanged — the worker now drops those deliveries
earlier, but the branches keep `evaluate` safe to call directly and keep gate 1
able to report which of the two states it saw.

Where the record is written to the ledger, pass it through:

```ts
      enrollment,
```

- [ ] **Step 6: Pass it through the worker**

In `src/worker.ts`, `postVerdicts` takes the record and forwards it:

```ts
/** Evaluate one pull request and write both check runs. */
async function postVerdicts(
  deps: WorkerDeps, ctx: EvalContext, deliveryId: string, enrollment: StoredEnrollment,
): Promise<void> {
  const verdicts = await deps.evaluate(ctx, enrollment);
```

and both call sites (in `handlePullRequest` and `handleCheckSuite`) pass the record they were given in Task 4.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
pnpm test
```

Expected: PASS. `tests/evaluate.test.ts` will need a second argument at every `evaluate(...)` call — pass a valid `StoredEnrollment` for the enrolled cases and `undefined` for the tests that exercise the short-circuit.

- [ ] **Step 8: Commit**

```bash
git add src/evaluate.ts src/signals/internal-confidence.ts src/ledger.ts src/worker.ts tests/
git commit -m "feat(evaluate): take the enrollment record and snapshot it on the eval record"
```

---

### Task 6: Delete the YAML enrollment path

Everything now reads the table. This removes the second source of truth and makes it impossible to reintroduce quietly.

**Files:**
- Modify: `src/enrollment.ts` (delete the old functions, rename the new ones)
- Modify: `src/rules-types.ts` (move `EnrollmentRecord`, drop `PolicyDocument.repos`)
- Modify: `policy-rules.yaml` (delete `repos:`)
- Modify: `scripts/build-rules.mjs:174-195` (reject the key instead of validating it)
- Delete: `tests/enrollment.test.ts` (superseded by `tests/enrollment-store.test.ts`)
- Modify: `tests/gates.test.ts:7,26,270,468`, `tests/render.test.ts:8,37,97,130,354,369`, `tests/build-rules.test.ts`

**Interfaces:**
- Produces: `isEnrolled(e)`, `fleetSize(send?)`, `signalChecksFor(e, rules)` — the Task 2 functions under their final names. `EnrollmentRecord` and `StoredEnrollment` both exported from `src/enrollment.ts`.

- [ ] **Step 1: Write the failing test**

In `tests/build-rules.test.ts`, add this. Note that `validatePolicy` **returns
an array of error strings** — it does not throw — so the assertion is an
`assert.match` on the first element, matching the existing tests in that file:

```ts
test('a `repos:` key is rejected — enrollment lives in DynamoDB now', () => {
  const doc = validDoc();
  doc.repos = [{ repo: 'bankrate/zapp' }];
  assert.match(validatePolicy(doc)[0], /repos.*no longer/i,
    'a stale repos section must fail the build rather than be silently ignored');
});
```

This test depends on `validDoc()` no longer including a `repos` key, which is
Step 4 below. Write the test now, expect it to fail for the right reason, and do
not reorder.

- [ ] **Step 2: Run it to verify it fails**

```bash
pnpm exec node --test tests/build-rules.test.ts
```

Expected: FAIL — the current validator accepts and requires `repos`, so
`validatePolicy(doc)` returns `[]` and indexing `[0]` gives `undefined`.

- [ ] **Step 3: Reject the key in the build**

In `scripts/build-rules.mjs`, replace the whole `repos` block (lines 174-195) with:

```js
  // Enrollment moved to the zapp-enrollments DynamoDB table (PLAT-1188 T4).
  // A leftover section here would look authoritative and be read by nothing, so
  // it fails the build rather than being ignored.
  if (doc?.repos !== undefined) {
    bad('repos', 'no longer belongs in this file — enrollment lives in the zapp-enrollments table');
  }
```

Also remove `repos` from whatever the script emits into `src/generated/rules.ts`.

- [ ] **Step 4: Delete the YAML section**

Remove the entire `repos:` block from `policy-rules.yaml` (everything from `repos:` to end of file), and replace the header comment's enrollment claim with:

```yaml
# Merge-policy rules. Reviewed as a PR; the file's git blob SHA is stamped into
# every evaluation, so any decision traces to the exact rules that produced it.
#
# ENROLLMENT IS NOT HERE. Which repositories are evaluated, and at what
# classification and CI trust tier, lives in the zapp-enrollments DynamoDB table
# and is edited through Conductor's Inventory -> Auto-Merge page (PLAT-1188).
# Each evaluation snapshots the enrollment record it used, so `rulesSha` pins
# the gates and thresholds while the record pins the enrollment.
```

- [ ] **Step 5: Update the types**

In `src/rules-types.ts`, delete `EnrollmentRecord` (lines 93-106) and the `repos` field from `PolicyDocument`. Move the interface into `src/enrollment.ts`, since it no longer describes the shape of `policy-rules.yaml`:

```ts
/** One enrolled repository, as stored in the zapp-enrollments table. */
export interface EnrollmentRecord {
  /** GitHub's `repository.id`, as a string. The IDENTITY — this is `sk`. */
  repoId: string;
  /**
   * `owner/repo`. A DISPLAY LABEL, not an identifier: it may lag a rename until
   * Conductor's sync refreshes it, and nothing resolves enrollment through it.
   */
  repo: string;
  classification: RepoClassification;
  ciTrustTier: number;
  mode: 'shadow' | 'off';
  stageEnabled: boolean;
  /** Replaces `Rules.signalChecks` for this repo when present. Never merged. */
  signalChecks?: string[];
  /** Replaces `Rules.blockingChecks` for this repo when present. Never merged. */
  blockingChecks?: string[];
  /** Base branches permitted in addition to the default branch. Never merged. */
  baseBranches?: string[];
}
```

`src/gates.ts` imports `EnrollmentRecord` from `./rules-types.js` — repoint it to `./enrollment.js`. `tsc` will name every other importer.

- [ ] **Step 6: Delete the old functions and rename the new ones**

In `src/enrollment.ts`, delete `enrollmentFor`, `isEnrolled`, `signalChecksFor` and `fleetSize` as they exist today, along with the `POLICY` import. Rename the Task 2 functions:

- `isEnrolledRecord` → `isEnrolled`
- `fleetSizeFromTable` → `fleetSize`
- `signalChecksForRecord` → `signalChecksFor`

Update the three call sites: `src/worker.ts` (`isEnrolledRecord`), `src/evaluate.ts` (`fleetSizeFromTable`, `signalChecksForRecord`), and `tests/enrollment-store.test.ts`.

Replace the file's header comment:

```ts
// Which repos this service evaluates, and the metadata gates 9 and 10 read.
//
// Reads the zapp-enrollments DynamoDB table (PLAT-1188 T4). READ ONLY: the
// Lambda role has GetItem and Query and deliberately no PutItem, so the service
// cannot enrol itself. Conductor's Inventory -> Auto-Merge page is the writer.
//
// Replaces the `repos` section of policy-rules.yaml, which in turn replaced the
// ENROLLED_REPOS environment variable. Enrollment is no longer covered by
// `rulesSha`, so every eval record snapshots the record it used (src/ledger.ts).
```

- [ ] **Step 7: Strip `repos` out of the build-rules tests**

`tests/build-rules.test.ts` references `repos` in nine places, and all of them
described validation that no longer exists. Work through them in this order:

| Line | Current | Action |
|---|---|---|
| 32 | `validDoc()` returns a `repos:` array | **Delete the key** from the returned object. |
| 64-65 | asserts `repos[0].classification` must be a known value | **Delete the test.** |
| 76-77 | asserts `repos[0].ciTrustTier` must be an integer | **Delete the test.** |
| 88 | pushes a duplicate to assert duplicate detection | **Delete the test.** |
| 100 | mutates `repos[0].classification` | **Delete the test**, unless its subject is something else — read it and keep the non-`repos` assertion if so. |
| 115 | `assert.equal(POLICY.repos[0].repo, …)` | **Delete the assertion.** If it is the test's only assertion, delete the test. |
| 212-213, 218 | `repos[0].signalChecks` validation and its absent case | **Delete both tests.** The absent-vs-empty distinction is now covered by `tests/enrollment-store.test.ts`. |
| 243-244 | `repos[0].blockingChecks` validation | **Delete the test.** |
| 308-309 | `repos[0].baseBranches` validation | **Delete the test.** |

Then confirm nothing is left:

```bash
grep -n "repos" tests/build-rules.test.ts
```

Expected: exactly one hit — the new rejection test from Step 1.

Deleting rather than porting is right here: these tests validated a YAML schema
that no longer has these fields. The equivalent guarantees now belong to the
Conductor form (which validates its own input) and to `fromItem`'s
absent-vs-empty handling, both of which are tested where they live.

- [ ] **Step 8: Fix the gate and render fixtures**

`tests/gates.test.ts` and `tests/render.test.ts` both call `enrollmentFor(DEMO)` against the compiled policy. Delete the import (`gates.test.ts:7`, `render.test.ts:8`) and add a local fixture near the top of each file:

```ts
/** The demo repo's enrollment, previously read from policy-rules.yaml. */
const DEMO_ENROLLMENT: EnrollmentRecord = {
  repoId: '1324428773',
  repo: DEMO,
  classification: 'sandbox',
  ciTrustTier: 2,
  mode: 'shadow',
  stageEnabled: false,
};
```

Then replace every `enrollmentFor(DEMO)` with `DEMO_ENROLLMENT` and every `{ ...enrollmentFor(DEMO)!, X }` with `{ ...DEMO_ENROLLMENT, X }` — `gates.test.ts` lines 26, 270, 468 and `render.test.ts` lines 37, 97, 130, 354, 369. `render.test.ts` already imports `EnrollmentRecord`; `gates.test.ts` does too (line 8).

Delete `tests/enrollment.test.ts`.

- [ ] **Step 9: Run everything**

```bash
pnpm build && pnpm test
```

Expected: PASS, and `src/generated/rules.ts` no longer contains a `repos` array:

```bash
grep -c "repos" src/generated/rules.ts
```

Expected: `0`.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "refactor(enrollment)!: remove the policy-rules.yaml repos section

Enrollment now lives only in the zapp-enrollments table. build-rules.mjs
rejects a leftover repos: key so it cannot return unnoticed."
```

- [ ] **Step 11: Verify in qa before continuing**

Merge and let the deploy run, then confirm evaluations still happen and carry the snapshot:

```bash
aws dynamodb scan --table-name zapp-evaluations \
  --filter-expression 'attribute_exists(enrollment) AND attribute_type(enrollment, :s)' \
  --expression-attribute-values '{":s":{"S":"S"}}' \
  --profile bankrate-qa --region us-east-1 --query 'Count'
```

Open a dependency PR on `bankrate/platform-cicd-v2-demo`, wait for the check runs, and re-run the query. Expected: the count increases, and the newest record's `enrollment` parses to the seeded record with `version: 1`.

---

### Task 7: Prepare for the widened App installation

Capacity and observability work that must land **before** installation 156198964 is widened. None of it changes application behaviour.

**Files:**
- Modify: `infrastructure/terraform/alarms.tf` (append a Throttles alarm)
- Modify: `infrastructure/terraform/vars.tf:70-79` (raise the default)
- Modify: `src/worker.ts:30` (`KNOWN_UNROUTED` comment)
- Modify: `README.md`, `docs/architecture.md` (the `repository_selection` claims)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `zapp-{env}-lambda-throttles` alarm.

- [ ] **Step 1: Add the Throttles alarm**

`alarms.tf` has exactly two alarms today, and neither fires on the failure this task exists to prevent: a throttled receiver returns errors to GitHub, GitHub retries and then disables the webhook, and the service goes silent. Append:

```hcl
# Throttling is currently invisible, and it is the specific failure mode of
# widening the App installation to all 1,112 repositories in the org: the
# receiver is synchronous with GitHub's delivery, so a throttle is an error
# returned to GitHub, and GitHub disables a webhook that fails persistently.
# The symptom would be silence, which no existing alarm covers.
#
# Threshold 0 over two periods: one throttle is a burst, a sustained rate means
# the reserved pool is too small for the installation's breadth.
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${local.name}-${var.environment}-lambda-throttles"
  alarm_description   = "zapp's Lambda is being throttled. The receiver answers GitHub synchronously, so a throttle is an error returned to GitHub — raise reserved_concurrency."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = module.lambda.name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
```

Three details copied from the file rather than guessed:

- **`module.lambda.name`**, not `module.lambda.function_name`. The module exposes
  `name` (used at `outputs.tf:7`) and `arn`; there is no `function_name` output.
- **Attribute order** follows `dlq_not_empty` (`alarms.tf:16-28`) — name,
  description, namespace, metric, dimensions, statistic, period, periods,
  threshold, operator, missing-data, actions.
- **`[aws_sns_topic.alerts.arn]`** is what both existing alarms use
  (`alarms.tf:28`, `:65`), and neither sets `ok_actions`, so this one does not
  either.

The SNS topic is documented as unsubscribed today (`docs/architecture.md:25`).
The alarm state is still visible in CloudWatch; wiring the topic to a
destination is out of scope here.

- [ ] **Step 2: Raise the concurrency default**

`vars.tf` describes 10 as "ample for a webhook receiver", which was written for eight repositories. Replace the description and default:

```hcl
variable "reserved_concurrency" {
  description = "Reserved concurrent executions for the Lambda (-1 = unreserved). Bounds blast radius on the public Function URL. Raised from 10 to 50 for PLAT-1188: the App installation covers every repository in the org, so the receiver sees org-wide webhook volume and a throttle is an error returned to GitHub."
  type        = number
  default     = 50

  validation {
    condition     = var.reserved_concurrency >= -1
    error_message = "reserved_concurrency must be >= -1 (-1 = unreserved)."
  }
}
```

The SQS `maximum_concurrency = 5` in `main.tf` stays: the worker's throughput is not the constraint, the receiver's is, and capping queue processing is what keeps them from competing.

- [ ] **Step 3: Validate and commit**

```bash
cd infrastructure/terraform && terraform fmt -check -recursive && terraform init -backend=false && terraform validate
cd ~/Projects/zapp
git add infrastructure/terraform/alarms.tf infrastructure/terraform/vars.tf
git commit -m "feat(infra): alarm on Lambda throttles and raise reserved concurrency"
```

- [ ] **Step 4: Unsubscribe `status` on the GitHub App**

Manual, in GitHub's UI — App settings for `neutral-planet` → Permissions & events → uncheck **Status**.

`status` is in `KNOWN_UNROUTED` (`src/worker.ts:30`), subscribed for T8's benefit and routed nowhere. On 1,112 repositories it is plausibly the highest-volume of the seven subscribed events. Dropping it is free and reversible.

Update the comment at `src/worker.ts:30`:

```ts
// Subscribed on the GitHub App because PLAT-1184 T8 (the required-checks
// snapshot) needs them, but deliberately not routed in this scope. Named
// explicitly so the log distinguishes "not routed yet" from "unknown event".
//
// `status` was UNSUBSCRIBED for PLAT-1188 when the installation widened to every
// repository in the org — it is the highest-volume of the seven subscribed
// events and routes nowhere. Re-subscribe when T8 needs it. It stays in this
// set so a redelivery
// of an old status event still logs as "not routed yet" rather than "unknown".
const KNOWN_UNROUTED = new Set(['status', 'merge_group', 'merge_queue_entry']);
```

- [ ] **Step 5: Widen the installation**

Manual, in GitHub's UI — org settings → GitHub Apps → `neutral-planet` → **All repositories**.

Then confirm:

```bash
gh api /app/installations/156198964 --jq '{selection: .repository_selection, events: .events}'
```

(Requires an App JWT. If that is inconvenient, read it from the installation settings page instead.)

Expected: `repository_selection: all`, and `status` absent from `events`.

- [ ] **Step 6: Watch for an hour, then record what happened**

```bash
aws logs filter-log-pattern --log-group-name /aws/lambda/zapp-qa \
  --filter-pattern 'repo_not_enrolled' --profile bankrate-qa --region us-east-1 \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) --query 'length(events)'
```

and check the throttle count:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Throttles \
  --dimensions Name=FunctionName,Value=zapp-qa --statistics Sum --period 3600 \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --profile bankrate-qa --region us-east-1 --query 'Datapoints[].Sum'
```

Expected: a non-zero `repo_not_enrolled` count (the drop path is working) and `Throttles` of zero or absent. If throttles are non-zero, raise `reserved_concurrency` again before proceeding.

- [ ] **Step 7: Commit the comment change**

```bash
git add src/worker.ts
git commit -m "docs(worker): record that status was unsubscribed when the installation widened"
```

---

### Task 8: Update the docs

Enrollment's source of truth is asserted in more places than is obvious, and every one of them is now wrong.

**Files:**
- Modify: `README.md:11,44-45,56,62-64,187`
- Modify: `docs/architecture.md:12,64,82,113-122,128,136-137,188,235,313,337,339,353,418`
- Modify: `docs/call-flows.md:17,37,84-85,142-144,350,367,411,448,461,492`
- Modify: `docs/policy.md:40,336`

- [ ] **Step 1: Rewrite the architecture section**

Replace `docs/architecture.md`'s "Enrollment (minimal slice, not the real registry)" section (lines 113-122) with:

```markdown
## Enrollment

`src/enrollment.ts`'s `lookupEnrollment` reads one item from the
`zapp-enrollments` DynamoDB table — `pk = "repo"`, `sk = "{owner}/{repo}"`,
`ConsistentRead` — and `isEnrolled` treats only `mode: "shadow"` as active. An
absent item means not enrolled; a `mode: "off"` item means enrolled but paused,
and gate 1 reports which. Matching is exact, so a fork never inherits its
upstream's enrollment.

**A failed read throws.** Not-found is a fact and drops the delivery; a failed
call is not a fact, so it propagates, SQS retries, and the message reaches the
DLQ where `zapp-{env}-dlq-not-empty` fires. This is the opposite of
`readFreeze`, which degrades to "frozen" and keeps running — enrollment has no
safe state to degrade to. "Assume not enrolled" would silently stop evaluating
the whole fleet while every delivery reported success; "assume enrolled" would
evaluate all 1,112 repositories in the org.

The read happens once per delivery in `createWorker`, **before the delivery is
claimed**, so an unenrolled repository costs exactly one `GetItem` and no
dedupe writes. Dropping without claiming is safe because nothing was done: a
redelivery reaches the identical decision.

`fleetSize` — which `internalConfidence` reads — is a paginated `Query` over the
single `pk = "repo"` partition, so "the whole fleet" needs no `Scan`. It runs
only for a candidate that has at least one dependency bump.

**zapp never writes this table.** Its role has `GetItem` and `Query` and
deliberately no `PutItem`. The writer is conductor-api's Inventory → Auto-Merge
page (PLAT-1188), which also writes an append-only `history#{owner}/{repo}`
partition. Because enrollment is no longer part of `policy-rules.yaml`,
`rulesSha` no longer pins it, so every eval record snapshots the enrollment
record it was decided under — `classification` and `ciTrustTier` are gate 9 and
gate 10 inputs, and a record that cannot name them cannot explain its verdict.
```

- [ ] **Step 2: Fix the remaining zapp doc claims**

Work through each reference and correct it. The substantive ones:

- `README.md:11` — "Enrollment is read from `policy-rules.yaml`" → the table.
- `README.md:44-45` — "`policy-rules.yaml`'s `repos` section now enrolls eight repositories" → the table holds them; `minFleetForConfidence: 5` is still cleared.
- `README.md:62-64` — delete the "full enrollment registry (T4) — not yet the real registry" limitation. This work closes it.
- `README.md:187` and `docs/architecture.md:12,82,121` — `repository_selection: selected` → `all`, with the note that `checks:write` is held org-wide and exercised only on enrolled repositories.
- `docs/architecture.md:337,339` — `policy-rules.yaml` is the source of truth "for the eligibility gates and enrollment" → gates and thresholds only.
- `docs/policy.md:40` — gate 1's description says "has an entry in `policy-rules.yaml`" → "has an item in the `zapp-enrollments` table and that item's mode is `shadow`".
- `docs/architecture.md` gains a **sharp edge**: enrollment is keyed on `repository.id` and survives a rename, but the per-repo freeze parameter `/zapp/freeze/{owner}/{repo}` is name-based and does not. That is deliberate — a human reaching for an emergency brake mid-incident should type a repository name, not look up a numeric id — but it means a freeze set under a repository's old name silently stops applying after a rename. It is now the only place a rename still bites.
- `docs/call-flows.md` — the participant named `src/enrollment.ts<br/>isEnrolled()` in three diagrams (17, 350, 448) becomes `src/enrollment.ts<br/>lookupEnrollment()`, and in each the call must move **above** the claim step. Prose at 84-85, 142-144, 411 and 492 describes the old ordering.

- [ ] **Step 3: Verify no stale claims survive**

```bash
cd ~/Projects/zapp
grep -rn "repos section\|repos\` section\|ENROLLED_REPOS\|repository_selection: selected" README.md docs/ policy-rules.yaml
grep -rn "isEnrolled" docs/
```

Expected: no hits for the first command. The second should show only `isEnrolled` used as the allow-list predicate, never as the thing that reads the file.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/
git commit -m "docs: enrollment reads the DynamoDB table, not policy-rules.yaml"
```

- [ ] **Step 5: Update the Jira ticket**

PLAT-1188's description says the source of truth is a config file and enrolling is a reviewed PR, and its acceptance criteria say "Enrollment PR → table sync is automatic and audited". This implementation deliberately does neither. Rewrite the description and replace the criteria with:

- Enrollment changes are audited — actor, timestamp, before and after — in a `history#{owner}/{repo}` record that outlives Conductor.
- Un-enrolled repos are ignored by the evaluator (tested), and the evaluator fails visibly rather than silently when it cannot tell.
- Every eval record names the enrollment that produced it.

The ticket's `sourceSha` field has no meaning without a source file; it is replaced by `version`.

---

## Self-review notes

**Spec coverage.** Every section of the spec maps to a task: the table and keys → Task 1; the split read, fail-closed semantics and absent-vs-empty → Task 2; the seed and parity assertion → Task 3; the drop-before-claim reorder → Task 4; the `evaluate` parameter, async `fleetSize` and the ledger snapshot → Task 5; deleting the YAML path → Task 6; `status`, concurrency, the Throttles alarm and the widening → Task 7; docs and the Jira rewrite → Task 8.

Two spec items are deliberately **not** tasks here: the Conductor page (its own plan) and teaching `RECORDED_FIELDS` about the `enrollment` field, which the spec lists as out of scope.

**Naming consistency.** Task 2 introduces `isEnrolledRecord`, `fleetSizeFromTable` and `signalChecksForRecord` purely to coexist with the functions Task 6 deletes; Task 6 renames them to `isEnrolled`, `fleetSize` and `signalChecksFor`. Tasks 4 and 5 use the Task 2 names, and Task 6's step 6 lists the three call sites to update. `StoredEnrollment` and `EnrollmentRecord` keep their names throughout, with `EnrollmentRecord` moving file in Task 6.

**Ordering constraint.** Tasks 4 and 5 should be done back to back: Task 4 threads the enrollment record into `handleDelivery` and the handlers, and Task 5 is what finally consumes it in `evaluate`. Doing 4 alone leaves a parameter passed and unused, which is noted in Task 4 step 4.
