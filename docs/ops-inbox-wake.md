# Operational alert inbox wake

Some machines run an operations runtime that records critical alerts - dead-man timers, tripwires, backup and service health checks - into a durable inbox instead of a chat transport.
An inbox nobody reads disarms every one of those checks silently, because each check still "fires" and still records its alert while no one is told.
This watch closes that gap by turning an unreviewed critical backlog into an ordinary Firstmate wake, so a stalled alert queue reaches the first mate the same way a crew signal or a merged pull request does.

Alerts route to the first mate, never straight to the captain, and never through any external service.
The first mate decides what an alert backlog means and escalates only what the captain actually needs.

## Exit dispositions

The invariant behind every exit is that the poll may stay silent only after it has established that the watch is disabled, absent by auto-mode design, within its thresholds, or already raised and not yet due for another wake.
`FAILS-CLOSED-AND-WAKES` means a genuine inability to establish that fact becomes the one-line wake instead of a silent process failure.
`WAKES` means the condition is an expected wake-worthy state.
`SILENT-BY-DESIGN` means the condition is benign or has already been reported within the dedupe interval.

| Surface and exit | Disposition | Contract |
|---|---|---|
| `fm_ops_inbox_config_load`: the optional config is absent. | `SILENT-BY-DESIGN` | Defaults are resolved and evaluation continues without output. |
| `fm_ops_inbox_config_load`: the config is not an ordinary file or is a symlink. | `FAILS-CLOSED-AND-WAKES` | The poll emits the configuration-error wake because no configured threshold can be trusted. |
| `fm_ops_inbox_config_load`: the config exists but `jq` is unavailable. | `FAILS-CLOSED-AND-WAKES` | The poll emits the configuration-error wake. |
| `fm_ops_inbox_config_load`: the config is unreadable, invalid JSON, or not an object. | `FAILS-CLOSED-AND-WAKES` | The poll emits the configuration-error wake. |
| `fm_ops_inbox_config_load`: whitelist validation or the final `jq` read fails. | `FAILS-CLOSED-AND-WAKES` | The poll emits the configuration-error wake. |
| `fm_ops_inbox_config_load`: a key is unrecognized, including when its value is null. | `FAILS-CLOSED-AND-WAKES` | The poll emits the configuration-error wake. |
| `fm_ops_inbox_config_load`: `enabled` has an invalid value. | `FAILS-CLOSED-AND-WAKES` | The poll emits the configuration-error wake. |
| `fm_ops_inbox_config_load`: a path setting is empty or non-string, or any string setting contains a code point below 32. | `FAILS-CLOSED-AND-WAKES` | The poll emits the configuration-error wake instead of resolving an unintended inbox path or accepting an injected setting. |
| `fm_ops_inbox_config_load`: a numeric setting is empty, negative, fractional, non-numeric, outside the supported arithmetic range, or a zero `max_lines`. | `FAILS-CLOSED-AND-WAKES` | The poll emits the configuration-error wake. |
| `fm_ops_inbox_config_load`: all settings are valid, with recognized null values omitted. | `SILENT-BY-DESIGN` | Defaults survive null values and evaluation continues without output. |
| `fm_ops_inbox_watch_expected`: `enabled` is explicitly true. | `SILENT-BY-DESIGN` | Evaluation continues even when the spool is absent, so the scan can fail closed. |
| `fm_ops_inbox_watch_expected`: `enabled` is explicitly false. | `SILENT-BY-DESIGN` | The poll exits without reading or waking. |
| `fm_ops_inbox_watch_expected`: auto mode runs in a secondmate home. | `SILENT-BY-DESIGN` | The poll exits because the primary home owns the machine-wide inbox. |
| `fm_ops_inbox_watch_expected`: auto mode finds the spool. | `SILENT-BY-DESIGN` | Evaluation continues without output. |
| `fm_ops_inbox_watch_expected`: auto mode does not find the spool. | `SILENT-BY-DESIGN` | The poll exits because this home has no inbox to watch. |
| `fm_ops_inbox_scan`: the active spool is absent. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake. |
| `fm_ops_inbox_scan`: `jq` is unavailable. | `FAILS-CLOSED-AND-WAKES` | The poll emits the dedicated missing-`jq` wake before scanning. |
| `fm_ops_inbox_scan`: the bounded overflow sample cannot be read or counted. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake. |
| `fm_ops_inbox_scan`: the acknowledgement log is absent. | `SILENT-BY-DESIGN` | The scan treats the inbox as having no external acknowledgements. |
| `fm_ops_inbox_scan`: the acknowledgement log cannot be read or parsed. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake. |
| `fm_ops_inbox_scan`: the spool tail cannot be read. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake. |
| `fm_ops_inbox_scan`: a nonblank complete spool record cannot be parsed. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake because the record cannot be classified safely. |
| `fm_ops_inbox_scan`: the final non-terminated fragment is malformed. | `SILENT-BY-DESIGN` | The fragment is ignored for overflow detection and parsing as a benign append in progress while complete records remain eligible. |
| `fm_ops_inbox_scan`: the final non-terminated record is valid JSON. | `SILENT-BY-DESIGN` | The valid record is included in the bounded scan and normal evaluation continues. |
| `fm_ops_inbox_scan`: a record is excluded by severity, inline acknowledgement, or the acknowledgement log. | `SILENT-BY-DESIGN` | Excluded records cannot trigger timestamp validation or a false scan failure. |
| `fm_ops_inbox_scan`: an included critical record has a malformed or calendar-invalid timestamp. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake before age comparison. |
| `fm_ops_inbox_scan`: acknowledgement filtering, timestamp validation, `awk`, or summary construction fails. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake. |
| `fm_ops_inbox_scan`: the bounded scan succeeds. | `SILENT-BY-DESIGN` | The result is returned to the poll for threshold evaluation without output. |
| `fm_ops_inbox_receipt_count`: the receipt is absent. | `WAKES` | The poll marks the receipt missing and reports that state after a successful scan. |
| `fm_ops_inbox_receipt_count`: `jq` is unavailable. | `FAILS-CLOSED-AND-WAKES` | The poll emits the dedicated missing-`jq` wake before receipt parsing. |
| `fm_ops_inbox_receipt_count`: JSON parsing fails or the count is missing, negative, fractional, non-numeric, or outside the supported arithmetic range. | `WAKES` | The poll marks the receipt unreadable and falls back to the spool count. |
| `fm_ops_inbox_receipt_count`: a usable count is returned. | `SILENT-BY-DESIGN` | A fresh receipt becomes authoritative for the reported total and evaluation continues. |
| `fm_ops_inbox_epoch_of_iso`: the timestamp shape is invalid. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake instead of omitting the oldest age. |
| `fm_ops_inbox_epoch_of_iso`: the timestamp is calendar-invalid. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake instead of omitting the oldest age. |
| `fm_ops_inbox_epoch_of_iso`: date conversion or exact round-trip validation fails. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake instead of omitting the oldest age. |
| `fm_ops_inbox_epoch_of_iso`: conversion succeeds. | `SILENT-BY-DESIGN` | The poll evaluates the exact oldest age without output. |
| `fm_ops_inbox_sidecar_read`: the sidecar is absent, symlinked, unreadable, lacks any of its first four lines, is version-mismatched, has a numeric value outside the supported arithmetic range, or is missing its state. | `WAKES` | A currently qualifying condition bypasses dedupe and wakes as though there were no prior record. |
| `fm_ops_inbox_sidecar_read`: the first four lines are valid. | `SILENT-BY-DESIGN` | The poll evaluates growth, class, state, and re-remind dedupe rules, treating an absent fifth class-list line as empty. |
| `fm_ops_inbox_sidecar_write`: the directory or existing target is invalid. | `WAKES` | The wake line is still printed and the recording failure is reported on standard error. |
| `fm_ops_inbox_sidecar_write`: temporary-file creation, content write, permission setting, or rename fails. | `WAKES` | The wake line is still printed and the recording failure is reported on standard error. |
| `fm_ops_inbox_sidecar_write`: the atomic record succeeds. | `WAKES` | The wake line is printed once and the new dedupe state is durable. |
| Poll: configuration loading fails. | `FAILS-CLOSED-AND-WAKES` | The poll emits the configuration-error wake and exits successfully for the watcher. |
| Poll: an active or malformed watch cannot read the current time as epoch seconds. | `FAILS-CLOSED-AND-WAKES` | The poll emits a direct one-line watch failure because age, receipt staleness, and dedupe cannot be evaluated. |
| Poll: the watch is disabled or auto mode has no owned spool. | `SILENT-BY-DESIGN` | The poll exits with no output. |
| Poll: `jq` is unavailable after default configuration resolution. | `FAILS-CLOSED-AND-WAKES` | The poll emits the dedicated missing-`jq` wake. |
| Poll: the receipt is missing, stale, or unreadable. | `WAKES` | The receipt state is included in the digest after a successful scan. |
| Poll: scanning or oldest-timestamp conversion fails. | `FAILS-CLOSED-AND-WAKES` | The poll emits the scan-failure wake. |
| Poll: the fresh receipt and scan establish that no wake threshold is met. | `SILENT-BY-DESIGN` | The poll clears prior dedupe state and exits with no output. |
| Poll: prior dedupe state cannot be cleared on the threshold-not-met path. | `FAILS-CLOSED-AND-WAKES` | The poll emits a dedupe-state failure wake instead of risking suppression of the next backlog. |
| Poll: a condition qualifies and no valid prior sidecar suppresses it. | `WAKES` | The poll prints the one-line digest. |
| Poll: an unchanged qualifying condition is still inside its dedupe interval. | `SILENT-BY-DESIGN` | The poll exits without repeating the same wake. |
| Poll: count growth, a new class, receipt-state change, or re-remind makes a prior condition due again. | `WAKES` | The poll prints the refreshed one-line digest. |
| Poll: recording a due wake fails. | `WAKES` | The digest is still printed, and standard error explains that dedupe durability failed. |

