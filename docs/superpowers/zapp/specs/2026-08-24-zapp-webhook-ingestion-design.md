# Webhook ingestion and the first shadow check runs

Design for [PLAT-1233](https://redventures.atlassian.net/browse/PLAT-1233) §3 (webhook ingestion —
verify, dedupe, route) and §4 (first check runs), under epic
[PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184) "Merge-policy service — Phase 0
shadow mode".

Status: approved 2026-08-24. Supersedes the "Scope" section of `README.md`, which describes the
state before this work.

## Goal

Turn zapp from a verify-and-ack skeleton into a service that ingests `pull_request` webhooks from
the `neutral-planet` GitHub App, handles them exactly once, and posts two visible, non-blocking
check runs back onto the pull request. Validated live on `bankrate/platform-cicd-v2-demo`.

The decision logic those checks report is **not** in scope. The evaluator is PLAT-1184 T6/T7/T8;
this work builds the pipe it will plug into, and ships an honest placeholder verdict in the
meantime.

## Starting state

Established by inspection on 2026-08-24, not assumed:

| Fact | Detail |
|---|---|
| Repo | `bankrate/zapp` exists; PLAT-1233 §1 (T1) is genuinely complete |
| Runtime | Node 22, TypeScript, esbuild bundle, shipped as a **container image** |
| Deploy | CI/CD v2 (`deploy-v2.yml` in `finserv-reusable-gha`), TFC workspaces `zapp-qa` / `zapp-prod` |
| Ingress | Lambda Function URL, `authorization_type = NONE` |
| QA endpoint | `https://2bszayed4hqtwttyh4wcjd5yem0qmght.lambda-url.us-east-1.on.aws/` → `zapp-qa`, account `194918977890` |
| Prod endpoint | `https://wfdga6b5stsnhwy3xi7yd7suqa0fgyaf.lambda-url.us-east-1.on.aws/` → `zapp-prod`, account `835272777014` |
| Handler | `src/index.ts` — verifies `X-Hub-Signature-256`, logs, returns 200. No routing, no dedupe. |
| App | `neutral-planet`, installation `156198964`, `repository_selection: selected` |
| App permissions | `checks:write` + `contents:read`, `issues:read`, `merge_queues:read`, `metadata:read`, `pull_requests:read`, `statuses:read` |
| App events | `pull_request`, `check_run`, `check_suite`, `push`, `status`, `merge_group`, `merge_queue_entry` |
| Webhook URL | Currently pointed at the QA endpoint above |

The App was re-scoped on 2026-08-24 before this design was approved. `checks:write` is now its only
write permission, which is what makes the Phase 0 invariant — the service cannot approve, merge, or
enable auto-merge — structurally true rather than merely intended.

`README.md` and `scripts/verify-qa.mjs` both currently claim the App "isn't installed on any repo."
That was wrong even before the re-scope; both are corrected as part of this work.

### The validation target

`bankrate/platform-cicd-v2-demo` is an internal repo whose required status checks live in **classic
branch protection**, not a ruleset — its "Default Branch Protection" ruleset is `disabled`, and the
three required contexts (`Cycode: Secrets`, `Cycode: SAST`, `Cycode: Vulnerable Dependencies`) are
classic. This is the same split the epic calls the fantasia lesson, and it makes the demo repo a
better validation target than a ruleset-only repo would be: the §4 acceptance criterion "neither
check is on any required-checks configuration" has to be verified against classic protection, and
here that is not a vacuous check.

## Architecture

```
GitHub App (neutral-planet)
      │  pull_request
      ▼
Lambda Function URL
      │
      ▼
receiver Lambda ──────► SQS zapp-deliveries ──────► worker Lambda ──────► GitHub Checks API
  verify HMAC                     │                   claim (DynamoDB)
  enqueue raw body                │                   route
  401 / 202                       │                   evaluate (stub)
                                  │                   post check runs
                                  ▼
                          DLQ (maxReceiveCount 3)
                                  │
                                  ▼
                          CloudWatch alarm
```

### Why a queue at all

`github-pr-jira-check`, the shape precedent, is a single synchronous Lambda behind a Function URL
with no queue. Splitting into receiver and worker buys three things that precedent doesn't need but
this service does:

