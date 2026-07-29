---
name: model-onboarding
description: >-
  Agent-only admission policy for routing a new model, and the promotion and demotion authority for models already routed.
  Load before adding or changing a model in routing config, before probing a model, before acting on an entitlement or price-drift alarm, and before deciding a promotion or demotion.
user-invocable: false
metadata:
  internal: true
---

# model-onboarding

The admission gate for any model firstmate may route work to, and the authority model for moving one between reasoning tiers.
`docs/configuration.md` owns the `config/models.json` schema; `bin/fm-model-registry-lib.sh` owns the enforcement mechanics; this skill owns the decision procedure.

## Why the ordering is what it is

Three failures produced this policy, and every one of them was a question answered with an instrument that could not answer it.

| The question actually being asked | Instrument used | Instrument that answers it |
|---|---|---|
| Entitlement - will *this account* get a response? | a catalogue listing | a live probe |
| Freshness - is this answer current? | a local cache read | nothing; a cache cannot answer it |
| Cost class - will this call cost money? | provider identity | per-model price plus explicit free-tier terms |

Entitlement, cost class and capability are independent axes.
A model can be entitled and billable, unentitled and free-if-it-worked, or catalogued and neither.

The single most important consequence:

> **The instrument that catches an entitlement error is itself a billable act on a metered provider.**

Probing a metered model "just to check it works" is a charge, and a *successful* probe then invites routing to it.
So cost class is established before entitlement, and a probe is authorized only after the model is shown to be subscription-flat or verified-free.
A framework ordered the other way would have prevented the entitlement incident and caused the billing one.

## The freshness rule

Every gate answer carries a source kind and a verified-at timestamp.
In descending authority: `probe`, `provider-entitlement`, `provider-doc`, `harness-static-catalogue`, `harness-fetched-cache`, `third-party`, `inference`.

> **A `harness-fetched-cache` answer may never be the sole evidence for cost class or entitlement.**

That source is refreshed by the provider underneath you.

Applied to price, the rule is narrower than it first looks, and the narrowing matters.
A **probe does not establish a price.**
It proves the account gets an answer; it says nothing about what that answer costs, and a model can answer perfectly while being metered.
So an allowlist entry needs a genuinely price-bearing source - `provider-doc` or `harness-static-catalogue` - and the validator refuses one whose price rests on a cache plus a probe.
Treating "it responded" as "it is free" is the shape of the billing incident, not a defence against it.

## The admission gate

Eight ordered stages, fail-closed. Refusal at stage N forbids stage N+1 from running.
Most stages are a checklist, not machinery.

**G0 Identity.** What exactly will the harness send?
Record the provider id and model id resolved through the harness's own resolution path, verbatim.
Refuse a name supplied by the captain, a vendor page, a benchmark table, or another agent that does not resolve.
Treat all model names and access claims from users or third parties as unverified until confirmed.

**G1 Cost class.** Can this call cost money?
Output exactly one of `subscription-flat`, `verified-free`, `metered`, `unknown`, **plus the price recorded numerically**.
Evidence must include a provider doc *and* the harness's price metadata, and they must agree; a cache alone is insufficient.
`metered` is rejected by cost policy. `unknown` is **refused, not deferred** - an unresolved free-tier boundary is a refusal.
Also record: billing required at signup, overage possible, free tier promotional or withdrawable, card attached that could silently absorb overage.

> Subscription is not automatically zero-marginal.
> A flat plan can carry a metered dimension on top, enabled per model by account policy.
> Classify `subscription-flat` only after confirming the *specific* usage sits inside the flat allowance.

**G2 Probe authorization.** May I make a live request?
Authorized if and only if G1 returned `subscription-flat` (with that flat-allowance confirmation) or `verified-free`.
Otherwise the probe needs the captain's explicit word, and the candidate is recorded as *researched, not probed*.
This stage exists only because of the ordering rule above.

