# agy quota poll - verification record

Evidence backing the live intake poll in `bin/fm-agy-quota-lib.sh`
(`fm_agy_quota_poll`), which is what supplies the agy model ladder in
`bin/fm-agy-ladder-lib.sh` with a current reading at dispatch time.

The poll's verdict comes from output agy itself emits, so the shape below is a
vendor fact and is pinned here rather than assumed.

Captured 2026-08-19 from agy 1.1.15 on macOS (`darwin-arm64`).

## The load-bearing claim: the poll costs no quota

The ladder exists to protect Opus 4.6 budget, so a poll that spent any of it
would be self-defeating. `/quota` is answered by agy's own local command runner
against the quota service and runs no model turn.

```
$ agy --version
1.1.15

$ agy --print /quota --output-format json | jq -c \
    '{status, conversation_id, duration_seconds, num_turns, usage, command_name: .command.name}'
{"status":"SUCCESS","conversation_id":"","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command_name":"usage"}
```

`num_turns` is 0, every field of `usage` is 0, and `conversation_id` is empty:
no conversation was created and no tokens were billed. Wall clock for the call
was about 3 seconds, which is why it is affordable on the dispatch path where
`bin/fm-spawn.sh` already runs a bounded `agy models` probe.

`/usage` is an accepted alias and returns the identical payload; the reported
`command.name` is `usage` for both.

Confirmed independently on 2026-08-19 by firstmate running the same command in
the live home: `num_turns` 0 and `total_tokens` 0, so the poll is free in
production and not only on this machine.

## The stale-evidence defect, reproduced in production

The same live run is also direct evidence of the defect this change fixes.
At that moment the live home's recorded reading still said Claude Opus 4.6 was
at 33.8% remaining, while the poll answered 93%.

The recorded figure was hours old and its reset window had already elapsed, so
the ladder was reasoning about a number that had stopped describing reality.
Here that gap was benign, because the stale reading was the pessimistic one and
merely blocked launches the account could afford.
The gap is symmetric, though, and the dangerous direction is the other one: a
reading taken early in a window overstates what is left for as long as the
window lasts, which is exactly how automatic dispatch used to run below the
captain's reserved 25%.
A single number that is hours old cannot be trusted in either direction, which
is why the ceiling in `fm_agy_quota_read` and the intake poll above are the fix
rather than the parser hardening alone.

## The shape the poll parses

One call answers EVERY model, which is what lets a single poll serve both of the
ladder's decisions - whether the requested rung is above its floor, and whether
every rung above it is spent.

```
$ agy --print /quota --output-format json \
    | jq -c '.command.data.groups[0].buckets[] | select(.id=="claude-opus-4-6-thinking")'
{"id":"claude-opus-4-6-thinking","name":"Claude Opus 4.6 (Thinking)","description":"Quota resets in 4 hours, 38 minutes.","remaining_fraction":0.949999988079071,"reset_time":"2026-08-20T00:01:27Z"}
```

| Field | Fact |
| --- | --- |
| Path | `.command.data.groups[].buckets[]` |
| `name` | The DISPLAY name, byte-identical to the pane footer's and to `fm_agy_ladder_display`, so both evidence sources key a reading the same way |
| `remaining_fraction` | Fraction remaining, 0.0-1.0. Multiplied by 100 to one decimal, matching the footer's precision |
| `reset_time` | RFC3339 UTC instant, converted to the `<n>h <n>m` window the recorded format speaks |
| `description` | Human prose. Deliberately NOT parsed; `reset_time` is the machine-readable form of the same fact |

The `.response` field carries the same rows as human-readable text, but rounds
to whole percents. The poll reads `remaining_fraction` instead, because whole
percents would blur exactly the last point above the 25% floor.

Group description as emitted, which is why a rung's reading is a session-window
figure and not a per-request throttle:

```
Gemini Pro, Gemini Flash, and Claude/GPT models have separate quota pools, each
with a per-week and per-5-hour cap; this shows the one closest to being reached.
```

## What agy does NOT offer

Checked on 1.1.15 before settling on print mode, so a future reader does not
repeat the search:

- `agy --help` lists no quota, usage, or limits subcommand.
- The subcommand list is `agent`, `agents`, `changelog`, `help`, `install`,
  `models`, `plugin`, `plugins`, `update`. None reports quota.
- `agy models` fetches the account's catalogue over the network but returns only
  `<id><TAB><Display Name>` rows, with no quota figure.

Print mode with a leading locally-handled slash command is therefore the only
non-interactive quota source, and it is a genuine one.

## Bounding the call

`fm_agy_bounded_output` runs it under a hard wall-clock ceiling. A stock macOS
has neither `timeout` nor `gtimeout`, so that helper also carries a perl
fork/`alarm` bound; without it the ceiling could not be imposed on this platform
and the probe declined to run at all, silently disabling both the model
catalogue check and this poll on exactly the platform the fleet runs on.

```
$ command -v timeout gtimeout
$ command -v perl
/usr/bin/perl
```

## Refreshing this record

Re-run the two commands above after an agy upgrade. The regression that pins the
parse without needing agy installed is
`tests/fm-agy-quota-lib.test.sh` ("Testing the live intake poll"), which drives
`fm_agy_quota_poll` against a stub emitting this exact JSON shape; the ladder
consequences are pinned in `tests/fm-agy-ladder-enforcement.test.sh`.
