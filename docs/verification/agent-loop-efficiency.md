# Agent-loop efficiency verification

Audience: maintainer verification.

This record supports current Firstmate-controlled agent-loop overhead evidence, cache-stable digest verification, deferred-discovery boundaries, bounded fleet inspection, Code Mode non-adoption, transport and compaction ownership, and Sol/Terra/Luna routing non-change.
Task chronology and delivery transcripts stay in private task or PR evidence.

## Baseline command

```sh
bin/fm-agent-loop-baseline.sh --json --with-session-fixture
```

Measured on 2026-07-30 at Firstmate commit `0564a48daa0b9afc34ef812d9256dfd67321a835` with Pi 0.83.0 and `pi-openai-server-compaction` 0.1.0 at commit `8a3de2f3b0c178fdd6f73f2f94172dfc3943e466` available on the host:

| Field | Observed |
| --- | --- |
| `schema` | `fm-agent-loop-baseline.v1` |
| `agents_md_bytes` | 54986 |
| `skill_description_bytes` | 7251 (19 skills) |
| `skill_body_bytes` | 202200 (on-demand bodies, not always-loaded) |
| `pi_extension_tool_description_bytes` | 727 |
| `pi_extension_tool_count` | 1 named LLM-callable tool registered in tracked extensions |
| `session_start_fixture_deterministic` | `true` |
| `session_start_fixture_sorted_ids` | `true` |
| `openai_server_compaction` | `present` |
| `openai_compact_threshold` | `260000` |
| `openai_use_previous_response_id` | `true` |
| `openai_codex_models` | `gpt-5.3-codex-spark,gpt-5.4,gpt-5.4-mini,gpt-5.5,gpt-5.6-luna,gpt-5.6-sol,gpt-5.6-terra` |
| `luna_available` | `true` via `openai-codex/gpt-5.6-luna` |
| `code_mode_embedded_runtime` | `absent` |

Re-run the command after material always-loaded surface changes and replace the table with fresh output.
Approximate tokens are a 4-byte heuristic for relative comparison only.
Host-dependent package, config, and model-store fields are inventory, not proof that a provider path was active during the measurement.

## Cache-stable prompt construction

The script headers own their respective contracts:

- `bin/fm-prompt-stable-lib.sh` - shared id-listing order
- `bin/fm-session-start.sh` - digest layout and stable-versus-volatile classification
- `bin/fm-supervision-instructions.sh` - render inputs and layout

Regression entry point:

```sh
bin/fm-test-run.sh tests/fm-agent-loop-efficiency.test.sh
```

The suite compares public rendered outputs under fixed inputs, proves single-variable captain-file sensitivity, proves sorted multi-entry task order, and keeps the complete stable prefix byte-identical across a single volatile status change.

## Deferred discovery boundary

Pi 0.83.0 documents dynamic registration and additive `setActiveTools` loading in its [Dynamic Tool Loading guide](https://github.com/earendil-works/pi/blob/v0.83.0/packages/coding-agent/docs/extensions.md#dynamic-tool-loading).
Firstmate's tracked Pi watch extension keeps core fleet arming immediately available as `fm_watch_arm_pi`.
Firstmate does not install an opaque tool proxy or Code Mode runtime.
Conditional agent skills remain progressive-disclosure descriptions with on-demand bodies.
External packages such as Linear tools stay outside Firstmate's launch contract.

## Bounded fleet inspection

Whole-fleet reviews use existing aggregates rather than serial per-task loops:

- `bin/fm-fleet-snapshot.sh` / `bin/fm-fleet-view.sh`
- `bin/fm-bearings-snapshot.sh`
- session-start compact backlog plus sorted meta dump

`AGENTS.md` heartbeat handling names those aggregate commands explicitly.
Existing bound helpers remain the only truncation applied to safety-critical status tails and errors.

## Code Mode evaluation

Tracked Firstmate material contains no embedded Code Mode runtime.
Existing shell aggregates already batch the highest-volume fleet inspection paths.
The baseline's `code_mode_embedded_runtime=absent` field records this declared boundary; it is not an automated source or runtime detector.

## Transport and compaction

| Concern | Firstmate control | Current evidence |
| --- | --- | --- |
| Pi spawn cache retention | `bin/fm-spawn.sh` header | Public spawn capture covers unset, explicit empty, and explicit nonempty `PI_CACHE_RETENTION` inputs for pi and pi-signed |
| OpenAI `previous_response_id` / WebSocket stream | Operator Pi package only | The version-scoped [package README](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/README.md) records direct `openai/*` support and retained built-in transport for `openai-codex/*` |
| Server-side compaction threshold | Operator package and config | The baseline observed `compactThreshold=260000` and `usePreviousResponseId=true` in the global operator config |
| Competing Firstmate compactors | None | Do not add a second path |
| GPU / KV / speculative decode | None | Outside Firstmate |

Firstmate does not add or own a custom OpenAI provider.
Provider transport remains with Pi or the operator-installed compaction package.

## Sol / Terra / Luna routing

The measured local Pi model store lists Luna alongside Sol and Terra on `openai-codex`.
Vendor benchmarks alone do not authorize a dispatch change.
Default `docs/examples/crew-dispatch.json` and standing dispatch policy remain unchanged until identical real integration-style tasks produce measured Firstmate evidence favoring a route.
The baseline reports `luna_available` for host inventory only.

## Related tests

End-to-end coverage here runs through public script interfaces in `tests/fm-agent-loop-efficiency.test.sh`.

```sh
bin/fm-test-run.sh tests/fm-agent-loop-efficiency.test.sh
bin/fm-test-run.sh tests/fm-session-start.test.sh
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
bin/fm-test-run.sh tests/fm-supervision-instructions.test.sh
```
