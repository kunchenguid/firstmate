# Usage-limit survivability verification

Active empirical evidence for the guarantees in [`docs/usage-limit-survivability.md`](../usage-limit-survivability.md).
Refresh it by re-running the commands below on the host in question.

## Environment

- Dates: 2026-08-26, extended 2026-08-27 with the live-fleet record, the predicted wall, and the wall this surface was itself stranded by; the headroom sections re-taken 2026-08-30 against the floor-compliant gauge
- Platform: Darwin 25.6.0
- `quota-axi 0.1.34` (at or above the `FM_QUOTA_AXI_MIN` floor of `0.1.29`, which is the only build this gauge reads)
- `no-mistakes version v1.57.0 (0fcbbff) 2026-08-22T05:14:30Z`
- `tmux 3.7b`

## How the two gauge paths are verified, and why differently

This is an asymmetry, and it is deliberate rather than an omission.

The FLOOR path is verified LIVE, by executing `bin/fm-usage-wall.sh headroom` against the real `quota-axi 0.1.34` on this host; every headroom sample below that is not explicitly marked otherwise is that command's own output.
The BELOW-FLOOR path is covered by a STUB, in `tests/fm-usage-wall.test.sh`, because no real below-floor build remains reachable here to execute against.
Neither is described as the other anywhere on this page.

A sample that is constructed rather than observed says so on the spot, every time - deliberately not counted here, because the set has grown in every round and a number written down once goes stale silently.
Some of them take this host's real report and drive a single field, because the conditions they show - an exhausted account, two windows disagreeing - do not arrive on demand; the rest are stubs, because the condition they reproduce has never appeared on this host at all.

## The gauge reads, and an unread gauge is distinguishable from a healthy one

`bin/fm-usage-wall.sh headroom` against the live `quota-axi 0.1.34`, one measurable provider and nine unmeasurable ones in a single reading, captured 2026-08-30T05:11Z:

```
HEADROOM: claude ok pct=54 bound=five_hour resets=2026-08-30T08:00:00.393951+00:00 runway=2h34m confidence=established
HEADROOM: codex unknown reason=provider-read-failed status=error detail=Codex quota unavailable
HEADROOM: cursor unknown reason=auth-required status=auth_required detail=Cursor sign-in required - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM: copilot unknown reason=auth-required status=auth_required detail=GitHub Copilot sign-in required - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM: grok unknown reason=auth-required status=auth_required detail=Grok sign-in required (auth unusable) - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM: kimi unknown reason=auth-required status=auth_required detail=kimi_credential_unavailable - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM: zai unknown reason=auth-required status=auth_required detail=zai_credential_unavailable - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM: agy unknown reason=no-measurable-window status=unavailable detail=Antigravity/agy is not running
HEADROOM: alibaba unknown reason=no-measurable-window status=unavailable detail=bl_cli_unavailable
HEADROOM: opencode-go unknown reason=auth-required status=auth_required detail=opencode_go_credential_unavailable - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM_SUMMARY: verdict=partial measured=1 tight=0 wall=0 unknown=9 source=quota-axi/0.1.34
HEADROOM_ROWS: emitted=14 read=11 declined=3 reasons=not-account-scope=2,superseded-by-reported-row=1
HEADROOM_NOTE: an unknown provider is UNMEASURED, not healthy - treat its headroom as unproven when deciding what to dispatch.
HEADROOM_NEXT: <repo>/bin/fm-usage-wall.sh resume regenerates the resume record for the work now in flight.
```

That reading is taken from this report, which is what the floor-compliant gauge actually emits.
Note that `claude` is present twice, once at account scope and once at `model:fable`, in every one of the three tables:

```
$ quota-axi
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,54,1.8637,projected_exhaustion,established,five_hour,"2026-08-30T07:59:59.782541+00:00"
  claude,"model:fable",54,unknown,projected_exhaustion,established,five_hour,"2026-08-30T07:59:59.782541+00:00"
exhaustion[2]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  claude,all_models,9256,"2026-08-30T07:45:40.345Z",five_hour
  claude,"model:fable",9256,"2026-08-30T07:45:40.345Z",five_hour
attention[10]{provider,scope,kind,detail,remedy}:
  claude,"model:fable",unmeasurable,"model:fable blocks spendPriority",none
  codex,all,error,Codex quota unavailable,none
  ...
```

The `HEADROOM_ROWS` line is checkable against that report by hand, which is the point of publishing it: 2 quota rows plus 2 exhaustion rows plus 10 attention rows is 14 emitted; the account-scoped quota row, the exhaustion row its runway came from, and nine attention rows is 11 read; the three `model:fable` rows are the 3 declined - two dropped by the scope filter because a model-scoped row is not the dispatch gauge, one suppressed because `claude` was already reported at account scope.
Nothing the gauge emitted is unaccounted for, and the reading says so rather than leaving it to be inferred.

An earlier capture on the same host and build, 2026-08-30T03:46Z, carried `exhaustion[0]:` - an empty table, rendered with a zero count and no field list at all - and the same reading then printed `runway=unknown(through_reset)` rather than zero.
That is the sparseness the layout guarantees and the reason a missing exhaustion row is an unknown runway rather than a zero one; the capture above simply happens to have runway rows.

