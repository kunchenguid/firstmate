# Enrollment Registry (Conductor UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Inventory → Auto-Merge page to conductor-api that lists every repository and lets an operator enroll, modify, pause and unenroll it in zapp's merge-policy service, writing the `zapp-enrollments` DynamoDB table.

**Architecture:** A Filament v5 **Page** (not a Resource — enrollment is not in MySQL) carrying a table over the `Repo` Eloquent model, with enrollment state joined in from one DynamoDB `Query` per request. A single injectable `EnrollmentStore` service owns all DynamoDB access and is the mocking seam for tests. Every write is a `TransactWriteItems` pairing the record change with an append-only history row, conditioned on the record's `version`, so an unaudited or clobbering change is structurally impossible.

**Tech Stack:** PHP 8.3 / Laravel, Filament v5, `aws/aws-sdk-php` 3.388.8 (already a dependency), `spatie/laravel-data`, `spatie/laravel-permission`, PHPUnit with `#[Test]` attributes + Livewire testing, DynamoDB Local via docker-compose.

**Spec:** `docs/superpowers/zapp/specs/2026-08-28-enrollment-registry-and-conductor-ui-design.md`

**Companion plan:** `docs/superpowers/zapp/plans/2026-08-28-enrollment-registry-zapp.md`. That plan's **Task 1** fixes the table schema and must be done first. Everything after that is independent — this plan develops against DynamoDB Local and needs nothing else from zapp.

## Global Constraints

- **Table:** `zapp-enrollments`. Same name in every environment; the AWS account disambiguates. conductor-api's `development` account (`194918977890`) is zapp's `qa`, and `production` (`835272777014`) is zapp's `prod` — **the same accounts**, so no cross-account role is needed.
- **Enrollment records:** `pk = "repo"`, `sk = "{owner}/{repo}"`.
- **History records:** `pk = "history#{owner}/{repo}"`, `sk = "{ISO8601}#{version}"`.
- **The join key is `CONCAT(owner, '/', name)`.** The `repos` table has no `full_name` column.
- **Absent is not empty.** `signalChecks`, `blockingChecks` and `baseBranches` absent means "use zapp's global list"; present-and-empty means "use nothing". A write must be able to express both.
- **Every write is a transaction** pairing the record with its history row, conditioned on `version`. A conditional failure means another operator changed it — surface it, never retry.
- **Writes are permission-gated** on a new `manage auto-merge enrollment` Spatie permission and feature-flagged on `features.zapp_enrollment_writes`.
- **Never write gate inputs Conductor already knows.** `soc2_scope`, resiliency tier and repo type are *displayed* to inform the operator; zapp reads its own from GitHub repository properties at evaluation time.
- Conventional Commits (`commitlint` runs in CI).
- Run `php artisan test` and `vendor/bin/pint --test` before every commit.

---

### Task 1: The `EnrollmentStore` service

All DynamoDB access, behind one injectable class. This is conductor-api's **first** DynamoDB usage — there is no local precedent to copy for client construction.

**Files:**
- Create: `app/Data/Zapp/EnrollmentData.php`
- Create: `app/Services/Zapp/EnrollmentStore.php`
- Create: `app/Exceptions/EnrollmentConflictException.php`
- Modify: `config/services.php` (append a `zapp` block)
- Create: `tests/Feature/Services/Zapp/EnrollmentStoreTest.php`

**Interfaces:**
- Consumes: the table schema from the zapp plan's Task 1.
- Produces:
  - `EnrollmentData` — `repo`, `classification`, `ciTrustTier`, `mode`, `stageEnabled`, `?signalChecks`, `?blockingChecks`, `?baseBranches`, `version`, `updatedBy`, `updatedAt`
  - `EnrollmentStore::fleet(): Collection` — keyed by repo full name
  - `EnrollmentStore::find(string $repo): ?EnrollmentData`
  - `EnrollmentStore::create(EnrollmentData $data, string $actor): void`
  - `EnrollmentStore::replace(EnrollmentData $data, int $expectedVersion, string $actor, string $action): void`
  - `EnrollmentStore::delete(string $repo, int $expectedVersion, string $actor): void`
  - `EnrollmentConflictException`

- [ ] **Step 1: Verify the base**

The local clone was last seen 211 commits behind `origin/main` on branch `fix/skip-default-branch-plan-comment`. Do not build on that.

```bash
cd ~/Projects/conductor-api
git fetch origin
git status --porcelain
git rev-list --count HEAD..origin/main
```

Expected: clean tree, `0` behind. If not, `git checkout main && git pull --ff-only`, then `composer install && npm i` — `composer.json` has moved since (Filament v5, Scorecards).

Confirm the two facts this plan depends on:

```bash
grep -n "filament/filament\|aws/aws-sdk-php" composer.json
grep -rn "DynamoDb" app/ config/ | wc -l
```

Expected: Filament `^5.0`, aws-sdk `^3.341`, and `0` existing DynamoDB references.

- [ ] **Step 2: Write the failing tests**

Create `tests/Feature/Services/Zapp/EnrollmentStoreTest.php`. These tests assert on the **commands built**, using a stubbed AWS client, so they need no network and no DynamoDB Local:

```php
<?php

namespace Tests\Feature\Services\Zapp;

use App\Data\Zapp\EnrollmentData;
use App\Exceptions\EnrollmentConflictException;
use App\Services\Zapp\EnrollmentStore;
use Aws\DynamoDb\DynamoDbClient;
use Aws\Exception\AwsException;
use Aws\Result;
use Mockery;
use Mockery\MockInterface;
use PHPUnit\Framework\Attributes\Test;
use Tests\TestCase;

class EnrollmentStoreTest extends TestCase
{
    private const ACTOR = 'scrosby@bankrate.com';

    /** One stored item, in the AttributeValue shape DynamoDB returns. */
    private function item(array $over = []): array
    {
        return array_merge([
            'pk' => ['S' => 'repo'],
            'sk' => ['S' => 'bankrate/portkey'],
            'repo' => ['S' => 'bankrate/portkey'],
            'classification' => ['S' => 'prod-service'],
            'ciTrustTier' => ['N' => '2'],
            'mode' => ['S' => 'shadow'],
            'stageEnabled' => ['BOOL' => false],
            'version' => ['N' => '3'],
            'updatedBy' => ['S' => self::ACTOR],
            'updatedAt' => ['S' => '2026-08-28T12:00:00+00:00'],
        ], $over);
    }

    private function data(array $over = []): EnrollmentData
    {
        return EnrollmentData::from(array_merge([
            'repo' => 'bankrate/portkey',
            'classification' => 'prod-service',
            'ciTrustTier' => 2,
            'mode' => 'shadow',
            'stageEnabled' => false,
            'signalChecks' => null,
            'blockingChecks' => null,
            'baseBranches' => null,
            'version' => 3,
            'updatedBy' => self::ACTOR,
            'updatedAt' => '2026-08-28T12:00:00+00:00',
        ], $over));
    }

    #[Test]
    public function the_fleet_is_one_query_over_the_shared_partition_keyed_by_repo(): void
    {
        $captured = null;

        $this->mock(DynamoDbClient::class, function (MockInterface $mock) use (&$captured): void {
            $mock->shouldReceive('query')
                ->once()
                ->andReturnUsing(function (array $args) use (&$captured): Result {
                    $captured = $args;

                    return new Result(['Items' => [$this->item()]]);
                });
        });

        $fleet = app(EnrollmentStore::class)->fleet();

        $this->assertSame('zapp-enrollments', $captured['TableName']);
        $this->assertSame('pk = :pk', $captured['KeyConditionExpression']);
        $this->assertSame(['S' => 'repo'], $captured['ExpressionAttributeValues'][':pk']);
        $this->assertTrue($captured['ConsistentRead']);
        $this->assertSame(['bankrate/portkey'], $fleet->keys()->all());
        $this->assertSame('prod-service', $fleet->get('bankrate/portkey')->classification);
        $this->assertSame(3, $fleet->get('bankrate/portkey')->version);
    }

    #[Test]
    public function the_fleet_query_follows_last_evaluated_key(): void
    {
        $this->mock(DynamoDbClient::class, function (MockInterface $mock): void {
            $mock->shouldReceive('query')
                ->twice()
                ->andReturn(
                    new Result([
                        'Items' => [$this->item(['sk' => ['S' => 'bankrate/a'], 'repo' => ['S' => 'bankrate/a']])],
                        'LastEvaluatedKey' => ['pk' => ['S' => 'repo'], 'sk' => ['S' => 'bankrate/a']],
                    ]),
                    new Result([
                        'Items' => [$this->item(['sk' => ['S' => 'bankrate/b'], 'repo' => ['S' => 'bankrate/b']])],
                    ]),
                );
        });

        $fleet = app(EnrollmentStore::class)->fleet();

        $this->assertSame(['bankrate/a', 'bankrate/b'], $fleet->keys()->all());
    }

    #[Test]
    public function an_absent_override_reads_as_null_not_as_an_empty_array(): void
    {
        $this->mock(DynamoDbClient::class, function (MockInterface $mock): void {
            $mock->shouldReceive('query')->once()->andReturn(new Result(['Items' => [$this->item()]]));
        });

        $record = app(EnrollmentStore::class)->fleet()->get('bankrate/portkey');

        $this->assertNull($record->signalChecks, 'absent means "use zapp\'s global list"');
    }

    #[Test]
    public function a_present_but_empty_override_reads_as_an_empty_array(): void
    {
        $this->mock(DynamoDbClient::class, function (MockInterface $mock): void {
            $mock->shouldReceive('query')->once()
                ->andReturn(new Result(['Items' => [$this->item(['signalChecks' => ['L' => []]])]]));
        });

        $record = app(EnrollmentStore::class)->fleet()->get('bankrate/portkey');

        $this->assertSame([], $record->signalChecks, 'empty means "wait on nothing" — a different fact');
    }

    #[Test]
    public function create_writes_the_record_and_its_history_in_one_transaction(): void
    {
        $captured = null;

        $this->mock(DynamoDbClient::class, function (MockInterface $mock) use (&$captured): void {
            $mock->shouldReceive('transactWriteItems')
                ->once()
                ->andReturnUsing(function (array $args) use (&$captured): Result {
                    $captured = $args;

                    return new Result([]);
                });
        });

        app(EnrollmentStore::class)->create($this->data(['version' => 1]), self::ACTOR);

        $this->assertCount(2, $captured['TransactItems'], 'a record change without a history row is an unaudited change');

        [$record, $history] = $captured['TransactItems'];

        $this->assertSame('attribute_not_exists(sk)', $record['Put']['ConditionExpression']);
        $this->assertSame(['S' => 'repo'], $record['Put']['Item']['pk']);
        $this->assertSame(['N' => '1'], $record['Put']['Item']['version']);
        $this->assertSame(['S' => self::ACTOR], $record['Put']['Item']['enrolledBy']);

        $this->assertSame(['S' => 'history#bankrate/portkey'], $history['Put']['Item']['pk']);
        $this->assertSame(['S' => 'enroll'], $history['Put']['Item']['action']);
        $this->assertSame(['S' => self::ACTOR], $history['Put']['Item']['actor']);
    }

    #[Test]
    public function create_omits_an_override_attribute_entirely_when_it_is_null(): void
    {
        $captured = null;

        $this->mock(DynamoDbClient::class, function (MockInterface $mock) use (&$captured): void {
            $mock->shouldReceive('transactWriteItems')->once()
                ->andReturnUsing(function (array $args) use (&$captured): Result {
                    $captured = $args;

                    return new Result([]);
                });
        });

        app(EnrollmentStore::class)->create($this->data(['version' => 1]), self::ACTOR);

        $item = $captured['TransactItems'][0]['Put']['Item'];
        $this->assertArrayNotHasKey('signalChecks', $item, 'writing [] would silently mean "wait on nothing"');
        $this->assertArrayNotHasKey('blockingChecks', $item);
        $this->assertArrayNotHasKey('baseBranches', $item);
    }

    #[Test]
    public function create_writes_an_empty_list_when_the_override_is_an_empty_array(): void
    {
        $captured = null;

        $this->mock(DynamoDbClient::class, function (MockInterface $mock) use (&$captured): void {
            $mock->shouldReceive('transactWriteItems')->once()
                ->andReturnUsing(function (array $args) use (&$captured): Result {
                    $captured = $args;

                    return new Result([]);
                });
        });

        app(EnrollmentStore::class)->create($this->data(['version' => 1, 'signalChecks' => []]), self::ACTOR);

        $this->assertSame(['L' => []], $captured['TransactItems'][0]['Put']['Item']['signalChecks']);
    }

    #[Test]
    public function replace_conditions_on_the_expected_version_and_bumps_it(): void
    {
        $captured = null;

        $this->mock(DynamoDbClient::class, function (MockInterface $mock) use (&$captured): void {
            $mock->shouldReceive('transactWriteItems')->once()
                ->andReturnUsing(function (array $args) use (&$captured): Result {
                    $captured = $args;

                    return new Result([]);
                });
        });

        app(EnrollmentStore::class)->replace($this->data(), 3, self::ACTOR, 'update');

        $record = $captured['TransactItems'][0]['Put'];
        $this->assertSame('version = :expected', $record['ConditionExpression']);
        $this->assertSame(['N' => '3'], $record['ExpressionAttributeValues'][':expected']);
        $this->assertSame(['N' => '4'], $record['Item']['version'], 'the write bumps the version it wrote');
        $this->assertSame(['S' => 'update'], $captured['TransactItems'][1]['Put']['Item']['action']);
        $this->assertSame(['N' => '4'], $captured['TransactItems'][1]['Put']['Item']['version'],
            'the history row records the version the write produced, so history and record agree');
    }

    #[Test]
    public function a_cancelled_transaction_becomes_a_conflict_exception(): void
    {
        $this->mock(DynamoDbClient::class, function (MockInterface $mock): void {
            $mock->shouldReceive('transactWriteItems')->once()->andThrow(
                new AwsException('cancelled', Mockery::mock(\Aws\CommandInterface::class), [
                    'code' => 'TransactionCanceledException',
                    'message' => 'Transaction cancelled, please refer cancellation reasons',
                ]),
            );
        });

        $this->expectException(EnrollmentConflictException::class);

        app(EnrollmentStore::class)->replace($this->data(), 3, self::ACTOR, 'update');
    }

    #[Test]
    public function delete_records_the_prior_state_as_history_before_removing_it(): void
    {
        $captured = null;

        $this->mock(DynamoDbClient::class, function (MockInterface $mock) use (&$captured): void {
            $mock->shouldReceive('getItem')->once()->andReturn(new Result(['Item' => $this->item()]));
            $mock->shouldReceive('transactWriteItems')->once()
                ->andReturnUsing(function (array $args) use (&$captured): Result {
                    $captured = $args;

                    return new Result([]);
                });
        });

        app(EnrollmentStore::class)->delete('bankrate/portkey', 3, self::ACTOR);

        [$record, $history] = $captured['TransactItems'];
        $this->assertSame('version = :expected', $record['Delete']['ConditionExpression']);
        $this->assertSame(['S' => 'unenroll'], $history['Put']['Item']['action']);
        $this->assertArrayHasKey('before', $history['Put']['Item']);
        $this->assertArrayNotHasKey('after', $history['Put']['Item'], 'there is no after state for a deletion');
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
php artisan test --filter=EnrollmentStoreTest
```

