# Robin

## Why it exists

Robin turns bounded public-source questions into reusable, sourced knowledge briefs for Firstmate.
It separates research judgment from retrieval, delivery, and filesystem effects.
It keeps reports available when delivery must be retried instead of repeating research unnecessarily.
It starts only on an explicit command and never installs tools, schedules work, or changes another application's configuration.

## How to run

Use Node 20 or newer, Bash, jq, and Perl from a fresh checkout.
`start` manually registers the foreground process through the shared service message port and handles one request at a time.
**Retrieval readiness: UNREADY.**
This M1 checkpoint delivers the message-port integration, durable refusal/report workflow, persona, help, and documentation, not live research.
Retrieval and model execution remain unavailable: enabling a live adapter refuses startup before registration, and requests under the disabled defaults receive durable unverified briefs.
No native retrieval boundary or network/model adapter is shipped in this checkpoint; proving those controls is a prerequisite for enabling retrieval.
No fake-backed result is evidence of live retrieval readiness.

```sh
bin/fm-robin.sh --help
mkdir -p ./robin-demo-home
bin/fm-robin.sh demo --home ./robin-demo-home
bin/fm-robin.sh status --json --home ./robin-demo-home
bin/fm-robin.sh stats --home ./robin-demo-home
bin/fm-robin.sh view --clean
NO_COLOR=1 bin/fm-robin.sh view --clean
bin/fm-robin.sh view --frames 16 --out ./robin-frames
```

The demo requires an explicit existing home without prior `state/robin/` data and never uses a live message identity, model, or network.
Frame export requires a new output directory and refuses overwrites.
`view` is a separate scene, not a research trigger: a mostly static original ASCII illustration with a brief blink every eight seconds.
It reuses two prebuilt poses, checks for a pose change every two seconds, and draws only changed poses; there are no sub-second production timers.
Its unknown queue is shown as `?`, never as an invented zero; redirected output, `--clean`, and `--no-ui` are static.
The scene does not yet subscribe to a live queue or implement the later acceptance ledger.
For a measured foreground preview, run `bin/fm-robin.sh view --home ./robin-demo-home` in a terminal and query `status --json` from another terminal.
Both `start` and the preview publish their own RSS and CPU sample every five seconds under `state/robin/resources.json`; `status` never substitutes the querying process's measurements.
A home has one diagnostics owner, so run a live preview in a separate home from a running service.
`resources.pid`, `rssBytes`, `cpuPercent`, `sampleMs`, and `sampledAt` identify the self-reported measurement; stopped or stale processes return `resources: null`.
The first sample has unknown CPU until a complete interval exists.
Diagnostics use an exclusive `resources.owner` file; clean SIGINT/SIGTERM exit removes only that process's records, while a stale owner requires explicit operator inspection rather than automatic takeover.
The fixed Node process budget is below 60,000,000 bytes RSS and below 1% idle CPU over 30 seconds.
Measured on 2026-09-11 with Node 24.15.0 on macOS arm64: the message service used a maximum sampled 45.04 MB RSS and 0.166% average idle CPU over 30.16 seconds, with 0.138% independently measured OS CPU.
The preview used 54.12 MB RSS and 0.216% CPU over 30.15 seconds, with 0.230% independently measured OS CPU.
Reproduce with `node --test modules/fm-robin/tests/resources.test.mjs`.
The real terminal-stack budget check covers both foreground processes; live retrieval/model execution and their possible subprocess costs are not yet measured.

