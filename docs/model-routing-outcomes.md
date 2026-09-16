# Model-routing outcome measurement

`bin/fm-routing-outcomes.py` adds receipt-backed measurement to existing Firstmate tasks without becoming a dispatcher, scheduler, quota provider, grader, or task lifecycle.
It records one task-linked attempt at a time, records explicitly heuristic shadow suggestions separately, and renders a compact descriptive scorecard.
Each record is bound to the existing task's current `spawn_gen` incarnation and metadata digest, while quota-axi remains the allowance source and `quota-array-dispatch` remains the routing decision owner.

## Rollout boundary

This slice supports two independent stages.

1. In `measurement`, import native receipts and verify attribution, token accounting, timing, grading, pricing, and replay behavior without changing the route selected for work.
2. In `shadow`, record a human or Firstmate route suggestion with optional raw quota context, but do not execute the suggestion or call it verified.
The importer itself never launches or switches a model.
Bounded routing remains deferred until external evidence verifies quota, capability, a genuinely different allowance pool, and safe handoff.
The committed tool never claims bounded readiness.
The approved model-category matrix remains private policy and is not committed or activated by this measurement slice.
Category labels and shadow judgments are descriptive and heuristic, so they never establish routing eligibility.

Initial paired comparisons are limited mechanically to two distinct low-risk pair identifiers per category in one outcome store.
A comparison manifest must state that the work is non-time-critical, has no private external action, and performs no external action.
A handoff manifest admits one distinct alternative attempt and requires explicit quality, privacy, and side-effect reconciliation evidence.
These records do not make an external-action task safe by assertion; such tasks stay outside the initial comparison set.

## Durable records

The default append-only stores are private and gitignored:

- `data/model-routing/outcomes.jsonl` holds full attempt revisions.
- `data/model-routing/shadow-decisions.jsonl` holds full shadow-decision revisions.

`FM_DATA_OVERRIDE` relocates both with the rest of the effective home.
`--store` and `--shadow-store` provide explicit locations for fixtures and intentionally separate evidence sets.
Legacy dispatch history remains with its existing owner and is not imported by this tool.

An import hashes its normalized record.
It also requires the named task's current authoritative `state/<task-id>.meta` record and exact `spawn_gen`, preventing telemetry from silently attaching to a reused task identifier.
Replaying an identical attempt is a no-op, while a changed attempt appends a new revision under the same task-incarnation and attempt identity.
Reusing a task identifier under a new `spawn_gen` creates a separate durable identity and observation.
Readers fold only the newest revision, so a restart, resume, or corrected grade does not duplicate the attempt.
A whole native session receipt cannot be attached to a second attempt, which prevents its tokens and cost from being counted twice.
Writers serialize and fsync each append.

The script header and `--help` own the manifest fields and command syntax.
Use `inspect --task <id>` for the folded machine record and `scorecard --format json` for stable machine output.
The default scorecard is Markdown.

## Native receipt boundary

The importer copies route, timing, token, usage, and completeness facts only.
It does not copy prompt text, response text, tool arguments, credentials, or provider headers from a source receipt.
Each imported source is bound by SHA-256.
A missing native field remains JSON `null` and contributes to the scorecard's unknown count rather than becoming zero.

Supported source shapes are:

- `pi-session` reads Pi v3 JSONL assistant usage and the sanitized `fm-routing-request` custom entry emitted by a Firstmate-spawned Pi worker.
- `claude-result` reads Claude Code `--output-format json`, including every native `modelUsage` row so an auxiliary model is not silently omitted.
- `claude-session` folds the latest copy of each native assistant message identifier in Claude Code JSONL, avoiding duplicate streaming snapshots.
- `agy-result` reads agy `--output-format json`; an optional native log proves only the selected model label and its low, medium, or high variant.

A Firstmate-spawned Pi worker writes one sanitized custom entry immediately before each provider request.
The entry contains the task identifier, task `spawn_gen`, request sequence, timestamp, selected provider/model/thinking level/API, final payload model, and final payload reasoning effort.
It contains no other payload field.
That final-payload evidence can enforce an `effective_effort` requirement rather than trusting requested launch metadata.
The associated assistant message remains Pi's native response/usage receipt.

Claude Code's current result and session receipts do not prove effective reasoning effort.
The importer therefore preserves requested effort and leaves effective effort unknown.
Agy's one-shot result gives native usage, and its native selected-model log can prove a named effort variant, while the current interactive conversation store is not treated as a prompt-safe portable receipt.
These limitations remain visible in `native.completeness` and in scorecard uncertainty.
A Pi session with mixed or partially missing task, incarnation, model, effort, provider, or API evidence is rejected instead of pooling its usage into one exact route.
A Claude session with mixed or partially missing assistant-model or session evidence is rejected, while a Claude result may retain separately itemized auxiliary-model usage.
When a Claude result contains multiple models, the scorecard labels its combined usage as a whole-session multi-model observation rather than assigning every token to the requested main model.
Multiple turns using the same native model and provider remain one exact attempt route.
The manifest harness must agree with the task metadata and receipt kind, and its provider must agree with native provider evidence when present.
Only Pi receipts carrying the task identifier and `spawn_gen` may certify an accepted outcome.
Claude and agy receipts remain useful raw measurements, but their task attribution and outcome stay unresolved operator observations.