Expected: FAIL — `App\Services\Zapp\EnrollmentStore` does not exist.

- [ ] **Step 4: Add the config block**

Append to `config/services.php`, before the closing `];`:

```php
    'zapp' => [
        // The merge-policy service's enrollment registry. Same table name in
        // every environment; the AWS account disambiguates. conductor-api's
        // `development` account IS zapp's `qa` account (194918977890) and
        // `production` IS zapp's `prod` (835272777014), so no cross-account
        // role is involved — the ECS task role is granted directly.
        'enrollment_table' => env('ZAPP_ENROLLMENT_TABLE', 'zapp-enrollments'),

        // Set only for local development against DynamoDB Local. Empty in every
        // deployed environment, where the SDK resolves the real endpoint.
        'dynamodb_endpoint' => env('ZAPP_DYNAMODB_ENDPOINT'),
    ],
```

- [ ] **Step 5: Write the data object**

Create `app/Data/Zapp/EnrollmentData.php`:

```php
<?php

namespace App\Data\Zapp;

use Spatie\LaravelData\Data;

/**
 * One repository's enrollment in zapp's merge-policy service.
 *
 * The three override lists are nullable ON PURPOSE, and null is not the same as
 * an empty array. zapp's `signalChecksFor` returns its GLOBAL list when the
 * attribute is absent and an EMPTY list — wait on nothing, every evaluation
 * immediately final — when it is present and empty. Collapsing the two here
 * would silently change check-waiting behaviour on every repository written.
 */
class EnrollmentData extends Data
{
    public function __construct(
        public string $repo,
        public string $classification,
        public int $ciTrustTier,
        public string $mode,
        public bool $stageEnabled,
        /** @var array<int, string>|null Null = use zapp's global list. [] = wait on nothing. */
        public ?array $signalChecks,
        /** @var array<int, string>|null Null = use zapp's global list. [] = nothing blocks. */
        public ?array $blockingChecks,
        /** @var array<int, string>|null Null = the default branch only. */
        public ?array $baseBranches,
        public int $version,
        public string $updatedBy,
        public string $updatedAt,
    ) {}

    /** Whether zapp will actively evaluate this repository. */
    public function isActive(): bool
    {
        return $this->mode === 'shadow';
    }
}
```

- [ ] **Step 6: Write the conflict exception**

Create `app/Exceptions/EnrollmentConflictException.php`:

```php
<?php

namespace App\Exceptions;

use RuntimeException;

/**
 * Another operator changed the enrollment record while this form was open.
 *
 * NOT retried. Last-write-wins on a control that decides what automation may
 * touch production would silently discard somebody's deliberate change.
 */
class EnrollmentConflictException extends RuntimeException
{
    public static function forRepo(string $repo): self
    {
        return new self("The enrollment for {$repo} changed while you were editing it.");
    }
}
```

- [ ] **Step 7: Write the store**

Create `app/Services/Zapp/EnrollmentStore.php`:

