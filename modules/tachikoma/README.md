# Tachikoma

## Why it exists

Tachikoma recommends a subscribed model from reviewed dispatch policy, current quota evidence, and task-class outcome cards.
Eligibility gates precede either highest-priority selection or reproducible weighted coding exploration.
It records the decision before returning it and learns only from sealed real attempts.
This slice is a manual CLI: no model calls, daemon, private messaging protocol, or animated service is started.

## How to run

From a fresh Firstmate checkout with Node 20+, Bash, jq, and the configured quota-axi available:

```sh
bin/fm-tachikoma.sh --help
bin/fm-tachikoma.sh status --clean
bin/fm-tachikoma.sh route --if-enabled --task example-1 --class bounded-implementation-proven-root-fix --repo example --brief brief.md
bin/fm-tachikoma.sh learn
bin/fm-tachikoma.sh stats
```

`-h` and `--help` on every verb list all implemented verbs and flags with one-line descriptions and examples.
Status is static, honors `NO_COLOR`, and supports `--clean`, `--no-ui`, and `--json`; it never rewrites the screen.
An absent/off policy with `--if-enabled` returns `{"status":"disabled","fallback":"profiles"}` without writing state.
Routing without that flag evaluates a reviewed policy even when off; `--require-enabled` enforces activation.
Exit 2 means invalid evidence/configuration or I/O failure; exit 3 means no selectable candidate, never permission for silent fallback.
The existing spawn command's `--dispatch-tachikoma` option performs the enabled route itself; do not separately consume an exploration allowance as a preflight.

## How to configure

`FM_HOME` selects the operational home; `FM_DATA_OVERRIDE` changes its data root, not its configuration or service telemetry root.
The operator writes `FM_HOME/config/tachikoma/policy.json`, validated against the shape in [config.schema.json](config.schema.json) and the CLI's semantic checks.
[config.json](config.json) supplies defaults; it is not an activated inventory.
Existing `config/model-catalog.json` and `config/crew-dispatch.json` remain the subscription and profile owners.
Their natural-language constraints require an explicit reviewed compilation, not prefix inference or model-auth guessing.
Verify each selected harness/model, subscription-account relation, quota scope, task-class fit, and disabled policy before approving that compilation.
Editing either source invalidates its recorded raw-file SHA256; learning never edits policy or activates a route.

| Policy key | Default / meaning |
| --- | --- |
| `schemaVersion`, `enabled` | Required `1` and boolean; activation defaults to false. |
| `catalogSha256`, `dispatchSha256` | Null until the reviewed raw source hashes are supplied. |
| `allowedHarnesses`, `disabledPools` | Empty arrays; explicit verified adapter allow-list and policy exclusions. |
| `maxLoadPerCpu` | 2; positive ceiling for one-minute load divided by logical CPUs. |
| `explorationRate` | 0.1; positive uniform exploration component within each allocation. |
| `unmeasuredRate` | 0.05; total exploration probability reserved for unmeasured pools, shared between them. |
| `unmeasuredDailyCap` | 1; maximum recorded unmeasured picks per pool per UTC day. |
| `rules` | Empty; exactly one matching `repo` and `taskClass` is required. |
| `bindings` | Empty; explicit mapping for every concrete profile in the matched source rule. |

Each rule specifies `repo`, `taskClass`, `matchedRule` (`default` or one-based `rule-N`), positive `horizonSeconds`, `strongestOnly`, and `selectionStrategy` (`highest-priority` or `quota-weighted`).
Each binding specifies `harness`, `model`, `effort` (including explicit null), `pool`, `catalogModel`, `quotaProvider`, `modelFamily`, nonempty `quotaScopes`, and `strongest`.
`accountProfile` is optional/null and supported only for native Claude; `qualityPrior` is an operator-reviewed 0-1 class-fit prior required for weighted selection, not a fabricated measured score.
Optional `modelVersion` and `cliVersion` enable exact-version card use; without them, selection discloses its profile prior rather than attributing unrelated history.
The catalog supplies the provider for cooldown checks; `quotaProvider` explicitly identifies the quota producer's possibly different provider label.
For example, Pi Cursor Grok, GLM, and Composer selectors belong to their approved Cursor pool, not to a direct Grok subscription merely because a model name contains “grok”.
Provider-wide quota bounds apply alongside every explicitly bound model/product scope; unknown headroom or runway is disclosed, not invented.

