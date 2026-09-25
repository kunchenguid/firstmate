# Webhook Ingestion + First Shadow Check Runs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ingest `pull_request` webhooks from the `neutral-planet` GitHub App exactly once, and post two visible, never-blocking check runs back onto pull requests in `bankrate/platform-cicd-v2-demo`.

**Architecture:** One Lambda in two roles, dispatched on event shape. The Function URL path verifies the HMAC signature and enqueues the raw body to SQS; the SQS path claims the GitHub delivery ID in DynamoDB, routes the event, and posts check runs via the GitHub App installation token. A DLQ with a CloudWatch alarm catches deliveries that fail three times.

**Tech Stack:** Node 22, TypeScript, `node:test` + `tsx`, esbuild, AWS SDK v3 (Secrets Manager, SQS, DynamoDB), Terraform (AWS provider ~> 6.0, TFC workspaces `zapp-qa` / `zapp-prod`), container-image Lambda deployed via `finserv-reusable-gha` CI/CD v2.

**Spec:** [`docs/superpowers/specs/2026-08-24-zapp-webhook-ingestion-design.md`](../specs/2026-08-24-zapp-webhook-ingestion-design.md)

**Jira:** [PLAT-1233](https://redventures.atlassian.net/browse/PLAT-1233) §3 and §4, epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184)

## Global Constraints

- **Shadow-mode invariant.** The service must not be able to approve, merge, or enable auto-merge. `checks:write` is the App's only write permission. Never add a code path that writes to pull requests, statuses, or merge queues.
- **Check conclusion is always `neutral`.** `postShadowCheck` takes no conclusion parameter; the value is a module constant. It is the only function in the repo permitted to call `POST /repos/{owner}/{repo}/check-runs`.
- **Check names, exactly:** `merge-policy/eligibility` and `merge-policy/risk`.
- **Never log secrets.** Per `src/log.ts`: repo names, PR numbers, SHAs, delivery IDs and event names are safe. Request headers (they carry the signature), tokens, and the App private key are not. Never log raw PR title or body content.
- **Enrolled repos in this phase:** `bankrate/platform-cicd-v2-demo`, and nothing else.
- **Node 22**, ESM (`"type": "module"`), so all relative imports carry a `.js` extension even from `.ts` sources.
- **Conventional Commits** — `release.yml` runs semantic-release on merge to `main` and derives versions from commit messages.
- **Terraform:** every resource name is prefixed `local.name` (`zapp`). Environment comes from `var.environment`, set by the TFC workspace.
- **Branch:** `feat/plat-1233-webhook-ingestion`, already created, already carrying the spec commits.
- **Execution order is 0, 1, 2, 3, 5, 6, 7, 4, 8, 9, 10** — Task 4 is numbered out of execution order deliberately; see its header.

---

### Task 0: Verify VPC egress before building on it

Both roles run with `create_in_vpc = true`. The worker must reach `api.github.com`; the receiver must reach SQS. If NAT egress is absent, Task 6's Terraform needs an SQS interface endpoint and the whole design needs revisiting. Finding that out now costs minutes; finding it out at deploy time costs a debugging session.

**Files:** none — investigation only.

**Interfaces:**
- Consumes: nothing
- Produces: a documented yes/no on NAT egress, appended to `AGENTS.md` in Task 8

- [ ] **Step 1: Confirm the deployed QA function's VPC configuration**

```bash
AWS_PROFILE=bankrate-qa aws lambda get-function-configuration \
  --function-name zapp-qa --region us-east-1 \
  --query '{subnets:VpcConfig.SubnetIds,sgs:VpcConfig.SecurityGroupIds}'
```

Expected: a non-empty list of subnet IDs.

- [ ] **Step 2: Check whether those subnets route to a NAT gateway**

Substitute the first subnet ID from Step 1:

```bash
AWS_PROFILE=bankrate-qa aws ec2 describe-route-tables --region us-east-1 \
  --filters "Name=association.subnet-id,Values=<SUBNET_ID>" \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[NatGatewayId,GatewayId]' --output text
```

Expected: a `nat-...` id. A `igw-...` id or empty output means no outbound path for a private Lambda.

- [ ] **Step 3: Check for an existing SQS interface endpoint**

```bash
AWS_PROFILE=bankrate-qa aws ec2 describe-vpc-endpoints --region us-east-1 \
  --query 'VpcEndpoints[?contains(ServiceName,`sqs`)].[VpcEndpointId,ServiceName,VpcId]' --output text
```

- [ ] **Step 4: Record the finding and decide**

If Step 2 returned a NAT gateway: proceed, no Terraform change needed. Note the result — it is reused in Task 8.

If Step 2 returned no NAT and Step 3 found no SQS endpoint: **stop and raise it.** Task 6 will need an `aws_vpc_endpoint` for SQS, and the worker's ability to reach `api.github.com` at all is in question — which is a design problem, not a plan problem.

No commit for this task.

---

### Task 1: The delivery claim protocol

The dedupe primitive, built first because everything else depends on it and it has no dependencies of its own.

**Files:**
- Create: `src/deliveries.ts`
- Create: `tests/deliveries.test.ts`
- Modify: `package.json` (add `@aws-sdk/client-dynamodb`)

**Interfaces:**
- Consumes: nothing
- Produces:
  - `claimDelivery(deliveryId: string, send?: DynamoSender): Promise<boolean>` — `true` if claimed, `false` if already present
  - `confirmDelivery(deliveryId: string, send?: DynamoSender): Promise<void>`
  - `releaseDelivery(deliveryId: string, send?: DynamoSender): Promise<void>`
  - `type DynamoSender = (cmd: unknown) => Promise<unknown>`

- [ ] **Step 1: Add the DynamoDB client dependency**

```bash
pnpm add @aws-sdk/client-dynamodb
```

- [ ] **Step 2: Write the failing tests**

Create `tests/deliveries.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { claimDelivery, confirmDelivery, releaseDelivery } from '../src/deliveries.js';

process.env.DELIVERY_IDS_TABLE = 'zapp-delivery-ids-test';

/** A fake DynamoDB `send` that records commands and can be told to reject. */
function fakeSend(reject?: Error) {
  const calls: any[] = [];
  const send = async (cmd: any) => {
    calls.push(cmd);
    if (reject) throw reject;
    return {};
  };
  return { send, calls };
}

/** The shape the AWS SDK throws when a ConditionExpression fails. */
function conditionalFailure(): Error {
  const err = new Error('The conditional request failed');
  err.name = 'ConditionalCheckFailedException';
  return err;
}

test('claiming an unseen delivery id succeeds', async () => {
  const { send, calls } = fakeSend();
  assert.equal(await claimDelivery('d-1', send), true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].input.TableName, 'zapp-delivery-ids-test');
  assert.equal(calls[0].input.Item.deliveryId.S, 'd-1');
  assert.equal(calls[0].input.ConditionExpression, 'attribute_not_exists(deliveryId)');
});

test('a claim sets a short TTL so a killed worker self-heals', async () => {
  const { send, calls } = fakeSend();
  await claimDelivery('d-1', send);
  const expiresAt = Number(calls[0].input.Item.expiresAt.N);
  const now = Math.floor(Date.now() / 1000);
  assert.ok(expiresAt > now, 'TTL is in the future');
  assert.ok(expiresAt <= now + 15 * 60, 'claim TTL is at most 15 minutes');
});

test('claiming an already-claimed delivery id returns false, not a throw', async () => {
  const { send } = fakeSend(conditionalFailure());
  assert.equal(await claimDelivery('d-1', send), false);
});

test('a non-conditional DynamoDB error propagates', async () => {
  const { send } = fakeSend(new Error('ProvisionedThroughputExceededException'));
  await assert.rejects(() => claimDelivery('d-1', send), /ProvisionedThroughputExceeded/);
});

test('confirming extends the TTL well beyond the claim window', async () => {
  const { send, calls } = fakeSend();
  await confirmDelivery('d-1', send);
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = Number(calls[0].input.ExpressionAttributeValues[':expiresAt'].N);
  assert.ok(expiresAt > now + 6 * 24 * 60 * 60, 'confirmed records outlive a manual redelivery');
});

test('releasing deletes the claim so a retry can re-claim', async () => {
  const { send, calls } = fakeSend();
  await releaseDelivery('d-1', send);
  assert.equal(calls[0].input.Key.deliveryId.S, 'd-1');
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/deliveries.js'`

- [ ] **Step 4: Write the implementation**

Create `src/deliveries.ts`:

```ts
// Delivery-ID dedupe: a claim-before-process conditional put on the GitHub
// delivery ID, so a replayed webhook cannot produce a second check run.
//
// The claim is taken BEFORE processing, not after: that ordering is what makes
// two workers racing the same delivery ID safe — exactly one claim succeeds.
// Claiming afterwards would leave a window in which both post.
import {
  DynamoDBClient,
  PutItemCommand,
  UpdateItemCommand,
  DeleteItemCommand,
} from '@aws-sdk/client-dynamodb';

/** Shared DynamoDB client (exported so tests can stub `send`). */
export const client = new DynamoDBClient({});

/** Sends a DynamoDB command. Injectable so tests avoid the network. */
export type DynamoSender = (cmd: unknown) => Promise<unknown>;

const defaultSend: DynamoSender = (cmd) => client.send(cmd as never);

// Short enough that a hard-killed worker's orphaned claim expires and a
// redelivery can re-claim, rather than becoming a permanent tombstone over an
// event that was never actually handled.
const CLAIM_TTL_SECONDS = 15 * 60;

// Long enough to outlive a manual redelivery from the App's Advanced tab,
// which a human may fire days later.
const DONE_TTL_SECONDS = 7 * 24 * 60 * 60;

const nowSeconds = (): number => Math.floor(Date.now() / 1000);

const table = (): string => process.env.DELIVERY_IDS_TABLE!;

/**
 * Claim a GitHub delivery ID for processing.
 *
 * Args:
 *   deliveryId: The `X-GitHub-Delivery` header value.
 *   send: Command sender (defaults to the real client).
 * Returns:
 *   true if this caller owns the delivery; false if it was already claimed,
 *   meaning the caller should drop the message as a duplicate.
 */
export async function claimDelivery(deliveryId: string, send: DynamoSender = defaultSend): Promise<boolean> {
  try {
    await send(new PutItemCommand({
      TableName: table(),
      Item: {
        deliveryId: { S: deliveryId },
        status: { S: 'claimed' },
        expiresAt: { N: String(nowSeconds() + CLAIM_TTL_SECONDS) },
      },
      ConditionExpression: 'attribute_not_exists(deliveryId)',
    }));
    return true;
  } catch (err) {
    // Keyed on the error NAME, not `instanceof`: the name is stable across SDK
    // versions and is reproducible in a fake sender, where constructing the
    // real exception class is not.
    if (err instanceof Error && err.name === 'ConditionalCheckFailedException') return false;
    throw err;
  }
}

/**
 * Mark a claimed delivery as fully processed and extend its TTL, so a later
 * redelivery of the same ID is recognised as a duplicate.
 */
export async function confirmDelivery(deliveryId: string, send: DynamoSender = defaultSend): Promise<void> {
  await send(new UpdateItemCommand({
    TableName: table(),
    Key: { deliveryId: { S: deliveryId } },
    UpdateExpression: 'SET expiresAt = :expiresAt, #status = :status',
    ExpressionAttributeNames: { '#status': 'status' },
    ExpressionAttributeValues: {
      ':expiresAt': { N: String(nowSeconds() + DONE_TTL_SECONDS) },
      ':status': { S: 'done' },
    },
  }));
}

/**
 * Drop a claim after a failed attempt, so the SQS redelivery can re-claim and
 * retry immediately rather than being mistaken for a duplicate.
 */
export async function releaseDelivery(deliveryId: string, send: DynamoSender = defaultSend): Promise<void> {
  await send(new DeleteItemCommand({
    TableName: table(),
    Key: { deliveryId: { S: deliveryId } },
  }));
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 6 tests in `tests/deliveries.test.ts`

- [ ] **Step 6: Typecheck**

Run: `pnpm run typecheck`
Expected: no output

- [ ] **Step 7: Commit**

```bash
git add src/deliveries.ts tests/deliveries.test.ts package.json pnpm-lock.yaml
git commit -m "feat: claim-before-process dedupe on the GitHub delivery id (PLAT-1233)"
```

---

### Task 2: Enqueue deliveries to SQS

**Files:**
- Create: `src/queue.ts`
- Create: `tests/queue.test.ts`
- Modify: `package.json` (add `@aws-sdk/client-sqs`)

**Interfaces:**
- Consumes: nothing
- Produces:
  - `enqueueDelivery(delivery: Delivery, send?: SqsSender): Promise<void>`
  - `interface Delivery { event: string; deliveryId: string; body: string }`
  - `type SqsSender = (cmd: unknown) => Promise<unknown>`

- [ ] **Step 1: Add the SQS client dependency**

```bash
pnpm add @aws-sdk/client-sqs
```

- [ ] **Step 2: Write the failing test**

Create `tests/queue.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { enqueueDelivery } from '../src/queue.js';

process.env.DELIVERY_QUEUE_URL = 'https://sqs.us-east-1.amazonaws.com/000/zapp-deliveries';

function fakeSend() {
  const calls: any[] = [];
  return { calls, send: async (cmd: any) => { calls.push(cmd); return {}; } };
}

test('enqueues the raw body verbatim, so the worker parses exactly what was signed', async () => {
  const { send, calls } = fakeSend();
  const body = '{"action":"opened"}';
  await enqueueDelivery({ event: 'pull_request', deliveryId: 'd-1', body }, send);
  assert.equal(calls[0].input.MessageBody, body);
  assert.equal(calls[0].input.QueueUrl, process.env.DELIVERY_QUEUE_URL);
});

test('carries the event type and delivery id as message attributes', async () => {
  const { send, calls } = fakeSend();
  await enqueueDelivery({ event: 'pull_request', deliveryId: 'd-42', body: '{}' }, send);
  const attrs = calls[0].input.MessageAttributes;
  assert.equal(attrs.githubEvent.StringValue, 'pull_request');
  assert.equal(attrs.deliveryId.StringValue, 'd-42');
});

test('a send failure propagates, so the receiver can 500 and let GitHub retry', async () => {
  const send = async () => { throw new Error('AWS.SimpleQueueService.NonExistentQueue'); };
  await assert.rejects(
    () => enqueueDelivery({ event: 'pull_request', deliveryId: 'd-1', body: '{}' }, send),
    /NonExistentQueue/,
  );
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/queue.js'`

- [ ] **Step 4: Write the implementation**

Create `src/queue.ts`:

```ts
// Hands a verified webhook delivery to the worker role via SQS.
//
// The raw body is enqueued verbatim — the receiver never parses it. The worker
// then parses exactly the bytes the signature was computed over, so there is no
// way for a re-serialisation to diverge from what GitHub signed.
import { SQSClient, SendMessageCommand } from '@aws-sdk/client-sqs';

/** Shared SQS client (exported so tests can stub `send`). */
export const client = new SQSClient({});

/** Sends an SQS command. Injectable so tests avoid the network. */
export type SqsSender = (cmd: unknown) => Promise<unknown>;

const defaultSend: SqsSender = (cmd) => client.send(cmd as never);

/** A verified webhook delivery, ready to hand to the worker. */
export interface Delivery {
  /** The `X-GitHub-Event` header value. */
  event: string;
  /** The `X-GitHub-Delivery` header value — the dedupe key. */
  deliveryId: string;
  /** The raw request body, exactly as signed. */
  body: string;
}

/**
 * Enqueue a verified delivery.
 *
 * Args:
 *   delivery: The event type, delivery id, and raw body.
 *   send: Command sender (defaults to the real client).
 * Raises:
 *   Error: When the SQS write fails — the caller turns this into a 500 so
 *     GitHub, which owns delivery retries, retries.
 */
export async function enqueueDelivery(delivery: Delivery, send: SqsSender = defaultSend): Promise<void> {
  await send(new SendMessageCommand({
    QueueUrl: process.env.DELIVERY_QUEUE_URL!,
    MessageBody: delivery.body,
    MessageAttributes: {
      githubEvent: { DataType: 'String', StringValue: delivery.event },
      deliveryId: { DataType: 'String', StringValue: delivery.deliveryId },
    },
  }));
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/queue.ts tests/queue.test.ts package.json pnpm-lock.yaml
git commit -m "feat: enqueue verified deliveries to SQS (PLAT-1233)"
```

---

### Task 3: The receiver role

Moves the existing handler logic out of `src/index.ts` into `src/receiver.ts`, fixes the latent base64 body bug, and enqueues instead of acking.

**Files:**
- Create: `src/receiver.ts`
- Create: `tests/receiver.test.ts`
- Delete: `tests/handler.test.ts` (its assertions move into `tests/receiver.test.ts`)

**Interfaces:**
- Consumes: `getWebhookConfig` from `src/secrets.ts`, `isValidSignature` from `src/signature.ts`, `log` from `src/log.ts`, `enqueueDelivery` from Task 2
- Produces:
  - `createReceiver(deps: ReceiverDeps): (event: APIGatewayProxyEventV2) => Promise<APIGatewayProxyResultV2>`
  - `interface ReceiverDeps { getWebhookConfig: typeof getWebhookConfig; enqueueDelivery: typeof enqueueDelivery }`

- [ ] **Step 1: Write the failing tests**

Create `tests/receiver.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import type { APIGatewayProxyEventV2 } from 'aws-lambda';
import { createReceiver } from '../src/receiver.js';

const SECRET = 'wh-secret';
const sign = (body: string): string => 'sha256=' + createHmac('sha256', SECRET).update(body).digest('hex');

function event({
  body, sig, ghEvent = 'pull_request', delivery = 'd-1', isBase64Encoded = false,
}: {
  body: string; sig?: string; ghEvent?: string; delivery?: string; isBase64Encoded?: boolean;
}): APIGatewayProxyEventV2 {
  return {
    body,
    isBase64Encoded,
    headers: {
      'x-hub-signature-256': sig ?? sign(body),
      'x-github-event': ghEvent,
      'x-github-delivery': delivery,
    },
  } as unknown as APIGatewayProxyEventV2;
}

function harness() {
  const enqueued: any[] = [];
  const receiver = createReceiver({
    getWebhookConfig: async () => ({ secret: SECRET }),
    enqueueDelivery: async (d: any) => { enqueued.push(d); },
  });
  return { receiver, enqueued };
}

test('rejects a bad signature with 401 and enqueues nothing', async () => {
  const { receiver, enqueued } = harness();
  const res = await receiver(event({ body: '{}', sig: 'sha256=bad' }));
  assert.equal(res.statusCode, 401);
  assert.equal(enqueued.length, 0);
});

test('rejects a missing signature with 401', async () => {
  const { receiver, enqueued } = harness();
  const res = await receiver(event({ body: '{}', sig: '' }));
  assert.equal(res.statusCode, 401);
  assert.equal(enqueued.length, 0);
});

test('enqueues a validly signed delivery and returns 202', async () => {
  const { receiver, enqueued } = harness();
  const body = JSON.stringify({ action: 'opened' });
  const res = await receiver(event({ body }));
  assert.equal(res.statusCode, 202);
  assert.equal(enqueued.length, 1);
  assert.deepEqual(enqueued[0], { event: 'pull_request', deliveryId: 'd-1', body });
});

test('enqueues every event type — the worker owns routing, not the receiver', async () => {
  const { receiver, enqueued } = harness();
  const body = JSON.stringify({ zen: 'test' });
  const res = await receiver(event({ body, ghEvent: 'ping' }));
  assert.equal(res.statusCode, 202);
  assert.equal(enqueued[0].event, 'ping');
});

test('verifies a base64-encoded body against its decoded bytes', async () => {
  const { receiver, enqueued } = harness();
  const body = JSON.stringify({ action: 'opened' });
  const encoded = Buffer.from(body, 'utf8').toString('base64');
  const res = await receiver(event({ body: encoded, sig: sign(body), isBase64Encoded: true }));
  assert.equal(res.statusCode, 202);
  assert.equal(enqueued[0].body, body, 'the decoded body is what gets enqueued');
});

test('rejects a delivery with no delivery id — there would be no dedupe key', async () => {
  const { receiver, enqueued } = harness();
  const body = '{}';
  const ev = {
    body, isBase64Encoded: false,
    headers: { 'x-hub-signature-256': sign(body), 'x-github-event': 'pull_request' },
  } as unknown as APIGatewayProxyEventV2;
  const res = await receiver(ev);
  assert.equal(res.statusCode, 400);
  assert.equal(enqueued.length, 0);
});

test('an empty body is signed as empty and still enqueued', async () => {
  const { receiver, enqueued } = harness();
  const ev = {
    isBase64Encoded: false,
    headers: { 'x-hub-signature-256': sign(''), 'x-github-event': 'ping', 'x-github-delivery': 'd-9' },
  } as unknown as APIGatewayProxyEventV2;
  const res = await receiver(ev);
  assert.equal(res.statusCode, 202);
  assert.equal(enqueued[0].body, '');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/receiver.js'`

- [ ] **Step 3: Write the implementation**

Create `src/receiver.ts`:

```ts
// Receiver role: the public Function URL path. Verifies the webhook HMAC and
// hands the raw body to the worker via SQS. Nothing else.
//
// It deliberately does not parse the payload, call GitHub, or touch DynamoDB:
// the Function URL is public and unauthenticated, so everything reachable
// before the signature check is attack surface.
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import { getWebhookConfig } from './secrets.js';
import { enqueueDelivery } from './queue.js';
import { isValidSignature } from './signature.js';
import { log } from './log.js';

/** Injectable collaborators for the receiver (real implementations by default). */
export interface ReceiverDeps {
  getWebhookConfig: typeof getWebhookConfig;
  enqueueDelivery: typeof enqueueDelivery;
}

/**
 * Build the Function URL handler bound to the given collaborators.
 *
 * Returns 401 on a bad signature, 400 on a delivery with no ID (there would be
 * no dedupe key), and 202 once the delivery is safely queued. A queue failure
 * propagates as a 500 so GitHub — which owns delivery retries — retries.
 */
export function createReceiver(deps: ReceiverDeps) {
  return async (event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> => {
    // Decode before verifying: the HMAC is computed over the decoded bytes, so
    // verifying the base64 text would fail as a misleading "bad signature".
    // Function URLs don't base64-encode application/json today, which makes
    // this latent rather than live — but it is one branch and it removes a
    // genuinely confusing future failure mode.
    const body = event.isBase64Encoded && event.body
      ? Buffer.from(event.body, 'base64').toString('utf8')
      : event.body ?? '';

    const { secret } = await deps.getWebhookConfig();
    if (!isValidSignature(secret, body, event.headers['x-hub-signature-256'])) {
      // This exact msg value is what the `InvalidSignature` CloudWatch log
      // metric filter matches on (see infrastructure/terraform/alarms.tf) —
      // renaming it silently breaks the alarm.
      log('warn', 'invalid_signature');
      return { statusCode: 401 };
    }

    const ghEvent = event.headers['x-github-event'] ?? 'unknown';
    const deliveryId = event.headers['x-github-delivery'] ?? '';
    if (!deliveryId) {
      log('warn', 'missing_delivery_id', { event: ghEvent });
      return { statusCode: 400 };
    }

    await deps.enqueueDelivery({ event: ghEvent, deliveryId, body });
    log('info', 'webhook_enqueued', { event: ghEvent, delivery: deliveryId });

    return {
      statusCode: 202,
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ ok: true }),
    };
  };
}
```

- [ ] **Step 4: Delete the superseded test file**

```bash
git rm tests/handler.test.ts
```

Its assertions now live in `tests/receiver.test.ts`, extended for the enqueue and base64 paths.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS, clean typecheck. `src/index.ts` is untouched and still exports its own self-contained `createHandler` — nothing imports `receiver.ts` yet, so the old entrypoint keeps working until Task 4 replaces it.

- [ ] **Step 6: Commit**

```bash
git add src/receiver.ts tests/receiver.test.ts tests/handler.test.ts
git commit -m "feat: receiver verifies and enqueues instead of acking (PLAT-1233)"
```

---

### Task 4: Entrypoint dispatch

One Lambda serves both roles because `deploy-v2.yml`'s `lambda-deploy` only ever updates one function name. This is the router that makes that work.

**Files:**
- Modify: `src/index.ts` (full rewrite — it is 50 lines)
- Create: `tests/index.test.ts`

**Interfaces:**
- Consumes: `createReceiver` from Task 3; `createWorker` from Task 7
- Produces: `handler(event: ZappEvent): Promise<APIGatewayProxyResultV2 | void>`

> **EXECUTE THIS TASK AFTER TASK 7, NOT IN NUMERIC ORDER.** It wires up `createWorker`, which Task 7 creates, so its tests cannot pass before then. It is numbered here because the dispatch decision belongs with the receiver work conceptually, and a reader following the receiver's story should meet it at this point. Execution order is: 0, 1, 2, 3, 5, 6, 7, **4**, 8, 9, 10.

- [ ] **Step 1: Write the failing test**

Create `tests/index.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isSqsEvent } from '../src/index.js';

test('an event carrying a Records array is an SQS batch', () => {
  assert.equal(isSqsEvent({ Records: [{ messageId: 'm-1' }] } as any), true);
});

test('a Function URL request is not an SQS batch', () => {
  assert.equal(isSqsEvent({ requestContext: {}, headers: {}, body: '{}' } as any), false);
});

test('an empty Records array is still an SQS batch, not a Function URL request', () => {
  assert.equal(isSqsEvent({ Records: [] } as any), true);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `isSqsEvent` is not exported

- [ ] **Step 3: Rewrite `src/index.ts`**

```ts
// Lambda entrypoint. One function serves two roles, dispatched on event shape.
//
// Why one function rather than a receiver and a worker: deploy-v2.yml's
// lambda-deploy call hard-codes `function-name: <app-name>-<env>` and runs once
// per environment, so a second Terraform-created function would never receive
// code — it would sit on the :bootstrap image forever. See
// docs/superpowers/specs/2026-08-24-zapp-webhook-ingestion-design.md.
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2, SQSEvent } from 'aws-lambda';
import { getWebhookConfig } from './secrets.js';
import { enqueueDelivery } from './queue.js';
import { claimDelivery, confirmDelivery, releaseDelivery } from './deliveries.js';
import { postShadowCheck } from './checks.js';
import { isEnrolled } from './enrollment.js';
import { createReceiver } from './receiver.js';
import { createWorker } from './worker.js';

/** Either role's input: an SQS batch, or a Function URL request. */
export type ZappEvent = APIGatewayProxyEventV2 | SQSEvent;

/**
 * Distinguish the two roles' events.
 *
 * `Records` is the discriminator: SQS batches always carry one, and a Function
 * URL request never does. Checked with `Array.isArray` rather than a truthiness
 * test so an empty batch still routes to the worker.
 */
export function isSqsEvent(event: ZappEvent): event is SQSEvent {
  return Array.isArray((event as SQSEvent).Records);
}

const receiver = createReceiver({ getWebhookConfig, enqueueDelivery });

const worker = createWorker({
  claimDelivery,
  confirmDelivery,
  releaseDelivery,
  postShadowCheck,
  isEnrolled,
});

/** Production Lambda handler, wired to the real collaborators. */
export const handler = async (event: ZappEvent): Promise<APIGatewayProxyResultV2 | void> => {
  if (isSqsEvent(event)) return worker(event);
  return receiver(event);
};
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS — the whole suite, since Tasks 5–7 are already done by the time this task runs.

- [ ] **Step 5: Commit**

```bash
git add src/index.ts tests/index.test.ts
git commit -m "feat: dispatch receiver and worker roles on event shape (PLAT-1233)"
```

---

### Task 5: GitHub App authentication

Ported from `github-pr-jira-check/src/github.ts`, which does exactly this against the same org. `src/secrets.ts` already exposes `getGitHubConfig`; it is currently unused.

**Files:**
- Create: `src/github.ts`
- Create: `tests/github.test.ts`

**Interfaces:**
- Consumes: `getGitHubConfig` from `src/secrets.ts`
- Produces:
  - `githubRequest(path: string, options?: RequestInit, deps?: GithubDeps): Promise<Response>`
  - `getInstallationToken(deps?: GithubDeps): Promise<string>`
  - `interface GithubDeps { getConfig: typeof getGitHubConfig; fetchImpl: typeof fetch }`
  - `resetTokenCache(): void` — test-only

- [ ] **Step 1: Write the failing test**

Create `tests/github.test.ts`:

```ts
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { getInstallationToken, githubRequest, resetTokenCache } from '../src/github.js';

const { privateKey } = generateKeyPairSync('rsa', {
  modulusLength: 2048,
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});

const config = {
  app_id: '12345',
  private_key: privateKey as string,
  installation_id: '156198964',
};

function fakeFetch(responses: any[]) {
  const calls: any[] = [];
  const fetchImpl = async (url: any, init: any) => {
    calls.push({ url, init });
    return responses.shift();
  };
  return { calls, fetchImpl: fetchImpl as unknown as typeof fetch };
}

const tokenResponse = (token: string, expiresInMs = 3_600_000) => ({
  ok: true,
  status: 201,
  json: async () => ({ token, expires_at: new Date(Date.now() + expiresInMs).toISOString() }),
});

beforeEach(() => resetTokenCache());

test('exchanges a signed JWT for an installation token', async () => {
  const { calls, fetchImpl } = fakeFetch([tokenResponse('ghs_abc')]);
  const token = await getInstallationToken({ getConfig: async () => config, fetchImpl });
  assert.equal(token, 'ghs_abc');
  assert.match(calls[0].url, /\/app\/installations\/156198964\/access_tokens$/);
  assert.match(calls[0].init.headers.Authorization, /^Bearer eyJ/);
});

test('reuses a cached token rather than minting one per request', async () => {
  const { calls, fetchImpl } = fakeFetch([tokenResponse('ghs_abc')]);
  const deps = { getConfig: async () => config, fetchImpl };
  await getInstallationToken(deps);
  await getInstallationToken(deps);
  assert.equal(calls.length, 1, 'the second call is served from cache');
});

test('a failed token exchange throws rather than returning an unusable token', async () => {
  const { fetchImpl } = fakeFetch([{ ok: false, status: 401, text: async () => 'Bad credentials' }]);
  await assert.rejects(
    () => getInstallationToken({ getConfig: async () => config, fetchImpl }),
    /Failed to get installation token: 401/,
  );
});

test('githubRequest injects auth, versioning, and the API host', async () => {
  const { calls, fetchImpl } = fakeFetch([tokenResponse('ghs_abc'), { ok: true, status: 201 }]);
  await githubRequest('/repos/bankrate/platform-cicd-v2-demo/check-runs',
    { method: 'POST', body: '{}' },
    { getConfig: async () => config, fetchImpl });
  const req = calls[1];
  assert.equal(req.url, 'https://api.github.com/repos/bankrate/platform-cicd-v2-demo/check-runs');
  assert.equal(req.init.headers.Authorization, 'Bearer ghs_abc');
  assert.equal(req.init.headers['X-GitHub-Api-Version'], '2022-11-28');
  assert.equal(req.init.method, 'POST');
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/github.js'`

- [ ] **Step 3: Port the implementation**

Copy `src/github.ts` verbatim from `github-pr-jira-check`, changing only the import of `getGitHubConfig` to `./secrets.js` (same path — no change needed in practice) and dropping the `/* c8 ignore */` pragmas, which are artifacts of that repo's coverage setup and are not used here.

The source is at `/Users/scrosby/Projects/github/github-pr-jira-check/src/github.ts`. It provides `GithubDeps`, `resetTokenCache`, `signJwt` (module-private), `getInstallationToken`, and `githubRequest`, with a module-scope token cache refreshed 60 s before expiry.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/github.ts tests/github.test.ts
git commit -m "feat: GitHub App installation-token auth (PLAT-1233)"
```

---

### Task 6: Check runs and the neutral invariant

The user-visible half of §4, and the one place the shadow-mode invariant is enforced structurally.

**Files:**
- Create: `src/checks.ts`
- Create: `src/evaluate.ts`
- Create: `src/enrollment.ts`
- Create: `tests/checks.test.ts`
- Create: `tests/enrollment.test.ts`

**Interfaces:**
- Consumes: `githubRequest` from Task 5
- Produces:
  - `postShadowCheck(repoFullName: string, headSha: string, name: string, output: CheckOutput, request?: typeof githubRequest): Promise<void>`
  - `interface CheckOutput { title: string; summary: string }`
  - `evaluate(): ShadowVerdict[]`
  - `interface ShadowVerdict { name: string; output: CheckOutput }`
  - `ELIGIBILITY_CHECK = 'merge-policy/eligibility'`, `RISK_CHECK = 'merge-policy/risk'`
  - `isEnrolled(repoFullName: string, allowlist?: string): boolean`

- [ ] **Step 1: Write the failing tests**

Create `tests/checks.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { postShadowCheck } from '../src/checks.js';
import { evaluate, ELIGIBILITY_CHECK, RISK_CHECK } from '../src/evaluate.js';

function fakeRequest(response: any = { ok: true, status: 201 }) {
  const calls: any[] = [];
  const request = async (path: string, options: any) => {
    calls.push({ path, body: JSON.parse(options.body), method: options.method });
    return response;
  };
  return { calls, request: request as any };
}

test('posts a check run against the PR head sha', async () => {
  const { request, calls } = fakeRequest();
  await postShadowCheck('bankrate/platform-cicd-v2-demo', 'f00d42', ELIGIBILITY_CHECK,
    { title: 't', summary: 's' }, request);
  assert.equal(calls[0].path, '/repos/bankrate/platform-cicd-v2-demo/check-runs');
  assert.equal(calls[0].method, 'POST');
  assert.equal(calls[0].body.head_sha, 'f00d42');
  assert.equal(calls[0].body.name, ELIGIBILITY_CHECK);
});

test('the conclusion is neutral for every verdict the evaluator can produce', async () => {
  const { request, calls } = fakeRequest();
  for (const verdict of evaluate()) {
    await postShadowCheck('bankrate/platform-cicd-v2-demo', 'f00d42', verdict.name, verdict.output, request);
  }
  assert.ok(calls.length > 0, 'the evaluator produced at least one verdict');
  for (const call of calls) {
    assert.equal(call.body.conclusion, 'neutral');
    assert.equal(call.body.status, 'completed');
  }
});

test('postShadowCheck exposes no way to ask for a non-neutral conclusion', () => {
  // The invariant is structural, not defensive: there is no conclusion
  // parameter to pass. Arity is (repo, headSha, name, output, request?).
  assert.equal(postShadowCheck.length, 4, 'four required params, none of them a conclusion');
});

test('a failed post throws, so the worker releases its claim and SQS retries', async () => {
  const { request } = fakeRequest({ ok: false, status: 422, text: async () => 'No commit found for SHA' });
  await assert.rejects(
    () => postShadowCheck('bankrate/platform-cicd-v2-demo', 'bad', RISK_CHECK, { title: 't', summary: 's' }, request),
    /check-run POST failed .*422/,
  );
});

test('the evaluator produces exactly the two named checks', () => {
  const names = evaluate().map(v => v.name);
  assert.deepEqual(names, ['merge-policy/eligibility', 'merge-policy/risk']);
});

test('each rationale states plainly that it never blocks', () => {
  for (const verdict of evaluate()) {
    assert.match(verdict.output.summary, /never block/i);
    assert.match(verdict.output.summary, /not required/i);
    assert.match(verdict.output.summary, /PLAT-1184/);
    assert.ok(verdict.output.title.length > 0);
  }
});
```

Create `tests/enrollment.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isEnrolled } from '../src/enrollment.js';

test('an enrolled repo passes the gate', () => {
  assert.equal(isEnrolled('bankrate/platform-cicd-v2-demo', 'bankrate/platform-cicd-v2-demo'), true);
});

test('a repo not on the list is rejected', () => {
  assert.equal(isEnrolled('bankrate/brcc-api', 'bankrate/platform-cicd-v2-demo'), false);
});

test('an empty allowlist enrols nothing — fail closed', () => {
  assert.equal(isEnrolled('bankrate/platform-cicd-v2-demo', ''), false);
});

test('whitespace and empty entries are tolerated', () => {
  assert.equal(isEnrolled('bankrate/b', ' bankrate/a , bankrate/b ,,'), true);
});

test('matching is exact — no prefix or substring match', () => {
  assert.equal(isEnrolled('bankrate/platform-cicd-v2-demo-fork', 'bankrate/platform-cicd-v2-demo'), false);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — missing modules

- [ ] **Step 3: Write `src/checks.ts`**

```ts
// Posts the shadow-mode check runs.
//
// SHADOW-MODE INVARIANT: this is the only code path in the repo permitted to
// call POST /repos/{owner}/{repo}/check-runs, and it takes no conclusion
// parameter — the value is the constant below. There is no argument a future
// caller can pass to make a shadow check non-neutral. Phase 0's whole premise
// is that this service observes and never blocks; keep it structural.
import { githubRequest } from './github.js';

const SHADOW_CONCLUSION = 'neutral';

/** The rendered body of a check run, as GitHub's `output` object. */
export interface CheckOutput {
  title: string;
  summary: string;
}

/**
 * Post a completed, neutral check run against a pull request's head commit.
 *
 * Args:
 *   repoFullName: `owner/repo`.
 *   headSha: The PR head SHA the check is pinned to.
 *   name: The check run name (see `evaluate.ts` for the two permitted values).
 *   output: The check's title and markdown summary.
 *   request: Injectable GitHub request client.
 * Raises:
 *   Error: On a non-2xx response, so the worker releases its delivery claim
 *     and SQS retries.
 */
export async function postShadowCheck(
  repoFullName: string,
  headSha: string,
  name: string,
  output: CheckOutput,
  request: typeof githubRequest = githubRequest,
): Promise<void> {
  const res = await request(`/repos/${repoFullName}/check-runs`, {
    method: 'POST',
    body: JSON.stringify({
      name,
      head_sha: headSha,
      status: 'completed',
      conclusion: SHADOW_CONCLUSION,
      completed_at: new Date().toISOString(),
      output,
    }),
  });

  if (!res.ok) {
    throw new Error(`check-run POST failed for ${name}: ${res.status} ${await res.text()}`);
  }
}
```

- [ ] **Step 4: Write `src/evaluate.ts`**

```ts
// The shadow evaluator.
//
// PLACEHOLDER BY DESIGN: the real decision logic is PLAT-1184 T6 (eligibility
// gates), T7 (risk heuristics) and T8 (required-checks snapshot), none of which
// are in PLAT-1233's scope. Those tickets replace this function's body; the
// call site in worker.ts and the shape below stay put.
//
// The text is written for someone who has never heard of this project and has
// just clicked a check on their PR. It says what the check is, that it cannot
// block them, and that nothing is required of them — a complete answer, even
// though the verdict is absent.
import type { CheckOutput } from './checks.js';

export const ELIGIBILITY_CHECK = 'merge-policy/eligibility';
export const RISK_CHECK = 'merge-policy/risk';

const SHADOW_TITLE = 'Shadow mode — no verdict yet';

/** One check run's name and rendered body. */
export interface ShadowVerdict {
  name: string;
  output: CheckOutput;
}

function shadowSummary(checkName: string): string {
  return [
    `This informational check (\`${checkName}\`) is posted by the merge-policy service.`,
    'It is **not required** and **will never block your pull request**.',
    '',
    'The service is running in shadow mode: it observes pull requests and records what an',
    'automated merge policy *would* have decided, without acting on it. The decision logic is',
    'not connected yet, so there is no verdict to report for this pull request.',
    '',
    'Nothing is needed from you. Tracking: [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184).',
  ].join('\n');
}

/**
 * Produce the shadow verdicts for a pull request.
 *
 * Takes no arguments today because the placeholder verdict does not depend on
 * the PR. T6/T7 give it the PR payload, diff, enrollment record and rules.
 */
export function evaluate(): ShadowVerdict[] {
  return [ELIGIBILITY_CHECK, RISK_CHECK].map((name) => ({
    name,
    output: { title: SHADOW_TITLE, summary: shadowSummary(name) },
  }));
}
```

- [ ] **Step 5: Write `src/enrollment.ts`**

```ts
// Which repos this service is allowed to evaluate.
//
// STAND-IN for PLAT-1184 T4 (the DynamoDB enrollment registry fed by a reviewed
// config file), which is not in PLAT-1233's scope. T4 replaces this function's
// body; every caller goes through `isEnrolled`, so the call sites do not move.
//
// This is defence in depth, not the primary control — the App installation is
// already narrowed to selected repositories. It matters because installation
// scope is changed by hand in a web UI, where this list is changed in a
// reviewed commit.

/**
 * Is this repository enrolled in shadow evaluation?
 *
 * Fails closed: an unset or empty allowlist enrols nothing. Matching is exact,
 * so `owner/repo-fork` never inherits `owner/repo`'s enrollment.
 *
 * Args:
 *   repoFullName: `owner/repo` from the webhook payload.
 *   allowlist: Comma-separated `owner/repo` entries (defaults to `ENROLLED_REPOS`).
 */
export function isEnrolled(
  repoFullName: string,
  allowlist: string = process.env.ENROLLED_REPOS ?? '',
): boolean {
  return allowlist
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .includes(repoFullName);
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/checks.ts src/evaluate.ts src/enrollment.ts tests/checks.test.ts tests/enrollment.test.ts
git commit -m "feat: neutral shadow check runs with a stub evaluator (PLAT-1233)"
```

---

### Task 7: The worker role

Ties it together: claim, route, gate on enrollment, evaluate, post, settle.

**Files:**
- Create: `src/worker.ts`
- Create: `tests/worker.test.ts`

**Interfaces:**
- Consumes: `claimDelivery`/`confirmDelivery`/`releaseDelivery` (Task 1), `postShadowCheck` (Task 6), `isEnrolled` (Task 6), `evaluate` (Task 6), `log`
- Produces:
  - `createWorker(deps: WorkerDeps): (event: SQSEvent) => Promise<void>`
  - `interface WorkerDeps { claimDelivery; confirmDelivery; releaseDelivery; postShadowCheck; isEnrolled }`

- [ ] **Step 1: Write the failing tests**

Create `tests/worker.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { SQSEvent } from 'aws-lambda';
import { createWorker } from '../src/worker.js';

const DEMO = 'bankrate/platform-cicd-v2-demo';

function prPayload({ action = 'opened', repo = DEMO, sha = 'f00d42' } = {}) {
  return JSON.stringify({
    action,
    pull_request: { number: 7, head: { sha } },
    repository: { full_name: repo },
  });
}

function sqsEvent(body: string, { event = 'pull_request', deliveryId = 'd-1' } = {}): SQSEvent {
  return {
    Records: [{
      messageId: 'm-1',
      body,
      messageAttributes: {
        githubEvent: { stringValue: event, dataType: 'String' },
        deliveryId: { stringValue: deliveryId, dataType: 'String' },
      },
    }],
  } as unknown as SQSEvent;
}

function harness({ claimed = true, enrolled = true, postFails = false } = {}) {
  const state = { claims: [] as string[], confirms: [] as string[], releases: [] as string[], posts: [] as any[] };
  const worker = createWorker({
    claimDelivery: async (id: string) => { state.claims.push(id); return claimed; },
    confirmDelivery: async (id: string) => { state.confirms.push(id); },
    releaseDelivery: async (id: string) => { state.releases.push(id); },
    isEnrolled: () => enrolled,
    postShadowCheck: async (repo: string, sha: string, name: string) => {
      if (postFails) throw new Error('check-run POST failed for ' + name + ': 500 ');
      state.posts.push({ repo, sha, name });
    },
  } as any);
  return { worker, state };
}

test('posts both check runs for an enrolled pull_request and confirms the claim', async () => {
  const { worker, state } = harness();
  await worker(sqsEvent(prPayload()));
  assert.deepEqual(state.posts.map(p => p.name), ['merge-policy/eligibility', 'merge-policy/risk']);
  assert.deepEqual(state.posts.map(p => p.sha), ['f00d42', 'f00d42']);
  assert.deepEqual(state.confirms, ['d-1']);
  assert.deepEqual(state.releases, []);
});

test('a duplicate delivery posts nothing and is not reprocessed', async () => {
  const { worker, state } = harness({ claimed: false });
  await worker(sqsEvent(prPayload()));
  assert.deepEqual(state.posts, []);
  assert.deepEqual(state.confirms, []);
  assert.deepEqual(state.releases, []);
});

test('a non-enrolled repo posts nothing but still settles the claim', async () => {
  const { worker, state } = harness({ enrolled: false });
  await worker(sqsEvent(prPayload({ repo: 'bankrate/brcc-api' })));
  assert.deepEqual(state.posts, []);
  assert.deepEqual(state.confirms, ['d-1'], 'a drop is a success, not a failure');
});

test('an unrouted event type posts nothing and is not a failure', async () => {
  const { worker, state } = harness();
  await worker(sqsEvent(JSON.stringify({ zen: 'x' }), { event: 'check_run' }));
  assert.deepEqual(state.posts, []);
  assert.deepEqual(state.confirms, ['d-1']);
});

test('an uninteresting pull_request action posts nothing', async () => {
  const { worker, state } = harness();
  await worker(sqsEvent(prPayload({ action: 'labeled' })));
  assert.deepEqual(state.posts, []);
  assert.deepEqual(state.confirms, ['d-1']);
});

test('each routed action posts checks', async () => {
  for (const action of ['opened', 'synchronize', 'reopened', 'edited']) {
    const { worker, state } = harness();
    await worker(sqsEvent(prPayload({ action })));
    assert.equal(state.posts.length, 2, `action ${action} should post two checks`);
  }
});

test('malformed JSON releases the claim and rethrows so the message reaches the DLQ', async () => {
  const { worker, state } = harness();
  await assert.rejects(() => worker(sqsEvent('not json at all')));
  assert.deepEqual(state.releases, ['d-1']);
  assert.deepEqual(state.confirms, []);
});

test('a payload missing head.sha releases the claim and rethrows', async () => {
  const { worker, state } = harness();
  const body = JSON.stringify({ action: 'opened', repository: { full_name: DEMO }, pull_request: {} });
  await assert.rejects(() => worker(sqsEvent(body)), /malformed pull_request payload/);
  assert.deepEqual(state.releases, ['d-1']);
});

test('a GitHub API failure releases the claim so the retry can re-claim', async () => {
  const { worker, state } = harness({ postFails: true });
  await assert.rejects(() => worker(sqsEvent(prPayload())));
  assert.deepEqual(state.releases, ['d-1']);
  assert.deepEqual(state.confirms, []);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/worker.js'`

- [ ] **Step 3: Write the implementation**

Create `src/worker.ts`:

```ts
// Worker role: the SQS-triggered path. Claims the delivery, routes it,
// evaluates, and posts the shadow check runs.
//
// Every side effect in this service lives here. The receiver only verifies and
// enqueues.
import type { SQSEvent } from 'aws-lambda';
import { claimDelivery, confirmDelivery, releaseDelivery } from './deliveries.js';
import { postShadowCheck } from './checks.js';
import { isEnrolled } from './enrollment.js';
import { evaluate } from './evaluate.js';
import { log } from './log.js';

// `edited` is included because a title or body edit can change eligibility once
// the real gates land (ticket linkage, conventional title). `labeled`,
// `assigned` and friends cannot, so they are dropped.
const PR_ACTIONS = new Set(['opened', 'synchronize', 'reopened', 'edited']);

// Subscribed on the GitHub App because PLAT-1184 T8 (the required-checks
// snapshot) needs them, but deliberately not routed in this scope. Named
// explicitly so the log distinguishes "not routed yet" from "unknown event".
const KNOWN_UNROUTED = new Set(['check_run', 'check_suite', 'status', 'push', 'merge_group', 'merge_queue_entry']);

/** Injectable collaborators for the worker (real implementations by default). */
export interface WorkerDeps {
  claimDelivery: typeof claimDelivery;
  confirmDelivery: typeof confirmDelivery;
  releaseDelivery: typeof releaseDelivery;
  postShadowCheck: typeof postShadowCheck;
  isEnrolled: typeof isEnrolled;
}

/**
 * Route one delivery and post its check runs.
 *
 * Returning without posting is a success, not a failure: an unrouted event, an
 * uninteresting action, and a non-enrolled repo are all normal outcomes that
 * should settle the claim rather than burn an SQS retry.
 *
 * Raises:
 *   Error: On a malformed payload or a failed GitHub call — the caller
 *     releases the claim and rethrows so the message eventually reaches the DLQ.
 */
async function handleDelivery(
  deps: WorkerDeps,
  ghEvent: string,
  deliveryId: string,
  rawBody: string,
): Promise<void> {
  if (ghEvent !== 'pull_request') {
    const known = KNOWN_UNROUTED.has(ghEvent);
    log('info', known ? 'event_not_routed_yet' : 'event_unknown', { event: ghEvent, delivery: deliveryId });
    return;
  }

  const payload = JSON.parse(rawBody);

  if (!PR_ACTIONS.has(payload.action)) {
    log('info', 'action_not_routed', { event: ghEvent, action: payload.action, delivery: deliveryId });
    return;
  }

  const repoFullName: string | undefined = payload.repository?.full_name;
  const headSha: string | undefined = payload.pull_request?.head?.sha;
  if (!repoFullName || !headSha) {
    throw new Error('malformed pull_request payload: missing repository.full_name or pull_request.head.sha');
  }

  if (!deps.isEnrolled(repoFullName)) {
    log('info', 'repo_not_enrolled', { repo: repoFullName, delivery: deliveryId });
    return;
  }

  for (const verdict of evaluate()) {
    await deps.postShadowCheck(repoFullName, headSha, verdict.name, verdict.output);
  }

  log('info', 'shadow_checks_posted', {
    repo: repoFullName,
    pr: payload.pull_request?.number,
    head_sha: headSha,
    delivery: deliveryId,
  });
}

/**
 * Build the SQS handler bound to the given collaborators.
 *
 * The event source mapping uses `batch_size = 1`, so this loop normally runs
 * once — it is written as a loop anyway so a batch-size change cannot silently
 * drop records.
 */
export function createWorker(deps: WorkerDeps) {
  return async (event: SQSEvent): Promise<void> => {
    for (const record of event.Records) {
      const deliveryId = record.messageAttributes?.deliveryId?.stringValue ?? record.messageId;
      const ghEvent = record.messageAttributes?.githubEvent?.stringValue ?? 'unknown';

      // Claim BEFORE processing: exactly one of two racing workers wins, so a
      // duplicate can never produce a duplicate check run.
      if (!(await deps.claimDelivery(deliveryId))) {
        log('info', 'duplicate_delivery', { delivery: deliveryId, event: ghEvent });
        continue;
      }

      try {
        await handleDelivery(deps, ghEvent, deliveryId, record.body);
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

- [ ] **Step 4: Run the full test suite**

Run: `pnpm test`
Expected: PASS — all files, including `tests/index.test.ts` from Task 4

- [ ] **Step 5: Typecheck and build**

Run: `pnpm run typecheck && pnpm run build`
Expected: no output from typecheck; `dist/index.js` written

- [ ] **Step 6: Commit**

```bash
git add src/worker.ts tests/worker.test.ts
git commit -m "feat: worker claims, routes, and posts shadow check runs (PLAT-1233)"
```

---

### Task 8: Infrastructure

**Files:**
- Create: `infrastructure/terraform/sqs.tf`
- Create: `infrastructure/terraform/dynamodb.tf`
- Create: `infrastructure/terraform/alarms.tf`
- Modify: `infrastructure/terraform/main.tf` (env vars + event source mapping)
- Modify: `infrastructure/terraform/iam.tf` (append the new policy)
- Modify: `infrastructure/terraform/vars.tf` (append `enrolled_repos`, `invalid_signature_threshold`)
- Modify: `infrastructure/terraform/outputs.tf` (append queue and table outputs)

**Interfaces:**
- Consumes: env var names from Tasks 1, 2, 6 — `DELIVERY_QUEUE_URL`, `DELIVERY_IDS_TABLE`, `ENROLLED_REPOS`; the `invalid_signature` log msg from Task 3
- Produces: the deployed queue, DLQ, table, event source mapping, and two alarms

- [ ] **Step 1: Create `infrastructure/terraform/sqs.tf`**

```hcl
# The delivery queue between the Lambda's two roles. It exists for two reasons
# that a direct Function URL -> handler call cannot provide:
#
#   1. A DLQ that actually fires. A Function URL invoke is SYNCHRONOUS, so a
#      Lambda async destination or async DLQ never sees it. SQS redrive is the
#      only mechanism here that satisfies PLAT-1233 §3's DLQ criterion.
#   2. Decoupling. GitHub expects a webhook response in 10s; the worker will
#      make several GitHub API calls per evaluation once T6-T8 land.

resource "aws_sqs_queue" "deliveries_dlq" {
  name = "${local.name}-deliveries-dlq"
  # Two weeks: long enough that a DLQ alarm firing over a weekend still has its
  # evidence intact on Monday.
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "deliveries" {
  name = "${local.name}-deliveries"

  # At least 6x the function timeout (10s), per AWS guidance — a message must
  # not become visible again while the worker is still holding it.
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.deliveries_dlq.arn
    maxReceiveCount     = 3
  })
}
```

- [ ] **Step 2: Create `infrastructure/terraform/dynamodb.tf`**

```hcl
# Delivery-ID dedupe. Named -delivery-ids, distinct from the -deliveries queue:
# they hold different things and confusing them in an alarm is avoidable.
#
# TTL does the cleanup. Two lifetimes are written by the application (see
# src/deliveries.ts): a 15-minute claim, so a hard-killed worker's orphaned
# claim expires rather than becoming a tombstone over an unhandled event; and a
# 7-day confirmation, long enough to outlive a manual redelivery fired from the
# App's Advanced tab days later.

resource "aws_dynamodb_table" "delivery_ids" {
  name         = "${local.name}-delivery-ids"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "deliveryId"

  attribute {
    name = "deliveryId"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.environment == "prod"
  }
}
```

- [ ] **Step 3: Append the event source mapping and env vars to `main.tf`**

Add the three env vars inside the existing `module "lambda"` `env_vars` block:

```hcl
  env_vars = {
    GITHUB_SECRET_NAME  = local.github_secret_name
    WEBHOOK_SECRET_NAME = local.webhook_secret_name
    NODE_OPTIONS        = "--enable-source-maps"

    DELIVERY_QUEUE_URL  = aws_sqs_queue.deliveries.url
    DELIVERY_IDS_TABLE  = aws_dynamodb_table.delivery_ids.name
    ENROLLED_REPOS      = var.enrolled_repos
  }
```

Then append to the end of `main.tf`:

```hcl
# Binds the SQS role of the single Lambda. One function serves both roles
# because deploy-v2.yml's lambda-deploy hard-codes `function-name:
# <app-name>-<env>` and runs once per environment — a second Terraform-created
# function would never receive code.
resource "aws_lambda_event_source_mapping" "deliveries" {
  event_source_arn = aws_sqs_queue.deliveries.arn
  function_name    = module.lambda.arn

  # One message per invocation: a poisoned message cannot fail a batch of
  # healthy ones, and each delivery's claim/settle cycle stays independent.
  batch_size = 1

  # The receiver and the worker share this function's concurrency pool
  # (reserved_concurrent_executions = 10). Capping queue processing at 5 means a
  # burst of queued work can never starve webhook receipt and cause GitHub
  # deliveries to fail.
  scaling_config {
    maximum_concurrency = 5
  }
}
```

- [ ] **Step 4: Append the new IAM policy to `iam.tf`**

```hcl
data "aws_iam_policy_document" "lambda_ingestion" {
  # SendMessage is the receiver role's grant; the consume actions are the
  # worker role's. They share one role because they share one function.
  statement {
    sid       = "SendDeliveries"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.deliveries.arn]
  }

  statement {
    sid       = "ConsumeDeliveries"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.deliveries.arn]
  }

  # No GetItem/Query: the claim protocol never reads. A conditional put is the
  # read.
  statement {
    sid       = "TrackDeliveryIds"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.delivery_ids.arn]
  }
}

resource "aws_iam_role_policy" "lambda_ingestion" {
  name   = "ingestion"
  role   = module.lambda.iam_role_name
  policy = data.aws_iam_policy_document.lambda_ingestion.json
}
```

- [ ] **Step 5: Create `infrastructure/terraform/alarms.tf`**

```hcl
# Alerting for PLAT-1233 §3.
#
# DELIBERATE DEVIATION from the ticket's acceptance criterion, which asks for
# "bad-signature and malformed events land in the DLQ with an alarm". Bad
# signatures do NOT reach the DLQ here. The Function URL is public and
# unauthenticated, so routing unsigned traffic to the DLQ would let anyone on
# the internet fill it on demand — firing the alarm continuously and burying
# the real failures it exists to surface. Invalid signatures get their own
# rate alarm instead; malformed-but-signed payloads do reach the DLQ, which is
# the case the criterion actually cares about.

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-${var.environment}-alerts"
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.name}-${var.environment}-dlq-not-empty"
  alarm_description   = "A webhook delivery failed 3 times and was dead-lettered. Inspect ${aws_sqs_queue.deliveries_dlq.name}."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.deliveries_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Counts the receiver's structured `invalid_signature` log line. A log metric