The same command with no `quota-axi` on `PATH`.
The verdict is `unknown` with its reason, never `ok`:

```
HEADROOM: (all providers) unknown reason=quota-axi is not installed
HEADROOM_SUMMARY: verdict=unknown measured=0 tight=0 wall=0 unknown=1 source=quota-axi/unavailable build=unavailable
HEADROOM_ROWS: emitted=0 read=0 declined=0
HEADROOM_NOTE: headroom is UNMEASURED, not healthy - install it with npm install -g quota-axi to get a reading.
HEADROOM_NEXT: <repo>/bin/fm-usage-wall.sh resume regenerates the resume record for the work now in flight.
```

`tests/fm-usage-wall.test.sh` pins the remaining unmeasurable paths - a failing gauge, a hanging gauge, a report with neither table, a row whose percentage is not a number, a row that names no provider, and `auth_required` - along with the rule that `--allow-keychain-prompt` is never passed.

The two surfaces that RENDER this gauge - the fleet view and the session-start digest - print the same lines when they could not run the command at all, from the one owner in [`bin/fm-headroom-lib.sh`](../../bin/fm-headroom-lib.sh), exactly as shown in the two samples above.
Written out per caller, the copies had drifted (`treat it as unproven` against `treat every provider as unproven`) and both emitted only the reason and the note, so a reader or consumer scanning for `HEADROOM_SUMMARY: verdict=` found no verdict on exactly the paths where the gauge failed.
`tests/fm-fleet-snapshot-view.test.sh` and `tests/fm-session-start.test.sh` each drive that fallback through a real non-zero exit and assert the full shape, so a gauge that could not be RUN reads exactly like a gauge that could not be READ.

## A build below the floor is refused, not read

Stub-covered, as stated above: no below-floor build is reachable on this host, so the stub declares `0.0.1` - the version `tests/fm-usage-wall.test.sh` actually gives it - and serves a report the gauge never reaches.
The refusal names the installed version and the floor in the line itself, and the `build=` label agrees with the verdict rather than sitting beside a contradictory one:

```
HEADROOM: (all providers) unknown reason=quota-axi 0.0.1 is below the supported floor 0.1.29, and its report layout is not the one this gauge reads
HEADROOM_SUMMARY: verdict=unknown measured=0 tight=0 wall=0 unknown=1 source=quota-axi/0.0.1 build=below-floor(0.1.29)
HEADROOM_ROWS: emitted=0 read=0 declined=0
HEADROOM_NOTE: headroom is UNMEASURED, not healthy - upgrade quota-axi to 0.1.29 or newer, then re-read; until then no provider headroom is measured.
HEADROOM_NEXT: <repo>/bin/fm-usage-wall.sh resume regenerates the resume record for the work now in flight.
```

No percentage appears, because nothing was parsed.
That is the point: builds below the floor emit a different layout, and a reading that looked fine from a build this repository rejects is the exact failure this surface exists to prevent.

## An exhausted provider reads as `wall`, in prose and in the JSON

CONSTRUCTED, not observed: this host's real `quota-axi 0.1.34` report with the account-level row's `effectivePercentRemaining` driven to `0`, which is the one field that separates an exhausted provider from a low one.
Everything else in the report is the host's real output:

```
HEADROOM: claude wall pct=0 bound=five_hour resets=2026-08-30T08:00:00.092088+00:00 runway=unknown(through_reset) confidence=early
HEADROOM_SUMMARY: verdict=wall measured=1 tight=0 wall=1 unknown=9 source=quota-axi/0.1.34
HEADROOM_NOTE: 1 provider(s) are AT the wall, not merely low - work on them has already stopped. Load the usage-limit-recovery skill.
```

The same reading through `--json`, which is what a programmatic consumer branches on:

```
{"verdict":"wall","wall":1,"tight":0,"measured":1,"unknown":9}
```

The distinction holds in both directions: the unmodified live report on the same host, taken minutes earlier, returned `{"verdict":"partial","wall":0,"tight":0,"measured":1,"unknown":9}`.

## An unmeasured provider never reads as healthy

Below are the ways a reading can go unmeasured, or be misread, without the gauge noticing, each one reproduced against a stub report and each now pinned in `tests/fm-usage-wall.test.sh`.
Deliberately not counted: the list grew in every round of this change, and a number restated in the sentence above it is stale the moment the next entry is added.

A percentage that is not a number.
`toon_block` resolves fields by name and yields `-` for one the header never declared, so an upstream rename of `effectivePercentRemaining` leaves every row unreadable at once.
Before the guard the row was counted as MEASURED and compared its way to healthy - `HEADROOM: claude ok pct=- ...` under `verdict=ok measured=1 unknown=0`, a clean dispatch gauge for a provider nobody measured.
It now reads:

```
HEADROOM: claude unknown reason=unreadable-percent status=unreadable_percent detail=effectivePercentRemaining is not a number (-)
HEADROOM_SUMMARY: verdict=unknown measured=0 tight=0 wall=0 unknown=1 source=quota-axi/0.1.40
```