**G3 Entitlement and liveness.** Will this account actually get an answer?
Run `bin/fm-model-verify.sh --model <provider>/<id>`.
Where the provider offers real entitlement data, read it first and probe second - an empty entitlement set is a refusal that costs nothing to detect.

Four distinguishable response shapes:

| Shape | rc | Meaning | Handler |
|---|---|---|---|
| `ok` | 0 | entitled and live | admit to the next gate |
| `entitlement-refused` | 1 | server-side refusal naming the account type | reject; never route |
| `unknown-model` | 1 | unknown id, still sent upstream | reject; identity error at G0 |
| `client-error` | 1 | request never left the machine | configuration error, not a provider fact |

A client-side failure returns in well under a second; a server-side refusal takes seconds.
That separation matters: a local typo must never be recorded as a provider outage.
Every probe closes stdin - `pi -p` can hang unbounded otherwise, and a wedged probe presents to supervision as a stale worker, making the monitor the fault.

**G4 Harness expressibility.** Can the harness express what the route requires *on this model*?
Check the effort band, tool calling, structured output, streaming, whether the context ceiling can be pinned, and whether the credential can be referenced by environment-variable name.
Refuse when the route is defined by a control the model cannot accept.

> Effort bands are **not portable**, and this is a gate rather than a footnote.
> Some models accept no reasoning-effort setting at all; others silently map low and medium onto the provider default.
> A substitution that looks capability-equivalent can therefore change reasoning depth silently - the exact failure the captain ruled against.

**G5 Competence.** Does it clear the floor for the *lowest* route proposed?
A candidate is never admitted on one successful task.
The evaluation suite is deliberately dormant until a candidate exists; see "What stays dormant".

**G6 Route assignment.** Which routes, and which are forbidden?
Record eligible routes, **explicitly prohibited routes**, the operational context ceiling (never the advertised maximum), rate and concurrency policy, failover position, and admission status.

**G7 Reversibility and entry state.** Can this be undone in one step?
The change must be a single declarative edit with a stated rollback, the model enters at observation level **O1**, never straight into the general pool, and the routing rule that will use it is named in advance so its blast radius is known.

## Cost policy

> **The monthly paid-usage budget for API-key providers is $0.00.**
> This is a safety rule, not a preference.

Four access classes:

- **A Subscription-backed.** Confirm the subscription permits use through the intended harness. Exhaustion is an availability event, not a semantic routing change.
- **B API key with a genuine free tier.** Verify the tier exists now, whether a card is required, whether enabling the API auto-enables overage, the limits and reset behaviour, and that the provider can be configured without enabling paid billing.
- **C Metered with no qualifying free tier.** Rejected by default. Record as researched, not enabled. Do not configure credentials or billing preemptively.
- **D Self-hosted or open-weight.** **Never labelled "free."** Report infrastructure cost separately from the $0.00 API budget.

> **The mixed-key rule.** Where one credential reaches both free and paid models, **the credential is not the unit of authorization - the model is.**
> Route only to an explicit allowlist; never to a provider generally; never to a provider default; **never substitute an unlisted sibling during failover.**

Standing prohibitions: do not enable pay-as-you-go, attach a payment method, consume prepaid credits, allow automatic overage, fall through from free into paid, or retry in a way that could trigger billable usage.
Do not treat free credits as a permanent free tier.
When free quota is exhausted, stop rather than continue.

Keys are referenced by environment-variable name only; no key is ever printed, logged, or committed.

## Admission statuses

