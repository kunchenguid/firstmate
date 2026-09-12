# Marvin

## Why it exists

Glance at subscription quota and spending pace without opening Baby Menu.
Named after Marvin from The Hitchhiker's Guide to the Galaxy: the depressed robot who always knows exactly how bad the numbers are, and says so.
One table row represents one configured account pool, sorted by pace urgency.
The observer only reads quota-axi; it never selects models, changes subscriptions, or reads credential files.
There is no background server, idle animation, or automatic startup.

## How to run

From a fresh checkout with Node.js 20+ and quota-axi installed and authenticated:

```sh
bin/fm-marvin.sh -h
bin/fm-marvin.sh
bin/fm-marvin.sh status --clean
bin/fm-marvin.sh status --json
bin/fm-marvin.sh watch --refresh 60
bin/fm-marvin.sh watch --frames 3 --out state/marvin/frames
bin/fm-marvin.sh history
bin/fm-marvin.sh stats
```

Every verb accepts `-h` and `--help` without querying quota-axi.
`watch` runs in the foreground and Ctrl+C exits; refresh is measured after each completed frame, so reads never overlap.
`NO_COLOR` disables color and `--clean` prints the same rows from the ASCII glyph set.
Each live pool is one row: a 10-cell remaining bar, floored percent, `!`/`!!` band, pace word with signed points, and the binding window's reset.
When a pool's limits differ, each limit gets its own indented line with bar, percent, pace, and reset.
Unavailable pools are omitted from the table; the footer keeps a dim unavailable count plus the bar legend.
The header separates data time from sample age and next refresh.
JSON output includes complete untruncated fields and one object per refresh, plus `resources.rssBytes` and `resources.cpuPercent` for this observer process.
CPU percent is process CPU time divided by process uptime, not host load or quota-axi child CPU.
TTY watch writes only changed cells and skips unchanged quota evidence; timestamps alone do not trigger a redraw.
At 100 cells the ACCOUNT column shows the configured pool id (email only in `--clean` and `--json`); below 100 that column is dropped and the footer splits onto two lines.
The last column truncates with `~`; rows never wrap.
`watch --frames 3 --out DIR` writes 80-column Unicode, 120-column Unicode, and 80-column ASCII review frames from one sample.
Use `--json` for complete identities, credential-source labels, original window names, ideal percentages, and per-window reset times.

## How to configure

The default home is the repository root; set `FM_HOME` to use another home.
Configuration comes from `FM_HOME/config/marvin.json` when present, otherwise [config.json](config.json); `--config FILE` overrides both.
The [schema](config.schema.json) owns the accepted shape, and invalid or unknown settings are refused before side effects.

- `refreshSeconds`: integer 1-86400, default 60; `--refresh N` overrides it.
- `pools`: default `[]`, discovering every provider in the ambient quota-axi snapshot, including unavailable providers.
- `pools[].id`: required unique stable identifier used for history, containing letters, digits, underscores or dashes; do not put secrets or emails here.
- `pools[].provider`: required quota-axi provider identifier.
- `pools[].label`: optional display name, default source label or provider identifier.
- `pools[].expectedEmail`: optional expected identity for mismatch detection; a missing observed identity stays unknown, not mismatched.
- `pools[].credentialSource`: optional display-only credential source path or label; default source evidence from quota-axi, or unknown.
- `pools[].env`: optional `CODEX_HOME` and/or `CLAUDE_CONFIG_DIR` passed only to that pool's quota-axi process; other environment keys are rejected.
- `pools[].windows`: optional map of quota-axi window IDs to positive durations in seconds, overriding source durations.

For example, create an untracked configuration with your real account homes:

```json
{
  "refreshSeconds": 60,
  "pools": [
    {"id":"claude","provider":"claude","label":"CLAUDE"},
    {"id":"codex-1","provider":"codex","label":"CODEX #1"},
    {"id":"codex-2","provider":"codex","label":"CODEX #2","env":{"CODEX_HOME":"/absolute/account-two"},"expectedEmail":"account-two@example.test","credentialSource":"/absolute/account-two/auth.json"},
    {"id":"cursor","provider":"cursor"},
    {"id":"kimi","provider":"kimi","windows":{"weekly":604800}},
    {"id":"grok","provider":"grok"}
  ]
}
```

