# Native remote-agent verification

This page records current maintainer evidence for the shared Firstmate remote-agent boundary and the iDA provider.
[`../configuration.md`](../configuration.md#remote-research-agents) owns operator setup and limits, [`../architecture.md`](../architecture.md#task-executors) owns architecture, script headers and `--help` own command mechanics, and the [`cloud-research-worker` skill](../../.agents/skills/cloud-research-worker/SKILL.md) owns conditional operation.
Historical and provider-specific AIME proof remains in [`aime-cloud-worker.md`](aime-cloud-worker.md).

## Installed official surface

Verified on 2026-08-19 with installed `bytedcli` 0.128.0.
The read-only commands were:

```sh
bytedcli --json --version
bytedcli ida --help
bytedcli ida session list --help
bytedcli ida session get --help
bytedcli ida chat completion close --help
bytedcli mcp --help
```

They establish the official SG selector, session list/get reads, close operation, and stdin MCP server with domain restriction and individual tools.
No live research session or cancellation was created for this evidence.
The provider's SG read endpoint was unavailable in the implementation environment, so behavioral proof below uses fake provider executables through the public Firstmate script interfaces rather than claiming live-provider success.

## Executable behavior

Run the focused suites with:

```sh
tests/fm-remote-agent.test.sh
tests/fm-aime-cloud-worker.test.sh
```

`fm-remote-agent.test.sh` supplies a fake `bytedcli` executable and exercises public dispatch, state, adoption, cancellation, retirement, and process-event entry points.
It verifies:

- explicit `remote-agent/aime` and `remote-agent/ida` dispatch metadata, with no heuristic provider selection;
- permanent reading of an existing `cloud-worker/aime` plus `fm-aime-task-state.v1` record without migration;
- iDA running, successful, failed, cancelled, unavailable, ambiguous, exact-zero, and error outcomes;
- private prompt carriage through MCP stdin, with no prompt in argv, state, normalized artifacts, or report, plus redaction of credential, OECID, long-id, and email shapes before the final answer crosses the adapter boundary;
- the timeout case where a provider accepted submission but the client timed out, followed by exact session-marker reconciliation and adoption without a second create;
- same-content idempotent re-storage of a normalized artifact at an unchanged revision after an interrupted handler;
- captain-authorized abandonment of a wedged ambiguous task after an authoritative complete non-truncated zero-match session list, its refusal without the authorization flag and on duplicate markers, and decision-gated retirement of the abandoned record;
- normalized terminal result capture and a state-bound mode-`0600` report;
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