1. **A real DLQ.** A Function URL invoke is synchronous, so a Lambda async destination or async DLQ
   never fires for it. Without a queue there is no mechanism that satisfies §3's DLQ acceptance
   criterion. SQS redrive gives one directly.
2. **A bounded public attack surface.** The Function URL is public and unauthenticated. The
   receiver does HMAC verification and an SQS write, nothing else — it never parses the payload
   beyond headers, never calls GitHub, never touches DynamoDB.
3. **Delivery timeouts decoupled from GitHub API latency.** GitHub expects a webhook response in
   10 seconds. The worker will eventually make several GitHub API calls per evaluation (T6–T8);
   putting that behind a queue means API slowness degrades evaluation latency, not delivery
   success.

### Why one Lambda in two roles, not two Lambdas

The natural shape would be two functions — a receiver and a worker — from the same image. **The
deploy pipeline forbids it.** `deploy-v2.yml` on `work/plat1233-lambda-deploy` calls the
`lambda-deploy` action with `function-name: ${{ inputs.app-name }}-qa`, hard-coded, once per
environment. A second Terraform-created function would never receive new code; it would sit
permanently on the `:bootstrap` image while the first one advanced. Supporting two would mean
changing `finserv-reusable-gha`, which is outside this ticket.

So: **one function, two roles, dispatched on event shape.** `src/index.ts` becomes a thin router —
an event carrying a `Records` array is an SQS batch and goes to the worker; anything else is a
Function URL request and goes to the receiver. Both roles keep their own module and their own
tests; only the entrypoint is shared.

What this costs, honestly:

- **A broader IAM role.** One role now holds `sqs:SendMessage`, the SQS consume actions, and the
  three DynamoDB item actions. Every one is resource-scoped to this service's own queue and table,
  and the public path still cannot reach any of them without passing HMAC verification first — but
  it is wider than a dedicated receiver role would be.
- **Shared concurrency.** A burst of queued work could otherwise starve webhook receipt and cause
  GitHub deliveries to fail. Mitigated explicitly: `reserved_concurrent_executions = 10` on the
  function, with `scaling_config.maximum_concurrency = 5` on the event source mapping, so queue
  processing can never consume more than half the pool and the receiver always has headroom.

The two reasons the queue exists — a DLQ mechanism that actually fires, and decoupling GitHub API
latency from webhook delivery timeouts — are both unaffected by this collapse.

## Components

### `src/index.ts` — entrypoint router

Nothing but dispatch: `Array.isArray(event.Records)` → worker, otherwise → receiver. No business
logic, so the shared entrypoint costs nothing in testability.

### `src/receiver.ts` — receiver role

- Verify `X-Hub-Signature-256` against `/zapp/webhook`. Failure → emit the `InvalidSignature`
  metric, log, return 401. The body is never parsed.
- Decode the body first when `isBase64Encoded` is true. The current handler reads `event.body`
  directly; a base64-encoded body would fail HMAC verification with a misleading "bad signature."
  Function URLs do not base64-encode `application/json`, so this is latent rather than live, but it
  is one line and removes a confusing future failure mode.
- `SendMessage` to the delivery queue: the raw body, plus `X-GitHub-Event` and `X-GitHub-Delivery`
  as message attributes. Return 202.

### `src/worker.ts` — worker role

SQS-triggered. Batch size 1, so one poisoned message cannot fail a batch of healthy ones.

1. **Claim** the delivery ID (below). Already claimed → log `duplicate_delivery`, return.
2. **Route** on event type. `pull_request` with action in `{opened, synchronize, reopened, edited}`
   proceeds; everything else is logged and dropped. `check_run`, `check_suite`, `status` and `push`
   are subscribed on the App because T8 needs them, but this scope drops them — explicitly and by
   name, so the log distinguishes "not routed yet" from "unknown event."
3. **Enrolment gate.** Drop anything whose `repository.full_name` is not in `ENROLLED_REPOS`.
4. **Evaluate** (stub) and **post** both check runs.
5. **Settle** the claim — confirm on success, release on failure.

### `src/deliveries.ts` — the claim protocol

DynamoDB table `zapp-delivery-ids`: hash key `deliveryId` (string), TTL attribute `expiresAt`,
`PAY_PER_REQUEST`. Named distinctly from the `zapp-deliveries` SQS queue — they hold different
things and confusing them in an alarm or a log line is avoidable.