Additional subscriptions require explicit pools because quota-axi reads only the active account for each provider/environment.
The adapter requests schema-v5 `quota-axi --json --full --no-credential-refresh`, with a 20-second bound per invocation; the full JSON adds identity and cycle fields omitted by the compact default report.
Credential discovery and provider scraping remain entirely in quota-axi.
If quota-axi supplies only a source type, it is shown honestly rather than inventing a credential path; configure a display path when known.
Quota-axi may omit plans, identities, or limits that Baby Menu has, so this view cannot promise identical account counts without matching pool configuration.

### Pace and labels

[The core](src/core/quota.mjs) owns the calculation: ideal remaining percentage is remaining window time divided by total duration, and pace delta is quota remaining minus ideal remaining, in percentage points.
Explicit start/reset timestamps determine duration unless configured otherwise; otherwise the source window duration is used.
Negative delta is `HOT`, positive is `UNDER`, and equality is `ON PACE`.
Missing cycle data is `PACE UNKNOWN`; expired limits, stale source data, missing measurements, and failed reads are never presented as fresh quota.
A pool is `HOT` when any measured limit is over pace; LEFT uses quota-axi's all-model effective availability when present, otherwise its smallest measured remaining percentage.
The row shows the binding window's reset and prints `EVEN` for core `ON PACE`.
`DUPLICATE ACCOUNT` marks both pools sharing a provider and account identity; `IDENTITY MISMATCH` compares a configured expected email with observed evidence.
Warnings are independent of pace, and the footer counts pools rather than silently deduplicating subscriptions.

## Telemetry

Each status/watch sample appends daily JSONL under `FM_HOME/state/marvin/telemetry/YYYY-MM-DD.jsonl`.
The adapter records source and renderer entry/exit, errors, counters, timings, and per-window percentage/pace samples; costs and tokens remain null because no model is invoked.
Emails, credential paths, raw provider output, and credential values are not recorded.
Files are created owner-readable/writable and the directory owner-only; full JSON and exported terminal frames do contain account identities, so keep exports private.
`history` reads the last seven days of per-pool samples in UTC and `stats` summarizes the last 24 hours without contacting quota-axi.
Daily files are capped at 512 KiB; after the cap, display refresh continues but further telemetry that day is omitted.
On the first write each day, files older than the seven-day history horizon are removed, bounding retention to eight UTC date files (4 MiB); history may therefore contain gaps.
Run one observer per home to avoid concurrent writers racing the daily size check; no database or extra retention process is installed.
An incomplete final JSONL line during an append is ignored, while malformed completed lines report an error.

```sh
bin/fm-marvin.sh history --json
bin/fm-marvin.sh stats --json
```

## Development

```sh
bin/fm-test-run.sh tests/fm-marvin.test.sh
npm --prefix modules/marvin test
bin/fm-doc-audience-check.sh
```

[The module pattern](../TEMPLATE.md) owns the layout conventions.
Core tests exercise pace and classification, use-case tests substitute [in-memory ports](tests/fakes.mjs), and adapter tests compose the actual CLI, a fake quota-axi executable, terminal output, and JSONL history.
The composition test asserts read/render/sleep ordering and Ctrl+C termination rather than only the final frame.
For a credentialed real-stack check, run `bin/fm-marvin.sh status --clean` and compare `status --json` with live `quota-axi --json --full --no-credential-refresh`; keep identity-bearing evidence private.
No runtime backend or agent harness integration is required or changed.

### Resource budget

The observer has no extra dependencies and sleeps between reads; default idle polling is 60 seconds with no sub-second timers.
The Node RSS budget is 60 MB and idle CPU must remain below 1% across 30 seconds.
Measured with Node v24.15.0 and live quota-axi on macOS: 36,061,184 bytes RSS (34.4 MiB), 0.033% idle CPU over 30.06 seconds after the first live frame.
These are observer-only measurements; quota-axi runs briefly as a separate bounded child during refresh.
Recheck the live budget explicitly with `FM_MARVIN_LIVE=1 node --test modules/marvin/tests/resource.test.mjs`; ordinary tests print an explicit skip because CI has no subscription credentials.
