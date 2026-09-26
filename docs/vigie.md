# Vigie recommendation digest

`bin/fm-vigie.sh` is a bounded, read-only projection over `bin/fm-fleet-snapshot.sh` and native Hermes readers.
The snapshot and native reader outputs are authoritative observations; Vigie does not create a ledger or execute merge, authentication, service, update, or notification actions.

Usage:

    bin/fm-vigie.sh
    bin/fm-vigie.sh --json
    bin/fm-vigie.sh --fr
    bin/fm-vigie.sh --json --event previous.json
    bin/fm-vigie.sh --json --daily --event previous.json

The default is compact AXI/TOON output.
`--json` emits `fm-vigie.v1`; `--fr` renders the same bounded recommendations as concise French notification text.
`FM_VIGIE_MAX` defaults to 10, `FM_VIGIE_AGE_DAYS` defaults to 14, `FM_VIGIE_NATIVE_TIMEOUT` defaults to 20 seconds, `FM_VIGIE_NATIVE_MAX_BYTES` defaults to 12000 bytes per output stream, and `FM_VIGIE_SOURCE_RECORD_MAX` defaults to 500 records per source.

Recommendation inventory:

- Ready PRs are projected from the native snapshot backlog rows (queued/in-flight records with a PR URL), with the recorded URL, title, state, and gate retained as evidence. A snapshot producer may also provide structured `ready_prs`; Vigie does not invent that field or query a forge itself.
- Client stage gates, credential evidence, and pending service/update decisions are read only from their explicitly named native snapshot fields. If the producer does not expose one of those fields, its inventory status is `unknown` rather than an inferred empty/clear result.
- No-argument runs also read `hermes kanban stats --json`, `hermes kanban notify-list`, `hermes monitoring status`, `hermes insights --days 1`, `hermes doctor`, `hermes cron list`, and `hermes cron doctor` when Hermes is installed.
- Each registered producer has a source record under `native` with its argument vector, status, stable reason code, exit status, timeout state, separately captured stdout and stderr, truncation state, and observation time.
- Missing, failed, timed-out, malformed, and truncated producers remain explicit instead of becoming empty evidence.
- Dossier and reflex have separate unavailable source records because no native reader is registered for either category.
- A ready Kanban count and actionable doctor, cron, or watched-tool observations become recommendations only when an explicit parser mapping recognizes source-owned identities.
- Keyed open decisions use task `hints.open_decisions` and secondmate `decisions_open` records. The task and source key remain in evidence.
- Every normalized observation contains a typed category, stable percent-encoded source identity, source id, status, structured evidence, stable unknown tokens, and optional authoritative age.
- The complete deduplicated observation set remains in `observations`; actionable observed records produce recommendations.

Daily and event semantics:

- Scheduling is outside this command. `--daily` declares a daily view and resurfaces existing recommendations whose authoritative `age_days` is at least `FM_VIGIE_AGE_DAYS`.
- `--event <previous.json>` compares the complete uncapped `observed_keys` with a prior JSON digest.
- `changes.new` contains additions, `changes.resolved` contains keys no longer observed, `changes.indeterminate` preserves prior keys whose current producer is unknown or unavailable, and daily `changes.resurfaced` contains retained items with authoritative age at or above the threshold.
- New and resurfaced records rank before retained records; the display cap is applied only after deltas and ranking.
- Display never answers a hold, closes a blocker, changes a service, updates credentials, runs a job, or marks work complete.

Delivery is explicit: the output identifies the approved pilot channel separately from the future desktop surface and reports `scheduled: false`. Notification scheduling or Discord activation requires separate approval.