```php
<?php

namespace App\Services\Zapp;

use App\Data\Zapp\EnrollmentData;
use App\Exceptions\EnrollmentConflictException;
use Aws\DynamoDb\DynamoDbClient;
use Aws\Exception\AwsException;
use Illuminate\Support\Collection;

/**
 * Read and write zapp's enrollment registry.
 *
 * The only DynamoDB access in this application, and the mocking seam for the
 * Auto-Merge page's tests.
 *
 * TWO INVARIANTS, both structural rather than conventional:
 *
 * 1. Every write is a TransactWriteItems pairing the record change with an
 *    append-only history row. A record change with no history row is an
 *    unaudited change to what automation may do to production.
 * 2. Every write is conditioned — `attribute_not_exists(sk)` to create,
 *    `version = :expected` otherwise. A cancelled transaction is surfaced, not
 *    retried.
 */
class EnrollmentStore
{
    /** Every enrollment record shares this partition, so the fleet is one Query. */
    private const FLEET_PK = 'repo';

    public function __construct(private readonly DynamoDbClient $client) {}

    private function table(): string
    {
        return config('services.zapp.enrollment_table');
    }

    /**
     * Every enrollment record, keyed by `owner/repo`.
     *
     * PAGINATES on LastEvaluatedKey. The table holds one item per ENROLLED
     * repository — eight today, not one per org repo — so the 1 MB limit is far
     * away, but a truncated read here would understate enrollment and the page
     * would offer to enroll a repository that already is.
     */
    public function fleet(): Collection
    {
        $records = collect();
        $startKey = null;

        do {
            $args = [
                'TableName' => $this->table(),
                'KeyConditionExpression' => 'pk = :pk',
                'ExpressionAttributeValues' => [':pk' => ['S' => self::FLEET_PK]],
                'ConsistentRead' => true,
            ];

            if ($startKey !== null) {
                $args['ExclusiveStartKey'] = $startKey;
            }

            $result = $this->client->query($args);

            foreach ($result['Items'] ?? [] as $item) {
                $record = $this->fromItem($item);
                $records->put($record->repo, $record);
            }

            $startKey = $result['LastEvaluatedKey'] ?? null;
        } while ($startKey !== null);

        return $records;
    }

    /** One repository's enrollment, or null when it has none. */
    public function find(string $repo): ?EnrollmentData
    {
        $result = $this->client->getItem([
            'TableName' => $this->table(),
            'Key' => ['pk' => ['S' => self::FLEET_PK], 'sk' => ['S' => $repo]],
            'ConsistentRead' => true,
        ]);

        $item = $result['Item'] ?? null;

        return $item === null ? null : $this->fromItem($item);
    }

    /** Enroll a repository that has no record. `$data->version` is ignored; creation is always version 1. */
    public function create(EnrollmentData $data, string $actor): void
    {
        $now = now()->toIso8601String();
        $item = $this->toItem($data, 1, $actor, $now);
        $item['enrolledBy'] = ['S' => $actor];
        $item['enrolledAt'] = ['S' => $now];

        $this->transact($data->repo, [
            [
                'Put' => [
                    'TableName' => $this->table(),
                    'Item' => $item,
                    // Refuses to overwrite. Two operators enrolling the same
                    // repository at once: exactly one succeeds.
                    'ConditionExpression' => 'attribute_not_exists(sk)',
                ],
            ],
            $this->historyPut($data->repo, 'enroll', 1, $actor, $now, null, $data),
        ]);
    }

    /**
     * Replace an existing record.
     *
     * Args:
     *   data: The new state. Its `version` field is not read.
     *   expectedVersion: The version the form was filled from.
     *   actor: The acting user's email.
     *   action: `update`, `pause` or `resume` — recorded in the history row.
     */
    public function replace(EnrollmentData $data, int $expectedVersion, string $actor, string $action): void
    {
        $before = $this->find($data->repo);
        $now = now()->toIso8601String();
        $nextVersion = $expectedVersion + 1;

        $this->transact($data->repo, [
            [
                'Put' => [
                    'TableName' => $this->table(),
                    'Item' => $this->toItem($data, $nextVersion, $actor, $now),
                    'ConditionExpression' => 'version = :expected',
                    'ExpressionAttributeValues' => [':expected' => ['N' => (string) $expectedVersion]],
                ],
            ],
            $this->historyPut($data->repo, $action, $nextVersion, $actor, $now, $before, $data),
        ]);
    }

    /** Remove a record. The history row keeps the deletion auditable. */
    public function delete(string $repo, int $expectedVersion, string $actor): void
    {
        $before = $this->find($repo);
        $now = now()->toIso8601String();

        $this->transact($repo, [
            [
                'Delete' => [
                    'TableName' => $this->table(),
                    'Key' => ['pk' => ['S' => self::FLEET_PK], 'sk' => ['S' => $repo]],
                    'ConditionExpression' => 'version = :expected',
                    'ExpressionAttributeValues' => [':expected' => ['N' => (string) $expectedVersion]],
                ],
            ],
            $this->historyPut($repo, 'unenroll', $expectedVersion + 1, $actor, $now, $before, null),
        ]);
    }

    /**
     * Run a two-item transaction, translating a cancellation into a conflict.
     *
     * A failed ConditionExpression inside TransactWriteItems surfaces as
     * `TransactionCanceledException`, NOT `ConditionalCheckFailedException` —
     * catching the latter here would let a clobbering write look like a success.
     */
    private function transact(string $repo, array $items): void
    {
        try {
            $this->client->transactWriteItems(['TransactItems' => $items]);
        } catch (AwsException $e) {
            if ($e->getAwsErrorCode() === 'TransactionCanceledException') {
                throw EnrollmentConflictException::forRepo($repo);
            }

            throw $e;
        }
    }

    /** Build one history row. `before` is null on enroll; `after` is null on unenroll. */
    private function historyPut(
        string $repo,
        string $action,
        int $version,
        string $actor,
        string $at,
        ?EnrollmentData $before,
        ?EnrollmentData $after,
    ): array {
        $item = [
            // A partition per repository, NOT the shared fleet partition —
            // history rows sharing it would appear in every fleet read.
            'pk' => ['S' => "history#{$repo}"],
            // The version suffix is not decoration: two writes in the same
            // millisecond would collide on the timestamp alone.
            'sk' => ['S' => "{$at}#{$version}"],
            'action' => ['S' => $action],
            'actor' => ['S' => $actor],
            'at' => ['S' => $at],
            'version' => ['N' => (string) $version],
        ];

        if ($before !== null) {
            $item['before'] = ['S' => $before->toJson()];
        }

        if ($after !== null) {
            $item['after'] = ['S' => $after->toJson()];
        }

        return ['Put' => ['TableName' => $this->table(), 'Item' => $item]];
    }

    /** Marshal a record. An override that is null writes NO attribute at all. */
    private function toItem(EnrollmentData $data, int $version, string $actor, string $at): array
    {
        $item = [
            'pk' => ['S' => self::FLEET_PK],
            'sk' => ['S' => $data->repo],
            'repo' => ['S' => $data->repo],
            'classification' => ['S' => $data->classification],
            'ciTrustTier' => ['N' => (string) $data->ciTrustTier],
            'mode' => ['S' => $data->mode],
            'stageEnabled' => ['BOOL' => $data->stageEnabled],
            'version' => ['N' => (string) $version],
            'updatedBy' => ['S' => $actor],
            'updatedAt' => ['S' => $at],
        ];

        foreach (['signalChecks', 'blockingChecks', 'baseBranches'] as $field) {
            $value = $data->{$field};

            // Null is skipped, [] is written. zapp reads an absent attribute as
            // "use the global list" and an empty one as "use nothing".
            if ($value !== null) {
                $item[$field] = ['L' => array_map(fn (string $s): array => ['S' => $s], $value)];
            }
        }

        return $item;
    }

    /** Unmarshal a record. A missing override attribute becomes null, never []. */
    private function fromItem(array $item): EnrollmentData
    {
        $list = function (?array $attr): ?array {
            if ($attr === null) {
                return null;
            }

            return array_map(fn (array $v): string => $v['S'], $attr['L'] ?? []);
        };

        return new EnrollmentData(
            repo: $item['repo']['S'],
            classification: $item['classification']['S'],
            ciTrustTier: (int) $item['ciTrustTier']['N'],
            mode: $item['mode']['S'],
            stageEnabled: (bool) ($item['stageEnabled']['BOOL'] ?? false),
            signalChecks: $list($item['signalChecks'] ?? null),
            blockingChecks: $list($item['blockingChecks'] ?? null),
            baseBranches: $list($item['baseBranches'] ?? null),
            version: (int) $item['version']['N'],
            updatedBy: $item['updatedBy']['S'] ?? 'unknown',
            updatedAt: $item['updatedAt']['S'] ?? 'unknown',
        );
    }
}
```

- [ ] **Step 8: Bind the client**

In `app/Providers/AppServiceProvider.php`'s `register()` method, add:

```php
        $this->app->singleton(DynamoDbClient::class, function (): DynamoDbClient {
            $config = [
                'region' => config('services.aws.region', env('AWS_DEFAULT_REGION', 'us-east-1')),
                'version' => 'latest',
            ];

            // Local development points at DynamoDB Local. Deployed environments
            // leave this unset and the SDK resolves the real endpoint from the
            // task role's region.
            if ($endpoint = config('services.zapp.dynamodb_endpoint')) {
                $config['endpoint'] = $endpoint;
                // DynamoDB Local rejects a request with no credentials at all,
                // and does not check them. The ECS task role supplies real ones.
                $config['credentials'] = ['key' => 'local', 'secret' => 'local'];
            }

            return new DynamoDbClient($config);
        });
```

Add `use Aws\DynamoDb\DynamoDbClient;` to the file's imports.

Read `AppServiceProvider.php` first — it already registers policies in `boot()` (line ~112). Put this in `register()`, not `boot()`.

- [ ] **Step 9: Run the tests to verify they pass**

```bash
php artisan test --filter=EnrollmentStoreTest
vendor/bin/pint --test app/Services/Zapp app/Data/Zapp app/Exceptions/EnrollmentConflictException.php
```

Expected: PASS, and Pint clean.

- [ ] **Step 10: Commit**

```bash
git add app/Services/Zapp app/Data/Zapp app/Exceptions/EnrollmentConflictException.php \
        app/Providers/AppServiceProvider.php config/services.php tests/Feature/Services/Zapp
git commit -m "feat(zapp): add the enrollment store backed by zapp-enrollments"
```

---

### Task 2: The permission and the feature flag

Small, and the migration half is the part that gets forgotten — without it the page ships and nobody in production can use it.

**Files:**
- Modify: `config/features.php`
- Modify: `database/seeders/DatabaseSeeder.php:57-70`
- Create: `database/migrations/2026_08_28_120000_add_manage_auto_merge_enrollment_permission.php`
- Modify: `.env.example`
- Create: `tests/Feature/Permissions/AutoMergeEnrollmentPermissionTest.php`

**Interfaces:**
- Produces: the `manage auto-merge enrollment` permission; `config('features.zapp_enrollment_writes')`.

- [ ] **Step 1: Write the failing test**

Create `tests/Feature/Permissions/AutoMergeEnrollmentPermissionTest.php`:

```php
<?php

namespace Tests\Feature\Permissions;

use Illuminate\Foundation\Testing\RefreshDatabase;
use PHPUnit\Framework\Attributes\Test;
use Spatie\Permission\Models\Permission;
use Spatie\Permission\Models\Role;
use Tests\TestCase;

class AutoMergeEnrollmentPermissionTest extends TestCase
{
    use RefreshDatabase;

    #[Test]
    public function the_migration_creates_the_permission(): void
    {
        // RefreshDatabase runs migrations and NOT seeders, so this passes only
        // if the permission comes from a migration. That is the point: the
        // seeder alone would leave deployed environments without it.
        $this->assertTrue(
            Permission::where('name', 'manage auto-merge enrollment')->exists(),
        );
    }

    #[Test]
    public function roles_that_already_manage_repos_inherit_it(): void
    {
        $role = Role::findOrCreate('platform-admin');
        $role->givePermissionTo(Permission::findOrCreate('manage repos'));

        // Calls the named helper the migration delegates to, rather than
        // re-running migrations — Laravel migrations are anonymous classes, and
        // `migrate:refresh` would drop the role this test just created.
        AutoMergePermission::grantToRepoManagers();

        app(PermissionRegistrar::class)->forgetCachedPermissions();

        $this->assertTrue(
            Role::findByName('platform-admin')->hasPermissionTo(AutoMergePermission::NAME),
            'a deployed environment must not need a manual grant before anyone can use the page',
        );
    }

    #[Test]
    public function writes_are_enabled_by_default(): void
    {
        $this->assertTrue(
            config('features.zapp_enrollment_writes'),
            'unlike external_writes, this one defaults on — the qa Conductor writing the qa table is correct',
        );
    }
}
```

Add these two imports to the test's `use` block alongside the others:

```php
use App\Support\AutoMergePermission;
use Spatie\Permission\PermissionRegistrar;
```

- [ ] **Step 2: Run it to verify it fails**

```bash
php artisan test --filter=AutoMergeEnrollmentPermissionTest
```

Expected: FAIL — the permission does not exist and `App\Support\AutoMergePermission` is undefined.

- [ ] **Step 3: Write the helper**

Create `app/Support/AutoMergePermission.php`:

```php
<?php

namespace App\Support;

use Spatie\Permission\Models\Permission;
use Spatie\Permission\Models\Role;

/**
 * Creating and granting the `manage auto-merge enrollment` permission.
 *
 * A named class rather than inline migration code so the grant is testable
 * without re-running migrations — Laravel migrations are anonymous.
 */
class AutoMergePermission
{
    public const NAME = 'manage auto-merge enrollment';

    /**
     * Create the permission and give it to every role that can already manage
     * repos.
     *
     * The inheritance matters: `DatabaseSeeder` only runs on a fresh install, so
     * without this a deployed environment would have the page and nobody
     * permitted to use it, and the fix would be a manual grant in production.
     *
     * Idempotent — safe to run twice.
     */
    public static function grantToRepoManagers(): void
    {
        $permission = Permission::findOrCreate(self::NAME);

        Role::all()
            ->filter(fn (Role $role): bool => $role->hasPermissionTo('manage repos'))
            ->each(fn (Role $role) => $role->givePermissionTo($permission));
    }
}
```

- [ ] **Step 4: Write the migration**

Create `database/migrations/2026_08_28_120000_add_manage_auto_merge_enrollment_permission.php`:

```php
<?php

use App\Support\AutoMergePermission;
use Illuminate\Database\Migrations\Migration;
use Spatie\Permission\Models\Permission;
use Spatie\Permission\PermissionRegistrar;

return new class extends Migration
{
    public function up(): void
    {
        AutoMergePermission::grantToRepoManagers();

        app(PermissionRegistrar::class)->forgetCachedPermissions();
    }

    public function down(): void
    {
        Permission::where('name', AutoMergePermission::NAME)->delete();

        app(PermissionRegistrar::class)->forgetCachedPermissions();
    }
};
```

