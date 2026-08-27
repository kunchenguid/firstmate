# FirstMate Automatic Subscription Routing Design

**Status:** Approved design, awaiting final specification review

**Date:** 2026-08-27

**Target repository:** `voipexpert/firstmate`
**Primary delivery:** Phase 1 — automatic routing across working Claude, Codex, and Pi subscription capacity

## 1. Purpose

FirstMate should finish engineering work faster by automatically assigning each task to the best available coding harness, model, and subscription lane while preserving its existing authority, worktree, review, supervision, and safety controls.

The optimization must stop concentrating work on one Claude or Codex account until its quota is exhausted. It must treat Pi as a first-class subscription-backed model fleet, distribute independent work in parallel, use different providers for important review, and avoid spawning extra workers or building abstractions that the task does not justify.

This design extends FirstMate's existing dispatcher. It does not replace FirstMate with a second scheduler.

## 2. Current State and Gaps

The coding server currently has:

- FirstMate on `main`, with dispatch-profile support through optional `config/crew-dispatch.json`.
- Working native Claude, native Codex, and Pi harnesses.
- Pi connected through CLIProxyAPI, with subscription-backed access to model families including GLM 5.3, Kimi K3, Grok 4.5/4.6, Gemini 3.7 Flash, Claude, and GPT/Codex variants.
- Existing FirstMate worktree isolation, supervision, safety gates, and backend machinery.
- `config/backend=tmux` and `config/startup-memory-budget=7500`.

The identified gaps are:

- No active `config/crew-dispatch.json` policy.
- `quota-axi` is absent, so the existing quota-aware array selector cannot operate.
- No unified view of subscription availability, current account-lane load, recent failures, and historical outcomes.
- No structured automatic classification of task complexity, risk, decomposability, or review needs.
- No enforced anti-overengineering budget tied to task class.
- Agy is installed but is not a supported FirstMate harness. OpenHands, OpenClaw, and Hermes require bounded specialist adapters and are deliberately deferred from Phase 1.

No credentials, tokens, cookies, or raw prompts may be copied into routing configuration or telemetry.

## 3. Scope

### Phase 1: automatic core-fleet routing

Phase 1 will:

1. Classify and, when useful, decompose incoming tasks.
2. Rank eligible native Claude, native Codex, and Pi profiles.
3. Select healthy subscription/account lanes using quota, load, task fit, and outcome history.
4. Launch workers through the existing FirstMate spawn and worktree mechanisms.
5. Apply bounded fallback and circuit breakers.
6. Record privacy-safe outcome metadata.
7. Enforce concurrency and anti-overengineering limits.
8. Support simulation, canary, automatic operation, and immediate rollback modes.

### Phase 2: specialist adapters

After Phase 1 proves reliable, separate designs and implementations may add:

- **Agy:** fast Gemini specialist for bounded analysis or implementation tasks.
- **OpenHands:** isolated, bounded issue-to-change or issue-to-PR implementation.
- **OpenClaw:** technical research, operational investigation, or independent review.
- **Hermes:** higher-level coordination under the existing captain/Paperclip authority model.

These systems must not become alternate uncontrolled dispatch authorities. Phase 2 is out of scope for the Phase 1 implementation.

### Phase 3: tuning and operational visibility

Phase 3 may add benchmark-driven profile tuning, richer dashboards, and refined failure policies. Phase 1 will produce the privacy-safe outcome data required for that work.

## 4. Authority and Safety Boundaries

FirstMate remains the sole execution coordinator for work it accepts. Existing rules for user authority, repository access, worktrees, destructive operations, write confirmation, reviews, and production changes remain authoritative.

The router may choose *who* performs an already-authorized task. It may not expand *what* is authorized.

The following always stop automatic execution and escalate:

- An ambiguous write target or unclear user authority.
- A request that crosses a repository, host, service, or production boundary not already authorized.
- A destructive action whose exact target is unresolved.
- Conflicting state that makes a retry potentially unsafe.
- A security or production finding requiring a human decision.

Retries and fallbacks must never repeat a write unless the system can establish that the prior attempt did not apply it, or the operation is explicitly idempotent.

## 5. Architecture

The request flow is:

`Captain/Paperclip → FirstMate classify/decompose → profile router → existing launcher/worktrees → supervision/tests/review → outcome ledger`

### 5.1 Structured task classifier

The classifier produces a small validated record:

- task class: `trivial`, `standard`, `decomposable`, `ambiguous`, or `high_risk`
- work type: mechanical edit, implementation, architecture/debugging, security/production, research/review, or mixed
- risk: low, medium, or high
- independently executable subtask list, if any
- required capabilities and repository/context constraints
- review requirement
- maximum useful worker count

Classification uses model judgment but must return schema-validated data. Invalid or low-confidence output falls back to a conservative static profile rather than blocking the task.

### 5.2 Decomposition gate

FirstMate only decomposes a task when the proposed subtasks:

- have separate deliverables or file/ownership boundaries;
- can make meaningful progress without waiting on each other;
- do not create conflicting writes to shared state; and
- save enough elapsed time to justify coordination overhead.

Trivial and standard tasks normally stay with one worker. Multiple competing implementations are reserved for genuinely ambiguous or high-impact choices, with a maximum of two approaches.

### 5.3 Ranked profile pools

Profiles are declared in the local, gitignored `crew-dispatch.json` policy using a schema version owned by tracked FirstMate code and documentation. A profile identifies a harness, model where applicable, effort, capability tags, provider/account lane, and eligibility constraints. Secrets are referenced through existing runtime authentication; they are never embedded in the policy.

Initial pools:

| Work type | Preferred qualified pool |
|---|---|
| Fast mechanical | Gemini 3.7 Flash through Pi, GLM 5.3 through Pi, Codex Luna/native fast Codex |
| General implementation | Native Codex, Kimi K3 through Pi, GLM 5.3 through Pi, native Claude |
| Architecture or difficult debugging | Native Claude, Codex Sol/native high-reasoning Codex, Grok 4.6 through Pi, Kimi K3 through Pi |
| Security or production | Strongest task-fit implementer plus mandatory reviewer from a different provider |

Exact model identifiers are discovered and validated against the live Pi/CLIProxyAPI catalog during preflight. Friendly names in policy are aliases; a missing or renamed model makes that profile temporarily ineligible rather than breaking dispatch.

### 5.4 Subscription and lane selector

Among qualified profiles, selection order is:

1. Task and model fit.
2. Available subscription quota or capacity.
3. Current account-lane load and expected start time.
4. Historical success for this work type.
5. Cost only as a minor tie-breaker when relevant.

Pi models are subscription-backed in this environment and must not be penalized as if each invocation were a metered external API call.

An account lane is a credential-backed execution capacity boundary, such as one Claude subscription, one Codex subscription, or the Pi/CLIProxyAPI fleet. Lane adapters expose only normalized health, availability, load, and cooldown state. Credentials remain in their existing protected stores.

`quota-axi` should be installed and integrated where it provides reliable subscription status. The selector must degrade gracefully when a quota signal is unavailable: it can use recent launch results and bounded probes, but it must not claim precise quota knowledge it does not have.

### 5.5 Existing launcher and supervision

The chosen concrete `--harness`, `--model`, and `--effort` are passed into FirstMate's existing spawn path. Existing worktree creation, task briefs, supervision, testing, review, merge, and cleanup behavior remain in force.

The new router must not directly create unmanaged terminal sessions or bypass FirstMate state.

### 5.6 Outcome ledger

A local, gitignored ledger records enough metadata to improve routing and audit failures:

- timestamp and anonymized task/run identifiers
- task class, work type, and risk
- selected profile and provider/account-lane identifier
- queue delay, start delay, and wall time
- retry and fallback counts with normalized reason codes
- test and review outcome
- whether output was redundant or discarded
- terminal state

It must not record prompts, source code, credentials, token values, proprietary payloads, or full tool output. Retention must be bounded and old entries rotated.

## 6. Worker and Concurrency Policy

| Task class | Default execution |
|---|---|
| Trivial | One worker |
| Standard | One worker |
| Decomposable | Two to four independent workers |
| Ambiguous | At most two competing approaches |
| High risk | One implementer plus one independent, different-provider reviewer |

Operational caps:

- Simulation launches no workers.
- Canary mode allows at most three concurrent workers.
- Full automatic mode defaults to six concurrent workers.
- A measured burst ceiling of eight is permitted only for truly independent work when host and subscription capacity are healthy.
- No more than two concurrent workers may occupy one provider/account lane.

FirstMate stops spawning when acceptance criteria are covered, no independent work remains, quota or host pressure is limiting, proposed work is redundant, or tests and required review are already clean.

## 7. Anti-Overengineering Controls

Each classified task receives a coordination budget:

- Trivial tasks cannot be decomposed and cannot receive a separate review worker unless a safety rule requires one.
- Standard tasks default to one implementation path and the repository's normal review flow.
- New abstractions require either repeated present-day use, an explicit requirement, or a demonstrated reduction in complexity.
- Workers must prefer the smallest change satisfying stated acceptance criteria.
- The supervisor rejects speculative refactors, unrelated cleanup, duplicate frameworks, and additional orchestration layers.
- A worker that has completed its deliverable is stopped; it is not kept active to invent follow-up work.
- Redundant or discarded worker output is measured and used as a negative routing signal.

## 8. Dispatch State and Failure Handling

Each dispatch follows a persisted state machine:

`ranked → preflighted → launched → supervised → scored`

Terminal states include `completed`, `failed_safe`, `escalated`, `cancelled`, and `superseded`.

Failure policy:

