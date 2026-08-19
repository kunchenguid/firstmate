---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array from current quota-axi output, including effective headroom, usable runway, and configured telemetry constraints.
  Load when a dispatch rule or default resolves to more than one profile candidate.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is the single owner of the completion-aware profile-array selection procedure.
`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning/tie safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`quota-axi` remains data-only, reports whatever granularity the vendor supplies, and never recommends, selects, ranks, or infers a route.
Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy, or producer-side route recommendation.
Deterministic shell owns only schema, configuration, and version validation plus concrete spawn safeguards; every model-to-provider, provider-to-credential, and quota-applicability relation is yours to establish transparently and to show your evidence for.
The optional per-candidate `preferWhileLoadBelowPercent` field is a local profile-array policy input, not provider data or shared product policy.
It is valid only for a TraeX candidate with an explicit model and a positive numeric threshold.

## Collect facts

Run `quota-axi --json` once per intake and reuse that snapshot for every candidate.
Do not take a second snapshot to settle a candidate, and read `quota-axi auth --json` when a candidate's credential surface is in question.
For each candidate, preserve explicit `harness`, `model`, and `provider`; `harness-adapters` owns identity, and model/provider never infer harness:

- task/profile fit and required reasoning class
- applicable effective headroom (`effectivePercentRemaining`) from the established provider/model scope
- usable runway status, `usableRunwaySeconds`, `projectedExhaustedAt`, `limitingWindowId`, `projectionConfidence`, and any `unmeasurableWindowIds`; every projection is cycle-average, so the current contract has no `projectionBasis` field
- the task-completion horizon and the evidence and confidence used to estimate it
- effective pace, signed reserve per window, and worst reserve (`worstReservePercentPoints` or minimum signed reserve) for later diagnostic tie-breaking
- for TraeX, the exact normalized `models[]` record joined by `catalogId`, including `load.status`, `load.percent`, `load.stale`, `quota.status`, `quota.scope`, `quota.windowIds`, `quota.relationship`, and `quota.sharing`
- the configured `preferWhileLoadBelowPercent` value, when present
- schema notes when runway, pace, or model telemetry fields are absent

Stale raw windows are diagnostic, never headroom or fabricated runway.
Grok's `credits.remaining` is a prepaid balance unrelated to `percentRemaining`; never read it as exhaustion.
Read all windows named by `boundedBy`, `limitingWindowIds`, `aheadWindowIds`, `behindWindowIds`, `onPaceWindowIds`, `unknownWindowIds`, and `unmeasurableWindowIds`.
The compact default output intentionally omits numeric reserve, while `--json` and `--full` retain reserve diagnostics.

## Establish the provider relation before reading quota

Deterministic shell must never map a model to a provider, a provider to a credential store, or a name prefix to a family.
You establish those relations yourself, in the open, from the candidate's own authoritative catalog (`harness-adapters` owns the per-harness discovery surface) plus the one intake snapshot.
Name the evidence for each relation you assert so the conclusion is inspectable.

1. Confirm the catalog lists the candidate's model and record the provider family it reports.
   A model the authoritative catalog does not list is concrete contradictory evidence: block that candidate and quote the catalog result.
2. Apply quota at the granularity the vendor actually supplies.
   A provider-level or `all_models`/`all_products` scope bounds every model you established in that family, including one with no window of its own.
   A named-model or named-product scope is an additional bound for that model alone and is irrelevant to every other model in the family.
   Treat `quotaSemantics.effectiveAvailability` as the structured declaration of applicable scopes and bounds.
   When a full snapshot includes `quotaSemantics.description`, use it as explanatory evidence; default `--json` legitimately omits it, so never require a second snapshot just to obtain prose.
3. Record what remains unknown instead of converting it into a verdict.

### TraeX model joins

For TraeX, the same `quota-axi --json` snapshot normalizes the harness's read-only model catalog into `providers[].models[]`.
Join the configured model to exactly one `models[].catalogId`; do not match by display label, backend name, array position, or the captain-approved display-name mapping.
A fresh TraeX provider record whose normalized catalog does not contain that exact `catalogId` is concrete unsupported-model evidence.
An unavailable, errored, rate-limited, auth-required, or stale provider record does not prove catalog absence and remains explicit uncertainty unless its selected credential is separately proven unusable.
Do not run another catalog command for this array decision: the one quota snapshot already contains the normalized TraeX catalog, load, and quota joins.

TraeX `load.percent` is provider-reported model load, can exceed 100, and is never quota usage, quota used, or quota remaining.
Only a fresh record with `load.status: "known"`, `load.stale: false`, and a numeric `load.percent` can satisfy or violate `preferWhileLoadBelowPercent`.
A value strictly below the configured threshold makes that otherwise viable TraeX candidate the explicit local preference; a value at or above the threshold blocks it.
Missing, invalid, or stale load neither satisfies the preference nor blocks the candidate; disclose the uncertainty and continue with quota, runway, pace, fit, and reasoning evidence.

Join `quota.status: "authoritative"` through its exact `quota.scope` to `quotaSemantics.effectiveAvailability[].scope`, and use `quota.windowIds` only as exact joins to `windows[]`.
`not_reported`, `not_applicable`, or `invalid` quota is not zero headroom.
Structurally equal TraeX windows remain distinct model-scoped evidence when `sharing` is `unknown`; never infer a shared family or account pool from equal values.

## Authentication is scoped to the selected surface

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the candidate actually uses rather than collapsing a provider to a single status.
A provider can carry a healthy source beside a missing or expired one; the unused source's state is not the candidate's state.
A Pi-hosted family may authenticate through the vendor's own store with no `pi:`-prefixed source at all, which is normal and never evidence against the candidate.

Uncertainty and ineligibility are different findings:

- No model-level window, no matching auth source, an absent `state.authStatus`, an unmeasurable or `unknown` scope, or a surface quota-axi does not model at all is disclosed uncertainty.
  Keep the candidate eligible, state the unknown, and prefer known sustainable evidence when otherwise comparable.
- An expired credential is a short-lived session token the owning vendor renews on next use, not a sign-out.
- Only concrete contradictory evidence blocks: an authoritative catalog proving the model unsupported, or proof that the credential the candidate actually selects is unusable.
- Reserve login wording for that proven-unusable case, and name the harness, model, surface, and evidence.

When a credential's local classification is the only thing standing between a candidate and a block, get ground truth before blocking.
`bin/fm-vendor-auth-probe.sh` is the only approved vendor-credential probe; its `--help` owns the registered probes and mechanics.
It takes no harness, model, or provider and returns a fact, not a route: only `authenticated` and `unauthenticated` are ground truth, while `indeterminate`, `timeout`, and `unavailable` establish nothing and must never be read as either outcome.
Never launch a vendor CLI yourself, and never probe a credential store the candidate does not use.

## Pace semantics

`reservePercentPoints = percentRemaining - timeRemainingPercent`.
Negative reserve means usage is ahead of reset pace and creates conservation pressure.
Positive reserve means usage is behind reset pace.
`on_pace` is neutral.
Conservation pressure is present for effective pace status `ahead`, effective pace status is `mixed` and any `aheadWindowIds` remain, or a bounding window is `ahead`.
When pace is the first unresolved comparison, known `behind` evidence has less conservation pressure than `on_pace`, which has less than `ahead`; compare signed reserve within the same pace class without turning it into a score.
`unknown` is valid explicit uncertainty from quota-axi, not parser failure or permission to assume health.
A candidate with unknown pace remains eligible, but known lower conservation pressure can justify the choice when all earlier completion evidence is otherwise comparable.

## Selection order

Apply only among candidates satisfying required fit and strongest reasoning class.
Never use headroom, runway, pace, or reserve to silently replace that reasoning class.

1. Concrete contradictory evidence or malformed configuration: stop and report the tuple and that evidence.
   Block only the affected candidate when the contradiction is candidate-scoped and another configured candidate remains usable; refuse the whole array only for malformed configuration or when no candidate can proceed.
   A fresh authoritative applicable scope with `effectivePercentRemaining` at zero, `runway.status: "exhausted_now"`, or a joined provider depletion flag is concrete depleted-quota evidence for that candidate.
   Unmeasurable quota, a missing model-level window, an absent runway field, and a credential surface quota-axi does not model are uncertainty, never this rule.
2. Apply `preferWhileLoadBelowPercent` only through the exact fresh TraeX model join above.
   A known value below the threshold establishes the configured preference only when the candidate has no known completion shortfall; it never rescues depleted quota, a known runway that ends before likely completion, unsupported model evidence, an unusable credential, incompatible task fit, or a weaker-than-required reasoning class.
   A known value at or above the threshold blocks that candidate, while unknown load leaves it eligible without preference.
   Never invent a generic percentage floor or apply a configured threshold to quota remaining.
3. Honor any explicit captain instruction that sets a floor for that candidate before the generic comparison.
   The current concrete instruction overrides a conflicting local profile preference within its exact scope.
4. Keep the strongest-reasoning class when every candidate is tight or completion evidence is poor.
   Dispatch inside that class when a candidate can proceed, or report that its strongest-class choice cannot proceed rather than downgrading it to conserve quota.
5. Compare comparable-fit candidates on their applicable effective headroom and usable runway.
   Eliminate a candidate only when another candidate Pareto-dominates it on both dimensions, with at least one dimension strictly better.
   Establish dominance only from comparable known evidence, never by treating absent, `unknown`, or unmeasurable headroom or runway as zero or as a healthy value.
6. Prefer supported runway evidence that projects availability through the inspectable likely-completion horizon.
   `projected_exhaustion` reaches only its finite `usableRunwaySeconds`; `through_reset` means every authoritative current-cycle bound reaches its own reset without exhaustion and has no synthetic finite deadline.
   When a bound resets before the likely completion horizon, `through_reset` is positive evidence that the candidate crosses that reset, while a finite projection ending before completion is a known shortfall.
   Known evidence that does not reach that horizon is inferior to known evidence that does, even when its signed reserve is less negative.
   Preserve projection confidence, the cycle-average basis, the limiting window when finite, and the horizon estimate in the rationale rather than hiding them in a score or model-specific heuristic.
7. Resolve remaining uncertainty explicitly.
   An authenticated candidate with unknown or unmeasurable headroom or runway stays eligible and cannot be silently excluded or assumed sustainable.
   Prefer known viable evidence when otherwise comparable, and report uncertainty or ask the captain when it still prevents a justified choice.
8. Use pace and signed reserve only as later diagnostic tie-break evidence among candidates still unresolved after headroom, runway, likely-completion viability, and uncertainty.
   Pace and reserve never rescue a clearly inferior completion prospect.
   Do not collapse these facts, `selection.spendPriority`, or any other aggregate into an opaque routing score.
9. Older schemas or absent runway, pace, or normalized TraeX model fields: do not crash, fabricate evidence, treat absence as healthy, or silently exclude a candidate.
   State which evidence is unavailable, retain the candidate unless separate concrete evidence blocks it, and apply only the comparisons the snapshot supports.
10. Genuine ties: stop and report every tied candidate for captain choice.
   Do not select by array order, harness name, or another arbitrary identity ordering.
   Report duplicate concrete profiles as a configuration error.

Account for every candidate visibly before selecting or escalating, naming its catalog evidence, provider relation, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, effective headroom, usable runway, likely-completion reasoning, and later pace or reserve evidence when used.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label.