There is precedent for a permission-mutating migration in
`database/migrations/2026_04_01_203624_drop_business_units_table_and_permission.php`.

- [ ] **Step 5: Add it to the seeder and the flag to config**

In `database/seeders/DatabaseSeeder.php`, add to the permission list (after `'manage repos',` at line 61):

```php
            'manage auto-merge enrollment',
```

In `config/features.php`, add after `'external_writes'`:

```php
    /*
     * Enrollment writes to zapp's registry. A SEPARATE flag from
     * external_writes, not an oversight: external_writes exists to stop
     * non-production Conductor mutating shared external systems (GitHub,
     * Auth0), and it defaults to production-only for that reason. Enrollment is
     * not that — the qa Conductor writes the qa account's own table, which is
     * the correct and desired behaviour. Reusing external_writes would either
     * block that or force it on and unblock every other external write in qa.
     *
     * Defaults on. Present so there is a kill switch.
     */
    'zapp_enrollment_writes' => env('ZAPP_ENROLLMENT_WRITES_ENABLED', true),
```

In `.env.example`, near the existing `EXTERNAL_WRITES_ENABLED=true` (line 122):

```
ZAPP_ENROLLMENT_WRITES_ENABLED=true
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
php artisan test --filter=AutoMergeEnrollmentPermissionTest
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/Support/AutoMergePermission.php database/migrations database/seeders/DatabaseSeeder.php \
        config/features.php .env.example tests/Feature/Permissions
git commit -m "feat(auto-merge): add the enrollment permission and its write flag"
```

---

### Task 3: DynamoDB Local and the seed command

Local validation infrastructure. Without this the page cannot be clicked before deploy.

**Files:**
- Modify: `docker-compose.yml`
- Create: `app/Console/Commands/SeedZappEnrollment.php`
- Modify: `.env.example`
- Create: `tests/Feature/Console/SeedZappEnrollmentTest.php`

**Interfaces:**
- Consumes: `EnrollmentStore` from Task 1.
- Produces: `php artisan zapp:enrollment-seed`.

- [ ] **Step 1: Add the service**

In `docker-compose.yml`, add alongside `mailpit`:

```yaml
  # zapp's enrollment registry, for local development of the Auto-Merge page.
  # Port 8001, not 8000 — `php artisan serve` owns 8000.
  dynamodb-local:
    image: amazon/dynamodb-local
    container_name: dynamodb-local
    restart: unless-stopped
    ports:
      - 8001:8000
    command: ["-jar", "DynamoDBLocal.jar", "-sharedDb", "-inMemory"]
```

`-inMemory` on purpose: a local table that survives a restart would drift from
the seed and produce confusing state. Re-run the seed command instead.

- [ ] **Step 2: Document the env vars**

In `.env.example`, next to the flag added in Task 2:

```
# Local only. Points the enrollment store at the docker-compose dynamodb-local
# service so the Auto-Merge page can be clicked without touching a real account.
# Leave EMPTY to use real AWS credentials and the real table.
ZAPP_DYNAMODB_ENDPOINT=http://localhost:8001
ZAPP_ENROLLMENT_TABLE=zapp-enrollments
```

- [ ] **Step 3: Write the failing test**

Create `tests/Feature/Console/SeedZappEnrollmentTest.php`:

```php
<?php

namespace Tests\Feature\Console;

use App\Models\Repo;
use App\Services\Zapp\EnrollmentStore;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Mockery\MockInterface;
use PHPUnit\Framework\Attributes\Test;
use Tests\TestCase;

class SeedZappEnrollmentTest extends TestCase
{
    use RefreshDatabase;

    #[Test]
    public function it_seeds_every_bundled_record(): void
    {
        $this->mock(EnrollmentStore::class, function (MockInterface $mock): void {
            $mock->shouldReceive('fleet')->andReturn(collect());
            $mock->shouldReceive('createTable')->once();
            $mock->shouldReceive('create')->times(8);
        });

        $this->artisan('zapp:enrollment-seed', ['--actor' => 'scrosby@bankrate.com'])
            ->assertSuccessful();
    }

    #[Test]
    public function it_creates_a_repos_row_for_each_seeded_repository(): void
    {
        $this->mock(EnrollmentStore::class, function (MockInterface $mock): void {
            $mock->shouldReceive('fleet')->andReturn(collect());
            $mock->shouldReceive('createTable')->once();
            $mock->shouldReceive('create')->times(8);
        });

        $this->artisan('zapp:enrollment-seed', ['--actor' => 'scrosby@bankrate.com'])
            ->assertSuccessful();

        // Without this the page renders every seeded record in the "not in
        // inventory" section and the main table shows nothing enrolled — a
        // correct rendering of an empty inventory, and a baffling first look.
        $this->assertDatabaseHas('repos', ['owner' => 'bankrate', 'name' => 'portkey']);
        $this->assertDatabaseHas('repos', ['owner' => 'bankrate', 'name' => 'zapp']);
        $this->assertSame(8, Repo::query()->where('owner', 'bankrate')->count());
    }

    #[Test]
    public function it_refuses_to_run_against_a_real_endpoint(): void
    {
        config(['services.zapp.dynamodb_endpoint' => null]);

        $this->artisan('zapp:enrollment-seed', ['--actor' => 'scrosby@bankrate.com'])
            ->expectsOutputToContain('ZAPP_DYNAMODB_ENDPOINT')
            ->assertFailed();
    }
}
```

- [ ] **Step 4: Run it to verify it fails**

```bash
php artisan test --filter=SeedZappEnrollmentTest
```

Expected: FAIL — the command does not exist.

- [ ] **Step 5: Add `createTable` to the store**

Append to `app/Services/Zapp/EnrollmentStore.php`:

```php
    /**
     * Create the table. LOCAL DEVELOPMENT ONLY.
     *
     * Deployed environments get the table from zapp's Terraform, which owns it.
     * This exists so DynamoDB Local has something to write to.
     */
    public function createTable(): void
    {
        $existing = $this->client->listTables()['TableNames'] ?? [];

        if (in_array($this->table(), $existing, true)) {
            return;
        }

        $this->client->createTable([
            'TableName' => $this->table(),
            'BillingMode' => 'PAY_PER_REQUEST',
            'KeySchema' => [
                ['AttributeName' => 'pk', 'KeyType' => 'HASH'],
                ['AttributeName' => 'sk', 'KeyType' => 'RANGE'],
            ],
            'AttributeDefinitions' => [
                ['AttributeName' => 'pk', 'AttributeType' => 'S'],
                ['AttributeName' => 'sk', 'AttributeType' => 'S'],
            ],
        ]);
    }
```

- [ ] **Step 6: Write the command**

Create `app/Console/Commands/SeedZappEnrollment.php`:

```php
<?php

namespace App\Console\Commands;

use App\Data\Zapp\EnrollmentData;
use App\Models\Repo;
use App\Services\Zapp\EnrollmentStore;
use Illuminate\Console\Command;

/**
 * Seed a LOCAL enrollment registry so the Auto-Merge page can be used.
 *
 * Mirrors the eight repositories zapp enrolled in PLAT-1233, and — importantly
 * — creates a `repos` row for each, because the page joins DynamoDB against
 * Conductor's own inventory and a fresh local database has neither side.
 */
class SeedZappEnrollment extends Command
{
    protected $signature = 'zapp:enrollment-seed {--actor= : Recorded as enrolledBy}';

    protected $description = 'Create and seed a local zapp enrollment registry (DynamoDB Local only)';

    /** The eight repositories zapp enrolled in PLAT-1233, at their real settings. */
    private const RECORDS = [
        ['bankrate/platform-cicd-v2-demo', 'sandbox', 2],
        ['bankrate/conductor', 'internal-tool', 2],
        ['bankrate/conductor-api', 'prod-service', 2],
        ['bankrate/portkey', 'prod-service', 2],
        ['bankrate/zapp', 'sandbox', 2],
        ['bankrate/brand-identity-pages-app', 'prod-service', 2],
        ['bankrate/redirect-management-api-v2', 'prod-service', 1],
        ['bankrate/crank', 'internal-tool', 2],
    ];

    public function handle(EnrollmentStore $store): int
    {
        // A guard, not a convenience. This command writes eight records with a
        // fabricated actor; running it against qa or prod would forge an audit
        // trail for the real fleet.
        if (! config('services.zapp.dynamodb_endpoint')) {
            $this->error('ZAPP_DYNAMODB_ENDPOINT is not set — refusing to seed a real DynamoDB endpoint.');
            $this->line('This command is for DynamoDB Local. Start it with `docker compose up -d dynamodb-local`.');

            return self::FAILURE;
        }

        $actor = $this->option('actor') ?: 'local@bankrate.com';

        $store->createTable();
        $existing = $store->fleet();

        foreach (self::RECORDS as [$repo, $classification, $tier]) {
            [$owner, $name] = explode('/', $repo, 2);

            // The page joins on CONCAT(owner, '/', name), so both sides need a row.
            Repo::query()->firstOrCreate(
                ['owner' => $owner, 'name' => $name],
                ['visibility' => 'internal', 'private' => true, 'archived' => false, 'default_branch' => 'main'],
            );

            if ($existing->has($repo)) {
                $this->line("skipped {$repo} (already enrolled)");

                continue;
            }

            $store->create(new EnrollmentData(
                repo: $repo,
                classification: $classification,
                ciTrustTier: $tier,
                mode: 'shadow',
                stageEnabled: false,
                // Null, not [] — none of the eight overrides zapp's global lists.
                signalChecks: null,
                blockingChecks: null,
                baseBranches: null,
                version: 1,
                updatedBy: $actor,
                updatedAt: now()->toIso8601String(),
            ), $actor);

            $this->line("seeded {$repo}");
        }

        $this->info('Local enrollment registry ready.');

        return self::SUCCESS;
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
php artisan test --filter=SeedZappEnrollmentTest
```

Expected: PASS. If `Repo::firstOrCreate` fails on a not-null column, read the `repos` table migration and add the missing column to the defaults array — do not make the column nullable.

- [ ] **Step 8: Try it for real**

```bash
docker compose up -d dynamodb-local
php artisan zapp:enrollment-seed --actor="$(git config user.email)"
aws dynamodb scan --table-name zapp-enrollments --endpoint-url http://localhost:8001 \
  --region us-east-1 --query 'Count'
```

Expected: eight `seeded …` lines, then `8`. (The `aws` CLI needs `AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local` in the environment for DynamoDB Local.)

- [ ] **Step 9: Commit**

```bash
git add docker-compose.yml app/Console/Commands/SeedZappEnrollment.php \
        app/Services/Zapp/EnrollmentStore.php .env.example tests/Feature/Console
git commit -m "feat(auto-merge): add DynamoDB Local and a local enrollment seed command"
```

---

### Task 4: The Auto-Merge page, read-only

The table, the join, the orphan section, and the nav entry. No writes yet.