A provider named in `attention[]` whose only `quota[]` row is model-scoped.
The quota loop reports account scope only, and the attention loop used to skip any provider named anywhere in `quota[]`, by name alone, so such a provider fell through both and vanished: `verdict=ok measured=1 unknown=0` with no `claude` line at all.
The dedupe now suppresses only a provider this reading actually reported, and reads `attention[]` account-scope-first rather than filtered to it:

```
HEADROOM: cursor ok pct=77 bound=seven_day resets=2026-09-02T07:59:59Z runway=unknown(projected_exhaustion) confidence=early
HEADROOM: claude unknown reason=auth-required status=auth_required detail=Claude sign-in required - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read
HEADROOM_SUMMARY: verdict=partial measured=1 tight=0 wall=0 unknown=1 source=quota-axi/0.1.40
```

A provider whose only `quota[]` row is model-scoped and which `attention[]` never names at all.
It fell through both loops the same way, and the dedupe fix above did not reach it because there was no `attention[]` row to read: `verdict=ok measured=1 unknown=0` with a provider at 3 percent invisible to the dispatch decision.
Enumerating the ways a provider can be missed is what kept reopening this, so the reading now sweeps every name the report mentions anywhere - `quota[]` at any scope, `exhaustion[]`, `attention[]` - and `tests/fm-usage-wall.test.sh` asserts that invariant directly, from one assertion body driven over a list of gauge fixtures, rather than adding a case per shape:

```
HEADROOM: cursor ok pct=77 bound=seven_day resets=2026-09-02T07:59:59Z runway=4h0m confidence=early
HEADROOM: claude unknown reason=no-account-level-row status=not_reported scope=model:fable detail=named only in quota, with no account-level quota row and nothing in attention
HEADROOM_SUMMARY: verdict=partial measured=1 tight=0 wall=0 unknown=1 source=quota-axi/0.1.40
```

A second `quota[]` block reading the FIRST block's column positions.
The header-parsing path was two copies and only one of them cleared the field-index map, so a second same-named block separated from the first by any non-indented line inherited the earlier positions - and the live 0.1.34 report emits exactly such a line, the sparse `exhaustion[0]:`.
With the live header first and a second block that drops `limitedBy`, `limitedBy` kept the first header's position 7, which is `resetsAt` in the second, and the row's own RESET TIME was printed as the window bounding its percentage:

```
HEADROOM: cursor ok pct=77 bound=2026-09-02T07:59:59Z resets=2026-09-02T07:59:59Z runway=unknown(projected_exhaustion) confidence=early
```

That is the mislabelled window the section below exists to prevent, reached through the report shape a supported build actually emits.
The two copies are now one function, so both entries clear and repopulate identically and a field the second header omits reads as absent:

```
HEADROOM: claude ok pct=97 bound=five_hour resets=2026-08-30T08:00:00Z runway=unknown(through_reset) confidence=early
HEADROOM: cursor ok pct=77 bound=- resets=2026-09-02T07:59:59Z runway=unknown(projected_exhaustion) confidence=early
HEADROOM: codex unknown reason=provider-read-failed status=error detail=Codex quota unavailable
HEADROOM_SUMMARY: verdict=partial measured=2 tight=0 wall=0 unknown=1 source=quota-axi/0.1.40
```

A percentage rejected for being fractional.
The guard accepted integers only while this command's own header states the rule as a number, so `34.5` read `unreadable-percent` and blanked a gauge that was fully readable on a build clearing the floor - the same false unmeasurable, arriving from the opposite direction and invisible to the below-floor refusal because the build is supported.
No observed build emits a fraction, so this is CONSTRUCTED rather than observed; it is fixed as a coherence defect, code disagreeing with its own authoritative description.
A fraction of a percent reads `tight`, not `wall`, because `wall` is the claim that the provider has already stopped:

```
HEADROOM: claude ok pct=34.5 bound=five_hour resets=2026-08-27T02:19:59Z runway=unknown(projected_exhaustion) confidence=early
HEADROOM: cursor tight pct=0.4 bound=seven_day resets=2026-09-02T07:59:59Z runway=unknown(projected_exhaustion) confidence=early
HEADROOM_SUMMARY: verdict=tight measured=2 tight=1 wall=0 unknown=0 source=quota-axi/0.1.40
```

A fractional percentage compared by its truncated integer part.
Accepting decimals made that truncation observable at the boundary: `FM_USAGE_WALL_TIGHT_PCT` is documented as the percent AT OR BELOW which a reading is labelled tight, and at the default of 20 a reading of `20.9` truncated to `20` and printed `HEADROOM: claude tight pct=20.9` under `verdict=tight measured=3 tight=3` - the definition and the behaviour describing different rules, which is the same coherence defect one round earlier, arriving through its own fix.
The threshold is validated as a whole number, so the comparison is exact rather than scaled: the integer part decides, and the fractional remainder settles the boundary.
CONSTRUCTED, not observed, for the same reason as the case above:

```
HEADROOM: claude ok pct=20.9 bound=five_hour resets=2026-08-27T02:19:59Z runway=unknown(projected_exhaustion) confidence=early
HEADROOM: cursor tight pct=20.0 bound=seven_day resets=2026-09-02T07:59:59Z runway=unknown(projected_exhaustion) confidence=early
HEADROOM: codex tight pct=0.4 bound=five_hour resets=2026-08-27T02:19:59Z runway=unknown(projected_exhaustion) confidence=early
HEADROOM_SUMMARY: verdict=tight measured=3 tight=2 wall=0 unknown=0 source=quota-axi/0.1.40
```

Each line prints the value the gauge gave rather than a rounded one, so a reader can reconcile the reading with the report it came from.

A row the gauge emitted with no provider in it.
The invariant above is phrased in terms of provider NAMES, and a row whose `provider` cell is declared but empty carries none, so it slipped underneath the rule: dropped by the quota loop, excluded from the name sweep, and never reaching the row-less exit because another row had been emitted.
A report mixing one named row with one unattributable row printed a clean, complete gauge over a row at 3% that was thrown away:

```
HEADROOM: claude ok pct=84 bound=five_hour resets=2026-08-27T02:19:59Z runway=unknown(-) confidence=-
HEADROOM_SUMMARY: verdict=ok measured=1 tight=0 wall=0 unknown=0 source=quota-axi/0.1.40
```

`toon_block` yields `-` for a field the header never declared AND for a declared field whose cell is empty, which is why this row looked like a layout change rather than an incomplete row; that ambiguity is now stated in `toon_block`'s own header rather than left to be rediscovered.
The invariant is restated about ROWS - every row the gauge emitted, in every table the reading consults, is either reported or accounted for - so the count reaches the reading and the summary can no longer describe itself as complete:

```
HEADROOM: claude ok pct=84 bound=five_hour resets=2026-08-27T02:19:59Z runway=unknown(-) confidence=-
HEADROOM: (unattributable rows) unknown reason=unattributable-row status=unattributable_row detail=1 row(s) in the report carried no provider, so no reading could be attributed to them
HEADROOM_SUMMARY: verdict=partial measured=1 tight=0 wall=0 unknown=1 source=quota-axi/0.1.40
```

Closing that per table left `exhaustion[]` open, because no loop enumerates it: it is consulted by per-provider lookups and by a sweep that dropped unnamed rows silently, so a row reporting zero usable runway was discarded under `verdict=ok measured=1 tight=0 wall=0 unknown=0`.
That was the third table to lose the same invariant, each time because the guard was written per table.
It is now one accounting pass over a single list of the tables consulted, and `tests/fm-usage-wall.test.sh` asserts the invariant per table from one assertion body plus a case carrying an unattributable row in all three at once - so a table that starts dropping rows shows up as an undercount rather than as a still-passing per-shape test:

```
HEADROOM: claude ok pct=84 bound=five_hour resets=2026-08-27T02:19:59Z runway=unknown(projected_exhaustion) confidence=early
HEADROOM: (unattributable rows) unknown reason=unattributable-row status=unattributable_row detail=3 row(s) in the report carried no provider, so no reading could be attributed to them
HEADROOM_SUMMARY: verdict=partial measured=1 tight=0 wall=0 unknown=1 source=quota-axi/0.1.40
```

An upstream remedy displacing the one-time operator command.
The `auth_required` hint was overwritten rather than extended, so an `attention[]` row carrying any remedy lost `quota-axi --allow-keychain-prompt` - the only thing that unblocks the reading at all.
Every live-captured row on this host carries `remedy=none`, so this is CONSTRUCTED; both now survive, the gauge's advice after this command's own:

```
HEADROOM: cursor unknown reason=auth-required status=auth_required detail=Cursor sign-in required - approve local credential access once with quota-axi --allow-keychain-prompt, then re-read - sign in at cursor.com/settings
```

A report whose rows are ALL unattributable still leaves through the single unmeasurable exit as `(all providers) unknown reason=no-named-provider-row`, because then no reading came back at all - and it carries the ledger, which is the reading that most needs one:

```
HEADROOM: (all providers) unknown reason=no-named-provider-row
HEADROOM_SUMMARY: verdict=unknown measured=0 tight=0 wall=0 unknown=1 source=quota-axi/0.1.40
HEADROOM_ROWS: emitted=3 read=0 declined=3 reasons=no-provider=3
```

The ledger is published on every reading, unmeasurable ones included, so its presence is never itself a signal to interpret: a reading that never saw a report at all - no gauge on `PATH` - reports `emitted=0 read=0 declined=0` rather than omitting the line.
Both emitters carry it, so the text form and `--json` cannot disagree about whether the fact exists; they did, and only `--json` had it.

An unknown carrying a reason that is false of the provider it names.
A provider named only in `exhaustion[]` fell through to the scope-based default and printed `reason=no-measurable-window` - for a provider whose limiting window and usable runway the gauge DID report, with the contradicting detail on the same line.
What it is actually missing is a quota row, which is a different absence from having one at model scope only, so the two now carry different reasons:

```
HEADROOM: cursor unknown reason=no-quota-row status=not_reported scope=all_models detail=named only in exhaustion, with no account-level quota row and nothing in attention
```