- A proven transient launch or transport failure receives one bounded retry.
- Quota exhaustion, authentication failure, or model unavailability selects the next qualified subscription/profile without retrying the same unavailable lane.
- Three failures for a lane within fifteen minutes open a thirty-minute circuit breaker.
- Success after cooldown closes the breaker; an operator can also reset it explicitly.
- Ambiguous writes, unsafe state, or uncertain partial execution stop and escalate without blind retry.
- Fallback may change provider or model, but may not silently lower a mandatory review or safety requirement.

State updates must be atomic enough that daemon restarts do not create duplicate active dispatches.

## 9. Configuration and Data

The implementation should use:

- A versioned, documented dispatch-policy schema in tracked code, with each home's policy remaining local and gitignored, for profile pools, aliases, capability tags, task rules, and caps.
- Local gitignored runtime state for lane health, circuit breakers, active load, and the outcome ledger.
- Environment or existing credential stores for authentication.
- A deterministic static fallback profile configurable by the operator.
- A single feature/mode switch supporting `off`, `simulate`, `canary`, and `automatic`.

Policy validation must fail closed to the static fallback. An invalid optimization policy must not make FirstMate unusable.

## 10. Rollout

### Stage 0: off and rollback validation

Before enabling the router, verify that switching it off immediately returns FirstMate to the configured static harness/profile without changing existing repositories or active worktrees.

### Stage 1: simulation

Replay or observe at least twenty completed tasks. The router records the profile and decomposition it would choose but launches nothing itself.

Exit criteria:

- Zero safety or authority misclassifications.
- No needless multiworker routing for trivial tasks.
- Valid profile resolution against current installed harnesses and the live Pi catalog.
- Reports explain each selection and rejected alternative without exposing secrets.

### Stage 2: canary

Enable automatic routing for ten eligible low- or medium-risk tasks with at most three concurrent workers.

Exit criteria:

- Zero lost tasks, duplicate unauthorized writes, or authority violations.
- No material routing regression against static operation.
- Median eligible-task cycle time improves.
- Fallback and circuit-breaker events are visible and recover correctly.

### Stage 3: automatic

Enable the six-worker default. Permit bursts up to eight only after measurements show healthy host utilization, low redundant-work rate, and stable subscriptions. High-risk review rules remain mandatory.

## 11. Verification Strategy

### Unit and contract tests

- Policy and task-classification schema validation.
- Deterministic ranking with fixed health, quota, load, and outcome inputs.
- Model-alias resolution and missing-model handling.
- Worker-count and per-lane cap enforcement.
- Anti-overengineering rules for trivial and standard tasks.
- Privacy checks preventing prompt, code, or secret fields in ledger records.

### Integration tests

- Existing dispatch-profile resolution through the selected concrete harness/model/effort.
- Quota unavailable, quota exhausted, auth failure, and model unavailable fallbacks.
- One-retry transient policy and no-retry unsafe-write policy.
- Three-failure circuit breaker, cooldown, and reset.
- Atomic recovery without duplicate launches after interruption.
- Different-provider reviewer selection for security and production work.

### Operational tests

- Non-mutating live smoke tests against every enabled harness and Pi model alias.
- Simulation report covering at least twenty representative completed tasks.
- Canary report covering ten eligible tasks.
- Rollback drill to static dispatch.
- Full existing FirstMate regression suite before integration.

## 12. Success Criteria

Phase 1 is successful when:

- FirstMate automatically spreads eligible work across available Claude, Codex, and Pi subscription capacity.
- Trivial and standard work does not become slower through unnecessary coordination.
- Independent subtasks run concurrently within the approved caps.
- High-risk work receives independent different-provider review.
- Quota, authentication, and model failures fall back safely without loops.
- No prompt, source, or credential data appears in routing telemetry.
- Canary median cycle time improves over the static baseline with no safety regression.
- The operator can disable optimization and return to static dispatch immediately.

## 13. Implementation Constraints

- Extend the existing `crew-dispatch.json`, `quota-array-dispatch`, and spawn pathways where practical.
- Do not introduce a second task scheduler, terminal manager, worktree manager, or review system.
- Preserve compatibility with existing static dispatch configuration.
- Keep model and account inventory data-driven; do not hard-code assumptions about subscription names or future catalog availability.
- Phase 1 must work with the currently installed Claude, Codex, and Pi harnesses before any Phase 2 adapter is attempted.
- All implementation work must follow test-driven development and pass the full FirstMate verification suite.

## 14. Deferred Decisions

The following require Phase 1 evidence or separate approval:

- Exact weighting constants for fit, queue delay, and historical success.
- Whether outcome history should use a rolling average, Bayesian score, or another estimator.
- The stable adapter contracts for Agy, OpenHands, OpenClaw, and Hermes.
- Rich dashboard technology and long-term telemetry retention.
- Raising any concurrency ceiling beyond the approved maximum of eight.

These deferred choices do not block Phase 1 because safe defaults and the staged rollout provide the necessary evidence before tuning.
