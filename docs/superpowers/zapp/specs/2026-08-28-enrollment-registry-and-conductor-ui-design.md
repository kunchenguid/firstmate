# Enrollment registry and Conductor enrollment UI — design

- **Date:** 2026-08-28
- **Ticket:** [PLAT-1188](https://redventures.atlassian.net/browse/PLAT-1188) — T4 | Repo enrollment registry
- **Epic:** [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184) — Merge-policy service, Phase 0 shadow mode (M1 · Foundations)
- **Repos touched:** `bankrate/zapp`, `bankrate/conductor-api`
- **Status:** design approved, plan to follow

## What this changes

Today enrollment is eight entries in `policy-rules.yaml`'s `repos:` section,
compiled into `src/generated/rules.ts` at build time. Enrolling a repository
means a pull request, a review, a merge, and a deploy.

After this work, enrollment is a DynamoDB table that a Conductor admin page
reads and writes, and zapp reads at runtime. Enrolling a repository means
filling in a form.

Three things follow from that, and they are the whole design:

1. **zapp's enrollment read becomes I/O**, so it can fail, so it needs
   fail-closed semantics it has never needed before.
2. **`rulesSha` stops describing enrollment**, so the eval record has to carry
   the enrollment it actually used or the shadow corpus loses the ability to
   explain its own decisions.
3. **The GitHub App has to see every repository**, because a UI that enrolls a
   repository and then requires a second manual step in GitHub is not a control
   surface, it is a form.

## This diverges from PLAT-1188 as written

The ticket says:

> Source of truth is a **config file in the merge-policy repo** — enrolling a
> repo is a reviewed PR — synced to the table on merge.

and its acceptance criteria say:

> Enrollment PR → table sync is automatic and audited

That is the inverse of what this design does. The table is the source of truth;
there is no config file and no sync job. **PLAT-1188's description and both
acceptance criteria need rewriting before this work is called done**, or the
ticket will close against criteria the implementation deliberately does not
meet.

The replacement criteria this design satisfies:

- Enrollment changes are audited — actor, timestamp, before and after — in a
  history record that outlives Conductor.
- Un-enrolled repos are ignored by the evaluator (tested), and the evaluator
  fails visibly rather than silently when it cannot tell.
- Every eval record names the enrollment that produced it.

The `sourceSha` field in the ticket's example record has no meaning once there
is no source file. It is replaced by `version` — a monotonic counter — which is
what the concurrency control and the audit trail both need anyway.

## Decisions

| # | Decision | Chosen |
|---|---|---|
| 1 | Source of truth | **Table only.** `repos:` is deleted from `policy-rules.yaml` and `build-rules.mjs` rejects the key. Every eval record stamps the resolved enrollment record and its `version`. |
| 2 | GitHub App install scope | **Widen installation 156198964 to `repository_selection: all`.** The worker still only posts checks for enrolled repos, so the permission is held and unexercised elsewhere. |
| 3 | Local validation | **DynamoDB Local in `docker-compose.yml`** plus an artisan command that creates and seeds the table, so enroll and unenroll are really clickable locally without touching qa. |

Resolved without asking, and why:

| Decision | Resolved | Reasoning |
|---|---|---|
| Unenroll: delete or soft-delete? | **Delete the item, write a history row.** | zapp already distinguishes "paused" (`mode: off`) from "absent". Adding a third `deletedAt` state would put that distinction in two places. The history row keeps the deletion auditable. |
| Pause and unenroll: one control or two? | **Two.** | The distinction already exists in zapp and gate 1 already reports it. A UI that collapses them discards a fact the service went out of its way to keep. |
| Filament Resource or Page? | **Page.** | Resources are Eloquent-backed. Enrollment is not in MySQL. A Page carrying a table over the `Repo` model, with enrollment joined in from DynamoDB, is the shape that fits. |
| Mirror the table into MySQL for native sorting/filtering? | **No.** | The table holds only *enrolled* repos — eight today, tens eventually — so the enrolled name set pushes straight into a `whereIn`. A mirror would buy sorting on enrollment columns at the cost of a second store that can drift. Revisit if operators ask to sort by `classification`. |
| Cache the enrollment read in zapp? | **No.** | The page is a control surface. If Unenroll takes up to a TTL to take effect, the operator learns not to trust the button. One `GetItem` per routed delivery is the price of the button meaning what it says. |

## Data model

One new table, `zapp-enrollments`, owned by zapp's Terraform. Table names in
zapp carry no environment suffix (`local.name = var.app_name`), and
conductor-api deploys into the *same two AWS accounts* as zapp —
`194918977890` and `835272777014` — so the table name is identical everywhere
and the account does the disambiguating. **No cross-account role is needed**,
which is the single biggest simplification available here.

### Enrollment records

```
pk = "repo"                      (constant)
sk = "bankrate/portkey"          (owner/repo, exactly as the webhook reports it)
```

| Attribute | Type | Notes |
|---|---|---|
| `repo` | S | Duplicates `sk`. Readers should not have to know the key encoding. |
| `classification` | S | `sandbox` \| `internal-tool` \| `prod-service`. Gate 9 reads it. |
| `ciTrustTier` | N | Gate 10 reads it. |
| `mode` | S | `shadow` \| `off`. |
| `stageEnabled` | BOOL | Recorded; gates nothing in Phase 0. |
| `signalChecks` | L | **Optional.** Absent means "use the global list". Present-and-empty means "wait on nothing". |
| `blockingChecks` | L | **Optional**, same absent-vs-empty rule. |
| `baseBranches` | L | **Optional**, same rule. |
| `version` | N | Monotonic. Bumped on every write. Concurrency control and audit key. |
| `enrolledBy` / `enrolledAt` | S | Set once, never overwritten. |
| `updatedBy` / `updatedAt` | S | Overwritten every write. |

A single partition for every enrollment record is deliberate: it makes "the
whole fleet" one `Query`, which is what `fleetSize` needs, and it keeps zapp's
IAM free of `dynamodb:Scan` — a property the existing policy states explicitly
and this work should not be the thing that breaks.

The partition is nowhere near a hot-partition limit. It holds one item per
*enrolled* repo, not per org repo: eight items today, against a 10 GB and
3,000 RCU/s partition ceiling.

**The `Query` must still paginate on `LastEvaluatedKey`.** `fleetSize` is a
denominator in `internalConfidence`, and a silently truncated read produces a
plausible wrong number rather than an error. The 1 MB response limit is not
reachable at today's size; the loop is insurance against the day it is.

### History records

```
pk = "history#bankrate/portkey"
sk = "2026-08-28T14:03:11.221Z#7"      (ISO 8601 + version)
```

| Attribute | Notes |
|---|---|
| `action` | `enroll` \| `update` \| `pause` \| `resume` \| `unenroll` |
| `actor` | The Conductor user's email. |
| `at` | ISO 8601. |
| `before` / `after` | JSON strings of the record. `before` absent on enroll, `after` absent on unenroll. |
| `version` | The version this write produced. |

A separate partition per repository, not the shared `"repo"` one — history rows
sharing the fleet partition would pollute every fleet read. The version suffix
on `sk` is there because two writes in the same millisecond would otherwise
collide on the timestamp alone.

History lives here *as well as* in Conductor's existing
`spatie/laravel-activitylog` (surfaced by `ActivityLogResource`) because the two
answer different questions. The activity log answers "what did this admin do
across Conductor". The DynamoDB history answers "why is this repository
configured this way", and it has to survive Conductor being unavailable, or
being replaced.

### Consistency

Every read — zapp's and Conductor's — uses `ConsistentRead: true`. The table is
small enough that the doubled RCU is noise, and it removes a whole class of
"I enrolled it and nothing happened" report that would be indistinguishable
from a real bug.

### Concurrency

- **Create:** `PutItem` with `ConditionExpression: attribute_not_exists(sk)`.
- **Update / pause / resume:** `UpdateItem` with
  `ConditionExpression: version = :expected`, setting `version = :expected + 1`.
- **Unenroll:** `DeleteItem` with `ConditionExpression: version = :expected`.

A `ConditionalCheckFailedException` is not an error to log and swallow. It means
another operator changed the record while this form was open, and the UI must
say so and refuse the write. Last-write-wins on a control that decides what
automation may touch production is not acceptable.

## zapp changes

### The read splits in two

The current API defaults its `repos` parameter to `POLICY.repos`, which is what
makes every call site invisible. The new API takes no default, so **the compiler
finds every call site** — that is the mechanism, not a nice side effect.

```ts
// src/enrollment.ts

/** One repository's enrollment, or undefined when it has none. Throws on a failed read. */
export async function lookupEnrollment(
  repoFullName: string,
  send?: DynamoSender,
): Promise<EnrollmentRecord | undefined>;

/** How many repositories are enrolled with mode other than `off`. Throws on a failed read. */
export async function fleetSize(send?: DynamoSender): Promise<number>;

/** Unchanged in spirit; now takes the record the caller already holds. */
export function signalChecksFor(
  enrollment: EnrollmentRecord | undefined,
  rules: Rules,
): readonly string[];
```

Two functions rather than one because the two callers want different things and
the cheap one is the common one:

- **The drop path** needs one repository. `GetItem`, ~1 RCU. With 1,112 repos in
  the `bankrate` org and eight enrolled, this is over 99% of deliveries.
- **`internalConfidence`** needs the fleet count, and only for candidates. Its
  deps interface at `src/signals/internal-confidence.ts:63` already declares
  `fleetSize: () => number` — a *function*, not a value. It becomes
  `() => Promise<number>` and the `Query` happens only when a candidate actually
  reaches the confidence signal.

`isEnrolled` disappears as a separate export. Its logic —
`record !== undefined && record.mode !== 'off'` — is two comparisons the worker
makes on the record it already has, and keeping a wrapper would hide the fact
that the read is now I/O.

### Fail-closed: a failed read throws

This is the new failure mode and it needs stating precisely, because zapp
already has a similar-looking case with the opposite answer.

| Observation | Meaning | Behaviour |
|---|---|---|
| No item for this repo | Not enrolled. A fact. | Drop the delivery. Log `repo_not_enrolled`. |
| Item present, `mode: off` | Enrolled but paused. A fact. | Drop the delivery. Log `repo_paused`. |
| The read failed | **Not a fact.** | **Throw.** SQS retries; the message reaches the DLQ; `zapp-{env}-dlq-not-empty` fires. |

Contrast `readFreeze`, where an unreadable flag means *frozen* — it degrades to
the safe state and keeps running. Enrollment cannot do that. "Assume not
enrolled" would silently stop evaluating the entire fleet while every delivery
reported success, and the shadow corpus would simply develop a hole. "Assume
enrolled" would evaluate 1,112 repositories. Neither is a safe state, so there
is no safe state to degrade to, and the only honest option is to fail loudly.

There is deliberately **no fallback to the compiled YAML**. A fallback is a
second source of truth that is consulted exactly when nobody is watching.

### The drop moves before the claim

Today `createWorker` claims each delivery, then `handleDelivery` routes it, then
each handler calls `isEnrolled`. With eight enrolled repos out of 1,112, that
order means every irrelevant delivery costs an SQS receive, a `PutItem` claim, a
release, and a route.

New order, inside the per-record loop:

1. Gate on `ghEvent` (unchanged) — `status` and friends still cost nothing.
2. Parse the body once. Read `repository.full_name`.
3. `lookupEnrollment`. Absent or `mode: off` → log and return **without
   claiming**.
4. Claim, then route, passing the resolved record down.

Dropping without claiming is safe precisely because nothing was done: a
redelivery takes the identical path and reaches the identical decision. The
dedupe table exists to stop *side effects* happening twice, and there are none
here.

`handleDelivery` and the four handlers take the parsed payload and the
`EnrollmentRecord` instead of `rawBody` and `deps.isEnrolled`. The five
`deps.isEnrolled` call sites in `src/worker.ts` (lines 87, 105, 184, 232, 285)
all collapse into the single check at step 3.

### `evaluate` receives the record

`src/evaluate.ts:211` currently calls `enrollmentFor(ctx.repoFullName)` itself.
It becomes a second positional parameter:

```ts
export async function evaluate(
  ctx: EvalContext,
  enrollment: EnrollmentRecord | undefined,
  deps: EvaluateDeps = defaultDeps,
): Promise<ShadowVerdict[]>
```

Not a field on `EvalContext`: that type is documented as "pull request identity
and metadata from the webhook payload", and enrollment is neither.

The `enrollment === undefined || enrollment.mode === 'off'` short-circuit stays
— it appears four times, at `src/evaluate.ts:216` (the files fetch), `:228`
(`skipFetches`), `:233` (check runs, properties, freeze) and `:271`
(`commitAuthorship`). The worker now drops those deliveries before
`evaluate` is reached, but the branch is tested, it is what makes `evaluate`
safe to call directly, and it is what lets gate 1 report *which* of the two
non-enrolled states it saw.

### The eval record carries its enrollment

`EvalRecord` in `src/ledger.ts` gains one field:

```ts
  /**
   * The enrollment record this decision was made under, including its version.
   *
   * `rulesSha` no longer covers enrollment — it pins the gates and thresholds
   * only. Gates 9 and 10 read `classification` and `ciTrustTier`, so without
   * this a record cannot explain its own verdict.
   */
  enrollment?: EnrollmentRecord & { version: number; updatedBy: string; updatedAt: string };
```

Stored as a JSON string, matching how `eligibility` and `classification` are
already stored — it is read back whole for analysis and never queried by inner
attribute.

Snapshotting the resolved record rather than a pointer to it makes the corpus
**better** than the YAML arrangement it replaces: today answering "what
classification produced this verdict" means resolving a `rulesSha` to a blob and
parsing it. After this, it is a field on the record.

Optional (`?`) because records written before this lands will not have it, and
the weekly report's recorder-health table already handles absent fields as a
first-class case.

Follow-up, deliberately not in scope: `RECORDED_FIELDS` in
`src/report/query.ts` should probably learn about `enrollment` so the weekly
report tracks its coverage. That is a small addition to the report work that
just landed and belongs with it, not here.

### IAM

zapp's Lambda role gains, in `infrastructure/terraform/iam.tf`:

```
dynamodb:GetItem, dynamodb:Query   on   aws_dynamodb_table.enrollments.arn
```

No `PutItem`. **zapp never writes its own enrollment**, and the absence of the
grant is what makes that structural rather than a convention. This mirrors the
existing shape of the file, where the delivery-ids statement documents its
missing `GetItem` as a design fact.

conductor-api's ECS task role gains `GetItem`, `Query`, `PutItem`,
`UpdateItem`, `DeleteItem` on the same table ARN, constructed from
`data.aws_caller_identity.current` — same account, so no remote state
dependency and no cross-workspace coupling. It gains nothing on
`zapp-evaluations` or `zapp-delivery-ids`.

## conductor-api changes

### The page

`app/Filament/Pages/AutoMerge.php` — a Filament v5 Page, not a Resource, with a
table over the `Repo` model.

```php
protected static string|\UnitEnum|null $navigationGroup = 'Inventory';
protected static ?string $navigationLabel = 'Auto-Merge';
```

sorted immediately after `RepoResource` (which sets the same group at
`app/Filament/Resources/Repos/RepoResource.php:49`).

**The join key is `CONCAT(owner, '/', name)`.** The `repos` table has `owner`
and `name` columns and no `full_name`, while zapp keys on `owner/repo` exactly
as the webhook reports it. Every filter that pushes the enrolled set into SQL
does so against that expression.

The fleet is loaded once per request into a keyed map and read from there for
every column. It must **not** be a public Livewire property — Livewire
serialises those between requests, which would both bloat the payload and
reintroduce the staleness the no-cache decision exists to avoid. A protected
memoised accessor, invalidated after any write action.

### Enrolled but not in inventory

An enrollment record whose repository has no row in Conductor's `repos` table
cannot appear in an Eloquent-backed table. That is not a hypothetical: it
happens when a repository is renamed or deleted in GitHub, and it happens on
every fresh local database.

The page renders these in a separate labelled section above the main table —
"Enrolled, not in Conductor's inventory" — with Unenroll available. Hiding them
would mean zapp is evaluating something the page claims is not enrolled, which
is the worst available outcome.

### Absent is not empty

The single most likely way to get this form wrong.

`signalChecksFor` returns the global list when `signalChecks` is **absent** and
an empty list — wait on nothing, every evaluation immediately final — when it is
**present and empty**. `blockingChecks` and `baseBranches` behave the same way.
A naive form that renders an empty tag input and writes `[]` silently changes
behaviour on every repository it touches.

So each of the three optional lists gets a paired control: a toggle
("Override the global list") and the list itself, shown only when the toggle is
on. Toggle off writes **no attribute at all**. Toggle on with an empty list
writes `[]` and the field's helper text says plainly what that means.

### Actions

| Action | Shown when | Notes |
|---|---|---|
| **Enroll** | Not enrolled | Form below. `PutItem` with `attribute_not_exists`. |
| **Edit** | Enrolled | Same form, pre-filled, version-checked. |
| **Pause** / **Resume** | Enrolled, `mode` shadow / off | Single-field update. Kept distinct from Unenroll. |
| **Unenroll** | Enrolled | Confirmation modal naming the repository. `DeleteItem`, version-checked. |

Form fields: `classification` (Select), `ciTrustTier` (Select), `mode`
(Select, default `shadow`), `stageEnabled` (Toggle, default off), and the three
override pairs.

Alongside the form, the page shows what Conductor **already knows** about the
repository — `repo_type`, `soc2_scope`, `archived`, `default_branch` — so
`classification` is chosen against the facts rather than from memory. These are
displayed, never written into the enrollment record: zapp reads SOC 2 scope and
resiliency tier from GitHub repository properties at evaluation time, and a
second copy here would be a second source of truth for a gate input.

### Links to zapp docs

A header link to `docs/policy.md`, plus per-field hints pointing at the gate
that reads the field — `classification` to gate 9 `classificationPermits`,
`ciTrustTier` to gate 10 `tierFloor`, the override lists to the completeness
model.

One caution: a hard-coded anchor into another repository's markdown is an
untested link. zapp's own anchor test (added with the report-legibility work)
covers `DOC_ANCHORS`; anchors outside that set are not covered. Deep-link only
to anchors zapp tests; link to the document otherwise.

### Authorization

A new Spatie permission, `manage auto-merge enrollment`, following the
`manage repos` pattern — `->authorize(...)` on every write action, view for
anyone who can reach the panel.

Distinct from `manage repos` because it decides what automation may do to a
repository, which is a different grant from editing inventory metadata.

Two steps, and the second is the one that gets forgotten: add it to the list in
`database/seeders/DatabaseSeeder.php` (fresh installs) **and** ship a migration
that `findOrCreate`s it and grants it to whichever roles already hold
`manage repos` (deployed environments, where the seeder does not run again).
There is precedent for permission-mutating migrations in
`database/migrations/2026_04_01_203624_drop_business_units_table_and_permission.php`.

### Feature flag

`config/features.php` already carries `external_writes`, defaulting to
production-only, for exactly this category of action.

Enrollment writes get their own flag rather than reusing it:

```php
'zapp_enrollment_writes' => env('ZAPP_ENROLLMENT_WRITES_ENABLED', true),
```

`external_writes` exists to stop non-production Conductor from mutating
*shared external* systems — GitHub, Auth0. Enrollment is not that: the qa
Conductor writes the qa account's table, which is the correct and desired
behaviour, and reusing `external_writes` would either block that or force the
flag on and unblock every other external write in qa. Default `true`, present so
there is a kill switch.

### The service seam

A single injectable service — `App\Services\Zapp\EnrollmentStore` — wrapping the
`aws/aws-sdk-php` DynamoDB client. `aws/aws-sdk-php` 3.388.8 is already a
dependency (S3, plus STS for break-glass); **this is conductor-api's first
DynamoDB usage**, so the client construction and endpoint override are new code
with no local precedent to copy.

The service is the mocking seam. conductor-api's Filament tests already mock
services this way — `$this->mock(RepoService::class, fn (MockInterface $m) => ...)`
in `tests/Feature/Filament/Resources/Repos/Pages/ListReposTest.php` — so the
page's tests need no AWS and no DynamoDB Local.

Config in `config/services.php`, wired through `infrastructure/terraform/env.tf`'s
`ecs_env_vars`:

```
ZAPP_ENROLLMENT_TABLE=zapp-enrollments
ZAPP_DYNAMODB_ENDPOINT=            # empty in deployed envs; set locally
```

## Widening the GitHub App, and the throughput it implies

This is the riskiest part of the work and it is not a code change.

Installation 156198964 is `repository_selection: selected`. Widening it to
`all` puts every one of the **1,112 repositories in the `bankrate` org** onto
the receiver's Function URL, for every subscribed event: `pull_request`,
`check_suite`, `push`, `check_run`, `status`, `merge_group`,
`merge_queue_entry`.

The current capacity, from `infrastructure/terraform/main.tf` and `vars.tf`:

| Setting | Value |
|---|---|
| `reserved_concurrent_executions` | **10**, shared by receiver and worker |
| SQS `maximum_concurrency` | 5 |
| SQS `batch_size` | 1 |
| Function timeout | 30 s |
| Memory | 256 MB |

Ten reserved executions is described in `vars.tf` as "ample for a webhook
receiver" — and it is, for eight repositories. The failure mode at 1,112 is
specific and bad: the receiver is synchronous with GitHub's delivery, so
throttling returns errors to GitHub, and GitHub disables a webhook that fails
persistently. The service would stop receiving anything, and the symptom would
be silence.

Three mitigations, all of which should land **before** the installation is
widened:

1. **Unsubscribe `status`.** It is in `KNOWN_UNROUTED` in `src/worker.ts:30`,
   subscribed for T8's benefit and routed nowhere today. It is also, on 1,112
   repositories, plausibly the highest-volume event of the seven. Dropping it at
   the App is free and reversible, and costs nothing until T8 needs it.
2. **Raise `reserved_concurrency`.** The value is already a variable; qa and prod
   set it per workspace.
3. **Add a Lambda `Throttles` alarm.** `alarms.tf` has exactly two alarms —
   `dlq-not-empty` and `invalid-signature-rate` — and neither fires on the
   failure above. Throttling is currently invisible.

Sequencing matters more than any of the individual numbers: the widening is the
**last** step of the rollout, after the drop path is live and its cost per
dropped delivery has been measured in qa.

Considered and rejected: moving the enrollment check into the receiver so
unenrolled deliveries never reach SQS. It would cut the volume further, but the
receiver's one architectural property is that it verifies and enqueues and does
nothing else — `src/worker.ts`'s header comment states it, and the design spec
argues it. Adding a DynamoDB read to the path that has to answer GitHub inside
its timeout trades a cheap, visible cost for a new way to fail at the front
door.

## Local validation

The requirement is to log in and use the page for real, the way the Portkey
reader/writer work was validated.

Local conductor-api runs on Herd with local MySQL; `docker-compose.yml` today
runs only `mailpit`.

1. Add a `dynamodb-local` service (`amazon/dynamodb-local`) on **port 8001** —
   8000 is `php artisan serve`.
2. `.env` gets `ZAPP_DYNAMODB_ENDPOINT=http://localhost:8001` and
   `ZAPP_ENROLLMENT_TABLE=zapp-enrollments`; `.env.example` documents both.
3. `php artisan zapp:enrollment-seed` creates the table and writes the eight
   records currently in `policy-rules.yaml`.
4. **The same command ensures a `repos` row exists for each of the eight.**
   Without it every seeded record renders in the orphan section and the main
   table shows nothing enrolled — which is a correct rendering of an empty
   inventory and a confusing first impression.

Then: log in at `http://127.0.0.1:8000/admin`, open Inventory → Auto-Merge, and
enroll, edit, pause, and unenroll a repository, with `ZAPP_ENROLLMENT_WRITES_ENABLED`
on and every write landing in DynamoDB Local. Nothing points at qa.

Order matters, as it did for Portkey: **log in before seeding**, so the session
is established against a database the seed does not then replace.

## Rollout sequence

The constraint is that there must be no window in which zapp reads an authority
that is empty.

1. **Terraform:** create `zapp-enrollments`; grant zapp read, conductor
   read/write. Nothing consumes it yet.
2. **Seed:** one-off idempotent script writes the eight YAML records into the
   table. It **asserts parity** against the compiled `POLICY.repos` and refuses
   to run on any mismatch.
3. **zapp reads the table.** `repos:` is still in the YAML at this point, unread.
   Verify in qa that evaluations still happen for the eight and that eval records
   carry the new `enrollment` snapshot.
4. **Delete `repos:`** from `policy-rules.yaml`; `build-rules.mjs` rejects the
   key so it cannot quietly return.
5. **Conductor page ships.**
6. **Unsubscribe `status`, raise concurrency, add the Throttles alarm.**
7. **Widen the installation to `all`** and watch.

Step 3 uses a one-off parity assertion rather than a runtime dual-read on
purpose. A dual-read is a second source of truth consulted only when nobody is
looking, which is the thing step 4 exists to remove.

## Testing

### zapp

Rewritten: `tests/enrollment.test.ts` — against a fake `DynamoSender`, no AWS.

The tests that carry the design:

- A failed read **throws**. It does not return `undefined` and it does not drop
  the delivery. This is the one that stops a future refactor from turning a
  fleet-wide outage into a silent one.
- An absent item drops the delivery **without claiming** it — asserted on the
  fake's call log, because "we did not write" is the actual claim.
- `mode: off` drops, and is distinguishable in the log from absent.
- `fleetSize` paginates: a fake returning `LastEvaluatedKey` on the first page
  must produce the summed count, not the first page's.
- `fleetSize` is **not called** for a non-candidate — the `Query` must not
  happen on the common path.

Touched by the signature changes: `tests/worker.test.ts` (`isEnrolled` →
`lookupEnrollment`, and the new claim ordering), `tests/gates.test.ts` and
`tests/render.test.ts` (both call `enrollmentFor(DEMO)` against `POLICY.repos`,
which no longer exists — they take a local fixture record),
`tests/evaluate.test.ts` (new parameter),
`tests/signals-internal-confidence.test.ts` (`fleetSize` async),
`tests/build-rules.test.ts` (a `repos:` key now fails the build),
`tests/ledger.test.ts` (the snapshot is written).

### conductor-api

`tests/Feature/Filament/Pages/AutoMergeTest.php`, PHPUnit with `#[Test]`,
`RefreshDatabase`, `Livewire::test()`, and `EnrollmentStore` mocked via
`$this->mock()` — matching `ListReposTest.php`.

- The table renders enrolled and unenrolled repositories, joined on
  `CONCAT(owner, '/', name)`.
- An orphan record — enrolled, no `repos` row — renders in its own section and
  can be unenrolled.
- **Toggling the override off writes no `signalChecks` attribute**; toggling it
  on with an empty list writes `[]`. Two tests, because the whole point is that
  these are different writes.
- A user without `manage auto-merge enrollment` sees no write actions.
- `ConditionalCheckFailedException` surfaces as a notification and does not
  retry.
- `ZAPP_ENROLLMENT_WRITES_ENABLED=false` disables the write actions.
- Enroll, edit, pause and unenroll each write a history record with the acting
  user.

## Docs to update

Enrollment's source of truth is asserted in more places than is obvious.

**zapp**

| File | What |
|---|---|
| `README.md` | Lines 11, 44-45, 62-64: "read from `policy-rules.yaml`", "eight repositories", and the "not yet the real registry" caveat that this work closes. |
| `docs/architecture.md` | The "Enrollment (minimal slice, not the real registry)" section (113-122) is rewritten. Line 337's source-of-truth claim. Lines 12, 82, 121 on `repository_selection: selected`. |
| `docs/call-flows.md` | Four sequence diagrams name `src/enrollment.ts isEnrolled()` as a participant (17, 350, 448) with the calls at 37, 367, 461, plus prose at 84-85, 142-144, 411, 492. The claim ordering changes in each. |
| `docs/policy.md` | Line 40: gate 1's description says "has an entry in `policy-rules.yaml`". Line 336. |
| `policy-rules.yaml` | The header comment describes the file as the source of truth for enrollment. |

**conductor-api**

`infrastructure/terraform/README.md` for the new environment variables.

**Jira**

PLAT-1188's description and acceptance criteria, per the section above.

## Out of scope

- `mode: 'enforce'`. Phase 0 is shadow; the enum stays `shadow | off`.
- Bulk enrollment. Eight repositories and a form is not a problem yet.
- A MySQL read model for sorting and filtering on enrollment columns.
- Exposing enrollment through Conductor's API or MCP surface. The page is the
  interface; an API is a separate decision about who else may write.
- T8's required-checks snapshot, which is why `status` can be unsubscribed now.
- Teaching the weekly report about the `enrollment` field.

## Risks

| Risk | Handling |
|---|---|
| Enrollment read becomes a fleet-wide single point of failure. | Fail loud, not silent: throw → DLQ → existing alarm. Accepted deliberately; the alternatives are a silent hole in the corpus or evaluating 1,112 repos. |
| Widening the App throttles the receiver and GitHub disables the webhook. | Unsubscribe `status`, raise concurrency, add a Throttles alarm — all before widening, which is the last step. |
| A form writes `[]` where it meant "absent", changing check-waiting behaviour fleet-wide. | Paired override toggles, and two tests asserting the two writes differ. |
| The permission migration is forgotten and nobody can use the page in prod. | Migration, not just the seeder; called out in the plan as its own step. |
| Conductor becomes a control-plane host for another service, which the "conductor is a data source, never a host" rule pushes against. | Accepted, and worth naming: Break Glass and the Security Dashboard are already Conductor-hosted platform *controls*, not inventory views. Portkey, by contrast, is a sidebar link to a separate app (`AdminPanelProvider.php:59`), so this is genuinely a new pattern for a datastore Conductor does not own. The narrow grant — this one table, no access to `zapp-evaluations` — is what keeps it a control surface rather than an owner. |
| The local conductor-api clone is 211 commits behind `origin/main` on branch `fix/skip-default-branch-plan-comment`. | The plan's first step verifies the base. Everything in this spec was read from `origin/main`, not the working tree. |
