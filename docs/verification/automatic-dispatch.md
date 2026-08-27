# Automatic dispatch verification

Audience: maintainer verification.

This guide was prepared on 2026-08-27 for the version 2 routing implementation through commit `2e1c937` plus the tracked operator contract that introduces this file.
It defines the evidence required to move from simulation to canary to automatic operation without changing the existing task-authority model.
Record dated command output in this file only when it establishes a current guarantee; keep task chronology, credentials, prompts, source, and proprietary output in private task evidence.

[`configuration.md`](../configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) is the single owner of the policy and native account-lane schemas.
This document owns only the staged verification procedure and evidence shape.

## Safety invariants

Routing chooses a qualified worker for work that Firstmate is already authorized to dispatch.
It does not grant repository writes, production access, destructive authority, merge authority, or permission to broaden a task.
Reservations, capability files, route metadata, circuit records, and outcomes never confer authority by themselves.
Active workers retain their recorded route when the policy mode changes and are not interrupted by rollback.

Policy files, account maps, normalized requests, candidates, decisions, reservations, and outcomes must not contain prompts, source code, credentials, cookies, token values, passwords, proprietary payloads, environment values, or raw tool output.
`crew-accounts.json` contains symbolic native account names and absolute authentication-store paths only.

## Preflight

Copy [`crew-dispatch.json`](../examples/crew-dispatch.json) to the home's gitignored `config/crew-dispatch.json` with mode left at `simulate`.
Copy [`crew-accounts.json`](../examples/crew-accounts.json) to that same home's gitignored `config/crew-accounts.json`, then adjust only the declared native account paths to match existing readable directories on that host.
Do not copy `crew-accounts.json` into another home or secondmate because it is deliberately non-inherited.

Run from the Firstmate code root:

```sh
bin/fm-dispatch-policy.sh validate config/crew-dispatch.json
bin/fm-account-lane.sh validate config/crew-accounts.json
bin/fm-bootstrap.sh
bin/fm-route.sh status
```

The two validators and bootstrap must exit zero without a `CREW_DISPATCH:` or `CREW_ACCOUNTS:` diagnostic.
Status must report `mode: "simulate"`, the five caps `3/6/8/2/2`, the fixed `3/900/1800` circuit breaker, current active totals, and any open circuits.

Confirm every configured model immediately before rollout through the authoritative catalog described by `harness-adapters`.
For the tracked example, the intended identifiers are native Claude `sonnet`, native Codex `gpt-5.6-sol` and `gpt-5.6-luna`, Pi `cliproxyapi/gemini-3.7-flash-high`, Pi `zai/glm-5.3`, Pi `cliproxyapi/kimi-k3`, and Pi `cliproxyapi/grok-4.6`.
A catalog-negative model is ineligible and must be corrected or removed before progressing.

The example identifiers were verified on 2026-08-27 with Pi 0.84.2, Codex CLI 0.147.0, and Claude Code 2.1.233 using:

```sh
pi --list-models | grep -E '^(cliproxyapi|zai)[[:space:]]+(gemini-3\.7-flash-high|grok-4\.6|kimi-k3|glm-5\.3)[[:space:]]'
jq -r '.models[]?.slug // .models[]?.id // empty' /home/yaro/.codex/models_cache.json | grep -E '^gpt-5\.6-(sol|luna)$' | sort -u
claude --help | grep -A2 -B1 -- '--model'
```

The exact supporting catalog rows were:

```text
cliproxyapi  gemini-3.7-flash-high         1.0M     16.4K    yes       yes
cliproxyapi  grok-4.6                      500K     16.4K    yes       yes
cliproxyapi  kimi-k3                       1.0M     16.4K    yes       yes
zai          glm-5.3                       1M       131.1K   yes       no
gpt-5.6-luna
gpt-5.6-sol
                                        strings (space-separated)
  --model <model>                       Model for the current session. Provide
                                        an alias for the latest model (e.g.
                                        'fable', 'opus', or 'sonnet') or a
```

## Account-absence and invalid-policy recovery

Temporarily test a native profile whose symbolic account is not declared in this home.
The profile must be reported ineligible without reading the path or credential content, and qualified Pi or other declared profiles must remain eligible.
If no optimized profile qualifies, new work must use configured static dispatch.

Test an invalid copy of the version 2 policy outside `config/`, then validate it directly:

```sh
bin/fm-dispatch-policy.sh validate /path/to/invalid-crew-dispatch.json
```

Validation must exit non-zero with one sanitized reason.
When an invalid version 2 file is active, bootstrap must emit exactly one `CREW_DISPATCH: invalid config/crew-dispatch.json - invalid dispatch policy` diagnostic, new work must use configured static dispatch, and `bin/fm-route.sh status` must show no optimization-state mutation caused by that fallback.

## Simulation gate

With valid simulation mode, Firstmate continues through account eligibility, catalog and quota evidence, exact request/candidate construction, and `fm-route.sh select`.
It then records the privacy-safe proposal through `fm-route.sh observe`, launches nothing, and stops before reserve/spawn.
Collect at least twenty representative observations, including trivial, standard, decomposable, ambiguous, high-risk, and review work where those classes are genuinely present.

Run:

```sh
bin/fm-route.sh report --stage simulation --minimum 20
bin/fm-route.sh status
```

