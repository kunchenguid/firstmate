---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array from quota-axi's default TOON, ranking by spendPriority after three
  orthogonal gates.
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
Deterministic shell owns only schema, configuration, and version validation plus concrete spawn safeguards; every model-to-provider, provider-to-credential, and quota-applicability relation is yours to establish transparently and to show your evidence for.

## Worker-side quota helper

The canonical shell helper for a worker that has already performed its model-selection reasoning and now needs to pick the first viable candidate is `bin/fm-quota-choose.sh`.
Pass it the intake's already-captured default TOON or permitted JSON fallback through stdin or `--snapshot`; it never takes another quota snapshot, so it selects from the same quota state as the intake.
Pass each candidate as `harness:model`, with earlier candidates preferred.
The helper maps each harness to its primary provider family and applies the provider-wide scopes plus the exact model or product scopes for the model.
An `exhausted_now` runway vetoes the candidate.
The helper selects a candidate only when its applicable quota has a known `effectivePercentRemaining` greater than zero.
This is an optional narrow helper with a known limitation: it maps each harness to one primary provider family only, so a candidate whose established provider differs from that primary family is checked against the wrong quota row.
Authoritative multi-provider routing - including provider discovery from the harness catalog and quota matching by that explicit provider - stays owned by this skill's intake procedure above and AGENTS.md section 4, not by the helper.
Use it only when the brief already fixed the candidate order and every candidate's provider is the harness's primary family.
It does not replace the reasoning-class, runway-feasibility, or authentication gates above.
Firstmate can optionally arm `bin/fm-procevent-quota.sh` for a recurring mid-task check that wakes when the tracked provider drops below its configured threshold or its runway becomes `exhausted_now`.

## Read the default TOON

Start each intake by running `quota-axi` once with no `--json`, and reuse that TOON for every candidate.
Post-consolidation quota-axi (the floor owned by `bin/fm-quota-axi-lib.sh`) puts `spendPriority` in the default `quota[]` block beside `effectivePercentRemaining`, `runway`, `confidence`, `limitedBy`, and `resetsAt`.
Sparse `exhaustion[]` carries finite-runway seconds only for `projected_exhaustion` and `exhausted_now`.
Sparse `attention[]` names auth, stale, and unmeasurable facts.
`spendPriority` is THE quota-perspective ranker.
It already computes the economics that older instructions reconstructed by hand from headroom, pace, reserve, and window-id lists; do not recompute those.
Do not read `--json` on the normal path, and do not reach for `--full` to rebuild that economics.

After reading the TOON, fall back to one `quota-axi --json` call only when that TOON is genuinely ambiguous for the decision, or when the installed quota-axi is somehow below the floor so its TOON lacks `spendPriority`.
Ambiguous means a candidate's `spendPriority` is the literal `unknown` or unmeasurable, a real tie still needs extra evidence, or a candidate's eligibility is unclear from `quota[]` plus `attention[]`.
The fallback therefore has an explicit TOON-then-JSON call sequence; reuse its JSON result and do not take any further quota snapshots.
Below-floor is rare: bootstrap enforces `FM_QUOTA_AXI_MIN` and normally reports `MISSING` before dispatch; if an intake somehow reaches an older build whose TOON lacks `spendPriority`, use the defensive `--json` fallback rather than treating the missing scalar as healthy.
`--json` is a defensive belt, not a habit; never reach for it because it feels more complete.
Read `quota-axi auth --json` only when a candidate's credential surface is in question.

For each candidate, preserve explicit `harness`, `model`, `effort`, `provider`, and optional `home`; `harness-adapters` owns identity, and model/provider never infer harness.

### Candidates that name a Codex home