Duplicate detection keys on `err.name === 'ConditionalCheckFailedException'` rather than
`instanceof`. The name is stable across AWS SDK versions and is trivially reproducible in a fake
sender, where constructing the real exception class is not.

```
claim:    PutItem, ConditionExpression attribute_not_exists(deliveryId)
                   expiresAt = now + 15 min, status = "claimed"
          ConditionalCheckFailedException → duplicate, caller drops the message

confirm:  UpdateItem expiresAt = now + 7 days, status = "done"

release:  DeleteItem
```

The claim is taken **before** processing, not after. That ordering is what makes two workers racing
the same delivery ID safe: exactly one claim succeeds, so a duplicate cannot produce a duplicate
check run. Claiming after processing would leave a window in which both workers post.

The short claim TTL is the self-heal. If a worker is hard-killed between claim and settle, the claim
expires in 15 minutes and a later redelivery can re-claim; the record does not become a permanent
tombstone over an event that was never handled. On an ordinary failure the worker releases the claim
explicitly and rethrows, so SQS redelivers and the next attempt re-claims immediately.

Reprocessing is safe on its own terms, independent of any of this: the evaluator is a stateless full
recompute for a given head SHA (epic PLAT-1184, race-condition section). The claim exists to prevent
duplicate *check runs*, not to make a non-idempotent operation idempotent.

Two duplicate sources are covered, and both need covering:

- **GitHub redelivery** — manual replay from the App's Advanced tab, or GitHub's own retries. May
  arrive days later, which is why the confirmed record lives 7 days.
- **SQS at-least-once** — a standard queue can deliver the same message twice even for a single
  enqueue. SQS FIFO's built-in deduplication would not substitute here: its window is 5 minutes.

### `src/checks.ts` — posting check runs

```ts
const SHADOW_CONCLUSION = 'neutral';

export async function postShadowCheck(
  repo: Repository, headSha: string, name: string, output: CheckOutput,
): Promise<void>
```

`postShadowCheck` takes **no conclusion parameter**, and it is the only code path in the repo that
calls `POST /repos/{owner}/{repo}/check-runs`. There is no argument a future caller can pass to make
a shadow check non-neutral. This is what §4's "enforced in code" means here — a structural
guarantee, not a runtime assertion that a later edit could delete.

Both checks post against the PR head SHA, with `status: "completed"`.

### `src/github.ts` — App authentication

Ported from `github-pr-jira-check` unchanged: RS256 JWT signed with the App private key, exchanged
for an installation token, cached in module scope until 60 s before expiry. Reads `/zapp/github`
via the existing `getGitHubConfig`, which is already defined in `src/secrets.ts` and currently
unused.

### `src/evaluate.ts` — the stub

Returns a fixed verdict shaped like the real one, so that T6/T7 replace a function body rather than
a call site. The rendered output is written for a human who has never heard of this project:

> **Shadow mode — no verdict yet**
>
> This informational check is posted by the merge-policy service (zapp). It is **not required** and
> **will never block your pull request**.
>
> The service is running in shadow mode: it is being wired up to observe pull requests and record
> what an automated merge policy *would* have decided, without acting on it. The decision logic is
> not yet connected, so there is no verdict to report for this pull request.
>
> Nothing is needed from you. Tracking: PLAT-1184.

Both `merge-policy/eligibility` and `merge-policy/risk` carry this text, differing only in which
check they name. Placeholder in substance, but complete and readable in form — a reader who lands on
it from a PR gets a full answer, not a `TODO`.

## Infrastructure

New Terraform in `infrastructure/terraform/`:

- `sqs.tf` — `zapp-deliveries` queue and `zapp-deliveries-dlq`. `maxReceiveCount = 3`,
  `visibility_timeout_seconds` at least 6× the worker timeout, 14-day retention on the DLQ.
- `dynamodb.tf` — the `zapp-delivery-ids` table, following `platform-agent`'s
  `PAY_PER_REQUEST` + TTL shape.
- `alarms.tf` — a CloudWatch alarm on DLQ `ApproximateNumberOfMessagesVisible > 0`, and a second on
  the `InvalidSignature` metric rate.