The report must show `stage: "simulation"`, `count` of at least 20, and `meetsMinimum: true`.
Review the underlying task evidence for zero authority or safety misclassifications, zero needless multiworker trivial routes, one explained disposition for every candidate, and only catalog-supported selected models.
Status must still show `mode: "simulate"` and no active reservation created by simulation.

Do not advance if any normalized routing artifact contains prohibited content, any selection cannot explain fit and uncertainty, or any simulation proposed more authority than the original task carried.

## Canary gate

Change only `.routing.mode` from `simulate` to `canary`, re-run the policy validator and bootstrap, then confirm `bin/fm-route.sh status` reports `mode: "canary"`.
Route ten eligible low- or medium-risk tasks through the normal Firstmate lifecycle.
The global active count must never exceed three, and lane or native account counts must never exceed two.

Run after those tasks reach terminal cleanup:

```sh
bin/fm-route.sh report --stage canary --minimum 10
bin/fm-route.sh status
```

The report must show `stage: "canary"`, `count` of at least 10, and `meetsMinimum: true`.
Correlate its terminal, test, review, redundancy, and median elapsed fields with task evidence to establish zero lost tasks, duplicate unauthorized writes, authority violations, unresolved admission records, or material regression from static operation.
Any fallback or circuit event must have a normalized, privacy-safe reason.

## Automatic gate

Change only `.routing.mode` from `canary` to `automatic`, re-run the policy validator and bootstrap, and confirm status reports `mode: "automatic"` with the expected active counts and circuits.
The normal ceiling is six.
The eight-worker burst is permitted only for low-risk decomposable work that has genuinely independent slots; per-lane and per-account ceilings remain two.
Keep the existing review, repository, production, destructive-action, and merge rules unchanged.

Use these read-only operator views during rollout:

```sh
bin/fm-route.sh status
bin/fm-route.sh evidence --work-type implementation
bin/fm-route.sh evidence --work-type review
```

`status` is the current capacity and circuit view.
`evidence` reports per-profile terminal successes and attempts for one bounded work type without exposing task content.

## Recovery

Do not edit or delete routing reservations, admission records, capabilities, circuits, or outcomes by hand.
The normal spawn, relaunch, and cleanup paths authenticate the exact task generation and recover incomplete admission transitions transactionally.
Use the existing [`agent-control.md`](../agent-control.md#transactional-relaunch) procedure when a routed worker needs relaunch, and use normal guarded cleanup for a terminal task.
After recovery, `bin/fm-route.sh status` must show one active capacity slot for the recovered route or the corresponding completed release, never duplicate capacity.
The task's guarded lifecycle records, not the aggregate status view, must retain the exact generation.
The terminal outcome must appear at most once and must retain the recorded profile, lane, account, task class, work type, risk, and mode.

An unsafe or uncertain write is not a recoverable transient.
Stop and escalate it without retrying or changing provider.

## Immediate rollback

Set `.routing.mode` to `off` in `config/crew-dispatch.json`, validate the edited file, and run bootstrap:

```sh
bin/fm-dispatch-policy.sh validate config/crew-dispatch.json
bin/fm-bootstrap.sh
bin/fm-route.sh status
```

Status must report `mode: "off"`.
With valid version 2 mode `off`, automatic-dispatch uses configured static dispatch and stops before account/candidate resolution, `select`, `observe`, `reserve`, or any routing ledger/state mutation.
As a defense-in-depth rollback boundary, `fm-route.sh select` validates the authoritative active policy before reading routing state and returns the exact static decision `action=static`, `reason=routing-mode-off`, with empty evidence and `maxWorkers=1` when valid version 2 mode is `off`. It does not initialize routing state on that path.
When the policy is absent, the low-level selector retains its legacy direct-selection contract; a valid version 1 policy retains the same compatibility. The automatic-dispatch procedure still requires an explicitly validated version 2 policy before optimized routing. An active malformed or unreadable policy, a symlinked home/config/policy component, or a policy override outside the authoritative home config makes the low-level selector fail closed with one sanitized diagnostic and no routing-state mutation.
Bootstrap validates and reports the edited policy; it does not rewrite routing state, stop workers, or turn the low-level selector into a static dispatcher.
Active workers keep their recorded route and continue uninterrupted through their existing supervision and cleanup lifecycle.
No outcome, reservation, or capability file grants write, merge, destructive, or production authority.

Restore a staged mode only after the rollback evidence is recorded and the reason for rollback is resolved.

## Read-only live verification

The portable suite never contacts model providers. To verify the actual coding host without launching a worker, run:

```sh
FM_AUTOMATIC_DISPATCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-automatic-dispatch-live-e2e.test.sh
```

The opt-in test uses a temporary home and routing state. It reports installed Claude, Codex, Pi, and quota-axi versions only after each version command exits successfully; checks the configured native aliases and Pi model rows through read-only catalog surfaces; reads one quota snapshot; and calls only `fm-route.sh select` in simulation mode. It preserves the shared test cleanup contract and never calls spawn, prints credentials, mutates a repository, or touches production routing state. A missing runtime, failed version command, model, catalog, or quota-axi fails closed with a named sanitized diagnostic; without the opt-in it records a clear gate skip.
