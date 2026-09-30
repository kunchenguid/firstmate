# Native remote-agent verification

This page records current maintainer evidence for the shared Firstmate remote-agent boundary and the iDA provider.
[`../configuration.md`](../configuration.md#remote-research-agents) owns operator setup and limits, [`../architecture.md`](../architecture.md#task-executors) owns architecture, script headers and `--help` own command mechanics, and the [`cloud-research-worker` skill](../../.agents/skills/cloud-research-worker/SKILL.md) owns conditional operation.
Historical and provider-specific AIME proof remains in [`aime-cloud-worker.md`](aime-cloud-worker.md).

## Installed official surface

The base lifecycle was re-verified on 2026-08-24 with installed `bytedcli` 0.130.0.
Model selection was re-verified on 2026-08-25 with installed `bytedcli` 0.131.0.
Task-bound terminal and non-empty result readback were re-verified on 2026-08-26 with installed `bytedcli` 0.131.0.
Those versions identify this evidence only; iDA setup and execution do not pin or compare them.
The read-only base surfaces were:

```sh
bytedcli --json --version
bytedcli --json --as user ida --region sg agent get
bytedcli --json --as user ida --region sg session raw list --agent-id 14638 --page-size 1
bytedcli mcp --help
bytedcli --as user mcp --allow-domains ida
bytedcli --as user mcp --allow-domains ida --all-tools
```

The model-selection commands were:

```sh
bytedcli ida --region sg deep-research create --help
env -u http_proxy -u https_proxy -u all_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY BYTEDCLI_NO_AUTO_UPGRADE=1 bytedcli --json --as user ida --region sg model list
```

The MCP commands were exercised with bounded stdin JSON-RPC for `tools/list`, `list_commands`, and a read-only `run_command`; no private prompt was used in those capability checks.
The installed help declares optional `--model <name>` as a model name returned by `ida model list`.
The installed `IdaSendOptions`, create handler, service, and client pass that string through `model` into `llmModel`, while an omitted CLI option remains absent at the command boundary.
The SG model-list response returned structured model names including `auto`, `usecase-frontend-doubao-seed-2.1-pro`, and `usecase-frontend-deepseek-v4-pro`; the implementation validates the current response rather than pinning this observed list.
Together these checks establish the official SG selector, structured user-identity reads, domain-restricted command runner, and advertised Deep Research create, model-selection, raw-list, session-get, and close commands with their required options.

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
A public data-free dispatch through `bin/fm-task-dispatch.sh remote-agent/ida` reached normalized `terminal-success` under SG with bound session/task identity, `result_availability=available`, and the exact first-line readiness result `FM_IDA_READINESS_V1 {"status":"ok","instruction_received":true,"business_data_accessed":false,"external_write_performed":false,"echo":"sg-ida-e2e-20260825-v1"}`.
The same completed provider session exposed that text in the last completed task step while `deep_research_content.finalAnswer` and visible type-8 `.text` were absent.
The validation used only harmless bounded prompts; no cancellation was issued.

## Executable behavior

Run the focused suites with:

```sh
bin/fm-test-run.sh tests/fm-remote-agent.test.sh
bin/fm-test-run.sh tests/fm-aime-cloud-worker.test.sh
```

Re-verified on 2026-08-26 against base `3a3e00dd447b2c8301a952c3a7d31390d3eeeb61` with GNU Bash 5.2.15, installed `bytedcli` 0.131.0, and the repository-pinned ShellCheck 0.11.0.
The focused iDA command above completed with the exact terminal assertion `# fm-remote-agent.test.sh: all assertions passed` and summary fields `total=1`, `failed=0`, and `skipped_gate=0`.

The data-free official SG check used the public dispatch and candidate process-event adapter, then verified its normalized state, report, acknowledgement, and one real post-terminal captured generation.
Its exact safe summaries were:

```text
contract=pass status_count=1 report_count=1 result_count=1 handled_count=1 answer_first_line_exact=true
duplicate_generation=pass revision_unchanged=true report_unchanged=true terminal_notifications=1 result_count=2 handled_count=2
```

`fm-remote-agent.test.sh` supplies a fake `bytedcli` executable and exercises public dispatch, state, adoption, cancellation, retirement, and process-event entry points.
It verifies:

- explicit `remote-agent/aime` and `remote-agent/ida` dispatch metadata, with no heuristic provider selection;
- explicit per-dispatch iDA model validation against the fake official SG list, exactly one create carrying the selected model, model-free omission, and private-state round-trip;
- zero provider calls for empty, malformed, or duplicate model input, zero create calls for an unsupported model, and explicit refusal of the iDA-only option on AIME;
- compatibility for legacy iDA config records with a model field and durable task records without one;
- permanent reading of an existing `cloud-worker/aime` plus `fm-aime-task-state.v1` record without migration;
- public iDA probe and direct dispatch with the version field absent, with a stale legacy config version, and without any bytedcli version query or comparison;
- foreground `PATH` resolution plus watcher-successor fallback to the user-global npm launcher, preserving the exact existing remote task and returning its result without replacement research, with genuinely missing and installed-but-unusable launchers kept distinct from CLI-emitted exit 126 or 127;
- child-local removal of all conventional proxy variables while preserving an unrelated environment sentinel across SG probe, reconciliation, and create;
- required-command discovery through domain-restricted MCP plus the exact parent-position `ida --region sg deep-research create` command through `run_command`, with refusal evidence if that placement drifts;
- raw-session reconciliation after provider-driven renaming, exact private first-message marker verification, and structured empty-result identity normalization;
- recorded-task terminal authority amid conflicting session tasks and aggregate error, including same-task running then success with its text-bearing `finalAnswer` recovered as redacted task-bound text and no unrelated task answer accepted;
- completed visible type-8 `deep_research_content.finalAnswer` readback with one file part and one inline-data part, normalized as an available artifact through the executable observe and process-event boundaries without creation, continuation, cancellation, or raw-content leakage;
- completed task-bound step-only text readback when visible type-8 `.text` and `finalAnswer` are absent, preserving the exact readiness marker through public dispatch and report capture;
- failed, cancelled, and closed sessions that still carry a visible type-8 text answer: the legacy redacted text payload stays a `text` result while availability remains `error` or `unavailable`, and readback reaches its terminal outcome without wedging;
- explicit safe failures for malformed and unsupported structured final-answer forms, while exact-empty supported forms remain `zero`;
- iDA running, successful, failed, cancelled, unavailable, ambiguous, exact-zero, and error outcomes;
- private prompt carriage through MCP stdin, with no prompt in argv, state, normalized artifacts, or report, plus redaction of credential, OECID, long-id, and email shapes before the final answer crosses the adapter boundary;
- the timeout case where a provider accepted submission but the client timed out, followed by exact session-marker reconciliation and adoption without a second create;
- same-content idempotent re-storage of a normalized artifact at an unchanged revision after an interrupted handler;
- idempotent process-event replay after acknowledgement, without a second state transition or status application;
- post-terminal nonterminal and terminal generations acknowledged without state regression, report replacement, source re-arm, or a duplicate terminal notification;
- source-local coalescing of identical nonterminal transient iDA read failures before a second captured generation, including bounded exponential retry timing, restart recovery from the state-linked observation, reset on successful or changed state, authorization, materially different error and terminal bypass, and idempotent handling of an earlier queued generation;
- local iDA executable-resolution, empty-output, malformed-JSON, invalid-structure, nonzero-exit, and session-mismatch read failures classified without persisting raw stdout or stderr, surfaced as one idempotent actionable blocker, and recovered by adoption of the exact recorded task without another create or cancellation;
- preservation of that local blocker across a genuine provider outage and a response missing the bound task, followed by resolution only after healthy task-bound readback and exactly one completion;
- captain-authorized abandonment of a wedged ambiguous task after an authoritative complete non-truncated zero-match session list, its refusal without the authorization flag and on duplicate markers, and decision-gated retirement of the abandoned record;
- normalized terminal result capture and a state-bound mode-`0600` report;
- legacy durable iDA version metadata remaining informational through state read, adoption, reconciliation, process-event handling, cancellation, report generation, and decision-gated retirement;
- explicit provider-cancellation authority, authoritative cancellation readback, decision-gated retirement, and durable report preservation; and
- unchanged fail-closed local/unsupported executor behavior.

`fm-aime-cloud-worker.test.sh` remains the regression owner for AIME create/send checkpoints, Feishu document results, event cursor and replay behavior, legacy recovery, interruption versus cancellation, terminal-unavailable sealing, decision gating, and local-agent delegation.
The shared runner's changed-file coverage maps both suites to the remote-agent owner scripts.

## State and recovery boundary

New native tasks publish `executor=remote-agent` and `provider=aime|ida`.
Ordinary `fm-task-state.sh` calls and fleet snapshots use provider-aware reads and report no local endpoint.
Session start instead reads the validated durable provider record, labels deferred freshness when remote readback could change the answer, and never reaches the provider from its blocking path.
The process-event source remains the existing durable notification and restart boundary; iDA adds no second notification control plane, and its retry delay stays inside the registered source waiter.
An idle or processing provider session maps to healthy working state, while unavailable observation remains distinct from terminal failure.
Repeated identical nonterminal transient read failures remain inside the adapter's current waiter after the first applied generation and therefore do not create a second notification identity.
The adapter keeps no per-attempt log or unbounded retry state; the state-linked normalized observation is the restart anchor, and any semantic change resumes ordinary durable capture and application.
Local CLI execution and invalid-response failures instead retire the current waiter, publish one `ida-readback-local` blocker without a remote terminal claim, and keep the exact session and task identity available for adoption after local repair.
The durable `local_readback_blocked` recovery marker survives intervening provider-transient or bound-task-missing observations and clears only on healthy task-bound readback.

iDA submission records `firstmate:<task-id>:<instruction-digest-prefix>` before the only permitted create.
The adapter lists sessions and exact-matches that marker before creation and after uncertain completion.
Zero unique matches permit creation only from `submission-not-started`; one match is adopted; duplicates, truncation, or unresolved readback become unavailable or ambiguous and never authorize another create.
A wedged `ambiguous` or `submission-unknown` record can fail-terminal only through the captain-authorized abandon command after a fresh authoritative complete non-truncated zero-match list; abandonment performs no provider write, never retries or recreates, and leaves re-execution to a separate explicit dispatch.

## Privacy and authority boundary

Only a private normalized observation reaches process-event capture.
Private prompts, credentials, tokens, OECIDs, PII-bearing request payloads, raw MCP JSON-RPC, raw SSE/event bodies, and unbounded provider messages are not durable task artifacts.
Reports preserve only normalized task/session/agent/model identity, result availability and kind, outcome, error class, final text when available, or a safe statement that a structured artifact is available through the recorded session.
The mode-`0600` normalized artifact reference carries only its schema, session-readback kind, artifact count, part count, and supported part kinds; artifact identifiers, names, file URIs, inline sheet data, bytes, and the provider message are discarded before the process-event boundary.
The separate read-only `fm-remote-agent-ida.sh artifacts <task-id>` discovery boundary retains only the recorded task/session binding plus artifact/file identities, URIs, sizes, types, counts, and availability/truncation needed to choose a later fetch; synthetic behavioral fixtures verify that tables, rows, text, scripts, descriptions, and raw errors do not reach stdout.
Provider output grants no implementation, publication, merge, destructive, compliance/legal, or security authority.

AIME cancellation remains explicitly unsupported.
iDA cancellation requires the public script's authorization flag and current destructive-action authority; a successful close response remains nonterminal until provider session readback confirms cancellation.
iDA abandonment likewise requires its own `--authorize-abandon` flag plus an authoritative complete non-truncated zero-match session-list proof and performs no provider write.
Both providers require the ordinary captain-hold gate and safe report linkage before retirement.
The paired backlog transition is owned by `bin/fm-backlog-transition-lib.sh`.
On 2026-09-24, with tasks-axi 0.2.4, `bin/fm-test-run.sh tests/fm-remote-agent.test.sh` passed, including `ok - remote retirement pairs closed/held backlog state and retries interrupted close without losing evidence`.
That executable regression uses the real markdown adapter to check normal closure, a retained captain hold, and a close whose acknowledgement is lost before retry; the provider is a local fixture and performs no remote operation.