# filter rather than a PutMetricData call: src/log.ts already emits parseable
# JSON, so this costs no dependency and no latency on the hot path.
#
# The pattern matches src/receiver.ts's log msg exactly. Renaming that string
# silently breaks this alarm.
resource "aws_cloudwatch_log_metric_filter" "invalid_signature" {
  name           = "${local.name}-${var.environment}-invalid-signature"
  log_group_name = "/aws/lambda/${module.lambda.name}"
  pattern        = "{ $.msg = \"invalid_signature\" }"

  metric_transformation {
    name          = "InvalidSignature"
    namespace     = "${local.name}/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

# Alarms on RATE, not on any single occurrence: one bad signature is a
# misconfigured webhook or an internet scanner, neither of which is worth
# waking anyone. A sustained rate means the secret is wrong or the endpoint is
# being probed.
resource "aws_cloudwatch_metric_alarm" "invalid_signature_rate" {
  alarm_name          = "${local.name}-${var.environment}-invalid-signature-rate"
  alarm_description   = "Sustained invalid webhook signatures — the shared secret may be wrong, or the public Function URL is being probed."
  namespace           = aws_cloudwatch_log_metric_filter.invalid_signature.metric_transformation[0].namespace
  metric_name         = aws_cloudwatch_log_metric_filter.invalid_signature.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.invalid_signature_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
```

- [ ] **Step 6: Append the new variables to `vars.tf`**

```hcl
variable "enrolled_repos" {
  description = "Comma-separated owner/repo list this service may evaluate. Stand-in for PLAT-1184 T4's enrollment registry; fails closed when empty."
  type        = string
  default     = "bankrate/platform-cicd-v2-demo"
}

variable "invalid_signature_threshold" {
  description = "Invalid webhook signatures in a 5-minute window before alarming. One is noise (a scanner, a misconfigured hook); a sustained rate means the secret is wrong or the endpoint is being probed."
  type        = number
  default     = 20
}
```

- [ ] **Step 7: Append the new outputs to `outputs.tf`**

```hcl
output "delivery_queue_url" {
  value       = aws_sqs_queue.deliveries.url
  description = "SQS queue carrying verified webhook deliveries to the worker role"
}

output "delivery_dlq_url" {
  value       = aws_sqs_queue.deliveries_dlq.url
  description = "Dead-letter queue for deliveries that failed three attempts; the dlq-not-empty alarm watches it"
}

output "delivery_ids_table" {
  value       = aws_dynamodb_table.delivery_ids.name
  description = "DynamoDB table holding delivery-ID claims for idempotent handling"
}

output "alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "SNS topic both alarms publish to. Subscribing it to Slack or PagerDuty is a follow-up — an unsubscribed topic means the alarms are visible in CloudWatch but page nobody."
}
```

- [ ] **Step 8: Validate the Terraform**

```bash
cd infrastructure/terraform && terraform fmt -check && terraform init -backend=false && terraform validate
```

Expected: `Success! The configuration is valid.`

If `module.lambda.name` is not a valid output of the `lambda-function` module (used in `alarms.tf`'s `log_group_name`), check the module's actual outputs — `outputs.tf` already uses `module.lambda.name`, so it should be valid. If the module also creates the log group under a different name, adjust the filter's `log_group_name` to match.

- [ ] **Step 9: Commit**

```bash
git add infrastructure/terraform/
git commit -m "feat: SQS ingestion queue, DLQ, dedupe table, and alarms (PLAT-1233)"
```

---

### Task 9: Correct the stale documentation

`README.md` and `scripts/verify-qa.mjs` both assert the `neutral-planet` App "isn't installed on any repo." It is — org-installed since before this work, now narrowed to selected repositories. Leaving that in place means the next reader trusts a false statement about the security posture of a live service.

**Files:**
- Modify: `README.md` (the "Scope" section and the References table)
- Modify: `scripts/verify-qa.mjs` (the header comment)
- Modify: `AGENTS.md` (append findings)

**Interfaces:**
- Consumes: the VPC finding from Task 0
- Produces: nothing code-facing

- [ ] **Step 1: Rewrite the README "Scope" section**

Replace it with what is now true: PLAT-1233 §1 and §3 are complete, §4 is complete with a placeholder evaluator, and the App is installed and shadow-scoped. State what is still absent — the evaluator (T6/T7/T8), the enrollment registry (T4), the decision ledger (T9), the reconcile sweep — and link the spec at `docs/superpowers/specs/2026-08-24-zapp-webhook-ingestion-design.md`.

Update the References table row `GitHub App (not yet installed) | neutral-planet` to record the real state: installation `156198964`, `repository_selection: selected`, `checks:write` as its only write permission.

Update the Architecture bullets to describe the receiver/worker split and the queue.

- [ ] **Step 2: Fix the `verify-qa.mjs` header comment**

Remove "there's no GitHub App installed yet to deliver a real signed webhook". Keep the accurate part — the pipeline has no access to the webhook secret, so it cannot produce a valid signature, and the happy path stays a manual `curl` recorded as QA deploy evidence. Keep the bad-signature assertion exactly as it is.

- [ ] **Step 3: Append to `AGENTS.md`**

Add entries for anything sharp that Tasks 0–8 turned up. At minimum:

- `deploy-v2.yml`'s `lambda-deploy` hard-codes `function-name: <app-name>-<env>` and runs once per environment — this repo can only ever have ONE code-receiving Lambda per environment, which is why `src/index.ts` dispatches two roles on event shape instead of Terraform declaring two functions.
- The VPC egress finding from Task 0 (NAT present or not, and which subnets), so nobody re-runs that investigation.
- The `invalid_signature` log msg in `src/receiver.ts` is load-bearing: `alarms.tf`'s metric filter matches it as a literal string.

Follow the file's own rule — rewrite or prune existing entries rather than appending indefinitely, and point at authoritative files rather than restating them.

- [ ] **Step 4: Commit**

```bash
git add README.md scripts/verify-qa.mjs AGENTS.md
git commit -m "docs: correct the stale 'App not installed' claim and record ingestion notes (PLAT-1233)"
```

---

### Task 10: Deploy to QA and validate live on platform-cicd-v2-demo

The point of the ticket. Everything before this is unproven.

**Files:** none — verification only, plus evidence recorded on the PR.

**Interfaces:**
- Consumes: everything
- Produces: the evidence that closes PLAT-1233 §3 and §4

- [ ] **Step 1: Open the pull request**

```bash
gh pr create --repo bankrate/zapp --base main --head feat/plat-1233-webhook-ingestion \
  --title "feat: webhook ingestion and first shadow check runs (PLAT-1233)" \
  --body "Implements PLAT-1233 §3 and §4. Spec: docs/superpowers/specs/2026-08-24-zapp-webhook-ingestion-design.md"
```

Confirm CI passes before going further.

- [ ] **Step 2: Merge and cut a QA pre-release**

Merge the PR. `release.yml` runs semantic-release on `main`. For a QA-only deploy that does not promote to prod, publish a pre-release tag (e.g. `v1.1.0-rc.1`) — `deploy-v2.yml` stops after QA verification when the tag contains a hyphen.

- [ ] **Step 3: Confirm the QA deploy succeeded**

```bash
gh run list --repo bankrate/zapp --workflow deploy.yml --limit 3
```

Then confirm the queue, DLQ and table exist:

```bash
AWS_PROFILE=bankrate-qa aws sqs get-queue-url --queue-name zapp-deliveries --region us-east-1
AWS_PROFILE=bankrate-qa aws dynamodb describe-table --table-name zapp-delivery-ids \
  --region us-east-1 --query 'Table.TableStatus'
```

- [ ] **Step 4: Set the App's webhook secret and confirm the URL**

The App's webhook URL is already pointed at QA: `https://2bszayed4hqtwttyh4wcjd5yem0qmght.lambda-url.us-east-1.on.aws/`.

Confirm `/zapp/webhook` in the QA account holds the same secret configured on the App. This is the one value that must match on both sides, and a mismatch presents as every delivery 401ing.

- [ ] **Step 5: Confirm the App is installed on the demo repo**

```bash
gh api /orgs/bankrate/installations --jq '.installations[] | select(.app_slug=="neutral-planet") | {repository_selection, permissions}'
```

Expected: `repository_selection: "selected"`, and `checks: "write"` as the only write permission. If any other write permission has reappeared, stop — the Phase 0 invariant is broken.

- [ ] **Step 6: Open a pull request on the demo repo**

Any trivial change on `bankrate/platform-cicd-v2-demo`. Then confirm both checks appear:

```bash
gh api repos/bankrate/platform-cicd-v2-demo/commits/<HEAD_SHA>/check-runs \
  --jq '.check_runs[] | select(.name|startswith("merge-policy/")) | {name, status, conclusion, title: .output.title}'
```

Expected: two entries, both `status: completed`, both `conclusion: neutral`.

- [ ] **Step 7: Read the rendered check on the PR page**

Open the PR in a browser and read the check output as a stranger would. If it does not answer "what is this and do I need to do anything?" on its own, fix the text in `src/evaluate.ts` — §4's readability criterion is a judgement call and this is where it is made.

- [ ] **Step 8: Prove idempotency against real GitHub redelivery**

In the App's Advanced tab (`https://github.com/organizations/bankrate/settings/apps/neutral-planet/advanced`), find the `pull_request` delivery from Step 6 and click **Redeliver**.

Then re-run Step 6's query. Expected: still exactly two `merge-policy/*` check runs, not four.

Confirm the worker saw it:

```bash
AWS_PROFILE=bankrate-qa aws logs filter-log-events --region us-east-1 \
  --log-group-name /aws/lambda/zapp-qa --filter-pattern '{ $.msg = "duplicate_delivery" }' \
  --start-time $(( ($(date +%s) - 900) * 1000 )) --query 'events[].message'
```

Expected: a `duplicate_delivery` line carrying the redelivered delivery ID. **This is §3's idempotency acceptance criterion** — proven against GitHub's own redelivery path, not a simulation.

- [ ] **Step 9: Prove a new push re-evaluates against the new head SHA**

Push a second commit to the demo PR. Confirm two fresh check runs against the new SHA, and that the old SHA's checks are untouched.

- [ ] **Step 10: Prove the DLQ and its alarm**

Send a validly signed but malformed payload. Sign it with the real webhook secret:

```bash
SECRET='<the /zapp/webhook value>'
BODY='{"action":"opened","repository":'
SIG="sha256=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  https://2bszayed4hqtwttyh4wcjd5yem0qmght.lambda-url.us-east-1.on.aws/ \
  -H 'content-type: application/json' \
  -H 'x-github-event: pull_request' \
  -H "x-github-delivery: dlq-probe-$(date +%s)" \
  -H "x-hub-signature-256: $SIG" \
  --data "$BODY"
```

Expected: `202` — the receiver accepted it, because the signature is valid. The worker then fails to parse it, three times.

After roughly three minutes:

```bash
AWS_PROFILE=bankrate-qa aws sqs get-queue-attributes --region us-east-1 \
  --queue-url "$(AWS_PROFILE=bankrate-qa aws sqs get-queue-url --queue-name zapp-deliveries-dlq --region us-east-1 --query QueueUrl --output text)" \
  --attribute-names ApproximateNumberOfMessages --query 'Attributes'

AWS_PROFILE=bankrate-qa aws cloudwatch describe-alarms --region us-east-1 \
  --alarm-names zapp-qa-dlq-not-empty --query 'MetricAlarms[].StateValue'
```

Expected: at least one message on the DLQ, and the alarm in `ALARM`. **This is §3's DLQ criterion.**

Purge the DLQ afterwards so the alarm clears.

- [ ] **Step 11: Confirm the checks are on no required-checks configuration**

```bash
gh api repos/bankrate/platform-cicd-v2-demo/branches/main/protection \
  --jq '.required_status_checks.contexts'
gh api repos/bankrate/platform-cicd-v2-demo/rulesets \
  --jq '.[] | {name, enforcement}'
```

Expected: the contexts list contains only the three `Cycode:` entries and no `merge-policy/*`. This repo's required checks live in **classic branch protection**, not a ruleset — its "Default Branch Protection" ruleset is `disabled` — so checking rulesets alone would be vacuous. **This is §4's final criterion.**

- [ ] **Step 12: Confirm the PR is mergeable throughout**

```bash
gh pr view <DEMO_PR> --repo bankrate/platform-cicd-v2-demo --json mergeable,mergeStateStatus
```

Expected: nothing this service posted blocks the merge.

- [ ] **Step 13: Record the evidence**

Post the outputs of Steps 6, 8, 10, 11 and 12 as a comment on the zapp PR (or on PLAT-1233 if the PR is already merged). These five are the acceptance criteria; a claim without the output is not evidence.

Update the PLAT-1233 delivery checklist: all six items under §3 and all five under §4, with the three deviations noted against the items they alter.

---

## Post-implementation

Not part of this plan, but worth filing before the context is lost:

- **Subscribe the SNS topic.** `zapp-<env>-alerts` has no subscribers. Both alarms are visible in CloudWatch and page nobody until it is wired to Slack or PagerDuty.
- **Prod rollout.** This plan stops at QA. Promoting means a clean `vX.Y.Z` release plus pointing the App's webhook at the prod Function URL — worth deferring until the evaluator gives the checks something to say.
- **T4 replaces `ENROLLED_REPOS`**, T6/T7 replace `evaluate()`, T8 adds the `check_run`/`check_suite`/`status`/`push` routes that `KNOWN_UNROUTED` currently names and drops. Each is a body swap behind a call site this plan already placed.