Start the message service with `bin/fm-robin.sh start --home ./robin-demo-home`; `--once` processes at most one pending request before closing.
Its shared participant name is `robin`; use the [message owner](../fm-state-reader/README.md#standalone-service-admission) to send it a request from an admitted participant.
The shared owner manages `state/services/robin.json`, `state/robin.inbox/`, thread correlation, replies, and acknowledgements; Robin defines no inbox envelope, sender override, or task metadata.
The service uses native directory notifications with a five-second metadata fallback, not repeated message CLI calls while idle.
SIGINT/SIGTERM waits for the current operation before deregistration and preserves inbox history, reports, and journals.
The application payload is JSON text inside a shared request message:

```json
{
  "question": "Which behavior do these public documents corroborate?",
  "scope": "Only the two specified public documents; no execution claims.",
  "topic": "api-behavior",
  "allowedSources": [
    {"adapter": "fetch", "url": "https://docs.example.org/api"},
    {"adapter": "scrapling", "url": "https://other.example.net/review"}
  ],
  "deadline": "2030-01-01T12:00:00Z",
  "publicOnly": true
}
```

`question` and `scope` are nonempty strings of at most 2000 characters each; `topic` is a lowercase slug of at most 64 characters.
`allowedSources` contains one to `maxFetches` distinct HTTPS URLs, with a configured adapter and approved origin for each.
`deadline` is a UTC ISO timestamp and caps the configured per-request time budget; expired requests do no retrieval.
`publicOnly: true` is the sender's assertion that the submitted content is authorized for public-source research, not a content classifier or an OS security boundary.
Identity, request ID, thread, and return routing come exclusively from the shared message envelope.

Finished reports live at `FM_HOME/data/knowledge/<topic>/<message-id>.md`; refused requests use topic `unclassified`.
[Core validation](src/core/research.mjs) owns the request and conclusion rules and the verdict-first report format; the [persona](personas/researcher.md) owns model instructions.
The real event adapter publishes the immutable report reference through the existing registered process-event owner, not a private wake queue writer.
Delivery order and restart behavior are owned by [the use case](src/usecases/research.mjs).
A crash after a reply is sent but before its receipt is journaled can repeat a reply; this is at-least-once delivery, not exactly once.
Known partial fan-outs retry their existing shared receipt rather than creating another message.

## How to configure

Configuration is `FM_HOME/config/robin/config.json`, falling back to the module's [config.json](config.json) only when no home configuration exists.
`--config FILE` selects an explicit configuration; a missing explicit file is an error.
[config.schema.json](config.schema.json) documents the configuration shape, and the direct validator rejects unknown fields before runtime side effects.
The intended persona location is relative to the selected configuration directory; module defaults use the bundled persona.
Live persona loading is not yet wired into a model adapter.

| Key | Default | Meaning |
| --- | --- | --- |
| `maxSeconds` | `120` | Per-request ceiling, 1-600 seconds, additionally capped by the request deadline. |
| `maxFetches` | `6` | Maximum explicitly requested retrieval operations, 1-20. |
| `maxBytes` | `65536` | Maximum accepted UTF-8 bytes per returned source, 1024-262144. |
| `enabledAdapters` | `[]` | Exact enabled names: `fetch`, `gh`, `scrapling`, `alphaxiv`; no fallback to a disabled adapter. |
| `sources` | `[]` | At most 100 approved source-origin and publication-group pairs. |
| `sources[].origin` | Required per entry | Unique canonical HTTPS origin, without credentials, port, or path. |
| `sources[].publisher` | Required per entry | Lowercase publication-group slug; mirrors and publications under common control must share a group. |
| `roles.researcher.harness` | `pi` | Configured reasoning executable family: `pi` or `pi-signed`. |
| `roles.researcher.model` | `default` | Explicit model name, or the selected harness default. |
| `roles.researcher.effort` | `low` | `low`, `medium`, `high`, or `xhigh`. |
| `roles.researcher.persona` | `personas/researcher.md` | Relative editable English persona path. |

No adapter is enabled by default.
The current service demonstrates shared message delivery, durable orchestration, and fake-backed research, not network destination enforcement, reader confinement, provider authentication, or model output reliability.
The existing retrieval setup's successful imports and static extraction do not prove safe local reads, egress, redirects, or private-destination handling.
Missing native controls must keep an affected retrieval path unavailable; a persona or Python environment is not a sandbox.

## Telemetry

The filesystem adapter appends the [shared telemetry shape](../TEMPLATE.md#application-contract) to `FM_HOME/state/robin/telemetry/YYYY-MM-DD.jsonl`.
It logs structured outcomes, bounded counters, and stable refusal codes, not source text, prompts, environment variables, credentials, or raw exceptions.
Tokens and cost are `null` when unavailable, not fabricated zeroes.

```sh
bin/fm-robin.sh stats --home ./robin-demo-home
jq . ./robin-demo-home/state/robin/telemetry/*.jsonl
```

`stats` reports the last 24 hours: completed requests, requests with supported conclusions (including partial briefs), unverified requests, errored steps, attempted retrievals, malformed telemetry rows, truncation, and unavailable tokens/cost.
Telemetry retains seven UTC days and caps each daily JSONL file at 512 KiB; individual records above 16 KiB are refused before writing.
When the daily cap is reached, the log restarts with a `telemetry.truncated` marker, and `stats.truncated: true` warns that counts are incomplete.
Day retention is applied on the first write of a new event date, never by an idle cleanup timer.
Knowledge reports and delivery journals are not telemetry and are not deleted by this retention policy.
A malformed line is counted, not silently interpreted as a successful operation.
The synthetic demo uses a fixed clock for repeatability, so its historical rows can fall outside the rolling window.
Durable per-request journals and immutable events live under `state/robin/`; runtime writes never belong in a project checkout's tracked files.
An existing `state/robin/run.lock` prevents concurrent processing; no stale lock is automatically removed.
Before an operator removes a stale lock, they must verify its process has exited and preserve its journals and reports.

## Development

Follow [the module template](../TEMPLATE.md) and [repository contributor guidance](../../CONTRIBUTING.md).
Core rules are plain functions; the use case receives only [its I/O ports](src/ports/research.d.ts).
Message fakes come from the shared message owner; [research fakes](tests/fakes.mjs) supply retrieval, reasoning, clock, journal, and event behaviors without services or credentials.
No module import starts work or opens a model session.

```sh
npm --prefix modules/fm-robin test
bin/fm-test-run.sh tests/fm-robin.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
```

Tests separate core rules, fake-backed workflow continuity, real file/journal recovery, registered event capture/wake composition, CLI refusal/help, bounded telemetry/scene exports, and the real 30-second terminal-process CPU/RSS budget.
The resource test requires Python 3's standard-library PTY support and `ps`, uses an isolated home, cross-checks native CPU counters with the operating system, and restores the terminal on exit.
Real service tests cover native admission, two sequential requests over the shared port, correlated replies, immutable report/event capture, durable wakes, retained acknowledgements, and graceful shutdown.
Their retrieval and reasoning ports are explicitly synthetic; they do not claim a live model, external retrieval, or a completed production research request.

The persona adapts the installed `@companion-ai/feynman` 0.3.47 researcher and verifier instructions, identified by their source-relative names `.feynman/agents/researcher.md` and `.feynman/agents/verifier.md` in [Feynman](https://github.com/companion-inc/feynman).
It retains traceable source numbers, read-before-summary discipline, specific-claim verification, coverage gaps, and rejection of unsupported execution claims.
It deliberately rejects the upstream inference that zero search results prove nonexistence and replaces a fixed five-source minimum with the owner's per-conclusion corroboration rule.
The authorized operational research charter supplies public/minimized outbound scope, evidence separation, contradictory evidence, and no self-directed work; the local retrieval safety receipt supplies the distinction between setup success and enforcement readiness.
Private source copies, checksums, and extraction evidence belong in the task report, not in published operational paths.