- `main.tf` — an `aws_lambda_event_source_mapping` binding the existing function to the queue,
  `batch_size = 1`, `scaling_config.maximum_concurrency = 5`; plus the three new env vars
  (`DELIVERY_QUEUE_URL`, `DELIVERY_IDS_TABLE`, `ENROLLED_REPOS`).
- `iam.tf` — the existing role gains `sqs:SendMessage`, the SQS consume actions, and
  `dynamodb:PutItem` / `UpdateItem` / `DeleteItem`, each scoped to this service's own resources.

The `InvalidSignature` metric is a CloudWatch **log metric filter** on the structured
`invalid_signature` log line, not an SDK `PutMetricData` call. The log line already exists and
`src/log.ts` already emits parseable JSON, so this adds a metric with no new code, no new
dependency, and no added latency on the hot path.

### Networking — verify before building

Both functions run with `create_in_vpc = true`, `vpc_tag = "PrimaryVPC"`. Two egress paths matter:

- The **worker** must reach `api.github.com`. `github-pr-jira-check` already does exactly this from
  a VPC Lambda in this org, so NAT egress is near-certainly present.
- The **receiver** must reach SQS from inside the VPC — NAT, or an SQS interface VPC endpoint.

The SQS event source mapping itself needs neither: the Lambda service polls the queue from outside
the VPC and invokes the function. Only the receiver's own `SendMessage` call is affected.

Both paths are verified against the deployed `zapp-qa` function before the SQS work starts, rather
than discovered at deploy time. If NAT egress is absent, the fix is an SQS interface endpoint in
`sqs.tf`.

## Deliberate deviations from the acceptance criteria

Three places where this design does not do what PLAT-1233 literally says. Approved 2026-08-24.

### Bad signatures do not reach the DLQ

§3 says "bad-signature and malformed events land in the DLQ with an alarm." This design splits them.

A bad signature is rejected at the receiver with 401 and never enqueued. The Function URL is public
and unauthenticated, so routing unsigned traffic to the DLQ would let anyone on the internet fill it
on demand — firing the alarm continuously and burying the real failures it exists to surface. That
converts a monitoring control into a denial-of-service amplifier.

Instead, invalid signatures increment an `InvalidSignature` CloudWatch metric with an alarm on
*rate*, which is the signal actually worth waking up for. Malformed-but-validly-signed payloads —
the case where something is genuinely wrong with our handling rather than with an anonymous
caller — do reach the worker, fail there, exhaust their retries, and land in the DLQ exactly as the
criterion intends.

Same detection coverage; no self-inflicted DoS surface.

### Enrolment is an environment variable, not the T4 registry

PLAT-1184 T4 specifies a DynamoDB enrolment registry fed by a reviewed config file. That ticket is
not in PLAT-1233's scope, and this work needs *some* gate to keep evaluation confined to the demo
repo.

`ENROLLED_REPOS`, a comma-separated allowlist, set to `bankrate/platform-cicd-v2-demo`. The gate is
a single function, `isEnrolled(repo: string): boolean`, so T4 replaces one implementation behind a
stable call site.

This is defence in depth rather than the primary control — the App installation is already narrowed
to selected repositories. It matters because installation scope is changed by hand in a web UI,
where the allowlist is changed in a reviewed commit.

### The check-run rationale is a placeholder

§4 requires rationale "readable by a non-team engineer without explanation," with the example
*"would have been a candidate: yes — dep-patch, tier 2/2, risk low."* That example is only
producible by T6/T7, which are out of scope.

The stub text above meets the readability bar without claiming a verdict it cannot compute. The
alternative — implementing a partial evaluator now — was considered and rejected: a thin subset of
the eleven gates would produce verdicts that look authoritative while being wrong by omission, and
the epic's whole premise is that the shadow dataset is trustworthy.

§4's other two criteria are met in full: the conclusion is structurally always `neutral`, and the
required-checks confirmation is a real verification step against this repo's classic protection.

## Error handling

| Condition | Behaviour |
|---|---|
| Bad or missing signature | 401, `InvalidSignature` metric, body never parsed, not enqueued |
| SQS `SendMessage` fails | 500 — GitHub retries the delivery, which is the correct owner of that retry |
| Duplicate delivery ID | Claim fails, message acked and dropped, logged as `duplicate_delivery` |
| Unroutable event or action | Claimed, logged by name, acked. Not a failure. |
| Repo not enrolled | Claimed, logged, acked. Not a failure. |
| Malformed JSON in worker | Claim released, throw → 3 attempts → DLQ → alarm |
| GitHub API 5xx or timeout | Claim released, throw → SQS retries → DLQ if persistent |
| Worker hard-killed mid-flight | Claim expires after 15 min; redelivery re-claims |