Token categories retain the native source's accounting.
Reasoning tokens are reported separately but never added on top of output tokens for cost calculations, because the price catalog contract requires `reasoning: included_in_output`.
Cache reads and cache writes remain separate.
A receipt with a missing category yields unknown for that aggregate rather than a fabricated zero.

## Time and grading

The manifest records task start and finish plus observable queue, model, tool, review, retry, handoff, and human durations.
Each attempt's end-to-end duration is computed from its timestamp pair rather than from model time alone.
The scorecard reports each attempt separately.
Complete accepted-journey time and cost across task incarnations or handoffs are deferred rather than reconstructed from incomplete lineage.
Native API duration is retained separately where a tool emits it.

An accepted outcome requires an independent deterministic or blind-review grade, a final pass, explicit task acceptance criteria, a separately identified grader or check, and hashed structured check artifacts covering every criterion.
Each check artifact is bound to the task identifier, `spawn_gen`, attempt identifier, and SHA-256 of the normalized acceptance criteria.
The implementation route cannot self-assert acceptance by setting an outcome string alone.
First-pass result, final result, defect count, fix count, retry count, grader duration, grader tokens, and grader incremental charge stay explicit.
The scorecard retains those supplied grader facts but does not claim a complete model-grader or accepted-task efficiency total.
The importer does not create a second full review pipeline; callers attach the ordinary task's actual check receipts and use limited blind review only where subjective grading requires it.

## Cost and allowance attribution

Three money concepts remain separate:

- `actual_incremental_usd` is an observed charge supplied by the caller.
- `fixed_subscription_usd` is a fixed expense supplied by the caller and is reported only as distinct contextual values, never summed or converted into a per-task charge.
- `api_equivalent_usd` is computed only from a private `fm-routing-prices.v1` catalog.

A price entry must match provider, exact model, context tier, service tier, and the attempt timestamp.
It must name a timestamped HTTPS source and explicit input, output, cache-read, and cache-write rates in USD per million tokens.
Every native model row must match exactly or the attempt's API-equivalent cost remains unknown.
Provider-reported list-cost fields are retained as native evidence but never promoted into executable API-equivalent billing without that catalog match.

Quota inputs are native quota-axi schema-version-5 snapshots taken before and after the attempt.
The importer retains the selected provider's literal windows and normalized semantics.
It computes a per-window consumption delta only when reset identity is unchanged, concurrent activity is explicitly absent, and attribution is exclusive.
It never sums shared and model-window deltas, converts allowance percentages to dollars, relabels unresolved windows, or treats unknown authentication/headroom as zero.
A shadow candidate may attach one raw dated quota-axi provider snapshot.
The tool displays its literal windows and semantics beside separately labeled heuristic eligibility, runway, and spend judgments without inferring provider-family mappings or verifying the recommendation.

## Scorecard interpretation

The scorecard groups attempt-route observations by category, task shape, harness, provider, effective model, effective effort, authentication category, context tier, and service tier.
When effective model or effort is unavailable, the route uses an explicit `requested-only:` label that is never pooled with observed route evidence.
Multi-model native results use an explicit whole-session label.
Task count reports unique task IDs, while task-incarnation count separately reports observed lifecycle incarnations.
The scorecard includes sample counts, outcomes, known execution token/cost/time totals, unknown counts, and an individual observation for every task incarnation and attempt.
Each individual observation includes its raw before/after quota snapshots, native semantics status, attempt bracketing, attribution, concurrency, reset caveats, and supported per-window delta in JSON, plus a concise non-aggregated rendering in Markdown.
Quota windows are never summed into route or task totals because they may overlap.
It also prints each heuristic shadow suggestion, raw quota context when present, and the recorded eligibility, capability-class fit, runway, spend priority, explanation, and uncertainty.

The scorecard is descriptive.
It deliberately has no opaque weighted score and does not claim a statistical winner from a few heterogeneous tasks.
Capability class and task fit remain routing gates rather than benchmark conclusions.

## Verification

Run the focused behavior suite with:

```sh
tests/fm-routing-outcomes.test.sh
```

The suite covers missing provider telemetry, refreshable-auth uncertainty, unresolved raw allowance windows, actual zero allowance, reset and concurrency boundaries, duplicate import/resume, whole-session receipt reuse, exact price matching, multi-model labeling, non-Pi outcome attribution, one-alternative handoff, comparison limits, independent grading, and heuristic shadow context.
`tests/fm-spawn-dispatch-profile.test.sh` verifies that a spawned Pi extension writes only the sanitized request-receipt fields.