A row dropped by a filter whose provider was reported by another row.
The accounting above sorted rows into "named, therefore swept by name" and "unattributable, therefore counted" - but a provider's NAME reaching the output does not mean THAT ROW did.
A model-scoped quota row beside an account-scoped one for the same provider was dropped by the scope filter, skipped by the sweep because the provider was already present, and counted by nothing:

```
HEADROOM: claude ok pct=84 bound=five_hour resets=2026-08-27T02:19:59Z runway=unknown(-) confidence=-
HEADROOM_SUMMARY: verdict=ok measured=1 tight=0 wall=0 unknown=0 source=quota-axi/0.1.40
```

That was the sixth appearance of one class, and the fifth formulation phrased around names.
The accounting is now an identity over ROWS - every row is READ or DECLINED with a reason, `emitted = read + declined` - published on every reading, so a filter cannot drop a row without saying what it dropped and a filter added later is covered by construction.
Over a fixture mixing account-scoped, model-scoped and unattributable rows across all three tables:

```
HEADROOM: claude ok pct=84 bound=five_hour resets=2026-08-27T02:19:59Z runway=4h0m confidence=early
HEADROOM_SUMMARY: verdict=partial measured=2 tight=0 wall=0 unknown=2 source=quota-axi/0.1.40
HEADROOM_ROWS: emitted=8 read=4 declined=4 reasons=no-provider=2,not-account-scope=1,superseded-by-reported-row=1
```

`tests/fm-usage-wall.test.sh` asserts the arithmetic rather than the shapes - `read + declined == emitted`, in text and in `--json` - so a filter that starts discarding rows breaks the sum instead of slipping past a shape-specific case.

A percentage borrowing the window that bounds the runway.
The singular-window fallback fired on `toon_block`'s absent marker, which means three different things: the header never declared `limitedBy`, the row is short, or the cell is declared and EMPTY on that row.
Borrowing is sound only for the first.
On a report whose header declares `limitedBy` and whose sibling row carries `seven_day`, the gauge provably publishes the field, yet the row with an empty cell was labelled with the runway's five-hour window while keeping its own row's seven-day reset - a number under a window it did not come from, beside a reset from another - and the `runway_bound=` disclosure was suppressed because the two windows had been made equal:

```
HEADROOM: claude tight pct=34 bound=five_hour resets=2026-09-02T08:00:00Z runway=35m confidence=early
```

The layout question is now asked of the block HEADER once, through `toon_block_declares`, instead of inferred per row from a marker that cannot answer it.
An empty cell on a declared field is missing data for that row, so the window is reported absent and the runway's is named separately:

```
HEADROOM: claude tight pct=34 bound=- resets=2026-09-02T08:00:00Z runway=35m runway_bound=five_hour runway_resets=unknown confidence=early
```

A gauge that declares no `limitedBy` at all still binds the percentage to the single window there is, which is the reading the fallback exists for; narrowing it did not remove it, and that is pinned too.

A row booked as read where it was LOOKED UP rather than where its value was emitted.
The ledger above closed the gap between the tables and the reading, and then left one inside itself: an exhaustion row's runway was recorded as used at the lookup, and the unreadable-percentage guard fires after that and before anything is printed.
On a report renaming `effectivePercentRemaining` - the layout change this parser documents as its motivating case - the runway was looked up, discarded, and still counted:

```
HEADROOM: claude unknown reason=unreadable-percent status=unreadable_percent detail=effectivePercentRemaining is not a number (-)
HEADROOM_ROWS: emitted=2 read=2 declined=0
```

`read=2 declined=0` asserts nothing was dropped while a runway had been, which is the same unaccounted discard the row identity exists to prevent, now inside the accounting rather than outside it.
The accounting point moved to the EMISSION: a row counts as read only where its value reaches the output, and the exhaustion row is booked after the reported line is appended, not when its lookup returned:

```
HEADROOM: claude unknown reason=unreadable-percent status=unreadable_percent detail=effectivePercentRemaining is not a number (-)
HEADROOM_ROWS: emitted=2 read=1 declined=1 reasons=runway-not-attached=1
```

Every early exit between the lookup and the emission was then walked rather than assumed: the blank-line guard (not a row), the unattributable-provider guard, the scope filter, and the unreadable-percentage guard.
The first is not an emitted row; the middle two decline with a reason; the last appends its own line and is counted read there.
The quota loop has exactly two emission points and both increment the ledger at the append, so no path can leave between the two points unaccounted, and the script carries no `set -e` that could add an implicit one.

The reasons list is emitted in sorted order under `LC_ALL=C`, because awk's associative-array iteration order is implementation-defined and this line is quoted here as recorded evidence and diffed between two readings of the same report.

## Each number carries the window that bounds it

Two windows answer two different questions, and pairing a percentage with the other window's reset sends a reader off to wait out a window that was never the constraint.

CONSTRUCTED, not observed: this host's real 0.1.34 report with the account row's percentage and `limitedBy` moved to the seven-day window and an `exhaustion[]` row added bounding the runway by the five-hour one.
The live report on this host has `exhaustion[0]:` and a single `limitedBy`, so a divergence cannot be waited for:

```
$ quota-axi
quota[2]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,all_models,34,2.1358,projected_exhaustion,early,seven_day,"2026-09-02T08:00:00.470847+00:00"
  claude,"model:fable",97,unknown,through_reset,early,five_hour,"2026-08-30T08:00:00.092088+00:00"
exhaustion[1]{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  claude,all_models,2100,"2026-08-30T03:48:51.786Z",five_hour

$ bin/fm-usage-wall.sh headroom
HEADROOM: claude tight pct=34 bound=seven_day resets=2026-09-02T08:00:00.470847+00:00 runway=35m runway_bound=five_hour runway_resets=unknown confidence=early
```

The percentage is bounded by `seven_day` and carries the seven-day reset; the runway is bounded by `five_hour` and is named separately because it differs.
`runway_resets=unknown` is the honest half: this layout publishes a reset only for the percentage's own window, so the runway's reset is reported as not known rather than borrowed from the other window, which would point a reader at the wrong clock.
Before this was fixed the line read `pct=34 bound=five_hour` with the five-hour reset, which claimed the window sitting at 97 percent was the one at 34.
It stayed latent because the two windows usually agree, so `tests/fm-usage-wall.test.sh` pins a fixture where they diverge far enough that mislabelling either is unmistakable.
A gauge that publishes only one window bounds both answers with it, and that reading is unchanged.

## The gauge saw a real wall before it landed

This is the guarantee working against a wall that actually arrived, rather than a constructed one.

While this surface was being built on 2026-08-26, the gauge read the account's five-hour window at 9 percent remaining with roughly four minutes of projected runway.
The worker recorded that reading, and the wall landed minutes later and stopped the account's workers, exactly as the reading projected.
The work on every branch survived it, and the record below is what a session picks the fleet back up from.

That is the whole point of reading the gauge before dispatching rather than after a crash log: the wall was visible while there was still time to act on it.

## The surface read the wall that stranded the surface

On 2026-08-27 this work's own validation run went terminal-failed on a provider limit, which makes the run the best available test of the guarantee.
`no-mistakes axi status` reported only `status: failed` and `error: agent fix: claude exited: exit status 1` - the shape that reads like a verdict on the code and is not one.
The deciding evidence was one command away, in the step's own log:

```
$ no-mistakes axi logs --run <run> --step review --full
  "I'll start by examining the current state of the code and the findings.You've hit your session limit - resets 1:40am (America/Los_Angeles)"
  "claude exited pid=91188 error=claude exited: exit status 1: "
```

`diagnose` reads that same log and returns the verdict, with the recorded endpoint made unreadable so the scan is forced onto the step-log path:

```
USAGE_WALL: proof wall source=step-log:review line="  "I'll start by examining the current state of the code and the findings.You've hit your session limit - resets 1:40am (America/Los_Angeles)""
USAGE_WALL_NEXT: this is a provider usage limit, not a crash - the work is intact. Load the usage-limit-recovery skill before touching the task.
```

That verdict is only correct because the run exposed a defect first.
On the first attempt the same command returned `no-signature`: the vendor's session-window phrasing was not in the signature table, which had been built from the weekly-window wording observed in the 2026-08-23 incident.
A real wall therefore read as an unrecognised failure.
The phrasing is now in the table with the observed line as its provenance and a case in `tests/fm-usage-wall.test.sh`.

This is the argument for the table's own rule rather than an exception to it.
The signature list is only ever as complete as the phrasings actually observed, which is exactly why a miss returns `no-signature` and never "it crashed" - the negative that is not a verdict is what kept a missing pattern from becoming a wrong answer.

## A wall verdict needs corroboration, and this page is its open residual

A matching phrasing is necessary but not sufficient, so the account above describes only half of what produces a verdict.
A `wall` also needs the harness's own non-zero exit on a different line of the same evidence, and that corroborating line must not itself carry a limit phrasing.
[`docs/usage-limit-survivability.md`](../usage-limit-survivability.md) owns the rule and the reasoning for it.

The rule exists because this detector's evidence sources can carry this repository's own documentation of the detector.
`tests/fm-usage-wall.test.sh` pins it, and builds its fixture from the tracked files themselves rather than from a paraphrase of them.

```
$ ./bin/fm-test-run.sh tests/fm-usage-wall.test.sh
ok - diagnose does not read this repository own tracked phrasings as a wall
ok - diagnose still reports a corroborated wall for both observed phrasings
FM_TEST_END 2026-08-28T13:37:00Z tests/fm-usage-wall.test.sh exit=0 duration_ms=37464 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=37512
```

What the rule does not close is stated here because this is the page it affects.
The step-log extract quoted above carries the limit line and the harness's exit line on separate lines, exactly as the harness emitted them, so a pane displaying that part of this page still reads as a wall.
Closing it would mean either degrading a record whose value depends on quoting real evidence, or guessing from layout, and both are worse trades than the residual.
Revisit it if the vendor ever emits the phrasing and the exit on one line, or if a real transcript turns up a multi-line wall being missed.

## The record generates from real fleet state

`bin/fm-usage-wall.sh resume --out <path>` run against a home with six tasks in flight, then read back from disk after the process that wrote it exited.
`--out` writes only to the named path, so a read-only inspection never disturbs the home's own record.

Task identifiers, local-copy paths, and pull-request URLs are redacted here because they are private fleet state; the structure and the verdicts are verbatim.
Both load-bearing warnings fired on real data, unprompted:

```
# Resume record

generated: 2026-08-27T03:46:06Z
home: <home>
source: bin/fm-usage-wall.sh resume
tasks in flight: 6

This record is GENERATED from live durable state. Do not hand-edit it; regenerate it.
It carries state only. The recovery procedure is owned by the usage-limit-recovery skill.
Nothing here is a merge authorisation: each task keeps the posture recorded on its own line.

## <task-a>

- kind: ship
- merge posture: mode=no-mistakes yolo=off (the captain approves every merge)
- runtime: harness=claude model=claude-opus-5 effort=xhigh backend=tmux
- endpoint: <endpoint-a> (present)
- local copy: <copy-1>
  - SHARED: another task in this home records the same local copy; resolve which one owns it before resuming either
- branch: <branch-a> head: feb6865 uncommitted: 2 unpushed commits: (branch not on origin)
- pipeline: no run is attributed to this local copy
- pull request: -
- current state: state: working · source: pane · harness busy (claude-hook)
- open captain calls: (none)
- delivered instructions: 0 acknowledged, 0 still unread by the worker

## <task-d>

- kind: ship
- merge posture: mode=no-mistakes yolo=off (the captain approves every merge)
- runtime: harness=claude model=claude-opus-5 effort=high backend=tmux
- endpoint: <endpoint-d> (present)
- local copy: <copy-4>
- branch: <branch-d> head: 2bf7e9ca uncommitted: 0 unpushed commits: 7
- pipeline: run=<run> status=running failed-steps=- custody=pipeline_owned next-action=continue_active_run head=4b2a52db (pipeline-only)
  - the pipeline owns this branch; settle custody through its next-action before any new work on it
  - the run holds commits this local copy does not have; rebuilding from the local head would silently redo work that already exists
- pull request: -
- current state: state: failed · source: run-step · run failed
- open captain calls: (none)
- delivered instructions: 0 acknowledged, 0 still unread by the worker
```

`<task-a>` and a second task record the same local copy, and the record flags the collision on both rows rather than silently picking one.
`<task-d>` is the stranded shape the whole surface exists for: the run is `pipeline_owned`, its head is `pipeline-only` - not present in the local copy at all - and the record says in words that starting from the local head would rebuild work that already exists.
Neither line is inferred from an incident write-up; both are computed from task metadata, the local copies, and the pipeline overview at the moment the command ran.

The remaining four tasks are elided for length.
`tests/fm-usage-wall.test.sh` pins the same behaviors portably, including that the record survives the process that wrote it, that regeneration replaces rather than accumulates, that a shared local copy is named on both rows, and that a broken record never replaces a good one.

## A present directory is not a readable repository

Every git reading of a local copy passes one readability gate, because the failure is silent in both directions: `git status --porcelain` prints nothing for a directory git cannot read, and the count of nothing is `0`.

CONSTRUCTED, not observed - a worktree whose directory is intact but whose git metadata has been removed, which is what a pruned or relocated worktree leaves behind and exactly the half-state a post-wall recovery walks into.
Ungated, the record made two definite claims about a repository nobody could read - `(detached)` and no uncommitted work - with only `head: -` hinting at the failure:

```
- branch: (detached) head: - uncommitted: 0 unpushed commits: (branch not on origin)
- pipeline: no run is attributed to this local copy
```

The gate is one probe in front of every fact rather than a check per fact, for the same reason the headroom accounting is one pass rather than one guard per table; `head_binding` takes it as a precondition too, since its lookup fails identically for a copy missing the commit and a copy git cannot read.
The record now reports nothing about the copy's contents as measured, and says why:

```
- branch: unknown head: unknown uncommitted: unknown unpushed commits: unknown
  - the directory is present but git cannot read it as a repository, so nothing about its contents was measured; it may have been pruned or moved
- pipeline: not read (the local copy is not a readable repository)
```

The gate asks whether THIS directory is the repository root, not whether it sits inside one.
`git rev-parse --git-dir` walks upwards, so a gate built on it passes whenever any ancestor is a checkout - a worktree path recorded under another checkout, or any copy under a `$HOME` that is itself a dotfiles repo - and the record then prints that ancestor's branch, head and dirty count as measured facts about the task's copy: the same clean-measured-and-false reading, now about the wrong repository.

`tests/fm-usage-wall.test.sh` drives both shapes: a copy with its git metadata removed and the directory left in place, and a plain directory NESTED INSIDE a repository whose branch and dirty file are distinctive, asserting neither is borrowed.

## The record tracks state changing under it

The same command run twice across a custody change, on the task above.
Before settling custody the record read:

```
- pipeline: run=<run> status=failed ... custody=pipeline_owned next-action=recover_custody head=b7e099d6 (pipeline-only)
  - the pipeline owns this branch; settle custody through its next-action before any new work on it
  - the run holds commits this local copy does not have; rebuilding from the local head would silently redo work that already exists
```

After the worker settled custody through that same `next_action`, a regenerated record read:

```
- pipeline: run=<run> status=failed failed-steps=review custody=custody_returned next-action=run_pipeline head=b7e099d6 (equal)
```

