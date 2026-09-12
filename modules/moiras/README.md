# Moiras

## Why it exists

Moiras turns scattered task records into a calm, readable terminal scene.
Clotho shows the current work, Lachesis measures the evidence, and Atropos proposes what deserves inspection.
It observes and explains; it never interrupts tasks, merges changes, or deletes work.
Missing signals remain unknown rather than becoming permission to act.

## How to run

From a fresh checkout, install Node 20+, Bash, jq, Perl and POSIX `ps` (Linux also uses procfs and `getconf`); configured repository queries also need authenticated `gh-axi`.
Every command supports `-h` / `--help`, listing every verb and flag with a description and example, without credentials or an operational home.

```sh
bin/fm-moiras.sh -h
bin/fm-moiras.sh start --demo
FM_HOME=/path/to/home bin/fm-moiras.sh start --no-llm
FM_HOME=/path/to/home bin/fm-moiras.sh status
FM_HOME=/path/to/home bin/fm-moiras.sh status --json
FM_HOME=/path/to/home bin/fm-moiras.sh stats
FM_HOME=/path/to/home bin/fm-moiras.sh reason clotho example-task
bin/fm-moiras.sh --demo --frames 24 --out frames --width 100 --height 30
```

Startup is manual and foreground-only; Ctrl+C drains in-flight capture/message calls before deregistering the service and releasing its lease.
The first snapshot becomes visible before serial notification delivery finishes; a fresh snapshot is not proof that all findings have been captured.
`start` and `status` never invoke models; `reason ROLE TASK` explicitly sends one bounded, sanitized evidence packet to the selected provider, prints an advisory and never acts on or publishes it.
`reason` requires an existing task, authenticated Pi or Claude, and a configured persona; `--no-llm`, `--demo` and `--frames` forbid that invocation.
The CLI checks its selected harness through `bin/fm-harness.sh validate`, including the active home's disabled-adapter policy, before invoking a provider.
`start` registers `fm-moiras` through the shared [standalone-service admission](../fm-state-reader/README.md#standalone-service-admission), never borrowing a task or supervisor identity.
Findings go to the supervisor as shared notes with full evidence ids; requests receive correlated replies only to their original sender.
Registration failure refuses startup rather than silently falling back to another identity.
`--clean` and `NO_COLOR` (even empty) print all tasks once in static ASCII without animation or escapes; `--no-ui` keeps plain event output.
The original half/full-block silhouettes hold the shared eye for six seconds, then ease it between hoods on a shallow two-second arc at one frame per second; resize rebuilds the display, while ordinary frames update only changed cells.
During holds, one four-second window can contain a single one-second spindle sway, measuring tick or scissors blink, never simultaneous; the live scene randomly seeds the choices once per launch, while exports use a reproducible seed.
Proposal lines show the first eight characters of the evidence-derived id, including in the demonstration; `status` keeps full ids for the confirmation contract.
Frame export samples every 250 ms starting at scene time 4000 ms to include an eye transfer; `--at-ms` changes that start, and existing frame files are never overwritten.

### Shared channel

With Moiras running, use the shared CLI from the supervisor's own operational home (or a correctly launched task retaining its inherited identity):

```sh
FM_HOME="$PWD" bin/fm-message.sh send fm-moiras --kind request -- "ask example-task"
FM_HOME="$PWD" bin/fm-message.sh receive
```

Requests are `ask TASK`, `confirm ID`, or `dismiss ID`; replace `ID` with the full current evidence id from a note or `status`.
Confirmation/dismissal records an answer, never a task action; changed evidence is refused and notes never cause reply loops.
Native watches discover the shared inbox on first delivery, so receiving does not require a polling process or unrelated task activity.
Moiras persists proposal and reply receipts before acknowledging requests; uncertain sends require shared-ledger inspection rather than replacement messages.
The [message owner](../fm-state-reader/README.md#standalone-service-admission) owns registration recovery and inbox durability; a separate Moiras observer lease is never automatically removed after an abnormal exit.

### Resource budget

The animated server redraws at most once per second and writes only changed cells; filesystem notifications coalesce on a one-second timer without waiting for perpetual event traffic to become quiet.
Headless/static operation has no redraw timer, and resource reporting creates no idle sampler.
`status --json` adds `server` with the lease owner's `pid`, `rssBytes`, native `ps` `cpuPercent`, cumulative `cpuSeconds`, birth identity and `sampledAt`; a missing, dead or mismatched owner yields null, never the status command's own measurements.
The real animated 100x30 / 70-task check measured 52.4 MB maximum sampled RSS and 0.450% CPU over 31.12 seconds, below the 60 MB / 1% idle budgets.
These are the server's idle measurements, not an active provider subprocess budget; [dated verification](../../docs/verification/runtime-backends.md#moiras-resource-budget) records the environment and reproducible check.

## How to configure

Defaults live in `modules/moiras/config.json`; `--config FILE` selects another JSON file, validated against `config.schema.json` before runtime state is created.
The observer reloads edited configuration and rebuilds state/pool subscriptions; new parent directories need a configuration touch or restart because native watches cover existing directories only.

| Key | Default | Meaning |
| --- | --- | --- |
| `beaconSeconds` | `300` | Watcher silence threshold in seconds. |
| `idleSeconds` | `900` | Both status age and generation-matched idle age must exceed this. |
| `busySilentSeconds` | `3600` | Busy status age before Moiras proposes the busy-but-silent advisory. |
| `loopSeconds` | `5400` | Duration of an observed repeated-failure episode, never inferred from old status alone. |
| `loopAttempts` | `2` | Matching failure-status threshold, integer 2-3; evidence is not proof of distinct command executions. |
| `poolRatio` | `0.9` | Lease fraction threshold, 0.01-1; incomplete pools stay unknown. |
| `quietSeconds` | `300` | Minimum interval for each rule/task pair; an unchanged captured event is not republished. |
| `forgeSeconds` | `60` | Repository refresh interval, minimum 30 seconds; no repository timer when unconfigured. |
| `repositories` | `[]` | Explicit GitHub `owner/repo` names; an empty list disables forge queries. |
| `poolFiles` | `[]` | Explicit pool files, absolute or relative to `FM_HOME`; never inferred from task metadata. |
| `roles.<role>.harness` | `pi` for all three | Runnable choices: `pi` or `claude`; native Codex is not supported. |
| `roles.<role>.model` | `openai-codex/gpt-5.6-luna` / same / `openai-codex/gpt-6-astra` | Clotho / Lachesis / Atropos defaults; Claude can use `haiku`. |
| `roles.<role>.effort` | `low` | Independent effort selection. |
| `roles.<role>.persona` | `personas/<role>.md` | Editable English instructions relative to the config file's directory. |

Editing role configuration never enables automatic reasoning.
Reasoning uses a fresh external scratch directory, disables tools and customizations, closes stdin, and limits each call to 60 seconds, its persona to 8 KiB and its evidence prompt to 16 KiB.
Malformed, incomplete, tool-using or semantic-error responses fail closed, even when the provider process exits successfully; Claude whole-answer code wrappers are stripped without accepting extra prose.
The live guard and [dated verification](../../docs/verification/runtime-backends.md#moiras-one-shot-reasoning) distinguish the Pi OpenAI Codex provider from the unsupported native Codex executable.
Forge failures withhold PR findings, and confirmation meaning requires the same current evidence id; confirmations only record a response, never execute its proposed action.

## Telemetry

Private JSONL lives in `FM_HOME/state/moiras/telemetry/YYYY-MM-DD.jsonl`, appended until 1 MiB and then rotated to the single `YYYY-MM-DD.1.jsonl` backup.
The current and previous UTC days are retained; older matching regular telemetry files expire on the next write, not through a background cleanup process.
Retention keeps two segments per retained day with a 1-MiB rotation threshold; concurrent writers are best-effort, not lossless audit storage.
Oversized pre-existing segments are refused and must be archived before retrying.
Read retained records with `jq . FILE` or use `fm-moiras stats` for retained rows from the last 24 hours; `rotated` identifies backup presence, and older rows can have been discarded, so totals are not guaranteed complete historical usage.
Rotation never deletes proposal evidence or reply receipts.
The [module template](../TEMPLATE.md) owns the record shape: correlate `requestId` and `threadId`, inspect adapter entry/exit, decisions/refusals, durations and cumulative per-request counters.
The telemetry sink is not recursively instrumented; message text and raw provider output never belong in logs, and unknown token/cost measurements remain null.
Reasoning entry/exit records include the selected harness/effort, reported model, token count and provider cost estimate when readable; estimates are not verified subscription charges.
Tachikoma and Backpass can ingest this feed; Moiras starts no ingestion process.
Snapshots, immutable findings, quiet receipts and reply receipts stay in `state/moiras`; the process-event owner additionally owns its registered-source records.
A capture is not acknowledgement or exactly-once delivery, and uncertain proposal or reply delivery requires inspecting the shared thread ledger rather than sending replacement text.
The shared transport owns its separate telemetry feed and registration/deregistration logging; Moiras additionally records receive, send, retry and acknowledgement steps without message text.
That transport feed is currently append-only and outside Moiras retention, so total telemetry storage is not yet bounded.

## Development

Run `bin/fm-test-run.sh tests/fm-moiras.test.sh tests/fm-modules.test.sh` from the root, or `npm --prefix modules/moiras test`.
The real-PTY resource regression requires Python 3, spends no model tokens, measures at least 30 idle seconds, and asserts CPU below 1%, sampled RSS below 60,000,000 bytes, actual server PID, terminal restoration and lock cleanup.
With authenticated Pi and Claude, `FM_MOIRAS_LIVE=1 bin/fm-test-run.sh --per-script-timeout-secs 420 tests/fm-moiras-live.test.sh` spends two bounded prompts per configured route, including an adversarial file-write request.
`FM_MOIRAS_LIVE_CASE=pi-default|pi-atropos|claude-alternative` selects one route; omitted routes are explicitly skipped, not counted as passed.
Pure rules and scene composition live in `src/core`; `src/usecases/inspect.mjs` receives I/O and returns plain results; `src/adapters` owns effects.
`StateSource` supplies bounded snapshots and notifications; `Forge` supplies projected PR records; `Journal` owns private records and telemetry; `Publisher` delivers immutable registered events; `Reasoner` supplies one strict advisory with measured usage.
The shared `MessagePort` owns message envelopes, correlation and acknowledgements; the shared `Terminal` port owns output capability and writes.
Tests use in-memory journals, sources and the canonical message fake alongside real file/process composition.
The [real CLI channel guard](tests/channel.test.mjs) proves service registration, first-inbox discovery, supervisor request/reply correlation, unchanged task bytes after confirmation, proposal deduplication across restart, and orderly deregistration without models.
An injected `observe({messages})` port stays caller-owned; omission selects real service admission, while explicit null is only for intentionally disconnected embedding/tests.
Firstmate integration uses the two shared libraries and the existing harness-policy, process-event and message owners; no application imports another application.
