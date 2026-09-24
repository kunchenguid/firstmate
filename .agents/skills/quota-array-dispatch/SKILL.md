---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array from quota-axi's default TOON, ranking by usable remaining quota,
  unstarted session windows, and spendPriority after three orthogonal gates.
  Load when a dispatch rule or default resolves to more than one profile candidate.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is the single owner of the completion-aware profile-array selection procedure.
`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning/tie safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`quota-axi` remains data-only: it publishes `spendPriority` as a comparable scalar and never recommends, selects, ranks, or infers a route.
Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy, or producer-side route recommendation.
The [worker helper](../../../bin/fm-quota-choose.sh) and [typed resolver](../../../docs/configuration.md#typed-dispatch-resolution-env-typesafe_api_key) own their deterministic mapping boundaries.

## Worker-side quota helper

The canonical shell helper for a worker that has already performed its model-selection reasoning and now needs to pick the first viable candidate is `bin/fm-quota-choose.sh`.
Pass it the intake's already-captured default TOON or permitted JSON fallback through stdin or `--snapshot`; it never takes another quota snapshot, so it selects from the same quota state as the intake.
Pass each candidate as `harness:model`, with earlier candidates preferred.
The helper's header owns its provider mapping and quota selection mechanics.
An `exhausted_now` runway vetoes the candidate.
The helper selects a candidate only when its applicable quota has a known `effectivePercentRemaining` greater than zero.
This is an optional narrow helper with a known limitation: it maps each harness to one primary provider family only, so a candidate whose established provider differs from that primary family is checked against the wrong quota row.
omp has no primary family, so the helper keys an `omp:` candidate on its model prefix, mapping only `openai-codex/` and `claude-bridge/` and refusing every other prefix; the helper's header owns that mapping.
Authoritative multi-provider routing - including provider discovery from the harness catalog and quota matching by that explicit provider - stays owned by this skill's intake procedure above and AGENTS.md section 4, not by the helper.
Use it only when the brief already fixed the candidate order and every candidate's provider is the harness's primary family.
It does not replace the reasoning-class, runway-feasibility, or authentication gates above.
Firstmate can optionally arm `bin/fm-procevent-quota.sh` for a recurring mid-task check that wakes when the tracked provider drops below its configured threshold or its runway becomes `exhausted_now`.
The opt-in [typed resolver](../../../docs/configuration.md#typed-dispatch-resolution-env-typesafe_api_key) has its own documented gates.
It never removes this skill's authority, and its `ambiguous`, `escalate`, and `error` outcomes return here.

## Explicit captain request on tight quota

When the captain makes an explicit per-task model or harness request, evaluate that provider's applicable quota from the snapshot before dispatching.
If that requested provider has little usable quota left and another configured candidate of an acceptable reasoning class has ample quota, do not silently spend the tight provider.
Surface a concise recommendation pointing out the abundant alternative (such as recommending an Antigravity worker like gemini-3.8-flash-high when an explicit Opus 5.5 request sits on nearly exhausted Claude quota) before launching.
The captain's explicit choice still wins when they insist; never silently override an explicit request.

## Read the default TOON

Start each intake by running `quota-axi` once with no `--json`, and reuse that TOON for every candidate.
Post-consolidation quota-axi (the floor owned by `bin/fm-quota-axi-lib.sh`) puts `spendPriority` in the default `quota[]` block beside `effectivePercentRemaining`, `runway`, `confidence`, `limitedBy`, and `resetsAt`.
Sparse `exhaustion[]` carries finite-runway seconds only for `projected_exhaustion` and `exhausted_now`.
Sparse `attention[]` names auth, stale, and unmeasurable facts.
`spendPriority` provides rate-of-burn economics from headroom, pace, reserve, and reset timing when every comparable candidate has a known scalar, but usable remaining quota and unstarted session windows rank before it.
It already computes the economics that older instructions reconstructed by hand from headroom, pace, reserve, and window-id lists; do not recompute those.
Do not read `--json` on the normal path, and do not reach for `--full` to rebuild that economics.

After reading the TOON, fall back to one `quota-axi --json` call only when that TOON is genuinely ambiguous for the decision, or when the installed quota-axi is somehow below the floor so its TOON lacks `spendPriority`.
Ambiguous means a candidate's `spendPriority` is the literal `unknown` or unmeasurable, candidates have comparable remaining quota where session-window start state must be inspected in `--json`, a real tie still needs extra evidence, or a candidate's eligibility is unclear from `quota[]` plus `attention[]`.
The fallback therefore has an explicit TOON-then-JSON call sequence; reuse its JSON result and do not take any further quota snapshots.
Below-floor is rare: bootstrap enforces `FM_QUOTA_AXI_MIN` and normally reports `MISSING` before dispatch; if an intake somehow reaches an older build whose TOON lacks `spendPriority`, use the defensive `--json` fallback rather than treating the missing scalar as healthy.
`--json` is a defensive belt, not a habit; never reach for it because it feels more complete.
Read `quota-axi auth --json` only when a candidate's credential surface is in question.

For each candidate, preserve explicit `harness`, `model`, and `provider`; `harness-adapters` owns identity, and model/provider never infer harness.

## Three gates, then ranking

Apply the three cheap orthogonal gates first.
Ranking evaluates only candidates that pass all three.
Ranking cannot override a hard-gate failure, and it is never hidden inside a new composite score.

### 1. Eligibility

Outside those documented mappings, deterministic shell must not infer a provider family or credential store from a harness, model, or source name.
You establish the remaining relations yourself, in the open, from the candidate's own authoritative catalog (`harness-adapters` owns the per-harness discovery surface) plus the one intake snapshot.

Confirm the catalog lists the candidate's model and record the provider family it reports.
A model the catalog does not list is concrete contradictory evidence: block that candidate and quote the catalog result.
Apply quota at the granularity the vendor actually supplies.
A provider-level or `all_models`/`all_products` scope bounds every model you established in that family within the candidate's matched account, including one with no window of its own.
A named-model or named-product scope is an additional bound for that model alone.
Match the candidate to its `quota[]` row by that established provider, its `accountKey` when the snapshot is schema 6 (a Pi lane's auth provider id such as `openai-codex-work`, or `codex-home` for native Codex including Pi's `codex-native/` adapter, then the `default` row, else unmeasured; never a row picked by position, never rows summed across accounts), and scope; a stale, auth-required, or unmeasurable scope is named in `attention[]` instead of a fabricated number.

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the candidate actually uses rather than collapsing a provider to a single status.
A provider can carry a healthy source beside a missing or expired one; the unused source's state is not the candidate's state.
A Pi-hosted family may authenticate through the vendor's own store with no `pi:`-prefixed source at all, which is normal and never evidence against the candidate.

Uncertainty and ineligibility are different findings:

- No model-level window, no matching auth source, an unmeasurable or `unknown` scope, or a surface quota-axi does not model at all is disclosed uncertainty.
  Keep the candidate eligible, state the unknown, and let remaining usable quota and fresh session windows decide; unknown `spendPriority` is disclosed uncertainty, never zero, never healthy, and never a default win over a candidate with clearly more remaining quota.
- An expired credential is a short-lived session token the owning vendor renews on next use, not a sign-out.
- Only concrete contradictory evidence blocks: an authoritative catalog proving the model unsupported, or proof that the credential the candidate actually selects is unusable.
- Reserve login wording for that proven-unusable case, and name the harness, model, surface, and evidence.

When a credential's local classification is the only thing standing between a candidate and a block, get ground truth before blocking.
`bin/fm-vendor-auth-probe.sh` is the only approved vendor-credential probe; its `--help` owns the registered probes and mechanics.
It takes no harness, model, or provider and returns a fact, not a route: only `authenticated` and `unauthenticated` are ground truth, while `indeterminate`, `timeout`, and `unavailable` establish nothing and must never be read as either outcome.
Never launch a vendor CLI yourself, and never probe a credential store the candidate does not use.
Grok prepaid `credits` are unrelated to paid-window headroom; never read them as exhaustion.

Malformed configuration is an actionable error, not a candidate to rank around.

### 2. Reasoning-class fit

Keep only candidates that meet the required reasoning class for this task (a simple bug fix versus very-difficult design).
Never use `spendPriority` or remaining quota to silently replace that class.
When every remaining candidate is tight, dispatch inside the strongest-reasoning class if one of those candidates can proceed, or stop and report that the strongest-class choice cannot proceed rather than downgrading it to spend or conserve quota.

### 3. Runway feasibility floor

Known runway that will not last until the inspectable likely-completion horizon fails this gate, even when that candidate has the highest `spendPriority`.
Read `runway` from the `quota[]` row: `through_reset` passes this generic feasibility floor because the window reaches its refill without exhausting; never compare its `resetsAt` with the completion horizon as though reset were an exhaustion deadline.
`exhausted_now` is zero, and `projected_exhaustion` uses the matching `exhaustion[]` row's `usableRunwaySeconds`.
A high `spendPriority` on a nearly empty window that will exhaust soon must not route into a mid-task stall.
Unknown or unmeasurable runway stays eligible with disclosed uncertainty and is never assumed to pass.
Do not invent a generic percentage floor, and honor an explicit captain floor for a candidate when one exists.

## Ranking procedure

Rank only candidates that pass all three hard gates.
Never evaluate ranking before the eligibility, reasoning-class, and runway-feasibility gates pass.
The ranker evaluates three layers in order:

### 1. Usable remaining quota
A candidate with strictly more usable remaining quota wins.
Compare the `effectivePercentRemaining` of the scope that bounds the candidate.
A candidate with strictly higher remaining percentage beats one with less remaining percentage, even when the losing candidate is the only one with a known `spendPriority`.
Unknown `spendPriority` stays disclosed uncertainty: never zero, never healthy, and never a default win over a candidate with clearly more remaining quota.

### 2. Unstarted five-hour or session window
When candidates are otherwise comparable in remaining quota, prefer the candidate whose five-hour or session window has not started yet, so its five-hour clock begins earlier and its reset arrives earlier.
A candidate's five-hour or session window is defined as not started precisely from the quota data when the window of kind `session` (such as `five_hour`, `gemini_5h`, or `claude_gpt_5h`) reports `percentRemaining` at exactly 100 in `--json`, or its bounding session scope in `quota[]` reports 100% remaining with no consumption.
Once any quota has been used in that window, its remaining percentage drops below 100 and its reset countdown is running.
An unstarted window has full 100% capacity and has not yet triggered its reset clock.
The five-hour preference must never select a candidate that is actually near exhaustion or fails the runway-feasibility floor.

### 3. spendPriority
Keep `spendPriority` as the ranker when every remaining candidate has a known comparable scalar.
A higher known scalar is better: positive means paid allowance is on track to reach reset unused, `0` is exact utilization, and negative means overdrawn against the reset clock.
Rank only from comparable known scalars.
Never treat absent, `unknown`, or unmeasurable `spendPriority` as zero or as healthy; `0` means exact utilization, a different claim from unknown.
An unknown `spendPriority` keeps the candidate eligible with disclosed uncertainty, but it never wins over a candidate with clearly more remaining quota or an unstarted session window.

Do not compare headroom against runway by hand.
Do not use pace or signed reserve as a later tie-break layer.
Do not read `aheadWindowIds`, `behindWindowIds`, `onPaceWindowIds`, `limitingWindowIds`, or other window-id lists to reconstruct what `spendPriority` already computed.

### Genuine ties
Genuine ties (candidates with comparable remaining quota, identical session-window start state, and identical or equally missing spendPriority): stop and report every tied candidate for captain choice.
Do not select by array order, harness name, or another arbitrary identity ordering.
Report duplicate concrete profiles as a configuration error.

After the permitted TOON-to-JSON fallback, escalate to Firstmate instead of routing if no candidate can be ranked or runway uncertainty prevents proving the feasibility floor for any candidate that could be selected.
Never resolve that terminal uncertainty by treating unknown as healthy or by choosing arbitrarily.
Show the remaining quota, session-window status, scalar or the literal `unknown` in the rationale; do not hide it in a score.

Account for every candidate visibly before selecting or escalating, naming its catalog evidence, provider relation, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, usable remaining quota (`effectivePercentRemaining`), session-window start state, `spendPriority`, and runway-versus-horizon result.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label.
