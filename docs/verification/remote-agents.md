# Native remote-agent verification

This page records current maintainer evidence for the shared Firstmate remote-agent boundary and the iDA provider.
[`../configuration.md`](../configuration.md#remote-research-agents) owns operator setup and limits, [`../architecture.md`](../architecture.md#task-executors) owns architecture, script headers and `--help` own command mechanics, and the [`cloud-research-worker` skill](../../.agents/skills/cloud-research-worker/SKILL.md) owns conditional operation.
Historical and provider-specific AIME proof remains in [`aime-cloud-worker.md`](aime-cloud-worker.md).

## Installed official surface

Re-verified on 2026-08-24 with installed `bytedcli` 0.130.0.
That version identifies this evidence only; iDA setup and execution do not pin or compare it.
The read-only surfaces were:

```sh
bytedcli --json --version
bytedcli --json --as user ida --region sg agent get
bytedcli --json --as user ida --region sg session raw list --agent-id 14638 --page-size 1
bytedcli mcp --help
bytedcli --as user mcp --allow-domains ida
bytedcli --as user mcp --allow-domains ida --all-tools
```

The MCP commands were exercised with bounded stdin JSON-RPC for `tools/list`, `list_commands`, and a read-only `run_command`; no private prompt was used in those capability checks.
They establish the official SG selector, structured user-identity reads, domain-restricted command runner, and advertised Deep Research create, raw-list, session-get, and close commands with their required options.

## Direct-dispatch failure separation

The public `bin/fm-task-dispatch.sh remote-agent/ida` path was reproduced against a mode-`0600` copy of the current iDA config and an ordinary private task brief/instruction:

- With the copied `enabled=false`, dispatch refused visibly before state publication. This is the intentional operator gate and masks every later failure.
- Changing only that copy to `enabled=true`, while retaining its then-matching `bytedcli_version=0.130.0`, published `submitted:` but left the durable phase at `submission-not-started` with an unavailable readback. This disproves version mismatch as the sole cause of the current-config launch failure.
- The same official SG session-list read failed with the ambient upper- and lower-case proxy environment, then succeeded with those variables unset while retaining `--as user`, `--region sg`, authentication state, and every non-proxy environment value. This isolates proxy routing from executable, identity, authentication, region, and provider availability.
- The installed all-tools MCP schema for `ida_deep_research_create` does not declare region. Supplying `args:["--region","sg"]` produced `CLI_PARSE_ERROR` because those arguments follow the leaf command; supplying an undeclared `region` value was ignored and selected the default non-SG identity. This disproves generic named-tool availability as sufficient SG capability.
- The domain-restricted MCP `list_commands` result advertised the required create command, and `run_command` successfully executed the read-only `ida --region sg session list --page-size 1` form under the same identity. This is the counterfactual used by the private submission transport.
- A bounded harmless create then exposed two later lifecycle mismatches: semantic `session list` returned no sessions while official `session raw list` returned the valid SG session, and SG automatically renamed the session despite `--name`. The completed no-answer command returned structured `IDA_EMPTY_RESULT` with authoritative session/task IDs. These facts disprove name-only reconciliation, semantic-list completeness, and a success-exit-only result contract.
- A separate legacy config with `bytedcli_version=0.0.0` failed before state publication under the old adapter even though the installed executable and structured version response were healthy. This isolates the obsolete exact-version refusal as an independent blocker rather than conflating it with the proxy and region-placement failures.

The implementation therefore keeps the enabled, executable, structured-output, identity, region, command-capability, exact-marker, and provider-state checks; sanitizes only iDA child proxy variables; puts SG region on the parent iDA command inside MCP stdin; reconciles raw sessions by an exact private first-message marker when SG renames them; preserves structured error identity; and treats legacy version fields as informational.
A final public dispatch through `bin/fm-task-dispatch.sh remote-agent/ida`, using the stale `0.0.0` legacy config field and the caller's ambient proxy variables, reached normalized `terminal-success` under SG with bound session/task identity and exact `zero` result availability.
The validation used only harmless bounded prompts; no cancellation was issued.

## Executable behavior

Run the focused suites with:

```sh
bin/fm-test-run.sh tests/fm-remote-agent.test.sh
bin/fm-test-run.sh tests/fm-aime-cloud-worker.test.sh
```

`fm-remote-agent.test.sh` supplies a fake `bytedcli` executable and exercises public dispatch, state, adoption, cancellation, retirement, and process-event entry points.
It verifies:

- explicit `remote-agent/aime` and `remote-agent/ida` dispatch metadata, with no heuristic provider selection;
- permanent reading of an existing `cloud-worker/aime` plus `fm-aime-task-state.v1` record without migration;
- public iDA probe and direct dispatch with the version field absent, with a stale legacy config version, and without any bytedcli version query or comparison;
- child-local removal of all conventional proxy variables while preserving an unrelated environment sentinel across SG probe, reconciliation, and create;
- required-command discovery through domain-restricted MCP plus the exact parent-position `ida --region sg deep-research create` command through `run_command`, with refusal evidence if that placement drifts;
- raw-session reconciliation after provider-driven renaming, exact private first-message marker verification, and structured empty-result identity normalization;
- iDA running, successful, failed, cancelled, unavailable, ambiguous, exact-zero, and error outcomes;
- private prompt carriage through MCP stdin, with no prompt in argv, state, normalized artifacts, or report, plus redaction of credential, OECID, long-id, and email shapes before the final answer crosses the adapter boundary;
- the timeout case where a provider accepted submission but the client timed out, followed by exact session-marker reconciliation and adoption without a second create;
- same-content idempotent re-storage of a normalized artifact at an unchanged revision after an interrupted handler;
- idempotent process-event replay after acknowledgement, without a second state transition or status application;
- captain-authorized abandonment of a wedged ambiguous task after an authoritative complete non-truncated zero-match session list, its refusal without the authorization flag and on duplicate markers, and decision-gated retirement of the abandoned record;
- normalized terminal result capture and a state-bound mode-`0600` report;
- legacy durable iDA version metadata remaining informational through state read, adoption, reconciliation, process-event handling, cancellation, report generation, and decision-gated retirement;
- explicit provider-cancellation authority, authoritative cancellation readback, decision-gated retirement, and durable report preservation; and
- unchanged fail-closed local/unsupported executor behavior.

`fm-aime-cloud-worker.test.sh` remains the regression owner for AIME create/send checkpoints, Feishu document results, event cursor and replay behavior, legacy recovery, interruption versus cancellation, terminal-unavailable sealing, decision gating, and local-agent delegation.
The shared runner's changed-file coverage maps both suites to the remote-agent owner scripts.

## State and recovery boundary

New native tasks publish `executor=remote-agent` and `provider=aime|ida`.
`fm-task-state.sh`, session start, and fleet snapshot use provider-aware reads and report no local endpoint.
The process-event source remains the existing durable notification and restart boundary; iDA adds no timer or control plane.
An idle or processing provider session maps to healthy working state, while unavailable observation remains distinct from terminal failure.

iDA submission records `firstmate:<task-id>:<instruction-digest-prefix>` before the only permitted create.
The adapter lists sessions and exact-matches that marker before creation and after uncertain completion.
Zero unique matches permit creation only from `submission-not-started`; one match is adopted; duplicates, truncation, or unresolved readback become unavailable or ambiguous and never authorize another create.
A wedged `ambiguous` or `submission-unknown` record can fail-terminal only through the captain-authorized abandon command after a fresh authoritative complete non-truncated zero-match list; abandonment performs no provider write, never retries or recreates, and leaves re-execution to a separate explicit dispatch.

## Privacy and authority boundary

Only a private normalized observation reaches process-event capture.
Private prompts, credentials, tokens, OECIDs, PII-bearing request payloads, raw MCP JSON-RPC, raw SSE/event bodies, and unbounded provider messages are not durable task artifacts.
Reports preserve only normalized task/session/agent/model identity, result availability, outcome, error class, and the final answer when available.
Provider output grants no implementation, publication, merge, destructive, compliance/legal, or security authority.

AIME cancellation remains explicitly unsupported.
iDA cancellation requires the public script's authorization flag and current destructive-action authority; a successful close response remains nonterminal until provider session readback confirms cancellation.
iDA abandonment likewise requires its own `--authorize-abandon` flag plus an authoritative complete non-truncated zero-match session-list proof and performs no provider write.
Both providers require the ordinary decision-hold gate and safe report linkage before retirement.
