# Agent-loop efficiency verification

Audience: maintainer verification.

This record supports current Firstmate-controlled agent-loop overhead baselines, cache-stable digest construction, deferred-discovery boundaries, bounded fleet inspection, Code Mode non-adoption, transport and compaction ownership, and Sol/Terra/Luna routing non-change.
Task chronology, AIDE candidate scoring, and delivery transcripts stay in private task or PR evidence.

## Baseline command

```sh
bin/fm-agent-loop-baseline.sh --json --with-session-fixture
```

Measured on 2026-07-30 against this branch tip with Pi-installed operator surfaces available on the host:

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
| `luna_available` | `true` via `openai-codex/gpt-5.6-luna` |
| `code_mode_embedded_runtime` | `absent` |

Re-run the command after material always-loaded surface changes and replace the table with fresh output.
Approximate tokens are a 4-byte heuristic for relative comparison only.

## Cache-stable prompt construction

Owner scripts:

- `bin/fm-prompt-stable-lib.sh` - deterministic `LC_ALL=C` id listing
- `bin/fm-session-start.sh` - every sorted stable metadata record before any volatile endpoint/status line; sorted orphan status ids
- `bin/fm-supervision-instructions.sh` - pure function of harness and flag inputs

Regression entry point:

```sh
bin/fm-test-run.sh tests/fm-agent-loop-efficiency.test.sh
```

The suite compares public rendered outputs under fixed inputs, proves single-variable captain-file sensitivity, proves sorted multi-entry task order, and keeps the complete stable prefix byte-identical across a single volatile status change.

## Deferred discovery boundary

Pi documents dynamic tool registration and additive `setActiveTools` deferred loading in its extensions guide.
Firstmate's tracked Pi tools keep core fleet arming immediately available (`fm_watch_arm_pi`).
Firstmate does not install an opaque tool proxy or Code Mode runtime.
Conditional agent skills remain progressive-disclosure descriptions with on-demand bodies.
External packages such as Linear tools stay outside Firstmate's launch contract.

## Bounded fleet inspection

Whole-fleet reviews use existing aggregates rather than serial per-task loops:

- `bin/fm-fleet-snapshot.sh` / `bin/fm-fleet-view.sh`
- `bin/fm-bearings-snapshot.sh`
- session-start compact backlog plus sorted meta dump

`AGENTS.md` heartbeat handling names those aggregate commands explicitly.
Safety-critical status tails and errors remain untruncated beyond existing bound helpers.

## Code Mode evaluation

No embedded Code Mode runtime was added.
Existing shell aggregates and parallel tool calls already batch the highest-volume fleet inspection paths.
The baseline schema reports `code_mode_embedded_runtime=absent` so a later regression cannot silently introduce a second orchestration layer without updating this record.

## Transport and compaction

| Concern | Firstmate control | Current evidence |
| --- | --- | --- |
| `PI_CACHE_RETENTION` on pi/pi-signed spawn | Always forwarded; `long` only when unset, while explicit empty/nonempty values are preserved | `tests/fm-agent-loop-efficiency.test.sh` spawn capture |
| OpenAI `previous_response_id` / WebSocket stream | Operator Pi package only | `pi-openai-server-compaction` when installed; `openai/*` yes, `openai-codex/*` retains built-in transport per package README |
| Server-side compaction threshold | Operator config | `compactThreshold=260000` when `~/.pi/agent/openai-server-compaction.json` is present |
| Competing Firstmate compactors | None | Do not add a second path |
| GPU / KV / speculative decode | None | Outside Firstmate |

Do not create a custom provider solely to imitate OpenAI internals.

## Sol / Terra / Luna routing

Luna is discoverable on the verified Pi `openai-codex` path alongside Sol and Terra.
Vendor benchmarks alone do not authorize a dispatch change.
Default `docs/examples/crew-dispatch.json` and standing dispatch policy remain unchanged until identical real integration-style tasks produce measured Firstmate evidence favoring a route.
The baseline reports `luna_available` for host inventory only.

## Integration with integration-evidence policy

Integration-evidence attestation for ship tasks is owned by the concurrent `integration-evidence` skill and `bin/fm-integration-evidence.sh` work when present.
This efficiency change does not duplicate that contract.
End-to-end coverage here runs through public script interfaces in `tests/fm-agent-loop-efficiency.test.sh`.

## Related tests

```sh
bin/fm-test-run.sh tests/fm-agent-loop-efficiency.test.sh
bin/fm-test-run.sh tests/fm-session-start.test.sh
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
bin/fm-test-run.sh tests/fm-supervision-instructions.test.sh
```