| Status | Produced by | Routing | Constraints |
|---|---|---|---|
| **Rejected** | a G0/G1/G3/G4/G5 refusal | none, permanently | Record the refusal and its evidence so it is not rediscovered. |
| **Researched but blocked** | G1 `metered`, G2 unauthorized, or unresolved credential, region or terms | none | The dossier stands; eligible only on captain approval. |
| **Experimental** | a thin G5 pass, or uncertain limits | allowlisted tasks only | Limited concurrency, explicit task allowlist, no Tier 1 unless specifically approved, immediate fallback, one-step disablement. Enters at O1. |
| **Approved fallback** | meets a route's floor but is not preferred | pool member for that route | Must meet the **same** floor as the primary. |
| **Approved specialist** | strong on a narrow workload | that workload only | Prohibited routes stated explicitly. |
| **Approved primary** | strong evidence, clean evaluation, dependable access, understood quota, and it **improves on the current primary** | preferred for its routes | "As good as" is not promotion-worthy. |

Status is orthogonal to availability: a rate-limited approved primary is still an approved primary.

## Runtime failure policy

Firstmate observes availability **unevenly**, and the design says so rather than assuming symmetry.
Authentication failure, model unavailability and provider unavailability are cheaply observable; rate limiting, daily and free-tier exhaustion, degradation and context incompatibility are visible only from a dispatch failure.
Build any quota-aware failover for that asymmetry, not around an assumption of symmetric telemetry.

Discriminate a model outage from a provider outage with two probes: a sibling that succeeds means a model outage, so substitute within the tier; a sibling that also fails means a provider outage, so promote a tier.

**On free-tier exhaustion:** mark unavailable, do not cross into paid usage, do not repeatedly retry, fall back only to a same-route candidate on the allowlist that meets the floor, otherwise stop and escalate.

**The terminal state:**

> **When no candidate in a route's pool meets that route's floor and is available, firstmate stops, queues the work, and reports to the captain immediately, naming the route, the floor, every candidate considered, and why each was unavailable.**
> **It does not degrade, does not substitute below the floor, and does not cross into paid usage to keep working.**

Throughput reaching zero on a route is an acceptable outcome; silent degradation is not.

## Promotion and demotion

**Authority, ruled 2026-07-28.** The registry validator enforces this as a ceiling - a home may be more conservative, never more permissive.

| Transition | Authority |
|---|---|
| Tier 4 -> Tier 3 | **Automatic** once configured thresholds are met, surfaced in the immediate notification band: the captain is told at once, not asked. |
| Tier 3 -> Tier 2 | **Captain confirmation.** Firstmate proposes with the accumulated evidence; the captain approves or declines. |
| Tier 2 -> Tier 1, Tier 1 -> Tier 0 | **Never entered by accumulated evidence.** |

The hard ceiling is not a tuning choice.
Tier 1 is triggered by **risk**, not capability rank, and a model that has completed two hundred clean Tier 2 tasks has demonstrated nothing whatsoever about credential handling or destructive-operation judgment.
Entry to Tier 1 or Tier 0 is a captain decision informed by a domain-specific risk evaluation.

**Evidence.** A bounded fixture suite systematically flatters the cheaper candidate, so it can *reject* but never *promote*.
Promotion therefore draws on real dispatch history.
A candidate test for tier N+1 is **a real task whose discriminator is tier N+1's**, not a harder task of tier N's shape.

Three rules on any deliberate candidate test:

1. **The candidate never judges itself.** Models are unreliable judges of the abstraction level of their own work; this mirrors the rule that an implementation worker never answers its own ask-user finding.
2. **It is real work, never a fixture.**
3. Every threshold is configuration, and firstmate must explain any promotion by naming the current value it acted on.

**Demotion is deliberately faster than promotion**, because reasoning quality must never silently degrade.
A landed defect at the promoted tier that the tier's own verification path should have caught, or work performed across a tier boundary it should not have crossed, demotes on a single occurrence.
Lost entitlement, a changed cost class, or a harness that can no longer express the route's effort band demotes immediately **and suspends the route**.

On demotion the model returns to its previous tier, promotion evidence **resets to zero rather than decaying** so a marginal model cannot oscillate across the threshold, a cooldown blocks re-promotion, and observation re-escalates.