A codex candidate may carry `home`, the absolute Codex home it runs against, which is how one fleet dispatches across two logged-in Codex accounts (`docs/configuration.md` owns that schema).
`quota-axi` reads exactly one Codex home per invocation, so measure such a candidate with `CODEX_HOME=<candidate.home> quota-axi` as its own default-TOON snapshot.
That is the one sanctioned extra snapshot: take it once per DISTINCT home per intake and reuse it for every candidate naming that home, exactly as the shared intake snapshot is reused for everything else.
A candidate with no `home` keeps using the shared intake snapshot.
The account row from that home's `quota-axi --full` is the evidence that the home resolves to the account you intended, and is the one use of `--full` this skill sanctions: it establishes identity, never the economics `spendPriority` already computed.
An unconfirmable account is disclosed uncertainty, while a home whose own credential quota-axi reports as unusable is concrete evidence against that candidate alone and never against the other home's candidates.
A session-start `CREW_DISPATCH: codex home unavailable: <path>` line carries that same candidate-local weight: eliminate the candidates naming that home and rank the rest normally, rather than treating the array or the dispatch file as unusable.
Rank the surviving candidates by `spendPriority` through the same three gates as any other array, and name each candidate's home beside its `harness` and `model` when you account for it.
`bin/fm-quota-choose.sh` cannot represent per-home candidates, so resolve these yourself rather than passing them to that helper.

## Three gates, then spendPriority

Apply the three cheap orthogonal gates first.
`spendPriority` ranks only among candidates that pass all three.
It cannot override a hard-gate failure, and it is never hidden inside a new composite score.

### 1. Eligibility

Deterministic shell must never map a model to a provider, a provider to a credential store, or a name prefix to a family.
You establish those relations yourself, in the open, from the candidate's own authoritative catalog (`harness-adapters` owns the per-harness discovery surface) plus the one intake snapshot.

Confirm the catalog lists the candidate's model and record the provider family it reports.
A model the catalog does not list is concrete contradictory evidence: block that candidate and quote the catalog result.
Apply quota at the granularity the vendor actually supplies.
A provider-level or `all_models`/`all_products` scope bounds every model you established in that family, including one with no window of its own.
A named-model or named-product scope is an additional bound for that model alone.
Match the candidate to its `quota[]` row by that established provider and scope; a stale, auth-required, or unmeasurable scope is named in `attention[]` instead of a fabricated number.

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the candidate actually uses rather than collapsing a provider to a single status.
A provider can carry a healthy source beside a missing or expired one; the unused source's state is not the candidate's state.
A Pi-hosted family may authenticate through the vendor's own store with no `pi:`-prefixed source at all, which is normal and never evidence against the candidate.

Uncertainty and ineligibility are different findings:

- No model-level window, no matching auth source, an unmeasurable or `unknown` scope, or a surface quota-axi does not model at all is disclosed uncertainty.
  Keep the candidate eligible, state the unknown, and prefer known viable evidence when otherwise comparable.
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

## Rank by spendPriority

Among candidates that pass all three gates, pick the highest known `spendPriority`.
A higher known scalar is better: positive means paid allowance is on track to reach reset unused, `0` is exact utilization, and negative means overdrawn against the reset clock.
Rank only from comparable known scalars.
Never treat absent, `unknown`, or unmeasurable `spendPriority` as zero or as healthy; `0` means exact utilization, a different claim from unknown.
An unknown `spendPriority` keeps the candidate eligible with disclosed uncertainty.
Prefer known viable evidence when otherwise comparable.
After the permitted TOON-to-JSON fallback, escalate to Firstmate instead of routing if no candidate can be ranked or runway uncertainty prevents proving the feasibility floor for any candidate that could be selected.
Never resolve that terminal uncertainty by treating unknown as healthy or by choosing arbitrarily.
Show the scalar or the literal `unknown` in the rationale; do not hide it in a score.

Do not compare headroom against runway by hand.
Do not use pace or signed reserve as a later tie-break layer.
Do not read `aheadWindowIds`, `behindWindowIds`, `onPaceWindowIds`, `limitingWindowIds`, or other window-id lists to reconstruct what `spendPriority` already computed.

Genuine ties: stop and report every tied candidate for captain choice.
Do not select by array order, harness name, or another arbitrary identity ordering.
Report duplicate concrete profiles as a configuration error.

Account for every candidate visibly before selecting or escalating, naming its catalog evidence, provider relation, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, `spendPriority`, and runway-versus-horizon result.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a bare `Grok unauthenticated` statement.
Never conclude with an unexplained "best quota" label.
After selecting, pass the winning candidate's concrete `harness`, `model`, and `effort` as `--harness`, `--model`, and `--effort`, and pass its `home` as `--codex-home` when present.