**Files:**
- Create: `app/Filament/Pages/AutoMerge.php`
- Create: `resources/views/filament/pages/auto-merge.blade.php`
- Modify: `app/Models/Repo.php` (add a `fullNameIn` scope and a `full_name` accessor)
- Create: `tests/Feature/Filament/Pages/AutoMergeTest.php`

**Interfaces:**
- Consumes: `EnrollmentStore::fleet()`, `EnrollmentData` from Task 1.
- Produces: `AutoMerge::class` with a memoised `enrollments(): Collection` and `orphans(): Collection`; `Repo::scopeFullNameIn`.

- [ ] **Step 1: Write the failing tests**

Create `tests/Feature/Filament/Pages/AutoMergeTest.php`:

```php
<?php

namespace Tests\Feature\Filament\Pages;

use App\Data\Zapp\EnrollmentData;
use App\Filament\Pages\AutoMerge;
use App\Models\Repo;
use App\Models\User;
use App\Services\Zapp\EnrollmentStore;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Livewire\Livewire;
use Mockery\MockInterface;
use PHPUnit\Framework\Attributes\Test;
use Spatie\Permission\Models\Permission;
use Spatie\Permission\PermissionRegistrar;
use Tests\TestCase;

class AutoMergeTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        app(PermissionRegistrar::class)->forgetCachedPermissions();
        Permission::findOrCreate('manage auto-merge enrollment');
    }

    private function record(string $repo, array $over = []): EnrollmentData
    {
        return EnrollmentData::from(array_merge([
            'repo' => $repo,
            'classification' => 'sandbox',
            'ciTrustTier' => 2,
            'mode' => 'shadow',
            'stageEnabled' => false,
            'signalChecks' => null,
            'blockingChecks' => null,
            'baseBranches' => null,
            'version' => 1,
            'updatedBy' => 'scrosby@bankrate.com',
            'updatedAt' => '2026-08-28T12:00:00+00:00',
        ], $over));
    }

    private function fleetIs(EnrollmentData ...$records): void
    {
        $keyed = collect($records)->keyBy(fn (EnrollmentData $r): string => $r->repo);

        $this->mock(EnrollmentStore::class, function (MockInterface $mock) use ($keyed): void {
            $mock->shouldReceive('fleet')->andReturn($keyed);
        });
    }

    #[Test]
    public function it_lists_enrolled_and_unenrolled_repositories_together(): void
    {
        Repo::factory()->create(['owner' => 'bankrate', 'name' => 'portkey']);
        Repo::factory()->create(['owner' => 'bankrate', 'name' => 'brcc-api']);

        $this->fleetIs($this->record('bankrate/portkey', ['classification' => 'prod-service']));
        $this->actingAs(User::factory()->create());

        Livewire::test(AutoMerge::class)
            ->assertOk()
            ->assertSee('portkey')
            ->assertSee('brcc-api')
            ->assertSee('prod-service');
    }

    #[Test]
    public function the_enrolled_filter_pushes_the_enrolled_set_into_sql(): void
    {
        Repo::factory()->create(['owner' => 'bankrate', 'name' => 'portkey']);
        Repo::factory()->create(['owner' => 'bankrate', 'name' => 'brcc-api']);

        $this->fleetIs($this->record('bankrate/portkey'));
        $this->actingAs(User::factory()->create());

        Livewire::test(AutoMerge::class)
            ->filterTable('enrolled', true)
            ->assertSee('portkey')
            ->assertDontSee('brcc-api');
    }

    #[Test]
    public function an_empty_fleet_shows_no_repository_as_enrolled(): void
    {
        Repo::factory()->count(3)->create(['owner' => 'bankrate']);

        $this->fleetIs();
        $this->actingAs(User::factory()->create());

        // The bug this guards: a naive `whereIn` with an empty array is either a
        // SQL syntax error or, written as a no-op, matches EVERY repository and
        // claims all 1,112 are enrolled.
        Livewire::test(AutoMerge::class)
            ->filterTable('enrolled', true)
            ->assertCanNotSeeTableRecords(Repo::all());
    }

    #[Test]
    public function an_enrollment_with_no_inventory_row_is_surfaced_not_hidden(): void
    {
        Repo::factory()->create(['owner' => 'bankrate', 'name' => 'portkey']);

        $this->fleetIs(
            $this->record('bankrate/portkey'),
            $this->record('bankrate/deleted-repo'),
        );
        $this->actingAs(User::factory()->create());

        // Hiding it would mean zapp is evaluating something the page says is not
        // enrolled — the worst available outcome.
        Livewire::test(AutoMerge::class)
            ->assertOk()
            ->assertSee('bankrate/deleted-repo')
            ->assertSee('not in Conductor');
    }

    #[Test]
    public function the_fleet_is_read_once_per_request(): void
    {
        Repo::factory()->count(5)->create(['owner' => 'bankrate']);

        $this->mock(EnrollmentStore::class, function (MockInterface $mock): void {
            // Once, not once per row. A per-column read would be 1,112 Queries.
            $mock->shouldReceive('fleet')->once()->andReturn(collect());
        });
        $this->actingAs(User::factory()->create());

        Livewire::test(AutoMerge::class)->assertOk();
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
php artisan test --filter=AutoMergeTest
```

Expected: FAIL — `App\Filament\Pages\AutoMerge` does not exist.

- [ ] **Step 3: Add the model scope and accessor**

In `app/Models/Repo.php`, add after `scopeScorecardEligible`:

```php
    /**
     * Restrict to repositories whose `owner/name` appears in the given list.
     *
     * The `repos` table has no `full_name` column, and zapp keys enrollment on
     * `owner/repo` exactly as the webhook reports it, so the join is on a
     * concatenation.
     *
     * An EMPTY list matches nothing. That case is load-bearing: `IN ()` is a
     * SQL syntax error, and writing the empty case as a no-op instead would
     * make "show me enrolled repositories" return all of them when the fleet is
     * empty.
     *
     * @param  array<int, string>  $names
     */
    public function scopeFullNameIn(Builder $query, array $names): Builder
    {
        if ($names === []) {
            return $query->whereRaw('1 = 0');
        }

        $placeholders = implode(',', array_fill(0, count($names), '?'));

        return $query->whereRaw("CONCAT(owner, '/', name) IN ({$placeholders})", $names);
    }

    /** The `owner/name` form zapp keys enrollment on. */
    public function getFullNameAttribute(): string
    {
        return "{$this->owner}/{$this->name}";
    }
```

`Builder` is already imported in that file.

- [ ] **Step 4: Write the page**

Create `app/Filament/Pages/AutoMerge.php`:

```php
<?php

namespace App\Filament\Pages;

use App\Data\Zapp\EnrollmentData;
use App\Models\Repo;
use App\Services\Zapp\EnrollmentStore;
use Filament\Pages\Page;
use Filament\Support\Icons\Heroicon;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Concerns\InteractsWithTable;
use Filament\Tables\Contracts\HasTable;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Filters\TernaryFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Collection;
use Livewire\Attributes\Url;

/**
 * Enrollment in zapp's merge-policy service (PLAT-1188).
 *
 * A PAGE, not a Resource: enrollment lives in the `zapp-enrollments` DynamoDB
 * table, and a Filament Resource is Eloquent-backed. This carries a table over
 * the `Repo` model — Conductor's own inventory of all ~1,112 org repositories —
 * with enrollment joined in from one DynamoDB Query per request.
 */
class AutoMerge extends Page implements HasTable
{
    use InteractsWithTable;

    #[Url]
    public ?array $tableFilters = null;

    #[Url]
    public $tableSearch = '';

    protected static string|\BackedEnum|null $navigationIcon = Heroicon::OutlinedArrowsRightLeft;

    protected static string|\UnitEnum|null $navigationGroup = 'Inventory';

    protected static ?string $navigationLabel = 'Auto-Merge';

    protected static ?string $title = 'Auto-Merge enrollment';

    protected string $view = 'filament.pages.auto-merge';

    /**
     * The fleet, keyed by `owner/repo`.
     *
     * MEMOISED per request, and deliberately NOT a public Livewire property:
     * Livewire serialises those between requests, which would both bloat the
     * payload and make the page show a stale fleet after somebody else's write.
     *
     * @var Collection<string, EnrollmentData>|null
     */
    private ?Collection $fleet = null;

    /** @return Collection<string, EnrollmentData> */
    public function enrollments(): Collection
    {
        return $this->fleet ??= app(EnrollmentStore::class)->fleet();
    }

    /** Forget the memoised fleet, after a write changed it. */
    public function refreshEnrollments(): void
    {
        $this->fleet = null;
    }

    /**
     * Enrollment records with no row in Conductor's inventory.
     *
     * Happens when a repository is renamed or deleted in GitHub, and on every
     * fresh local database. These cannot appear in an Eloquent-backed table, so
     * the view renders them separately — hiding them would mean zapp is
     * evaluating something this page says is not enrolled.
     *
     * @return Collection<int, EnrollmentData>
     */
    public function orphans(): Collection
    {
        $known = Repo::query()
            ->fullNameIn($this->enrollments()->keys()->all())
            ->get()
            ->map->full_name;

        return $this->enrollments()
            ->reject(fn (EnrollmentData $record): bool => $known->contains($record->repo))
            ->values();
    }

    /** The record for one inventory row, or null. */
    public function enrollmentFor(Repo $repo): ?EnrollmentData
    {
        return $this->enrollments()->get($repo->full_name);
    }

    public function table(Table $table): Table
    {
        return $table
            ->query(Repo::query()->active())
            ->defaultSort('name')
            ->columns([
                TextColumn::make('owner')->sortable()->toggleable(),
                TextColumn::make('name')
                    ->label('Repository')
                    ->searchable()
                    ->sortable(),
                TextColumn::make('enrollment_state')
                    ->label('Enrollment')
                    ->badge()
                    ->state(function (Repo $record): string {
                        $enrollment = $this->enrollmentFor($record);

                        if ($enrollment === null) {
                            return 'not enrolled';
                        }

                        // Paused and absent are different facts, and zapp's gate
                        // 1 reports which — so the page must show both.
                        return $enrollment->isActive() ? 'shadow' : 'paused';
                    })
                    ->color(fn (string $state): string => match ($state) {
                        'shadow' => 'success',
                        'paused' => 'warning',
                        default => 'gray',
                    }),
                TextColumn::make('classification')
                    ->state(fn (Repo $record): string => $this->enrollmentFor($record)?->classification ?? '—'),
                TextColumn::make('ci_trust_tier')
                    ->label('CI trust tier')
                    ->state(fn (Repo $record): string => (string) ($this->enrollmentFor($record)?->ciTrustTier ?? '—')),
                TextColumn::make('overrides')
                    ->label('Overrides')
                    ->state(function (Repo $record): string {
                        $enrollment = $this->enrollmentFor($record);

                        if ($enrollment === null) {
                            return '—';
                        }

                        $set = collect([
                            'signalChecks' => $enrollment->signalChecks,
                            'blockingChecks' => $enrollment->blockingChecks,
                            'baseBranches' => $enrollment->baseBranches,
                        ])->reject(fn (?array $v): bool => $v === null);

                        return $set->isEmpty() ? 'global' : $set->keys()->join(', ');
                    })
                    ->tooltip('"global" means this repo uses zapp\'s own lists. An override REPLACES the global list; an empty override means nothing is waited on.'),
                // Conductor's own facts, shown so classification is chosen
                // against evidence. Never written into the enrollment record —
                // zapp reads its own from GitHub repository properties.
                TextColumn::make('repo_type')->label('Type')->toggleable(),
                TextColumn::make('soc2_scope')
                    ->label('SOC 2')
                    ->badge()
                    ->state(fn (Repo $record): string => $record->soc2_scope ? 'in scope' : '—')
                    ->color(fn (string $state): string => $state === 'in scope' ? 'danger' : 'gray')
                    ->toggleable(),
                TextColumn::make('updated_by')
                    ->label('Last changed by')
                    ->state(fn (Repo $record): string => $this->enrollmentFor($record)?->updatedBy ?? '—')
                    ->toggleable(isToggledHiddenByDefault: true),
            ])
            ->filters([
                TernaryFilter::make('enrolled')
                    ->label('Enrollment')
                    ->placeholder('All repositories')
                    ->trueLabel('Enrolled only')
                    ->falseLabel('Not enrolled')
                    ->queries(
                        true: fn (Builder $query): Builder => $query->fullNameIn($this->enrollments()->keys()->all()),
                        false: fn (Builder $query): Builder => $query->whereNotIn(
                            'id',
                            Repo::query()->fullNameIn($this->enrollments()->keys()->all())->select('id'),
                        ),
                        blank: fn (Builder $query): Builder => $query,
                    ),
                SelectFilter::make('classification')
                    ->options([
                        'sandbox' => 'sandbox',
                        'internal-tool' => 'internal-tool',
                        'prod-service' => 'prod-service',
                    ])
                    ->query(function (Builder $query, array $data): Builder {
                        if (blank($data['value'] ?? null)) {
                            return $query;
                        }

                        $names = $this->enrollments()
                            ->filter(fn (EnrollmentData $r): bool => $r->classification === $data['value'])
                            ->keys()
                            ->all();

                        return $query->fullNameIn($names);
                    }),
            ]);
    }
}
```

