# Conductor Enrollment Page Follow-Up Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the one correctness defect and four hygiene items left behind by [conductor-api#654](https://github.com/bankrate/conductor-api/pull/654), which merged through the queue before they could be folded in.

**Architecture:** Five independent changes to code that already exists. The only correctness fix is `EnrollmentStore::replace()` silently deleting `enrolledBy`/`enrolledAt` — it issues a `Put`, which replaces the whole item, and `toItem()` does not emit them. The rest are a per-render query multiplication, a config key that is read but never defined, mode strings as bare literals, and two untested branches.

**No spec.** These are known defects in existing code with no design decisions attached. The `enrolledBy` fix has one shape choice, resolved inline in Task 1.

**Tech Stack:** PHP 8.3 / Laravel, Filament v5, `aws/aws-sdk-php`, PHPUnit with `#[Test]` attributes + Livewire testing.

**Origin:** PR #654's own body deferred items 3 and 4 plus a "genuine Minor" list. Task 1 is the one that body under-rates — see below.

## Global Constraints

- **`EnrollmentStore::replace()` uses `Put`, so any attribute `toItem()` omits is deleted.** That is the root cause of Task 1 and the reason Task 1 adds a docblock rule rather than only a patch.
- **The 8 live qa records currently have `enrolledBy` populated and `version: 1`** — verified 2026-08-31. The first edit, pause, or resume through the page wipes it. Land Task 1 before the Task 8 browser walkthrough.
- **Do not make `enrolledBy`/`enrolledAt` required constructor parameters.** There are **9** `EnrollmentData` construction sites, and `EnrollmentFormSchema::toData()` genuinely cannot supply them — the form is not the source of that fact.
- Conventional Commits (`commitlint` runs in CI). Run `php artisan test` and `vendor/bin/pint --test` before every commit.
- Local tests need real MySQL, not SQLite. PR #654's body records that two implementers lost time to this; if `.env` is missing, copy `.env.example` and point it at a local MySQL 8 before starting.

---

### Task 1: Stop `replace()` deleting the original enroller

The only correctness fix here. PR #654 ruled this acceptable on the grounds that
"nothing reads these fields today" and they are "recoverable via the DynamoDB
history partition" — both true, and both beside the point:
`docs/superpowers/zapp/specs/2026-08-28-enrollment-registry-and-conductor-ui-design.md`
specifies `enrolledBy`/`enrolledAt` as **"Set once, never overwritten."** The
implementation overwrites them with nothing on every update.

**Files:**
- Modify: `app/Data/Zapp/EnrollmentData.php`
- Modify: `app/Services/Zapp/EnrollmentStore.php` (`fromItem`, `replace`, `toItem` docblock)
- Modify: `tests/Feature/Services/Zapp/EnrollmentStoreTest.php`

**Interfaces:**
- Produces: `EnrollmentData::$enrolledBy` and `::$enrolledAt`, both `?string` defaulting to `null`.

- [ ] **Step 1: Verify the base and the defect**

```bash
cd ~/Projects/conductor-api
git fetch origin && git checkout main && git pull --ff-only
git log --oneline -3
grep -n "enrolledBy" app/Services/Zapp/EnrollmentStore.php
```

Expected: PR #654's merge commit present, and `enrolledBy` appearing **only**
inside `create()` — not in `toItem()` and not in `replace()`. If it already
appears in `replace()`, this task has landed; stop and re-read.

```bash
grep -c "new EnrollmentData\|EnrollmentData::from" -r app/ tests/
```

Expected: 9. That count is why Step 2 uses nullable defaults rather than
required parameters.

- [ ] **Step 2: Write the failing test**

In `tests/Feature/Services/Zapp/EnrollmentStoreTest.php`, first add the two
attributes to the `item()` fixture so a stored record looks like a real one:

```php
            'enrolledBy' => ['S' => 'scrosby@bankrate.com'],
            'enrolledAt' => ['S' => '2026-08-28T10:00:00+00:00'],
```

Then add the regression test:

```php
    #[Test]
    public function replace_preserves_the_original_enroller(): void
    {
        // A Put replaces the WHOLE item, so any attribute toItem() does not emit
        // is deleted. Before this fix, the first pause or edit wiped who
        // originally enrolled the repository — and the spec says those two
        // fields are set once, never overwritten.
        $captured = null;

        $this->mock(DynamoDbClient::class, function (MockInterface $mock) use (&$captured): void {
            $mock->shouldReceive('getItem')->once()->andReturn(new Result(['Item' => $this->item()]));
            $mock->shouldReceive('transactWriteItems')->once()
                ->andReturnUsing(function (array $args) use (&$captured): Result {
                    $captured = $args;

                    return new Result([]);
                });
        });

        app(EnrollmentStore::class)->replace(
            $this->data(['mode' => 'off']), 3, 'someone-else@bankrate.com', 'pause',
        );

        $item = $captured['TransactItems'][0]['Put']['Item'];
        $this->assertSame(['S' => 'scrosby@bankrate.com'], $item['enrolledBy'],
            'the original enroller survives an update by a different person');
        $this->assertSame(['S' => '2026-08-28T10:00:00+00:00'], $item['enrolledAt']);
        $this->assertSame(['S' => 'someone-else@bankrate.com'], $item['updatedBy'],
            'updatedBy DOES change — that is the difference between the two pairs');
    }

    #[Test]
    public function replace_preserves_an_empty_override_list(): void
    {
        // The same Put-drops-what-toItem-omits hazard, on the other field that
        // carries meaning by its emptiness. `[]` means "wait on nothing", which
        // is a deliberate instruction and must survive a pause round-trip.
        $captured = null;

        $stored = $this->item(['signalChecks' => ['L' => []]]);

        $this->mock(DynamoDbClient::class, function (MockInterface $mock) use (&$captured, $stored): void {
            $mock->shouldReceive('getItem')->once()->andReturn(new Result(['Item' => $stored]));
            $mock->shouldReceive('transactWriteItems')->once()
                ->andReturnUsing(function (array $args) use (&$captured): Result {
                    $captured = $args;

                    return new Result([]);
                });
        });

        app(EnrollmentStore::class)->replace(
            $this->data(['mode' => 'off', 'signalChecks' => []]), 3, 'a@bankrate.com', 'pause',
        );

        $this->assertSame(['L' => []], $captured['TransactItems'][0]['Put']['Item']['signalChecks']);
    }
```

The second test may already pass — `toItem()` writes `{L: []}` for `[]` because
it checks `!== null`. Write it anyway: it is the *other* attribute whose
emptiness is load-bearing, and nothing currently pins it.

- [ ] **Step 3: Run to verify the first fails**

```bash
php artisan test --filter=replace_preserves_the_original_enroller
```

Expected: FAIL — `$item['enrolledBy']` is undefined, because `toItem()` never
emitted it.

- [ ] **Step 4: Add the fields to the data object**

In `app/Data/Zapp/EnrollmentData.php`, append to the constructor — **after**
`updatedAt`, since promoted parameters with defaults must come last:

```php
        /**
         * Set once at enrollment and never overwritten.
         *
         * NULLABLE WITH A DEFAULT on purpose. Nine call sites construct this,
         * and `EnrollmentFormSchema::toData()` cannot supply these — the form is
         * not the source of that fact. Only `EnrollmentStore::fromItem()`
         * populates them, and `replace()` carries them across from the stored
         * record.
         */
        public ?string $enrolledBy = null,
        public ?string $enrolledAt = null,
```

- [ ] **Step 5: Read them, carry them, and document the hazard**

In `app/Services/Zapp/EnrollmentStore.php`:

`fromItem()` gains, matching how `updatedBy` already defends against absence:

```php
            enrolledBy: $item['enrolledBy']['S'] ?? null,
            enrolledAt: $item['enrolledAt']['S'] ?? null,
```

`replace()` carries them forward from `$before`, which it already fetches:

```php
        $item = $this->toItem($data, $nextVersion, $actor, $now);

        // enrolledBy/enrolledAt are set once and never overwritten. This is a
        // Put, which replaces the WHOLE item, so they must be restated or they
        // are deleted. Taken from $before rather than $data because the stored
        // record is authoritative — a caller that built $data from a form has
        // nulls here.
        if ($before?->enrolledBy !== null) {
            $item['enrolledBy'] = ['S' => $before->enrolledBy];
        }
        if ($before?->enrolledAt !== null) {
            $item['enrolledAt'] = ['S' => $before->enrolledAt];
        }
```

And the durable guard — add to `toItem()`'s docblock:

