# Routing cooldown suppression verification

Audience: maintainer verification.

This record supports the automatic-suppression predicate owned by `bin/fm-quota-cooldown.sh` and the oracle strength of `tests/fm-quota-cooldown.test.sh`.
It exists because a suppression guard that is never exercised by its own tests fails silently: the tests keep passing while every cooled tuple dispatches.
Task chronology and delivery evidence stay in private reports or PR evidence.

## Oracle strength against suppression-predicate mutations

Verified 2026-08-16 on Node v24.19.0 and GNU bash 5.3.9 under Linux 7.0.0-29-generic.

The control and every mutation run the same command from the repository root:

```sh
bash tests/fm-quota-cooldown.test.sh
```

Each mutation is a single edit to the authorization path of `bin/fm-quota-cooldown.sh`, applied to a working copy and reverted before the next run.
The pristine control is the unmutated worktree.

| run | edit applied to the suppression predicate | exit | first failing case |
|---|---|---|---|
| pristine control | none | `0` | none |
| deletion | remove the whole `const refused = matched[0]; ... process.exit(3);` refusal block | `1` | `active cooldown should suppress an automatic candidate: expected exit 3, got 0` |
| textually present but unreachable | insert `process.exit(0);` immediately before that refusal block, leaving the block in the file | `1` | `active cooldown should suppress an automatic candidate: expected exit 3, got 0` |
| weakened | replace `if (matched.length === 0) process.exit(0);` with `if (matched.length < 2) process.exit(0);` | `1` | `active cooldown should suppress an automatic candidate: expected exit 3, got 0` |
| constant true | replace `const matched = applicable.filter((entry) => relation(entry, candidate) === 'match');` with `const matched = store.cooldowns;` | `1` | `expired cooldown should not suppress a candidate: expected exit 0, got 3` |

Every mutation is killed and the pristine control passes, so the suppression cases are load-bearing in both directions: a lost refusal fails on the active-cooldown case, and an over-broad refusal fails on the expiry case.
Re-run the table above whenever the authorization path or its behavior cases change.

## Explicit override outranks the missing-axis refusal

Verified 2026-08-16 on the same toolchain.

The automatic missing-axis refusal is fail-closed for automatic selection only, so `authorize` evaluates an explicit `--task-id` plus `--override-reason` before it.
Against the earlier owner, `authorize --harness cursor-agent --task-id unscoped-retry --override-reason '<captain instruction>'` against an active provider-scoped record exited `3` with `active routing cooldown could match; automatic selection requires --provider ...`, so the captain escape hatch was reachable only by also supplying axes the captain may not have.
The same command now exits `0`, while the identical command without the override flags still exits `3`.
`an explicit captain override is evaluated before the missing-axis refusal` in `tests/fm-quota-cooldown.test.sh` pins both exit codes, that an override which identifies no record writes no departure, and that an override whose axes identify two active records is recorded on both.

## Expiry instants are zone-qualified

Verified 2026-08-16 on the same toolchain.

Against the earlier owner, `record --expires-at 9/14/2026` under `TZ=Europe/Berlin` exited `0` and stored `2026-09-13T22:00:00.000Z`: a local-midnight instant shifted by the recording machine's timezone offset, so a cooldown recorded east of UTC stopped suppressing two hours before the provider's own reset.
`record` now exits `2` for `9/14/2026`, `2026-09-14T00:00:00`, `Sep 14 2026`, and `2026-09-14T00:00:00+0200`, creating no durable file, and still exits `0` for `2026-09-14T00:00:00-04:00` and `2026-09-14`, which it stores as `2026-09-14T04:00:00.000Z` and `2026-09-14T00:00:00.000Z`.
`an expiry that depends on the recording machine's timezone is refused` in `tests/fm-quota-cooldown.test.sh` pins those exit codes and stored instants.

## Axis identity is canonical, so a case variant cannot fail open

Verified 2026-08-16 on the same toolchain.

The recording moment and the dispatch moment are different callers naming the same vendor axes, so an uncanonical comparison fails OPEN inside a guard whose whole purpose is to fail closed.
Against the earlier owner, `record --scope model-family --harness cursor-agent --provider Cursor --model-family GLM --expires-at 2026-09-14T00:00:00Z` exited `0`, and the matching `authorize --harness cursor-agent --provider cursor --model-family glm` then exited `0` as well: the cooled tuple dispatched with no diagnostic, while a merely *missing* axis had always exited `3`.
The current owner exits `3` for that same pair, including against a store the earlier owner already wrote in mixed case, because harness, provider, and model-family are trimmed and case-folded when they are stored, keyed, and compared.
`provider, harness, and model-family axes match by canonical identity` in `tests/fm-quota-cooldown.test.sh` pins the suppression in both directions, that a padded or upper-case dispatch axis is still suppressed, that a sibling family stays eligible, and that re-recording one proven scope under a different case replaces the entry instead of creating a second one.

## Recovering a store the owner cannot read

Verified 2026-08-16 on the same toolchain.

An unreadable `data/quota-cooldowns.json` refuses every command with exit `2`, and `bin/fm-spawn.sh` relays that status, so a corrupt store is a fleet-wide spawn outage.
`recover` is the only exit and is deliberately narrow: against a store that still validates it exits `2` and changes nothing, and against a store proven invalid it renames those bytes to `data/quota-cooldowns.json.corrupt.<recorded instant>`, durably writes an empty store, and exits `0`.
`recover quarantines only a store proven invalid and leaves the owner recording again` in `tests/fm-quota-cooldown.test.sh` pins every one of those exit codes, that the refused `recover` leaves the live suppression refusing with exit `3`, that the quarantined file holds the original invalid bytes, that the recovered store lists `schema_version` 1 with no cooldowns, and that a cooldown recorded again afterwards suppresses with exit `3`.
The recovered store suppresses nothing until each still-active cooldown is recorded again from its provider evidence, which is why `recover` never rewrites or drops an individual entry.

## Durable file stays usable after a refused write

Verified 2026-08-16 on the same toolchain.

`bin/fm-quota-cooldown.sh` takes the shared `fm-wake-lib.sh` lock in its own shell rather than inside the Node writer, because every refusal there calls `process.exit`, which skips a JavaScript `finally`.
The regression that pins this is `a refused durable write leaves the owner able to record and override again` in `tests/fm-quota-cooldown.test.sh`: it truncates `data/quota-cooldowns.json`, observes the refused `record` exit `2`, requires that refusal to leave no `data/quota-cooldowns.json.lock` behind, recovers the damaged store through the owner's `recover` command, and requires the next `record` to exit `0` and its cooldown to suppress again with exit `3`.
The absent-lock assertion is the part that separates `trap release_lock EXIT` from `fm-wake-lib.sh`'s stale-owner recovery, which would let the second `record` succeed anyway once the first shell's PID is dead; the later exit codes pin the recovered end state rather than which mechanism produced it.

Against the pre-fix owner the same sequence left `data/quota-cooldowns.json.lock` behind and the second `record` exited `2` with `timed out waiting for .../quota-cooldowns.json.lock`, which no documented step could clear because the file is never hand-edited.
The `recover` step in that case also keeps the whole suite free of a hand-deleted durable file, so no test models a repair the operator documentation forbids.