- [ ] **Step 5: Write the view**

Create `resources/views/filament/pages/auto-merge.blade.php`:

```blade
<x-filament-panels::page>
    <div class="text-sm text-gray-500 dark:text-gray-400">
        Enrollment in the merge-policy service (<code>zapp</code>). Enrolled repositories
        get two <strong>neutral</strong> shadow check runs on every pull request; nothing is
        ever blocked or merged in this phase.
        <a href="https://github.com/bankrate/zapp/blob/main/docs/policy.md"
           target="_blank" rel="noopener"
           class="text-primary-600 hover:underline dark:text-primary-400">
            What the gates and grades mean &rarr;
        </a>
    </div>

    @if ($this->orphans()->isNotEmpty())
        <div class="rounded-lg border border-warning-300 bg-warning-50 p-4 text-sm dark:border-warning-700 dark:bg-warning-950">
            <p class="font-semibold text-warning-800 dark:text-warning-200">
                {{ $this->orphans()->count() }}
                {{ \Illuminate\Support\Str::plural('repository', $this->orphans()->count()) }}
                enrolled but not in Conductor's inventory
            </p>
            <p class="mt-1 text-warning-700 dark:text-warning-300">
                zapp is still evaluating these. Usually a rename or a deletion in GitHub.
            </p>
            <ul class="mt-2 list-inside list-disc font-mono text-warning-800 dark:text-warning-200">
                @foreach ($this->orphans() as $orphan)
                    <li>{{ $orphan->repo }} <span class="font-sans text-xs">({{ $orphan->mode }})</span></li>
                @endforeach
            </ul>
        </div>
    @endif

    {{ $this->table }}
</x-filament-panels::page>
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
php artisan test --filter=AutoMergeTest
vendor/bin/pint --test app/Filament/Pages/AutoMerge.php app/Models/Repo.php
```

Expected: PASS.

If `assertCanNotSeeTableRecords` is not available in this Filament version, replace that assertion with `->assertSee('No repositories')` against the table's empty state, or count the records via `->assertCountTableRecords(0)`.

- [ ] **Step 7: Check it renders**

```bash
php artisan serve
```

Log in at `http://127.0.0.1:8000/admin`, confirm **Auto-Merge** appears in the Inventory group under Repos, and that the eight seeded records show as `shadow`.

- [ ] **Step 8: Commit**

```bash
git add app/Filament/Pages/AutoMerge.php resources/views/filament/pages/auto-merge.blade.php \
        app/Models/Repo.php tests/Feature/Filament/Pages/AutoMergeTest.php
git commit -m "feat(auto-merge): add the enrollment page with the DynamoDB join"
```

---

### Task 5: The write actions

**Files:**
- Create: `app/Filament/Pages/Actions/EnrollRepoAction.php`
- Create: `app/Filament/Pages/Actions/EnrollmentFormSchema.php`
- Modify: `app/Filament/Pages/AutoMerge.php` (register row actions)
- Modify: `tests/Feature/Filament/Pages/AutoMergeTest.php`

**Interfaces:**
- Consumes: `EnrollmentStore::create/replace/delete`, `EnrollmentConflictException`, `AutoMergePermission::NAME`.
- Produces: row actions `enroll`, `edit_enrollment`, `toggle_mode`, `unenroll`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Feature/Filament/Pages/AutoMergeTest.php`:

```php
    private function permittedUser(): User
    {
        $user = User::factory()->create();
        $user->givePermissionTo('manage auto-merge enrollment');

        return $user;
    }

    #[Test]
    public function enrolling_writes_the_record_with_the_acting_user_as_actor(): void
    {
        $repo = Repo::factory()->create(['owner' => 'bankrate', 'name' => 'brcc-api']);
        $user = $this->permittedUser();

        $this->mock(EnrollmentStore::class, function (MockInterface $mock) use ($user): void {
            $mock->shouldReceive('fleet')->andReturn(collect());
            $mock->shouldReceive('create')
                ->once()
                ->withArgs(function (EnrollmentData $data, string $actor) use ($user): bool {
                    return $data->repo === 'bankrate/brcc-api'
                        && $data->classification === 'prod-service'
                        && $data->ciTrustTier === 2
                        && $data->mode === 'shadow'
                        && $data->stageEnabled === false
                        && $actor === $user->email;
                });
        });

        $this->actingAs($user);

        Livewire::test(AutoMerge::class)
            ->callTableAction('enroll', $repo, data: [
                'classification' => 'prod-service',
                'ciTrustTier' => 2,
                'mode' => 'shadow',
                'stageEnabled' => false,
                'overrideSignalChecks' => false,
                'overrideBlockingChecks' => false,
                'overrideBaseBranches' => false,
            ])
            ->assertHasNoTableActionErrors();
    }

    #[Test]
    public function leaving_the_override_toggle_off_writes_null_not_an_empty_list(): void
    {
        $repo = Repo::factory()->create(['owner' => 'bankrate', 'name' => 'brcc-api']);

        $this->mock(EnrollmentStore::class, function (MockInterface $mock): void {
            $mock->shouldReceive('fleet')->andReturn(collect());
            $mock->shouldReceive('create')->once()->withArgs(
                fn (EnrollmentData $data): bool => $data->signalChecks === null,
            );
        });

        $this->actingAs($this->permittedUser());

        Livewire::test(AutoMerge::class)
            ->callTableAction('enroll', $repo, data: [
                'classification' => 'sandbox', 'ciTrustTier' => 2, 'mode' => 'shadow',
                'stageEnabled' => false,
                'overrideSignalChecks' => false, 'signalChecks' => [],
                'overrideBlockingChecks' => false, 'overrideBaseBranches' => false,
            ])
            ->assertHasNoTableActionErrors();
    }

    #[Test]
    public function turning_the_override_on_with_an_empty_list_writes_an_empty_list(): void
    {
        $repo = Repo::factory()->create(['owner' => 'bankrate', 'name' => 'brcc-api']);

        $this->mock(EnrollmentStore::class, function (MockInterface $mock): void {
            $mock->shouldReceive('fleet')->andReturn(collect());
            // [] means "wait on nothing, every evaluation immediately final" —
            // a deliberate and very different instruction from null.
            $mock->shouldReceive('create')->once()->withArgs(
                fn (EnrollmentData $data): bool => $data->signalChecks === [],
            );
        });

        $this->actingAs($this->permittedUser());

        Livewire::test(AutoMerge::class)
            ->callTableAction('enroll', $repo, data: [
                'classification' => 'sandbox', 'ciTrustTier' => 2, 'mode' => 'shadow',
                'stageEnabled' => false,
                'overrideSignalChecks' => true, 'signalChecks' => [],
                'overrideBlockingChecks' => false, 'overrideBaseBranches' => false,
            ])
            ->assertHasNoTableActionErrors();
    }

    #[Test]
    public function pausing_replaces_the_record_with_a_pause_action_and_the_read_version(): void
    {
        $repo = Repo::factory()->create(['owner' => 'bankrate', 'name' => 'portkey']);

        $this->mock(EnrollmentStore::class, function (MockInterface $mock): void {
            $mock->shouldReceive('fleet')->andReturn(collect([
                'bankrate/portkey' => $this->record('bankrate/portkey', ['version' => 5]),
            ]));
            $mock->shouldReceive('replace')
                ->once()
                ->withArgs(function (EnrollmentData $data, int $expected, string $actor, string $action): bool {
                    return $data->mode === 'off' && $expected === 5 && $action === 'pause';
                });
        });

        $this->actingAs($this->permittedUser());

        Livewire::test(AutoMerge::class)
            ->callTableAction('toggle_mode', $repo)
            ->assertHasNoTableActionErrors();
    }

    #[Test]
    public function unenrolling_deletes_at_the_read_version(): void
    {
        $repo = Repo::factory()->create(['owner' => 'bankrate', 'name' => 'portkey']);

        $this->mock(EnrollmentStore::class, function (MockInterface $mock): void {
            $mock->shouldReceive('fleet')->andReturn(collect([
                'bankrate/portkey' => $this->record('bankrate/portkey', ['version' => 5]),
            ]));
            $mock->shouldReceive('delete')->once()->with('bankrate/portkey', 5, \Mockery::type('string'));
        });

        $this->actingAs($this->permittedUser());

        Livewire::test(AutoMerge::class)
            ->callTableAction('unenroll', $repo)
            ->assertHasNoTableActionErrors();
    }

    #[Test]
    public function a_concurrent_change_is_reported_and_not_retried(): void
    {
        $repo = Repo::factory()->create(['owner' => 'bankrate', 'name' => 'portkey']);

        $this->mock(EnrollmentStore::class, function (MockInterface $mock): void {
            $mock->shouldReceive('fleet')->andReturn(collect([
                'bankrate/portkey' => $this->record('bankrate/portkey', ['version' => 5]),
            ]));
            // Once. A retry would clobber whatever the other operator wrote.
            $mock->shouldReceive('replace')->once()->andThrow(
                \App\Exceptions\EnrollmentConflictException::forRepo('bankrate/portkey'),
            );
        });

        $this->actingAs($this->permittedUser());

        Livewire::test(AutoMerge::class)
            ->callTableAction('toggle_mode', $repo)
            ->assertNotified();
    }

    #[Test]
    public function a_user_without_the_permission_gets_no_write_actions(): void
    {
        $repo = Repo::factory()->create(['owner' => 'bankrate', 'name' => 'brcc-api']);

        $this->fleetIs();
        $this->actingAs(User::factory()->create());

        Livewire::test(AutoMerge::class)
            ->assertOk()
            ->assertTableActionHidden('enroll', $repo);
    }

    #[Test]
    public function the_write_actions_disappear_when_the_feature_flag_is_off(): void
    {
        config(['features.zapp_enrollment_writes' => false]);

        $repo = Repo::factory()->create(['owner' => 'bankrate', 'name' => 'brcc-api']);

        $this->fleetIs();
        $this->actingAs($this->permittedUser());

        Livewire::test(AutoMerge::class)
            ->assertOk()
            ->assertTableActionHidden('enroll', $repo);
    }
