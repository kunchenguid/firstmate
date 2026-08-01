---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array from current quota-axi output, including effective headroom and usable-runway evidence.
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

## Collect facts

Run `quota-axi --json` once per intake and reuse that snapshot for every candidate.
Do not take a second snapshot to settle a candidate, and read `quota-axi auth --json` when a candidate's credential surface is in question.
For each candidate, preserve explicit `harness`, `model`, and `provider`; `harness-adapters` owns identity, and model/provider never infer harness:

- task/profile fit and required reasoning class
- applicable effective headroom (`effectivePercentRemaining`) from the established provider/model scope
- usable runway status, `usableRunwaySeconds`, `projectedExhaustedAt`, `limitingWindowId`, `projectionConfidence`, `projectionBasis`, and any `unmeasurableWindowIds`
- the task-completion horizon and the evidence and confidence used to estimate it
- effective pace, signed reserve per window, and worst reserve (`worstReservePercentPoints` or minimum signed reserve) for later diagnostic tie-breaking
- schema notes when runway or pace fields are absent

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
   Read `quotaSemantics.description`, which states the vendor's own bounding rule.
3. Record what remains unknown instead of converting it into a verdict.

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
`unknown` is valid explicit uncertainty from quota-axi, not parser failure or permission to assume health.

## Selection order

Apply only among candidates satisfying required fit and strongest reasoning class.
Never use headroom, runway, pace, or reserve to silently replace that reasoning class.

1. Concrete contradictory evidence or malformed configuration: stop and report the tuple and that evidence.
   Unmeasurable quota, a missing model-level window, an absent runway field, and a credential surface quota-axi does not model are uncertainty, never this rule.
2. Honor any explicit captain instruction that sets a floor for that candidate before the generic comparison.
   Do not invent a generic percentage floor or treat a low percentage as an automatic failure.
3. Keep the strongest-reasoning class when every candidate is tight or completion evidence is poor.
   Dispatch inside that class when a candidate can proceed, or report that its strongest-class choice cannot proceed rather than downgrading it to conserve quota.
4. Compare comparable-fit candidates on their applicable effective headroom and usable runway.
   Eliminate a candidate only when another candidate Pareto-dominates it on both dimensions, with at least one dimension strictly better.
   Establish dominance only from comparable known evidence, never by treating absent, `unknown`, or unmeasurable headroom or runway as zero or as a healthy value.
5. Prefer supported runway evidence that projects availability through the inspectable likely-completion horizon.
   Known evidence that does not reach that horizon is inferior to known evidence that does, even when its signed reserve is less negative.
   Preserve projection confidence and basis, the limiting window, and the horizon estimate in the rationale rather than hiding them in a score or model-specific heuristic.
6. Resolve remaining uncertainty explicitly.
   An authenticated candidate with unknown or unmeasurable headroom or runway stays eligible and cannot be silently excluded or assumed sustainable.
   Prefer known viable evidence when otherwise comparable, and report uncertainty or ask the captain when it still prevents a justified choice.
7. Use pace and signed reserve only as later diagnostic tie-break evidence among candidates still unresolved after headroom, runway, likely-completion viability, and uncertainty.
   Pace and reserve never rescue a clearly inferior completion prospect.
   Do not collapse these facts into an opaque composite score.
8. Older schemas or absent runway/pace fields: do not crash, fabricate runway or pace, treat absence as healthy, or silently exclude a candidate.
   State which evidence is unavailable, retain the candidate, and apply only the comparisons the snapshot supports.
9. Genuine ties: stop and report every tied candidate for captain choice.
   Do not select by array order, harness name, or another arbitrary identity ordering.
   Report duplicate concrete profiles as a configuration error.

Account for every candidate visibly before selecting or escalating, naming its catalog evidence, provider relation, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, effective headroom, usable runway, likely-completion reasoning, and later pace or reserve evidence when used.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label.