Both warnings dropped on their own because the condition they described was gone.
Nothing was edited: a hand-written plan would still have carried the stale pair, which is the failure mode generating the record exists to remove.

## Both scans are bounded by a budget, not by how much is broken

`tests/fm-session-start.test.sh` drives the digest's per-task scan against a wedged backend and six dead endpoints - the post-wall shape - and asserts on the scan's own disclosure rather than on a clock.
Under a 2s shared budget over 1s captures it reaches at most three of the six, where a per-task bound would have spent its full second on each and reached all six; every task still gets a line under both a tight and a generous budget; and what the budget could not reach reports `unknown reason=scan-budget-exhausted` while the digest names those tasks as unchecked.
An earlier version of this test compared the wall-clock cost of a budgeted run against a generous one, and that comparison was deleted rather than documented: the expected separation was about four seconds measured at one-second granularity, and the two runs were not equivalent because the first writes baseline markers the second does not, so an unlucky machine could collapse the inequality with nothing regressed.
Counting what the scan itself reports distinguishes a shared budget from a per-task one without a clock at all.
It asserts the same for an endpoint with no window recorded, which is not alive either and draws on the same budget.
`tests/fm-fleet-snapshot-view.test.sh` asserts the heartbeat view bounds a gauge that never answers and renders it as unknown rather than healthy or absent, and that the view reads the fixture's gauge rather than the host's, so the suite performs no real provider read.
`tests/fm-usage-wall.test.sh` asserts a step log that cannot be read reports `unknown reason=step-log-unreadable` rather than `no-signature`, that a partially read scan discloses its `unread=` steps separately from the `unscanned=` steps its budget never reached, that a limit line in a fourth failed step is still found, and that one reading spends one cumulative budget across both `quota-axi` calls rather than a bound per call.

## The endpoint-gone recovery, end to end

Run on a disposable scratch task on a private tmux socket, never on live work.
Steps 1 and 2 establish a task whose harness has just hit the wall; step 3 removes the whole terminal server, which is the shape of [issue #3113](https://github.com/kunchenguid/firstmate/issues/3113).

To reproduce: put a `tmux` shim on `PATH` that redirects to a private socket (`tmux -L <name>`, the pattern `tests/fm-backend-tmux-smoke.test.sh` uses); create a scratch `FM_HOME`, git repo, worktree, and a `state/<id>.meta` carrying a project identity as well as the window and worktree; open the recorded session and window with the worktree as its working directory; then run the steps below in order.
Print the harness's real TWO-line output into the pane - the vendor limit line and the harness's own exit line on its own line - because the corroboration rule requires the exit line and a lone phrasing no longer reads as a wall.
Print it from a file rather than typing it, or the shell's own command echo carries the phrasing and becomes the matched line instead of the harness's output.
An unrelated turn-end guard banner is elided from step 6's output.

```
=== 1. the scratch task's endpoint exists and the harness has just hit the wall ===
fm-proofcrew
agent state: dead

=== 2. diagnose separates the wall from a crash ===
USAGE_WALL: proofcrew wall source=endpoint line="You've hit your weekly limit - resets Aug 26 at 10am (Europe/Rome)"
USAGE_WALL_NEXT: this is a provider usage limit, not a crash - the work is intact. Load the usage-limit-recovery skill before touching the task.

=== 3. the whole terminal server goes away (this is the #3113 shape) ===
agent state: missing

=== 4. control refuses while the endpoint is gone ===
error: task proofcrew's recorded endpoint is gone, so there is no agent to stop; reconcile the task before any further control action
exit status: 1

=== 5. the work itself is intact on the branch ===
fm/proofcrew
95395a9 init

=== 6. teardown also refuses, because the work is unlanded ===
REFUSED: worktree <scratch>/wt has work not on any remote and not landed.
unpushed commits:
95395a9 init
Push the branch, land its PR, or get the captain's explicit OK to discard, then --force.
exit status: 1

=== 7. recreate the EXACT recorded endpoint, with the recorded local copy as its working directory ===
agent state: dead
window working directory: <scratch>/wt

=== 8. control now accepts the same command it refused in step 4 ===
already-stopped proofcrew harness=claude backend=tmux endpoint=fmproof:fm-proofcrew worktree=<scratch>/wt
exit status: 0

=== 9. relaunch gets past the endpoint gate too ===
error: task proofcrew has no instructions at <scratch>/home/data/proofcrew/brief.md; refusing to relaunch a worker with nothing to work from
exit status: 1
```

What this proves, in order: the wall is separable from a crash by evidence (step 2); an endpoint whose server is gone classifies as `missing` and both the control plane and teardown refuse, which is the deadlock (steps 3, 4 and 6); the work itself is untouched (step 5); recreating the exact recorded endpoint with the recorded local copy as its working directory makes the same endpoint classify as `dead` (step 7); and the control plane then accepts the command it refused four steps earlier (step 8), with `relaunch` passing the same gate and stopping only at a later requirement this synthetic task does not have (step 9).

The classification underneath it - a vanished server as `missing`, a plain shell as `dead` - is already pinned portably by `tests/fm-secondmate-liveness.test.sh`, so it is not duplicated here.