```

- [ ] **Step 2: Run them to verify they fail**

```bash
php artisan test --filter=AutoMergeTest
```

Expected: FAIL — the table has no actions.

- [ ] **Step 3: Write the shared form schema**

Create `app/Filament/Pages/Actions/EnrollmentFormSchema.php`:

```php
<?php

namespace App\Filament\Pages\Actions;

use App\Data\Zapp\EnrollmentData;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TagsInput;
use Filament\Forms\Components\Toggle;

/**
 * The enrollment form, shared by enroll and edit.
 *
 * THE OVERRIDE TOGGLES ARE THE POINT. zapp reads an absent `signalChecks` as
 * "use my global list" and a present-but-empty one as "wait on nothing, every
 * evaluation immediately final". A single tag input cannot express both — an
 * untouched empty input would write `[]` and silently change behaviour on every
 * repository it touched. So each list is a toggle plus an input, and the toggle
 * being off means the attribute is not written at all.
 */
class EnrollmentFormSchema
{
    private const OVERRIDES = [
        'signalChecks' => [
            'label' => 'Signal checks',
            'help' => 'Check runs the risk grade waits for before it is final. An override REPLACES zapp\'s global list. Empty means nothing is waited on and every evaluation is immediately final.',
        ],
        'blockingChecks' => [
            'label' => 'Blocking checks',
            'help' => 'Check runs that must be green for a pull request to be a candidate. An override REPLACES the global list. Empty means no check blocks.',
        ],
        'baseBranches' => [
            'label' => 'Base branches',
            'help' => 'Base branches permitted in addition to the default branch. Empty means the default branch only.',
        ],
    ];

    /** @return array<int, \Filament\Forms\Components\Component> */
    public static function make(): array
    {
        $fields = [
            Select::make('classification')
                ->options([
                    'sandbox' => 'sandbox — pilot or proof-of-concept',
                    'internal-tool' => 'internal-tool — internal audience, not a running service',
                    'prod-service' => 'prod-service — real production blast radius',
                ])
                ->required()
                ->helperText('Gate 9 (classificationPermits) reads this: each change class declares which classifications may use it.'),
            Select::make('ciTrustTier')
                ->label('CI trust tier')
                ->options([
                    1 => '1 — no pull-request lint/test gate',
                    2 => '2 — lint and tests run on every pull request',
                    3 => '3 — reserved',
                ])
                ->required()
                ->default(2)
                ->helperText('Gate 10 (tierFloor) reads this: each change class declares a minimum tier.'),
            Select::make('mode')
                ->options(['shadow' => 'shadow — evaluate and report', 'off' => 'off — enrolled but paused'])
                ->required()
                ->default('shadow')
                ->helperText('Phase 0 has no enforcing mode. "off" keeps the record so history survives a pause.'),
            Toggle::make('stageEnabled')
                ->label('Stage enabled')
                ->default(false)
                ->helperText('Recorded on every evaluation; gates nothing in Phase 0.'),
        ];

        foreach (self::OVERRIDES as $field => $copy) {
            $toggle = 'override'.ucfirst($field);

            $fields[] = Toggle::make($toggle)
                ->label("Override {$copy['label']}")
                ->default(false)
                ->live()
                ->helperText('Off means this repository uses zapp\'s global list.');

            $fields[] = TagsInput::make($field)
                ->label($copy['label'])
                ->helperText($copy['help'])
                ->visible(fn (callable $get): bool => (bool) $get($toggle));
        }

        return $fields;
    }

    /** Build the record from submitted form data. An override that is off becomes null. */
    public static function toData(string $repo, array $form, int $version, string $actor): EnrollmentData
    {
        $override = function (string $field) use ($form): ?array {
            if (! ($form['override'.ucfirst($field)] ?? false)) {
                return null;
            }

            return array_values($form[$field] ?? []);
        };

        return new EnrollmentData(
            repo: $repo,
            classification: $form['classification'],
            ciTrustTier: (int) $form['ciTrustTier'],
            mode: $form['mode'],
            stageEnabled: (bool) ($form['stageEnabled'] ?? false),
            signalChecks: $override('signalChecks'),
            blockingChecks: $override('blockingChecks'),
            baseBranches: $override('baseBranches'),
            version: $version,
            updatedBy: $actor,
            updatedAt: now()->toIso8601String(),
        );
    }

    /** Pre-fill the form from an existing record. A null override leaves its toggle off. */
    public static function fill(EnrollmentData $record): array
    {
        return [
            'classification' => $record->classification,
            'ciTrustTier' => $record->ciTrustTier,
            'mode' => $record->mode,
            'stageEnabled' => $record->stageEnabled,
            'overrideSignalChecks' => $record->signalChecks !== null,
            'signalChecks' => $record->signalChecks ?? [],
            'overrideBlockingChecks' => $record->blockingChecks !== null,
            'blockingChecks' => $record->blockingChecks ?? [],
            'overrideBaseBranches' => $record->baseBranches !== null,
            'baseBranches' => $record->baseBranches ?? [],
        ];
    }
}
```

- [ ] **Step 4: Register the actions on the page**

In `app/Filament/Pages/AutoMerge.php`, add `->recordActions([...])` to the `table()` builder, plus the imports (`Filament\Actions\Action`, `Filament\Actions\ActionGroup`, `Filament\Notifications\Notification`, `App\Exceptions\EnrollmentConflictException`, `App\Filament\Pages\Actions\EnrollmentFormSchema`, `App\Support\AutoMergePermission`):

```php
            ->recordActions([
                ActionGroup::make([
                    Action::make('enroll')
                        ->label('Enroll')
                        ->icon(Heroicon::OutlinedPlusCircle)
                        ->visible(fn (Repo $record): bool => $this->canWrite() && $this->enrollmentFor($record) === null)
                        ->schema(EnrollmentFormSchema::make())
                        ->action(fn (Repo $record, array $data) => $this->guarded(
                            fn () => app(EnrollmentStore::class)->create(
                                EnrollmentFormSchema::toData($record->full_name, $data, 1, $this->actor()),
                                $this->actor(),
                            ),
                            "Enrolled {$record->full_name}",
                        )),

                    Action::make('edit_enrollment')
                        ->label('Edit enrollment')
                        ->icon(Heroicon::OutlinedPencilSquare)
                        ->visible(fn (Repo $record): bool => $this->canWrite() && $this->enrollmentFor($record) !== null)
                        ->fillForm(fn (Repo $record): array => EnrollmentFormSchema::fill($this->enrollmentFor($record)))
                        ->schema(EnrollmentFormSchema::make())
                        ->action(function (Repo $record, array $data): void {
                            // The version the form was FILLED from, so a change
                            // made while it was open is rejected rather than
                            // silently overwritten.
                            $version = $this->enrollmentFor($record)->version;

                            $this->guarded(
                                fn () => app(EnrollmentStore::class)->replace(
                                    EnrollmentFormSchema::toData($record->full_name, $data, $version, $this->actor()),
                                    $version,
                                    $this->actor(),
                                    'update',
                                ),
                                "Updated {$record->full_name}",
                            );
                        }),

                    Action::make('toggle_mode')
                        ->label(fn (Repo $record): string => $this->enrollmentFor($record)?->isActive() ? 'Pause' : 'Resume')
                        ->icon(fn (Repo $record): Heroicon => $this->enrollmentFor($record)?->isActive()
                            ? Heroicon::OutlinedPause
                            : Heroicon::OutlinedPlay)
                        ->color('warning')
                        ->visible(fn (Repo $record): bool => $this->canWrite() && $this->enrollmentFor($record) !== null)
                        ->requiresConfirmation()
                        ->modalHeading(fn (Repo $record): string => $this->enrollmentFor($record)?->isActive()
                            ? "Pause evaluation of {$record->full_name}"
                            : "Resume evaluation of {$record->full_name}")
                        ->modalDescription('Pausing keeps the enrollment record, so its history and settings survive. It is not the same as unenrolling.')
                        ->action(function (Repo $record): void {
                            $current = $this->enrollmentFor($record);
                            $paused = $current->isActive();

                            $next = EnrollmentData::from([
                                ...$current->toArray(),
                                'mode' => $paused ? 'off' : 'shadow',
                            ]);

                            $this->guarded(
                                fn () => app(EnrollmentStore::class)->replace(
                                    $next,
                                    $current->version,
                                    $this->actor(),
                                    $paused ? 'pause' : 'resume',
                                ),
                                $paused ? "Paused {$record->full_name}" : "Resumed {$record->full_name}",
                            );
                        }),

                    Action::make('unenroll')
                        ->label('Unenroll')
                        ->icon(Heroicon::OutlinedTrash)
                        ->color('danger')
                        ->visible(fn (Repo $record): bool => $this->canWrite() && $this->enrollmentFor($record) !== null)
                        ->requiresConfirmation()
                        ->modalHeading(fn (Repo $record): string => "Unenroll {$record->full_name}")
                        ->modalDescription('zapp stops evaluating this repository entirely. The record is deleted; the change is kept in the enrollment history. To stop evaluation temporarily, use Pause instead.')
                        ->modalSubmitActionLabel('Unenroll')
                        ->action(fn (Repo $record) => $this->guarded(
                            fn () => app(EnrollmentStore::class)->delete(
                                $record->full_name,
                                $this->enrollmentFor($record)->version,
                                $this->actor(),
                            ),
                            "Unenrolled {$record->full_name}",
                        )),
                ]),
            ]);