`quota-axi` owns pacing economics; its TOON is read once, with one JSON fallback only for ambiguous applicable evidence.
Snapshots older than 300 seconds refuse; known exhaustion, insufficient projected runway, active cooldowns, overload, and policy/class exclusions are vetoes.
Weighted selection uses shifted `spendPriority`, smoothed exact-class acceptance/relaunch/findings quality, and comparable observed wall-time/cost factors; the full inputs, factors, normalized probabilities, exploration rates, and uint32 draw are logged.
Unknown costs are neutral rather than zero; currencies are never silently mixed.
Unmeasured exploration requires a measured baseline, retains its disclosed small allocation, and cannot exceed the pool's daily cap; the journal lock covers the count, draw, and append together.
An identical `--request-id` replays its decision without spending the cap again; a changed task, brief, or compiled policy under that identity refuses.
`highest-priority` retains the existing highest-known-scalar rule and refuses genuine ties.

## Telemetry

Decisions append to `data/tachikoma/decisions.jsonl`; `learn` rebuilds `data/tachikoma/cards/<percent-encoded-model>.json` and publishes `data/tachikoma/sync.json` last.
Pool observations in decisions, cards, status, and stats retain quota pacing, reset timestamps, applicable cooldown expiry, and a countdown to recheck.
An unavailable producer pacing-recovery estimate stays null; reaching a timestamp means fresh evidence is due, never authority to clear a gate.
Each new route re-reads quota and the existing cooldown owner, so expiration/refill can re-admit a pool without changing a blacklist.
The append-only model ledger remains owned by `bin/fm-model-telemetry.sh`; new joins require exact decision identity and tuple, while pre-router history stays explicitly unjoined.
Teardown seals observed terminal facts before losing session identity, and distinguishes proven delivery from merely permitted cleanup.
Unavailable test-assertion counts, review findings, blocker totals, turns, tokens, and cost remain null unless their mechanical producer supplied them.

Service events append to `FM_HOME/state/tachikoma/telemetry/YYYY-MM-DD.jsonl` using the shared [module event shape](../TEMPLATE.md), with additive `schemaVersion:1` and port/operation identifiers.
Adapter entry/exit timings, decisions, refusal reasons, request/thread IDs, and counters are recorded without prompt bodies, account descriptions, credentials, or raw provider responses.
The deterministic CLI has no observed model token/cost usage to report.
Use `status --json` for decisions and recovery evidence and `stats --day YYYY-MM-DD` for deduplicated daily request outcomes, port costs, counters, and latest pool observations.

## Development

Follow [the shared template](../TEMPLATE.md): `src/core` contains pure rules, `src/usecases` composes required ports, and `src/adapters` owns real I/O.
Shared imports use only the public `fm-state-reader` and `fm-tui-core` entries; there are no application-to-application imports.
The [port declarations](src/ports/routing.d.ts) are small interfaces, not a runtime container:

- `RoutingEvidence`: read and validate a minimized routing snapshot plus decision provenance.
- `RoutingJournal`: serialize decisions and daily allowance use, read cards, and publish derived learning.
- `ModelTelemetry`: read projected attempts through the existing append-only ledger owner.
- `ServiceTelemetry`: append minimized observations and read one UTC day.

The shared `messages` adapter and `MessagePort` in [fm-state-reader](../fm-state-reader/README.md) own service envelopes; this CLI-only slice has no receiver or duplicate placeholder protocol.
[In-memory fakes](tests/fakes.mjs) exercise use cases separately from the thin executable adapter tests.
From the repository root, run `bin/fm-test-run.sh tests/fm-tachikoma.test.sh tests/fm-model-telemetry.test.sh tests/fm-model-usage.test.sh`, then `bin/fm-lint.sh` and the affected delivery/spawn checks.
`npm test --prefix modules/tachikoma` runs the colocated tests with the Firstmate owner scripts available.
The shell entry is deliberately thin; package extraction must provide those owner adapters rather than copy their policy into the core.