```php
 * EVERY ATTRIBUTE THE RECORD SHOULD KEEP MUST BE EMITTED HERE. `replace()`
 * issues a Put, which replaces the whole item, so anything this method omits is
 * silently deleted on the next update. `enrolledBy`/`enrolledAt` are the
 * exception and are restated by `replace()` itself, because they are set once
 * and this method has no access to the prior values.
```

That comment is worth more than the patch: it is what stops the next person
adding a set-once attribute from reintroducing this.

- [ ] **Step 6: Run everything**

```bash
php artisan test
vendor/bin/pint --test app/Data/Zapp app/Services/Zapp
```

Expected: PASS, including all 9 construction sites — the nullable defaults mean
none of them needed touching. If any fail on a missing argument, the two
parameters were not appended last.

- [ ] **Step 7: Commit**

```bash
git add app/Data/Zapp/EnrollmentData.php app/Services/Zapp/EnrollmentStore.php \
        tests/Feature/Services/Zapp/EnrollmentStoreTest.php
git commit -m "fix(auto-merge): stop replace() deleting the original enroller

EnrollmentStore::replace() issues a Put, which replaces the whole item, and
toItem() never emitted enrolledBy/enrolledAt -- so the first edit, pause or
resume wiped them. The spec specifies both as set once, never overwritten."
```

- [ ] **Step 8: Confirm the live records survive an edit**

After deploy, pause and resume one repository through the page, then:

```bash
aws dynamodb query --table-name zapp-enrollments --profile bankrate-qa --region us-east-1 \
  --key-condition-expression 'pk = :pk' --expression-attribute-values '{":pk":{"S":"repo"}}' \
  --query 'Items[].{repo:repo.S,v:version.N,enrolledBy:enrolledBy.S,updatedBy:updatedBy.S}' --output table
```

Expected: the touched record shows `version: 3`, `enrolledBy` still
`scrosby@bankrate.com`, and `updatedBy` set to whoever clicked. All 8 records had
`enrolledBy` populated at `version: 1` as of 2026-08-31 — if any read blank
before you start, an edit already happened and that record's original enroller is
recoverable only from its `history#{repoId}` partition.

---

### Task 2: Memoize `needsAttention()`

**Files:**
- Modify: `app/Filament/Pages/AutoMerge.php`
- Modify: `tests/Feature/Filament/Pages/AutoMergeTest.php`

- [ ] **Step 1: Confirm the multiplication**

```bash
grep -n "needsAttention()" app/Filament/Pages/AutoMerge.php resources/views/filament/pages/auto-merge.blade.php
```

Expected: **5 call sites** — the header action's `visible`, its `badge`, its
`options`, its `action`, and the Blade view. Each runs a `Repo::query()`, so a
single render costs up to five queries for identical data. `enrollments()` is
already memoized against exactly this; `needsAttention()` was not given the same
treatment.

- [ ] **Step 2: Write the failing test**

```php
    #[Test]
    public function the_stale_set_is_computed_once_per_request(): void
    {
        // Five call sites read it — the header action's visible/badge/options/
        // action plus the Blade view. Unmemoized that is five identical queries
        // per render, the same reason enrollments() is memoized.
        Repo::factory()->create(['external_id' => '777', 'owner' => 'bankrate', 'name' => 'old', 'archived' => true]);

        $this->fleetIs($this->record('777', 'bankrate/old'));
        $this->actingAs($this->permittedUser());

        \DB::enableQueryLog();
        Livewire::test(AutoMerge::class)->assertOk();
        $staleQueries = collect(\DB::getQueryLog())
            ->filter(fn (array $q): bool => str_contains($q['query'], 'external_id'))
            ->count();
        \DB::disableQueryLog();

        $this->assertLessThanOrEqual(2, $staleQueries,
            'one for the table filter, one for the stale set — not one per call site');
    }
```

If the table's own filters also query `external_id`, raise the bound to match
what a memoized implementation actually produces — read the query log output
rather than guessing the number.

- [ ] **Step 3: Memoize it**

Mirror the existing `$fleet` memoization exactly, including the reason it is not
a public Livewire property:

```php
    /**
     * Stale enrollments, computed once per request.
     *
     * Memoised for the same reason as $fleet, and deliberately NOT a public
     * Livewire property: those are serialised between requests, which would both
     * bloat the payload and serve a stale set after somebody else's write.
     *
     * @var Collection<int, array{record: EnrollmentData, reason: string}>|null
     */
    private ?Collection $stale = null;
```

Wrap the existing body, and extend `refreshEnrollments()` to clear it — a write
changes the stale set as surely as it changes the fleet:

```php
    public function refreshEnrollments(): void
    {
        $this->fleet = null;
        $this->stale = null;
    }
```

**Forgetting the second line is the bug this task would otherwise introduce:**
resolving a stale enrollment would leave the banner showing it until reload.

- [ ] **Step 4: Fold in the docblock fix**

PR #654's body parks a "purely cosmetic" finding at `AutoMerge.php:99-100` — a
leftover docblock sentence ("…a renamed one sends them under a name that is not
enrolled") made locally contradictory by a fix-wave edit to the adjacent bullet.
Since this task is already in that file, read those lines and strike the
sentence if it is still there.

```bash
sed -n '90,110p' app/Filament/Pages/AutoMerge.php
```

If it is already gone, note that and move on — it is not worth a hunt.

- [ ] **Step 5: Test and commit**

```bash
php artisan test --filter=AutoMergeTest
vendor/bin/pint --test app/Filament/Pages/AutoMerge.php
git add app/Filament/Pages/AutoMerge.php tests/Feature/Filament/Pages/AutoMergeTest.php
git commit -m "perf(auto-merge): compute the stale-enrollment set once per request"
```

---

### Task 3: Define the AWS region config key that is read

**Files:**
- Modify: `config/services.php`
- Modify: `app/Providers/AppServiceProvider.php`

- [ ] **Step 1: Confirm the defect**

```bash
grep -n "services.aws.region" app/Providers/AppServiceProvider.php
grep -n -A4 "'aws' =>" config/services.php
```

Expected: `AppServiceProvider` reads `config('services.aws.region', env('AWS_DEFAULT_REGION', 'us-east-1'))`, and the `services.aws` block has
`conductor_role_name` and `sso_access_portal_url` but **no `region`**.

**Why this matters more than "harmlessly falls through to `env()`":** that
`env()` call is in *application* code, not a config file. Laravel's
`config:cache` — which production runs — makes `env()` return `null` outside
config files. So in production the expression collapses to the literal
`'us-east-1'`, and the `AWS_DEFAULT_REGION` env var the ECS task sets is
**ignored**. Correct today only because `us-east-1` happens to be right.

- [ ] **Step 2: Define the key**

In `config/services.php`, inside the existing `'aws' =>` block:

```php
        // Read by the DynamoDB client binding in AppServiceProvider. Defined
        // HERE rather than as an inline env() default in that provider, because
        // env() returns null outside config files once config:cache has run —
        // which would silently ignore the task definition's AWS_DEFAULT_REGION.
        'region' => env('AWS_DEFAULT_REGION', 'us-east-1'),
```

- [ ] **Step 3: Simplify the read**

In `app/Providers/AppServiceProvider.php`:

```php
                'region' => config('services.aws.region'),
```

- [ ] **Step 4: Verify under a cached config**

```bash
php artisan config:cache
php artisan tinker --execute="dd(config('services.aws.region'));"
php artisan config:clear
```

Expected: the region, not `null`. **Run `config:clear` afterwards** — a stale
cached config in a dev checkout produces mystifying failures later.

- [ ] **Step 5: Commit**

```bash
git add config/services.php app/Providers/AppServiceProvider.php
git commit -m "fix(config): define services.aws.region instead of an env() default in app code"
```

---

### Task 4: Replace the mode string literals

Hygiene. A reviewer may reasonably decline this one; it is separated so they can.

**Files:**
- Create: `app/Enums/EnrollmentMode.php`
- Modify: the files that carry the literals

- [ ] **Step 1: Count them**

```bash
grep -rn "'shadow'\|'off'" app/ --include=*.php | grep -v Enums | wc -l
grep -rln "'shadow'" app/ --include=*.php
```

PR #654's body reports 17 occurrences of `'shadow'` across several files,
confirmed 2026-08-31.

- [ ] **Step 2: Add the enum**

```php
<?php

namespace App\Enums;

/**
 * A repository's enrollment mode in zapp's merge-policy service.
 *
 * zapp treats this as an ALLOW-LIST, not `!== off`: only a recognised active
 * mode counts as enrolled, because the value comes from a table rather than a
 * build-time-validated file. Adding a case here without adding it to zapp's
 * `isEnrolled` makes repositories silently un-enrolled.
 */
enum EnrollmentMode: string
{
    case Shadow = 'shadow';
    case Off = 'off';
}
```

That docblock is the actual value of this task — it records a cross-repo
coupling that a bare string cannot.

- [ ] **Step 3: Replace the literals**

Use `EnrollmentMode::Shadow->value` where a string is needed (the DynamoDB
marshalling, the `EnrollmentData::$mode` property, the Filament `Select`
options). **Do not** change `EnrollmentData::$mode`'s type to the enum —
`spatie/laravel-data` will cast it, but `toItem()`/`fromItem()` and every
`EnrollmentData::from([...])` spread then need updating, which turns a hygiene
task into a refactor across all 9 construction sites. Keep the property a
`string` and use the enum at the literal sites only.

- [ ] **Step 4: Test and commit**

```bash
php artisan test
vendor/bin/pint --test
git add app/ tests/
git commit -m "refactor(auto-merge): name the enrollment modes instead of repeating literals"
```

---

### Task 5: Cover the `resolve_stale` race branch

**Files:**
- Modify: `tests/Feature/Filament/Pages/AutoMergeTest.php`

- [ ] **Step 1: Read the branch**

```bash
grep -n -A12 "resolve_stale" app/Filament/Pages/AutoMerge.php | grep -A10 "no longer stale"
```

The action re-reads `needsAttention()` inside its handler and, if the selected
repository is no longer there, notifies and refreshes instead of deleting. That
is the branch where two operators resolve the same stale enrollment at once, and
nothing tests it.

- [ ] **Step 2: Write the test**

```php
    #[Test]
    public function resolving_an_already_resolved_stale_enrollment_deletes_nothing(): void
    {
        // Two operators clicking the same stale entry. The second must not
        // delete a record that is no longer stale — the selected id is stale
        // only in the first operator's now-superseded view.
        Repo::factory()->create(['external_id' => '777', 'owner' => 'bankrate', 'name' => 'old', 'archived' => false]);

        $this->mock(EnrollmentStore::class, function (MockInterface $mock): void {
            // Healthy: present in inventory and not archived, so not stale.
            $mock->shouldReceive('fleet')->andReturn(collect([
                '777' => $this->record('777', 'bankrate/old'),
            ]));
            $mock->shouldReceive('delete')->never();
        });

        $this->actingAs($this->permittedUser());

        Livewire::test(AutoMerge::class)
            ->callAction('resolve_stale', data: ['repo' => '777'])
            ->assertNotified();
    }
```

The action may be hidden when `needsAttention()` is empty, in which case
`callAction` cannot reach the handler. If so, set the repository archived so the
action is visible, and have the mocked `fleet()` return a *healthy* record on
its second call — read the action's `visible()` closure and shape the mock to
exercise the handler rather than the guard.

- [ ] **Step 3: Run and commit**

```bash
php artisan test --filter=resolving_an_already_resolved
git add tests/Feature/Filament/Pages/AutoMergeTest.php
git commit -m "test(auto-merge): cover the concurrent stale-resolution branch"
```

---

## Self-review notes

**Origin coverage.** PR #654's ruling 3 (`enrolledBy`/`enrolledAt`) → Task 1. Ruling 4 (the docblock) → folded into Task 2, which is already in that file. From its deferred-Minors list: `needsAttention()` re-querying → Task 2; `services.aws.region` → Task 3; mode literals → Task 4; the `resolve_stale` race branch → Task 5; and the `[]`-survives-a-pause case → Task 1's second test, since it is the same Put-drops-what-`toItem()`-omits hazard.

**One item from that list is deliberately not here.** PR #654 also mentions `EnrollmentStore::replace()` not carrying `enrolledBy` "matching the plan's own original Task 1 code exactly" — which is true, and the defect originated in that plan rather than in the implementation. Recorded so the next reader does not go looking for an implementer error.

**Task independence.** All five touch disjoint files except Tasks 2 and 5, which both edit `AutoMergeTest.php` — do them in order or expect a trivial conflict. Only Task 1 is a correctness fix; a reviewer could decline 3, 4 or 5 without affecting the others.

**Two tasks add tests that may already pass.** Task 1's `replace_preserves_an_empty_override_list` and Task 5's race-branch test both pin existing behaviour rather than fixing it. Each step says so, so nobody spends time hunting a failure that is not there.

**The riskiest step is Task 2's.** Memoizing without clearing the memo in `refreshEnrollments()` makes the banner stale after a write — a worse bug than the four queries it removes. Step 3 states it explicitly for that reason.