> **Demotion is a routing change, not an availability change.**
> A rate-limited, quota-exhausted or cooling-down model is **not demoted** - it is unavailable, which the failure policy handles on an independent axis.
> Conflating them would make every outage permanently degrade the routing table.
> The separation is structural: availability lives in `state/model-health.json`, routing status in `config/models.json`, written by different code.

## Observation levels and the floor that never reaches zero

Monitoring intensity is defined concretely as how often the gate is re-verified plus how deeply evidence is reviewed.

| Level | Gate re-verification | Evidence review | Entry condition |
|---|---|---|---|
| **O1 Probation** | probe before first dispatch each day | every task reviewed | newly admitted, or newly promoted |
| **O2 Watch** | probe at session start | weekly | a run of clean tasks at O1 |
| **O3 Routine** | probe at session start | monthly | a longer clean run at O2 |
| **O4 Maintenance floor** | probe at session start **plus a price-drift check** | on trigger only | stable **and structurally promotion-ineligible** |

Tapering stops at O4, entered only when the model is stable and **structurally** ineligible for further promotion.
That is checkable rather than a judgment call, and holds in exactly two ways: the ladder has no next rung (the model sits at the top of the automatic ladder), or a floor it cannot meet (G4 shows it cannot express a control the next tier requires).
"We decided not to promote it" is **not** structural ineligibility.

**Observation never reaches zero.** At O4 two checks still run at every session start, forever, because **the two things that decay are not properties of the model** - they are properties of the account and of the provider's price list, and both change without warning.
A model can be perfectly stable while its entitlement is revoked and its price is raised.

Re-escalate O4 -> O2 (never back to O1, which is for unproven models) on any demotion trigger, a failed entitlement probe, **any price drift**, a harness upgrade that changes the model's catalogue entry, a provider incident affecting that model, or a terminal task line recording a repair or escalation.

## What stays dormant, and what activates it

| Component | Status | Activated by |
|---|---|---|
| The gate, statuses, floors, failure policy | live now | - |
| Session-start probe and price-drift floor | live now | - |
| Registry integrity and spawn refusal | live now | - |
| Evaluation suite | **dormant** | a candidate actually reaching G5 |
| Automatic promotion thresholds | **dormant** | the evidence instrument producing terminal task lines, then `promotion.enabled` |
| Shadow dual-dispatch evaluation | **dormant** | the free natural experiment proving insufficient |

Promotion activation is a **config and data condition, never a code change**: the named instrument must be producing terminal task lines and `promotion.enabled` must be true.
`fm_model_promotion_state` reports which of the two is unmet, because a trigger nobody can check is indistinguishable from a rejected one.

Do not build per-model capability scores, a provider-health abstraction layer, or automatic quota-aware profile arrays without fresh evidence that the simpler mechanism failed.
Scoring a handful of models on several axes from a short suite manufactures precision the evidence cannot support; pass/fail against a floor is the honest granularity.

## Operating checklist

Adding a model:

1. Load this skill and walk G0-G7 in order. Do not skip to the probe.
2. Record the dossier under `data/model-onboarding-policy/dossiers/`, including the exact rollback edit - admission time is the only time that is cheap to know.
3. Add the registry entry, and the `zero_budget.allowlist` entry when the provider is API-key backed.
4. Only then add the dispatch rule. Bootstrap refuses a rule naming an unregistered, non-approved, or unprobed model.

Acting on an alarm:

- `MODEL_VERIFY: ... REFUSED by the provider` - the account cannot use it. Remove it from routing; this is a rejection, not an outage.
- `MODEL_VERIFY: ... failed locally` - a configuration error on this machine, not a provider fact.
- `MODEL_PRICE: ... no longer zero` - suspend the route immediately, then re-verify the cost class at G1.
- `MODEL_PRICE: ... price drifted` - re-verify G1 and update `price_at_verification`.
- `MODEL_REGISTRY: ...` - the dispatch config and the registry disagree. Fix the config; do not weaken the check.
