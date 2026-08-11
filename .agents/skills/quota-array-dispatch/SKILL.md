---
name: quota-array-dispatch
description: >-
  Agent-only decision procedure for resolving a matched crew-dispatch profile
  array through subscription-aware routing, provider identity, capacity evidence,
  reserve, cooldown, and deterministic rotation boundaries.
  Load when a dispatch rule or default resolves to more than one profile candidate.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is the single owner of the judgment boundary around subscription-aware profile-array selection.
`bin/fm-dispatch-select.mjs` owns the exact telemetry, reserve, cooldown, state, and deterministic rotation mechanics.
`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`quota-axi` remains data-only and never recommends a route.
Do not add a daemon, opaque composite score, hard-coded model-specific policy, or producer-side route recommendation.

## Collect facts

Establish model support and provider identity through the discovery surface owned by `harness-adapters` before selection.
The verified native `claude`, `codex`, and `grok` adapters establish their same-named subscription provider without a redundant profile field.
Every non-native adapter needs an explicit `provider` field when it enters subscription-aware selection, because model spelling never proves provider identity.
For each candidate, preserve explicit `harness`, `model`, and `provider` where present, then account for:

- task/profile fit and required reasoning class
- whether it belongs to the task's required fit and strongest acceptable reasoning class
- whether the native or explicitly declared provider relationship is established
- whether the candidate may be handed to the selector without silently changing model, harness, or effort

Do not pass a weaker reasoning class merely because it has more quota.
Do not pass a candidate whose provider relationship or current model support remains unresolved.

## Authentication is scoped to the selected surface

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the candidate actually uses rather than collapsing a provider to a single status.
When a credential's local classification is the only thing standing between a candidate and a block, get ground truth before blocking.
`bin/fm-vendor-auth-probe.sh` is the only approved vendor-credential probe; its `--help` owns the registered probes and mechanics.
It takes no harness, model, or provider and returns a fact, not a route: only `authenticated` and `unauthenticated` are ground truth, while `indeterminate`, `timeout`, and `unavailable` establish nothing and must never be read as either outcome.
Never launch a vendor CLI yourself, and never probe a credential store the candidate does not use.

## Subscription evidence

Providers exposed by quota-axi, including Claude, Codex, and Grok, require fresh telemetry within the configured maximum age and a tightest live percentage strictly above `reservePercent`.
Stale, unavailable, malformed, or windowless telemetry makes that provider ineligible for a new dispatch.
Kimi is excluded from subscription-aware selection because its 0.29.1 lifecycle exit was not deterministic after interrupt in the guarded Herdr lab.
Do not pass a Kimi profile to the selector or substitute another Moonshot route.
The exact defaults, bounds, state schema, failure exit, and test seams are owned by `bin/fm-dispatch-select.mjs --help` and the canonical config schema in `docs/configuration.md`.

## Selection order

Apply only among candidates satisfying required fit and strongest reasoning class.
Never use subscription state to silently replace that reasoning class.

1. Reduce the matched rule or default to comparable candidates after model/provider discovery.
2. Pass that exact object or array to `FM_HOME=<active-home> bin/fm-dispatch-select.mjs select`.
3. Read its sanitized per-provider diagnostics and selected JSON profile.
4. Pass the selected `harness`, `provider`, `model`, and `effort` axes to `fm-spawn.sh`; it records `provider` as routing evidence without forwarding it to the harness CLI.
5. If it exits 3, stop and report that no candidate has current dispatch-capacity evidence rather than choosing manually around the reserve, cooldown, or telemetry refusal.
6. If a running task with recorded routing-provider metadata records provider rate-limit or quota-exhaustion evidence in its status log, run `fm-dispatch-select.mjs record-failure --provider <provider> --task <id>` before retrying the candidate set.
7. Use `clear --provider <provider>` only after the credential or provider condition is known to be corrected; it clears the cooldown, not dispatch history.

The selector accounts for every provider in sanitized diagnostics, rejects duplicate profiles, distributes eligible subscriptions by persisted least-recent use, and breaks an initial never-used tie with a home-stable hash independent of candidate array order.
Do not replace that stateful choice with static array order, harness-name order, randomness, or an unexplained "best quota" label.
Another harness CLI cannot block the selected tuple's authentication check.