```

and the three helpers on the class:

```php
    /** The acting user's email — what the audit trail records. */
    private function actor(): string
    {
        return auth()->user()->email;
    }

    /** Both the permission and the kill switch must allow it. */
    private function canWrite(): bool
    {
        return (bool) config('features.zapp_enrollment_writes')
            && auth()->user()?->can(AutoMergePermission::NAME);
    }

    /**
     * Run a write, reporting the outcome and forgetting the memoised fleet.
     *
     * A conflict is NOT retried: another operator changed the record while this
     * form was open, and last-write-wins on a control that decides what
     * automation may touch production would discard their deliberate change.
     */
    private function guarded(callable $write, string $success): void
    {
        try {
            $write();
        } catch (EnrollmentConflictException $e) {
            Notification::make()
                ->title('Enrollment changed while you were editing')
                ->body($e->getMessage().' Reload the page and try again.')
                ->warning()
                ->persistent()
                ->send();

            $this->refreshEnrollments();

            return;
        }

        $this->refreshEnrollments();

        Notification::make()->title($success)->success()->send();
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
php artisan test --filter=AutoMergeTest
vendor/bin/pint --test app/Filament
```

Expected: PASS.

Filament v5 renamed several table APIs. If `->recordActions()`, `->schema()` on an action, `callTableAction`, `assertTableActionHidden` or `assertNotified` do not exist under these names, check the v5 method against another resource in this codebase (`RepoResource::table()` uses `ViewAction` and `ActionGroup`; `ListReposTest` uses `callAction` and `TestAction`) and follow whatever that file does. Do not guess from memory of v3.

- [ ] **Step 6: Commit**

```bash
git add app/Filament tests/Feature/Filament
git commit -m "feat(auto-merge): enroll, edit, pause and unenroll from the page"
```

---

### Task 6: Grant the task role access to the table

**Files:**
- Modify: `infrastructure/terraform/iam.tf`
- Modify: `infrastructure/terraform/env.tf` (the `ecs_env_vars` list)

- [ ] **Step 1: Add the policy**

Append to `infrastructure/terraform/iam.tf`:

```hcl
# zapp's enrollment registry (PLAT-1188). conductor-api's Auto-Merge page is the
# ONLY writer; zapp itself holds GetItem and Query and deliberately no PutItem.
#
# SAME ACCOUNT, so no assume-role: conductor-api's `development` account is
# zapp's `qa` (194918977890) and `production` is zapp's `prod` (835272777014).
# The table name carries no environment suffix, so the account disambiguates.
#
# Scoped to this one table. Nothing here grants access to zapp-evaluations or
# zapp-delivery-ids — the page is a control surface for enrollment, not a reader
# of the shadow corpus.
data "aws_iam_policy_document" "zapp_enrollments" {
  statement {
    sid = "ManageZappEnrollments"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
    ]
    resources = [
      "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/zapp-enrollments",
    ]
  }
}

resource "aws_iam_policy" "zapp_enrollments" {
  name        = "conductor-api-${local.environment}-zapp-enrollments"
  description = "Read and write zapp's repository enrollment registry"
  policy      = data.aws_iam_policy_document.zapp_enrollments.json
}

resource "aws_iam_role_policy_attachment" "zapp_enrollments" {
  role       = module.conductor_api_ecs_task.task_role_name
  policy_arn = aws_iam_policy.zapp_enrollments.arn
}
```

`data.aws_caller_identity.current` and `data.aws_region.current` are both already declared in `infrastructure/terraform/init.tf`, and `local.environment` is defined there too. **Do not redeclare them** — read `init.tf` and confirm before writing.

`dynamodb:PutItem` and `dynamodb:DeleteItem` cover the transaction: `TransactWriteItems` authorises against the underlying item actions, not a separate permission.

- [ ] **Step 2: Add the env vars**

In `infrastructure/terraform/env.tf`'s `ecs_env_vars` list, add:

```hcl
    {
      name  = "ZAPP_ENROLLMENT_TABLE"
      value = "zapp-enrollments"
    },
    {
      name  = "ZAPP_ENROLLMENT_WRITES_ENABLED"
      value = "true"
    },
```

`ZAPP_DYNAMODB_ENDPOINT` is deliberately **not** set — the SDK resolves the real endpoint, and an accidental value here would point production at nothing.

- [ ] **Step 3: Validate and commit**

```bash
cd infrastructure/terraform
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
cd ~/Projects/conductor-api
git add infrastructure/terraform/iam.tf infrastructure/terraform/env.tf
git commit -m "feat(infra): grant the task role access to zapp's enrollment table"
```

- [ ] **Step 4: Document it**

Add a row to `infrastructure/terraform/README.md`'s environment-variable table for `ZAPP_ENROLLMENT_TABLE` and `ZAPP_ENROLLMENT_WRITES_ENABLED`, and note that the Auto-Merge page writes a DynamoDB table owned by `bankrate/zapp`'s Terraform, in the same account.

```bash
git add infrastructure/terraform/README.md
git commit -m "docs(infra): document the zapp enrollment env vars"
```

---

### Task 7: Validate it end to end, locally

The requirement: log in and use the page for real, the way the Portkey reader/writer work was validated.

- [ ] **Step 1: Start clean**

```bash
cd ~/Projects/conductor-api
docker compose up -d dynamodb-local mailpit
php artisan migrate:fresh --seed
php artisan serve
```

- [ ] **Step 2: Log in BEFORE seeding**

Open `http://127.0.0.1:8000/admin/login` and log in.

Order matters, and it did for Portkey too: establish the session first, because a
seed that touches `users` after login can invalidate it and the failure looks
like a permissions bug.

- [ ] **Step 3: Seed**

```bash
php artisan zapp:enrollment-seed --actor="$(git config user.email)"
```

- [ ] **Step 4: Grant yourself the permission**

`migrate:fresh --seed` creates the permission but your user may hold no role that has it:

```bash
php artisan tinker --execute="\App\Models\User::where('email','$(git config user.email)')->first()->givePermissionTo('manage auto-merge enrollment'); app(\Spatie\Permission\PermissionRegistrar::class)->forgetCachedPermissions();"
```

- [ ] **Step 5: Walk the page**

Reload `/admin`, open **Inventory → Auto-Merge**, and confirm each of these:

| Check | Expected |
|---|---|
| Nav placement | "Auto-Merge" in the Inventory group, below Repos |
| The eight seeded repos | badge `shadow`, classification and tier populated, Overrides `global` |
| Any other repo | badge `not enrolled`, `—` in the enrollment columns |
| Filter → Enrolled only | exactly eight rows |
| Filter → Not enrolled | the eight are absent |
| Filter → classification `prod-service` | four rows (conductor-api, portkey, brand-identity-pages-app, redirect-management-api-v2) |
| Enroll on an unenrolled repo | form opens; the three override toggles are off and their inputs hidden |
| Enroll, submitted | success notification, badge flips to `shadow` without a manual reload |
| Pause | badge flips to `paused`; the row keeps its classification |
| Resume | badge returns to `shadow` |
| Edit, override toggled on with one entry | Overrides column shows `signalChecks` |
| Edit, override toggled back off | Overrides column returns to `global` |
| Unenroll | confirmation names the repository; row returns to `not enrolled` |
| Doc link | opens zapp's `docs/policy.md` |

- [ ] **Step 6: Verify the writes really landed, and that absence was preserved**

```bash
export AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local
aws dynamodb query --table-name zapp-enrollments \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"repo"}}' \
  --endpoint-url http://localhost:8001 --region us-east-1 \
  --query 'Items[].{repo:repo.S,mode:mode.S,v:version.N,sc:signalChecks}' --output table
```

Expected: the repo you enrolled is present, and the `sc` column is **empty** for
every record whose override toggle you left off — not `[]`. This is the one
result worth checking by hand: `[]` would tell zapp to wait on no checks at all.

Then the history for a repository you edited:

```bash
aws dynamodb query --table-name zapp-enrollments \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"history#bankrate/brcc-api"}}' \
  --endpoint-url http://localhost:8001 --region us-east-1 \
  --query 'Items[].{action:action.S,actor:actor.S,at:at.S,v:version.N}' --output table
```

Expected: one row per action you took, in order, each naming your email, with
`version` incrementing.

- [ ] **Step 7: Prove the conflict path**

With the Edit form open for one repository, change its version behind the page's back:

```bash
aws dynamodb update-item --table-name zapp-enrollments \
  --key '{"pk":{"S":"repo"},"sk":{"S":"bankrate/portkey"}}' \
  --update-expression 'SET version = :v' \
  --expression-attribute-values '{":v":{"N":"99"}}' \
  --endpoint-url http://localhost:8001 --region us-east-1
```

Now submit the form. Expected: a persistent warning notification saying the
enrollment changed, and — confirmed by re-querying — **no write**. This is the
one behaviour that cannot be verified any other way, and the one whose absence
would silently discard an operator's deliberate change.

- [ ] **Step 8: Run everything and commit**

```bash
php artisan test
vendor/bin/pint --test
```

Expected: the full suite passes.

- [ ] **Step 9: Record the walkthrough**

Add a short "Local development" note to the page's own docs — either a new
`docs/auto-merge.md` or a section in the existing docs directory — covering:
start `dynamodb-local`, set `ZAPP_DYNAMODB_ENDPOINT`, log in, seed, grant the
permission. Steps 1-4 above are the content.

```bash
git add docs/
git commit -m "docs(auto-merge): how to run the enrollment page locally"
```

---

## Self-review notes

**Spec coverage.** The `EnrollmentStore`, `TransactWriteItems`, optimistic concurrency and absent-vs-empty marshalling → Task 1; the permission, its migration and the feature flag → Task 2; DynamoDB Local and the seed → Task 3; the page, the `CONCAT` join and the orphan section → Task 4; the four write actions, the override toggles and the doc links → Task 5; IAM and env vars → Task 6; the log-in-and-click validation → Task 7.

**Two things the spec asked for that landed differently.** The spec said "a header link plus per-field hints"; the hints are `helperText` on each form field in Task 5's `EnrollmentFormSchema` and the header link is in the Blade view, and only the document is deep-linked — no anchors, since anchors outside zapp's own tested `DOC_ANCHORS` set are unverified. The spec also described the orphan section as offering Unenroll; Task 4 renders it as a read-only warning banner, because a Filament Page has one table and an orphan has no Eloquent record to hang a row action on. **Unenrolling an orphan is therefore not possible through the UI** — it needs a CLI `delete-item`. That is a real gap; if it matters, the fix is a page-header action with a Select of orphan names, which is a small follow-up rather than a change to anything here.

**Type consistency.** `EnrollmentData` keeps its field names throughout, and `EnrollmentFormSchema::fill` / `::toData` are exact inverses over the `override{Field}` booleans. `EnrollmentStore::replace` takes `(EnrollmentData, int $expectedVersion, string $actor, string $action)` in Task 1 and is called with exactly that in Task 5. `AutoMergePermission::NAME` is the single source for the permission string, used by the migration, the seeder list and `canWrite()`.

**Known API risk.** Filament v5 is recent and renamed table-action APIs. Task 5 step 5 says explicitly to check `->recordActions()`, `->schema()`, `callTableAction` and `assertTableActionHidden` against `RepoResource.php` and `ListReposTest.php` in this repo rather than assuming. Whoever executes Task 5 should read those two files first.

**One stray line to drop.** Task 1's `replace_conditions_on_the_expected_version_and_bumps_it` test contains `$this->assertSame(['S' => '4'], ['S' => (string) 4]);`, which asserts nothing about the code. It is called out in Task 1 step 2 and must not be carried into the file.
