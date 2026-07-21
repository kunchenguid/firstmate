# Provider failover for active workers

Preservation-first provider switching for an already-running OpenAI/Codex-routed direct report.
`bin/fm-failover.sh` owns the mechanics and flags, `bin/fm-failover-lib.sh` owns the classification predicates, `bin/fm-provider-hold.sh` owns exhaustion holds, and the `provider-failover` skill owns the decision procedure; this document records the mechanism narrative and the empirical evidence behind each supported axis.

## Why it exists

A worker whose provider exhausts its quota mid-task would otherwise sit dead or retrying until a vendor reset, with an implementation, dirty worktree bytes, and an in-flight no-mistakes run held hostage.
The failover path moves that one worker to another provider while preserving the task identity, backend endpoint, isolated copy, branch, commits, dirty bytes, and the existing pipeline run - a recovery of an active worker, never a change to how future work is routed.
Generic dispatch preferences (`config/crew-harness`, `config/crew-dispatch.json`, `config/secondmate-harness`) are never read or written by this path.

## Detection and surfacing

`bin/fm-watch.sh` scans every non-secondmate OpenAI/Codex-routed task's pane tail and last status line for quota and rate-limit signatures (`fm_failover_outage_evidence`; `FM_FAILOVER_OUTAGE_RE` overrides the set).
Evidence surfaces an immediate actionable `stale: <window> (provider-outage: ...)` wake that outranks the busy, provably-working, and declared-pause absorb classes, because a verified exhaustion must never be waited out silently - including a worker that declared `paused: rate limit resets at ...` and exited.
The wake is deduplicated once per digit-normalized evidence text through `state/.provider-outage-<key>`, which clears when the evidence clears or the route stops being OpenAI.
A stopped agent process and genuine wedge escalation are already surfaced by the existing stale/wedge machinery; the failover eligibility gate accepts those signals as evidence classes of their own.

## Eligibility

`fm-failover.sh` re-verifies evidence itself and refuses everything else:

- `outage` - quota/rate-limit signatures in the live pane capture or last status line.
- `dead` - `fm_backend_agent_alive` confidently reports no agent process.
- `wedge` - the watcher's `.wedge-escalations-<key>` count reached `FM_WEDGE_DEMAND_INSPECT_COUNT`.

A healthy worker (no evidence), an intentionally parked review decision (`fm-crew-state.sh` reports `parked`, unless the evidence is `outage` or `dead` - a quota-dead worker cannot answer its own gate), and a merely long-running pipeline (`working` with only wedge pressure) are refused with exit 3.
Secondmates are refused outright (`secondmate-provisioning` owns them), and a gone endpoint or missing isolated copy is refused toward `stuck-crewmate-recovery`.

## Preservation receipt and proofs

Before any switch work, the script atomically writes `data/<id>/failover/receipt-<utc>.md`: task identity, project, exact isolated-copy path, branch, HEAD, `git status --porcelain`, recent commits, a sha256 digest of the working-copy diff, the active no-mistakes run id/head/status/step, the current harness/model/effort, the backend endpoint, and the resume context.
It then proves the isolated copy is a real worktree root distinct from the primary checkout (the same isolation shape `fm-spawn.sh` enforces), that no other recorded task with a live or ambiguous agent claims the same copy, and - after the old agent exits - that the endpoint shell still sits in the preserved copy.
After the destination is live, the HEAD and dirty digest are compared against the receipt again; a mismatch is a loud blocker and the route metadata stays unchanged.

## Destination ladder and probing

Default ladder: Anthropic Claude Code `claude-fable-5[1m]`, then Pi `ollama/kimi-k2.7-code`, then Pi `ollama/glm-5.2`.
OpenAI is never a destination: `fm_failover_candidates` refuses any OpenAI-backed entry, including through the `FM_FAILOVER_CANDIDATES` override.
Each candidate is probed with a bounded, task-free model call in a scratch directory (`claude --model <m> -p ...`, `pi --print --model <m> ...`).
Probe outcomes are classified deterministically (`fm_failover_probe_classify`): success selects the candidate; auth, quota, rate-limit, unknown-model, connection, and timeout failures mean genuinely unavailable and advance the ladder; any other failure is inconclusive and stops the whole failover rather than advancing past a provider that may be fine.
A candidate whose provider has an active exhaustion hold is skipped without probing.
If every allowed destination is unavailable, the script exits 4 with the task, its records, and the current worker fully intact.