Logging follows `src/log.ts` — one JSON object per line, and its existing rule that only non-secret
metadata is ever logged. Delivery IDs, repo names, PR numbers and SHAs are safe; headers (which
carry the signature), tokens, and the private key are not.

## Testing

Unit tests follow the existing injectable-`Deps` convention in `tests/`, `node:test`, no network:

- **Claim protocol** — first claim succeeds; second claim on the same ID raises
  `ConditionalCheckFailed` and the worker drops the message; a failed process releases the claim and
  rethrows; confirm extends the TTL. Against a fake DynamoDB send function.
- **Routing** — each subscribed event type and each `pull_request` action reaches the right outcome,
  including the deliberate drops.
- **Enrolment** — an enrolled repo proceeds; a non-enrolled repo posts nothing, asserted by the
  GitHub client never being called.
- **Neutral invariant** — across a matrix of stub verdicts, every captured request body carries
  `conclusion: "neutral"`. Plus a test asserting `postShadowCheck`'s signature accepts no conclusion.
- **Receiver** — 401 paths preserved from `tests/handler.test.ts`; a valid delivery enqueues once
  with the right message attributes; a base64-encoded body verifies correctly.

`scripts/verify-qa.mjs` keeps its bad-signature assertion and drops the stale "no App installed"
comment. It cannot gain a happy-path assertion: the pipeline has no access to the webhook secret,
so it cannot produce a valid signature. The signed-request path stays what it already is — a manual
`curl` recorded as QA deploy evidence on the PR.

### Live validation on platform-cicd-v2-demo

The point of the ticket. In order:

1. Open a PR on `bankrate/platform-cicd-v2-demo`.
2. Both `merge-policy/eligibility` and `merge-policy/risk` appear on it, `neutral`, with the stub
   rationale rendered.
3. Redeliver that same delivery from the App's Advanced tab. No second check run appears, and the
   worker logs `duplicate_delivery` — this is §3's idempotency criterion, proven against the real
   GitHub redelivery path rather than a simulated one.
4. Push a second commit. A new evaluation runs against the new head SHA and posts fresh checks.
5. Confirm neither check name appears in the demo repo's classic branch protection required
   contexts, nor in any active ruleset — §4's final criterion.
6. Send a validly signed but malformed payload. It lands in the DLQ and the alarm fires — §3's DLQ
   criterion.
7. Confirm the PR is mergeable throughout. Nothing this service posts blocks anything.

## Out of scope

Named explicitly so the boundary survives review:

- The evaluator — eligibility gates (T6), risk heuristics (T7), required-checks snapshot (T8)
- The decision ledger (T9) and outcome collection (T11)
- `policy-rules.yaml` and its loader (T5)
- The enrolment registry (T4) — stubbed by `ENROLLED_REPOS`, as above
- The 10-minute EventBridge reconcile sweep — it belongs with T8, whose snapshot it heals
- Routing `check_run`, `check_suite`, `status`, `push` — subscribed on the App for T8, dropped here
- Prod rollout. This work is validated on QA against one repo; promoting to prod is a separate call
  once the evaluator gives the checks something to say.

## Definition of done

- [ ] Receiver verifies the signature and enqueues; malformed base64 bodies handled
- [ ] Worker claims on delivery ID, routes `pull_request`, gates on enrolment
- [ ] Replayed deliveries are proven no-ops, both in unit tests and by real GitHub redelivery
- [ ] Malformed signed events reach the DLQ and fire an alarm
- [ ] Invalid signatures fire a rate alarm without touching the DLQ
- [ ] `merge-policy/eligibility` and `merge-policy/risk` post as `neutral`, non-required check runs
- [ ] Conclusion is structurally always `neutral`, with a test proving it
- [ ] Rationale is complete and readable by a non-team engineer
- [ ] Neither check appears in the demo repo's classic protection or any ruleset
- [ ] `README.md` and `verify-qa.mjs` no longer claim the App is uninstalled
- [ ] `AGENTS.md` records anything sharp discovered along the way