## What is watched

The watch reads three paths and writes to none of them:

| Path | Role |
|---|---|
| `<state_dir>/ops-inbox.jsonl` | append-only alert spool, one JSON object per line with `id`, `ts`, `source`, `severity`, and an inline `ack` flag |
| `<state_dir>/ops-inbox-acks.jsonl` | acknowledgement log, one JSON object per line with `event_id` |
| `<state_dir>/ops-inbox-receipt.json` | the runtime's own periodic review receipt, carrying `unacked_critical_count` |

An alert counts as unacked exactly when the spool's own reader counts it: `severity` is `critical`, the inline `ack` flag is `false`, and no acknowledgement entry names its `id`.
Firstmate never acknowledges, rotates, or edits these files; acknowledging remains the operations runtime's own command.

`<state_dir>` defaults to `$HOME/.openclaw/state` and is overridable per home; see [Configuration](#configuration).

## When it wakes

Any one of these conditions makes the backlog wake-worthy:

- more unacked critical alerts than `count` (default 25);
- at least one unacked critical alert older than `age_hours` (default 6);
- the review receipt is stale, missing, or unreadable, because a dead receipt generator is itself the alerting failure, and it is the failure that hides every other one;
- the spool has grown past `max_lines` (default 20000), so it can no longer be read whole inside one check and needs rotating or triaging;
- the watch configuration is malformed, so no threshold can be trusted.

A fresh receipt's own `unacked_critical_count` is the reported total; when the receipt is stale, missing, or unreadable, the total is counted from the spool instead and the wake says which case it is.
The oldest age and the alert classes always come from the spool, since the receipt does not carry them.

The wake is one compact digest line, enough to triage without reading the whole inbox:

```
ops-inbox: 621 unacked critical alerts, oldest 13d, top: routine-scheduler 154, pipeline-verifier 96, scheduled-work-inventory 60
```

```
ops-inbox: alert receipt stale 9h; 3 unacked critical alerts, oldest 8h, top: backup-verify 3
```

Alert class is the spool's `source` field, sanitized and length-capped so a hostile or malformed alert cannot forge extra fields, split the line, or corrupt the durable wake record.

The read itself is bounded: the check samples at most `max_lines + 1` spool lines to detect overflow, then parses only the most recent `max_lines` of the spool and acknowledgement log, so its work stays bounded however large the inbox grows.
Exceeding that cap is reported without claiming the exact spool length, because a capped read understates both the total and the oldest age:

```
ops-inbox: inbox past its 20000-line read cap, so the total and oldest age below are understated; 20000 unacked critical alerts, oldest 6d, top: routine-scheduler 5104
```

A valid final JSON record is included even without a trailing newline, while a malformed non-terminated fragment is ignored as an append in progress.
Malformed nonblank complete records fail closed, blank complete records are ignored, and timestamp validation runs only after severity and acknowledgement exclusions so benign excluded records cannot create false wakes.
Every included critical timestamp must have the exact UTC shape and represent a real calendar instant before the scan can succeed.

## When it stays quiet

A standing backlog must not re-wake on every poll, or the wake becomes noise and gets ignored - the same failure in a different shape.
`state/.ops-inbox-wake` privately records the last wake's total, receipt state, and class set.
After a first wake, a further wake needs one of:

- a total at least `growth` larger than the last wake's total (default 10);
- an alert class that was not present at the last wake;
- a changed receipt state, such as a fresh receipt going stale;
- `remind_hours` elapsed since the last wake (default 24), so an unreviewed backlog is raised again daily rather than once and forgotten.

When the fresh receipt and scan no longer meet any wake condition, that record is removed, so the next qualifying backlog wakes immediately instead of being deduplicated against an already-resolved one.

## How it is armed

The watch is the reserved standing check `state/ops-watch.check.sh`, registered through the ordinary custom-check trust binding in `bin/fm-check-register.sh`.
That shim only exports the home and runs `bin/fm-ops-inbox-poll.sh`; the watcher runs the registered bytes and turns any output into one `check:` wake.
Arming is a session-start bootstrap sweep, so it converges on its own rather than depending on anyone remembering to arm it.

By default a home arms the watch only when the configured alert spool actually exists, so a machine with no operations runtime writes nothing and prints nothing.
Secondmate homes never auto-arm, because the primary home owns the one machine-wide inbox, but an explicit `enabled: true` still arms a secondmate home.
The local config is not inherited into secondmate homes.
In auto mode, bootstrap disarms it again when the inbox goes away.
Bootstrap also refuses to arm over a live task holding the reserved `ops-watch` id and reports an arming failure as an actionable `OPS_INBOX:` line.
Arming and disarming are otherwise silent; `FM_BOOTSTRAP_VERBOSE_FACTS=1` prints them as `BOOTSTRAP_INFO` facts.

An armed watch counts as a supervision need in `bin/fm-supervision-lib.sh`, exactly like an X-mode relay poll.
A standing poll only ever reaches the first mate through a live watcher, so a home that is watching alerts keeps supervision alive even with an empty fleet.

## Configuration

Local, gitignored `config/ops-inbox.json` under the effective home overrides the defaults.
Every key is optional, and an unrecognized key is refused rather than ignored, so a mistyped threshold can never read as a configured one.

```json
{
  "enabled": "auto",
  "state_dir": "/absolute/path/to/.openclaw/state",
  "age_hours": 6,
  "count": 25,
  "remind_hours": 24,
  "growth": 10,
  "receipt_stale_hours": 3,
  "max_lines": 20000
}
```

- `enabled` is `auto` (default: arm only when the spool exists), `true` (always arm, and treat a missing spool or receipt as an alerting failure), or `false` (never arm).
- `state_dir` selects the watched directory; `spool`, `acks`, and `receipt` override those three paths individually.
- `remind_hours: 0` disables re-reminding, and `receipt_stale_hours: 0` disables the staleness condition.
- `max_lines` bounds how many recent spool and acknowledgement lines one check reads (default 20000).
- `FM_OPS_INBOX_STATE_DIR` overrides the default watched directory for tests and specialized setups; an explicit config value always wins over it.

`docs/configuration.md` owns where this file sits among the other local operating choices, and `bin/fm-ops-inbox-lib.sh`'s header owns the exact resolution mechanics.

## Two paths named "ops-inbox"

The JSONL spool above is the alert inbox this watch reads.
A second, unrelated path shares the name: some operations routines drop plain-text `.event` files into `<firstmate-home>/ops-inbox/<source>/`, a spool with no severity field, no acknowledgement model, and no reader on the Firstmate side.

Those two are not two views of one inbox; they are one watched inbox and one unread drop directory.
Firstmate treats the JSONL spool plus its receipt as the single alert surface, and gitignores the drop directory so its machine-local files can never be committed into this shared repo.
Converging the routines that write `.event` files onto the JSONL spool belongs to the operations repository that owns those routines, not here: an alert only reaches this watch once its producer records it in the spool.
Until that convergence lands, an alert written only as an `.event` file is not covered by this watch.