## Relaunch and live verification

The old agent is exited in place (interrupt, then the harness's verified exit command, then a bounded wait for a confidently dead agent); the pane's treehouse subshell keeps the worktree as its cwd, which is re-proven before launch.
A resume prompt at `data/<id>/failover/resume-<utc>.md` binds the exact receipt and instructs the new worker to verify the preserved identity, then inspect and continue the existing no-mistakes run through its own gate flow - never abort, restart, or replace it, and never reset, stash, clean, rebase, or re-branch.
The destination harness's turn-end hook is installed with the identical mechanics and git-exclusion semantics as a normal spawn (`bin/fm-launch-lib.sh:fm_launch_install_turnend_hook`), and the launch command comes from the same shared templates, so the project-write boundary is exactly the normal spawn's.
Live verification reads the endpoint's actual process tree and requires a process running the destination harness with the destination model on its command line - configuration and metadata are never trusted alone.
Only then are `harness=`, `model=`, and `effort=` atomically rewritten in `state/<id>.meta`, and one record is appended to the append-only `data/<id>/failover/history` (epoch, from/to route, evidence class, receipt path, reason, verification evidence).
The stdout result names the exact provider and model.
Re-running after success is a no-op (the route is no longer OpenAI), and a concurrent second failover of the same task is refused by a task-scoped lock.

## Captain's standing Fable rule

Every Claude Fable launch - ordinary spawn or failover relaunch - runs at normal speed with effort capped at `high`; `xhigh` and `max` are clamped by `fm_launch_fable_effort_cap` at the shared render choke point, callers record the capped value so metadata matches the live launch, and no speed/fast-mode flag is ever emitted (the claude template carries none).

## Exhaustion holds

Verified provider exhaustion (`outage` evidence) immediately records `state/.provider-hold-<provider>` through `bin/fm-provider-hold.sh set`, before any switch work.
While a hold exists, `fm-spawn.sh` refuses every new launch whose resolved route (`fm_failover_provider_of_route`) lands on that provider - fail closed and deliberately independent of quota-cache or dispatch-selection data, so a stale quota read can never re-open a held provider - and `fm-failover.sh` skips held destination candidates.
Eligibility is restored only by `bin/fm-provider-hold.sh release <provider>`, which verifies recovery with a live bounded probe and keeps the hold when the probe fails; `--force` skips verification and requires explicit captain authority.

## Usage telemetry and pressure

`bin/fm-provider-usage.sh` records provider subscription-usage snapshots (`state/.provider-usage-<provider>`) with an epoch, source identity, session/weekly percentages, and optional model-window percentages.
`refresh` reads Claude and Codex machine-readably through `quota-axi --json --full` with NO interactive keychain prompt; parsing was verified 2026-07-22 against the installed quota-axi 0.1.7 (schemaVersion 2: `providers[].windows[]` with `kind` session/weekly/model, `percentUsed`, and `state.stale`; command `quota-axi --provider claude --json` returned that shape live).
A failed, stale, or missing read records nothing, so that provider's telemetry ages into `unknown` instead of masquerading as fresh.
Providers with no documented quota API (Ollama today) are optional and explicit: an external reading - for example the captain's authenticated usage page in the persistent provider browser profile - is fed in through `record`; absent or expired external telemetry never blocks work, because error-based supervision and holds remain the backstop.

Pressure (`fm_failover_provider_pressure`) is consulted from fresh snapshots only: session use at `FM_PROVIDER_SESSION_AVOID_PCT` (70) or any weekly/matching model window at `FM_PROVIDER_WEEK_AVOID_PCT` (90) excludes the provider from NEW launches in `fm-spawn.sh`; session use at `FM_PROVIDER_SESSION_HANDOFF_PCT` (85) additionally calls for a planned safe-checkpoint handoff of active workers on that provider.
Snapshots older than `FM_PROVIDER_USAGE_MAX_AGE_SECS` (1800s) read `unknown` and gate nothing.
Telemetry never releases a hold: a verified provider hold is authoritative over any quota result, fresh or stale - the observed failure mode is a generic quota read reporting low use while the provider's real per-model limit is exhausted - and only `bin/fm-provider-hold.sh release`'s live probe restores eligibility.

## Planned safe-checkpoint handoff

`fm-failover.sh <id> --planned` performs the same preservation-first switch when fresh telemetry for the worker's provider reaches the handoff threshold, with two extra guards: the worker must be at a safe checkpoint - no actively-working pipeline step and no busy pane - or the script defers with exit 6 and leaves everything intact for a later retry, and destination candidates under `avoid`/`handoff` pressure are skipped so rebalancing never piles onto a nearly-exhausted provider.
Emergency recovery (outage, dead agent, wedge) ignores destination pressure and uses any non-held available candidate: a preserved task beats a perfectly balanced ladder.

## Nested pipeline agents

A No Mistakes pipeline step can own a live native agent subprocess on a different provider than the outer worker - observed live 2026-07-22: three outer Fable workers whose active review steps were still native `codex exec resume` processes.
`fm_failover_nested_agents` inspects the endpoint's process tree and reports every such agent's harness and model separately from the outer route; `fm-failover.sh` includes that summary in `--check-only` output and in the non-OpenAI no-op message, and refuses to exit an outer agent while any nested agent is live, so a pipeline-owned subprocess is never interrupted or restarted by a failover.
Changing only the outer TUI is not a complete provider failover: the pipeline's own agent allocation is No Mistakes configuration (the captain's global setting moved future pipeline agents from codex to claude, doctor-verified, on 2026-07-22), and already-live pipeline subprocesses keep their original provider until their step finishes on its own.

