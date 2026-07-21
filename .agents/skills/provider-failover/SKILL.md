---
name: provider-failover
description: >-
  Agent-only procedure for preservation-first provider failover of an active worker.
  Use on a provider-outage wake, before switching an already-running OpenAI/Codex-routed worker to another provider after quota exhaustion, rate limiting, a dead agent, or genuine wedge escalation, when handling a provider-exhaustion hold, and before acting on a provider-failover blocker.
user-invocable: false
metadata:
  internal: true
---

# provider-failover

Use this procedure on a `provider-outage` wake, before switching an already-running worker's provider, when a provider-exhaustion hold blocks a launch, and before acting on a provider-failover blocker.
`bin/fm-failover.sh` owns every mechanic (evidence gate, preservation receipt, probing, in-place relaunch, live verification, records); `bin/fm-provider-hold.sh` owns exhaustion holds; `docs/provider-failover.md` owns the mechanism narrative and backend-support evidence.

## When a provider-outage wake arrives

The watcher surfaces `stale: <window> (provider-outage: ...)` when an OpenAI/Codex-routed worker shows quota or rate-limit exhaustion in its pane or last status line, including a self-declared pause for a rate-limit reset.
Never wait out a vendor reset silently: act on the wake in the same turn.

1. Run `FM_HOME=<this-home> bin/fm-failover.sh <id> --check-only` for the deterministic eligibility verdict and evidence class.
2. If eligible, run `FM_HOME=<this-home> bin/fm-failover.sh <id> --reason "<one line of context>"`.
3. If ineligible, trust the refusal: a healthy worker, an intentionally parked review decision, and a merely long-running pipeline are never failed over; do not work around the gate.

## What the script guarantees

The switch preserves the task's identity, endpoint, isolated copy, branch, commits, dirty bytes, and any existing no-mistakes run; it never resets, stashes, cleans, aborts, restarts, or starts a new pipeline run.
The destination ladder is Claude Fable (`claude-fable-5[1m]`), then Pi `ollama/kimi-k2.7-code`, then Pi `ollama/glm-5.2`; OpenAI is never a destination.
The captain's standing Fable rule applies automatically: normal speed, effort capped at `high`, never fast mode.
Success prints the exact provider and model; relay that outcome to the captain in section 9 language (the worker was moved to <provider>/<model>, the work and pipeline continue unchanged).
Failure at any proof leaves all task work and records intact; relay the concrete blocker and recommend a next step instead of retrying blindly.

## Quota pressure and planned handoffs

Refresh machine-readable usage with `bin/fm-provider-usage.sh refresh` (non-interactive; never pops a keychain prompt) and inspect it with `bin/fm-provider-usage.sh status`.
Fresh telemetry at the avoid threshold excludes a provider from new launches automatically at spawn time; at the handoff threshold, run `FM_HOME=<this-home> bin/fm-failover.sh <id> --planned` for each active worker on that provider.
A planned handoff switches only at a safe checkpoint: the script defers (exit 6) while the worker owns a running pipeline step or busy pane - accept the deferral and retry at the next heartbeat, never interrupt the worker to force it.
Stale or unknown telemetry gates nothing and never releases a hold; feed externally-read usage (for example Ollama's authenticated usage page) in through `bin/fm-provider-usage.sh record` when available, and rely on error-based supervision otherwise.

## Exhaustion holds

Verified exhaustion records a durable hold that refuses every new launch on that provider, independent of any quota cache, until recovery is verified.
Inspect holds with `bin/fm-provider-hold.sh list`; restore eligibility only through `bin/fm-provider-hold.sh release <provider>`, which verifies recovery with a live probe first.
`--force` skips that verification and needs explicit captain authority.
A blocked spawn naming a held provider means: pick a non-held route for the new work, or verify recovery, not delete the hold.

## Nested pipeline agents

`--check-only` reports `nested_agents=` from live process inspection: a pipeline step can own a native agent on a different provider than the outer worker, and its route counts separately.
Never interrupt or restart a live pipeline-owned agent subprocess; the script refuses the switch while one runs - accept that refusal, let the step finish or drive the run through its own gate flow, then retry.
The pipeline's own future agent allocation is No Mistakes configuration, not something this path changes.

## Boundaries

Failover covers ordinary ship and scout direct reports on a supported backend; secondmates stay with `secondmate-provisioning`, and a gone endpoint or missing isolated copy stays with `stuck-crewmate-recovery`.
Generic dispatch preferences for future launches (`config/crew-harness`, `config/crew-dispatch.json`) are untouched by a failover; captain routing mixes live there, not in this recovery path.
If every allowed destination is unavailable, report the blocker to the captain with the receipt path; do not retry in a loop and do not fall back to OpenAI.