## Dispatch-selection integration

`bin/fm-dispatch-select.sh` applies the same hold and pressure view as an eligibility pre-filter before any selection strategy: a held or pressure-excluded candidate is logged and dropped, selection proceeds deterministically among the remaining explicit candidates, and only when every candidate is excluded does it return a structured `all-candidates-excluded` object (exit 3) so firstmate re-selects from another rule or the default.
An excluded candidate therefore never becomes a launch that `fm-spawn.sh` refuses while an explicit eligible candidate remains, and no unlisted model is ever chosen silently.

## Backend support

Failover requires two proofs per backend: a verified agent-process liveness classifier (for the no-second-agent and old-agent-exit gates) and a verified live-process command/model read (for post-relaunch verification).
`fm_failover_backend_supported` fails closed for any backend missing either proof.

| Backend | Verdict | Basis |
|---|---|---|
| tmux | supported | Agent liveness: `fm_backend_tmux_agent_alive`, verified in `docs/tmux-backend.md`. Live process read: verified 2026-07-22 on tmux 3.6a - `tmux display-message -p -t <target> '#{pane_pid}'` returned the pane's root pid on an isolated `-L` socket, and a fixed-point closure over one `ps -ax -o pid=,ppid=,args=` snapshot listed the root and every descendant with full args, including a literal bracketed `--model claude-fable-5[1m]` argument shown verbatim (commands: `tmux -L <sock> new-session`, `send-keys` launching parent+child processes, then the `ps`+awk closure in `fm_failover_pane_process_args`). Deterministic regression coverage: `tests/fm-failover.test.sh`. |
| herdr | refused | Agent liveness is verified (`docs/herdr-backend.md` husk classifier), but no live process command/model read has been verified for herdr panes; support is withheld rather than claimed without evidence. |
| zellij | refused | No verified agent-process liveness classifier (`fm_backend_agent_alive` reports `unknown`; `docs/configuration.md` "Runtime backend"). |
| orca | refused | Same missing liveness proof as zellij. |
| cmux | refused | Same missing liveness proof as zellij. |

Extending support to another backend means verifying both proofs empirically against the real binary, recording the evidence in that backend's guide, and only then widening `fm_failover_backend_supported`.

## Tuning

`FM_FAILOVER_OUTAGE_RE`, `FM_FAILOVER_OUTAGE_TAIL_LINES`, `FM_FAILOVER_CANDIDATES`, `FM_FAILOVER_PROBE_TIMEOUT`, `FM_FAILOVER_EXIT_TIMEOUT`, `FM_FAILOVER_VERIFY_TIMEOUT`, `FM_PROVIDER_PROBE_MODEL_OLLAMA`, the pressure thresholds (`FM_PROVIDER_SESSION_AVOID_PCT`, `FM_PROVIDER_SESSION_HANDOFF_PCT`, `FM_PROVIDER_WEEK_AVOID_PCT`, `FM_PROVIDER_USAGE_MAX_AGE_SECS`), and `FM_PROVIDER_USAGE_REFRESH_TIMEOUT` are documented in `docs/configuration.md`'s environment-variable list; the script headers stay authoritative for exact semantics.
